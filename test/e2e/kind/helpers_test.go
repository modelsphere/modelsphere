//go:build e2e

package e2e

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

// Helpers for the specs in e2e_test.go.

// apiKey is openresty's API key in the kind environment
// (llmGateway.openrestyOverrides.secret in environments/kind.yaml).
const apiKey = "sk-e2e-kind"

// verbose is E2E_VERBOSE: print core step outputs (helm releases, pods,
// cilium-dbg status, model objects, openresty answers) as the specs pass.
// Off by default; failures dump the cluster state either way.
var verbose = os.Getenv("E2E_VERBOSE") == "1" || os.Getenv("E2E_VERBOSE") == "true"

// show prints a step's output when verbose. With -ginkgo.v (the Makefile
// default) GinkgoWriter is streamed to stdout as it is written.
func show(title, out string) {
	if verbose {
		_, _ = fmt.Fprintf(GinkgoWriter, "\n--- %s\n%s\n", title, strings.TrimRight(out, "\n"))
	}
}

// showHTTP prints an HTTP answer's status and the start of its body.
func showHTTP(title string, code int, body string) {
	if len(body) > 400 {
		body = body[:400] + "..."
	}
	show(fmt.Sprintf("%s -> %d", title, code), body)
}

// showKubectl prints a kubectl command's output when verbose.
func showKubectl(title string, args ...string) {
	if verbose {
		out, err := kubectl(args...)
		if err != nil {
			out += "\nerror: " + err.Error()
		}
		show(title, out)
	}
}

// deployModel plans and installs the mock model with swissd, then waits for
// its pod and its ModelRoute.
func deployModel(token, backend, rel string) {
	By(fmt.Sprintf("[%s] planning %s as %s/%s", backend, cfg.model, modelNS, rel))
	var planned struct {
		Hash string `json:"hash"`
	}
	// Nothing creates the model namespace beforehand: swissd, installed at
	// cluster scope, creates it on install.
	mustAPI(token, http.MethodPost, "/api/plans", map[string]any{
		"model": cfg.model, "release": rel, "namespace": modelNS, "serviceId": rel,
		"createNamespace": true,
	}, &planned)
	Expect(planned.Hash).NotTo(BeEmpty())

	By("[" + backend + "] installing")
	var installed struct {
		Status      string `json:"status"`
		StatusError string `json:"statusError"`
	}
	mustAPI(token, http.MethodPost, "/api/install", map[string]string{
		"planHash": planned.Hash, "applyWith": backend,
	}, &installed)
	Expect(installed.Status).To(Equal("applied"), installed.StatusError)

	By("[" + backend + "] waiting for the release to be ready")
	Eventually(func(g Gomega) {
		var st struct {
			Ready int    `json:"ready"`
			Total int    `json:"total"`
			Route string `json:"route"`
		}
		code, body := call(http.MethodGet, fmt.Sprintf("%s/api/releases/%s/%s/status", swissd.base(), modelNS, rel), token, "", nil, &st)
		g.Expect(code).To(Equal(http.StatusOK), body)
		g.Expect(st.Total).To(BeNumerically(">", 0))
		g.Expect(st.Ready).To(Equal(st.Total))
		g.Expect(st.Route).To(Equal(rel))
	}).WithTimeout(readyTimeout).WithPolling(5 * time.Second).Should(Succeed())

	Eventually(func(g Gomega) {
		out, err := kubectl("-n", modelNS, "get", "modelroute", rel,
			"-o", `jsonpath={.status.conditions[?(@.type=="Ready")].status}`)
		g.Expect(err).NotTo(HaveOccurred(), out)
		g.Expect(out).To(Equal("True"))
	}).WithTimeout(readyTimeout).WithPolling(2 * time.Second).Should(Succeed())
	showKubectl("["+backend+"] "+rel+" objects", "-n", modelNS, "get", "llmservices,modelroutes,deploy,pods", "-o", "wide")
	showKubectl("["+backend+"] modelroute "+rel+" status", "-n", modelNS, "get", "modelroute", rel, "-o", "jsonpath={.status}")
}

// removeModel uninstalls through swissd and waits for its objects to go. A
// 404 is fine: a deploy that failed early may have left nothing to remove.
func removeModel(token, rel string) {
	By("uninstalling " + rel)
	code, body := call(http.MethodDelete, fmt.Sprintf("%s/api/releases/%s/%s", swissd.base(), modelNS, rel), token, "", nil, nil)
	Expect(code).To(BeElementOf(http.StatusOK, http.StatusNotFound), body)
	Eventually(func(g Gomega) {
		out, err := kubectl("-n", modelNS, "get", "deploy,svc,pods,llmservices,modelroutes,llmscalers", "-o", "name")
		g.Expect(err).NotTo(HaveOccurred(), out)
		for _, obj := range nonEmptyLines(out) {
			name := obj[strings.LastIndex(obj, "/")+1:]
			g.Expect(name == rel || strings.HasPrefix(name, rel+"-")).To(BeFalse(), "%s is still there", obj)
		}
	}).WithTimeout(goneTimeout).WithPolling(3 * time.Second).Should(Succeed())
}

func secretValue(ns, name, key string) string {
	out := mustKubectl("-n", ns, "get", "secret", name, "-o", "jsonpath={.data."+key+"}")
	b, err := base64.StdEncoding.DecodeString(out)
	Expect(err).NotTo(HaveOccurred())
	Expect(b).NotTo(BeEmpty(), "secret %s/%s has no %s", ns, name, key)
	return string(b)
}

// mustAPI calls swissd and expects 200.
func mustAPI(token, method, path string, in, out any) {
	var body io.Reader
	ctype := ""
	if in != nil {
		body, ctype = jsonBody(in), "application/json"
	}
	code, text := call(method, swissd.base()+path, token, ctype, body, out)
	ExpectWithOffset(1, code).To(Equal(http.StatusOK), "%s %s: %s", method, path, text)
}

// httpClient opens a connection per request. kubectl port-forward drops idle
// ones, and Go does not retry a DELETE that hits the closed socket (seen: EOF
// on the uninstall after a minute without a swissd call).
var httpClient = &http.Client{Transport: &http.Transport{DisableKeepAlives: true}}

// call does one HTTP request and decodes a 2xx JSON body into out when given.
func call(method, target, token, ctype string, body io.Reader, out any) (int, string) {
	ctx, cancel := context.WithTimeout(context.Background(), apiTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, method, target, body)
	ExpectWithOffset(1, err).NotTo(HaveOccurred())
	if ctype != "" {
		req.Header.Set("Content-Type", ctype)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return 0, err.Error()
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	if out != nil && resp.StatusCode/100 == 2 {
		ExpectWithOffset(1, json.Unmarshal(b, out)).To(Succeed(), string(b))
	}
	return resp.StatusCode, string(b)
}

func jsonBody(v any) io.Reader {
	b, err := json.Marshal(v)
	ExpectWithOffset(1, err).NotTo(HaveOccurred())
	return bytes.NewReader(b)
}

type modelList struct {
	Data []struct {
		ID string `json:"id"`
	} `json:"data"`
}

func (m modelList) ids() []string {
	var ids []string
	for _, d := range m.Data {
		ids = append(ids, d.ID)
	}
	return ids
}

func chatRequest(model, content string) map[string]any {
	return map[string]any{
		"model":    model,
		"messages": []map[string]string{{"role": "user", "content": content}},
	}
}

type chatResponse struct {
	Choices []struct {
		Message struct {
			Content string `json:"content"`
		} `json:"message"`
	} `json:"choices"`
}

func messagesRequest(content string) map[string]any {
	return map[string]any{
		"max_tokens": 16,
		"messages":   []map[string]string{{"role": "user", "content": content}},
	}
}

type response struct {
	code        int
	ctype, body string
}

// post sends a JSON body to openresty with the API key and extra headers.
func post(target string, body any, headers map[string]string) response {
	ctx, cancel := context.WithTimeout(context.Background(), apiTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, target, jsonBody(body))
	ExpectWithOffset(1, err).NotTo(HaveOccurred())
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+apiKey)
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return response{body: err.Error()}
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return response{code: resp.StatusCode, ctype: resp.Header.Get("Content-Type"), body: string(b)}
}

// burst sends n chat requests at once and returns their status codes.
func burst(target string, n int, headers map[string]string) []int {
	codes := make([]int, n)
	var wg sync.WaitGroup
	for i := range n {
		wg.Add(1)
		go func() {
			defer wg.Done()
			defer GinkgoRecover()
			codes[i] = post(target, chatRequest(cfg.model, fmt.Sprintf("burst %d", i)), headers).code
		}()
	}
	wg.Wait()
	return codes
}
