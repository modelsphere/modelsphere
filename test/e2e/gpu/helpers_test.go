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
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

// verbose is E2E_VERBOSE: print helm releases, pods and chat answers as the
// specs pass. Off by default; failures dump the cluster state either way.
var verbose = os.Getenv("E2E_VERBOSE") == "1" || os.Getenv("E2E_VERBOSE") == "true"

const apiTimeout = 60 * time.Second

func show(title, out string) {
	if verbose {
		_, _ = fmt.Fprintf(GinkgoWriter, "\n--- %s\n%s\n", title, strings.TrimRight(out, "\n"))
	}
}

func showHTTP(title string, code int, body string) {
	if len(body) > 400 {
		body = body[:400] + "..."
	}
	show(fmt.Sprintf("%s -> %d", title, code), body)
}

func showKubectl(title string, args ...string) {
	if verbose {
		out, err := kubectl(args...)
		if err != nil {
			out += "\nerror: " + err.Error()
		}
		show(title, out)
	}
}

// deployModel plans and installs the configured variant through swissd, then
// waits until the release is ready and its ModelRoute is Ready. Readiness
// includes the engine startup probe, which for a real weight download is
// E2E_MODEL_TIMEOUT (default 90m, the catalog variant's own probe budget).
func deployModel(token string) {
	rel := cfg.release
	By(fmt.Sprintf("planning %s variant %s as %s/%s", cfg.model, cfg.variant, cfg.namespace, rel))
	plan := map[string]any{
		"model":           cfg.model,
		"variant":         cfg.variant,
		"release":         rel,
		"namespace":       cfg.namespace,
		"serviceId":       rel,
		"createNamespace": true,
	}
	// Empty gpuProducts does not pin a product: the variant's requires.gpus
	// still sets the GPU count. Sending the field is opt-in (E2E_GPU_PRODUCTS)
	// and uses the profile's gpuProductAliases. forceGpuProducts is only sent
	// together with a product list; swiss 0.7.2 has no gpuResource field.
	if len(cfg.gpuProducts) > 0 {
		plan["gpuProducts"] = cfg.gpuProducts
		if cfg.forceGPU {
			plan["forceGpuProducts"] = true
		}
	}
	var planned struct {
		Hash string `json:"hash"`
	}
	mustAPI(token, http.MethodPost, "/api/plans", plan, &planned)
	Expect(planned.Hash).NotTo(BeEmpty())

	By("installing with backend " + cfg.backend)
	var installed struct {
		Status      string `json:"status"`
		StatusError string `json:"statusError"`
	}
	mustAPI(token, http.MethodPost, "/api/install", map[string]string{
		"planHash": planned.Hash, "applyWith": cfg.backend,
	}, &installed)
	Expect(installed.Status).To(Equal("applied"), installed.StatusError)

	By("waiting for the release to be ready")
	Eventually(func(g Gomega) {
		var st struct {
			Ready int    `json:"ready"`
			Total int    `json:"total"`
			Route string `json:"route"`
		}
		code, body := call(http.MethodGet, fmt.Sprintf("%s/api/releases/%s/%s/status", swissd.base(), cfg.namespace, rel), token, "", nil, &st)
		g.Expect(code).To(Equal(http.StatusOK), body)
		g.Expect(st.Total).To(BeNumerically(">", 0))
		g.Expect(st.Ready).To(Equal(st.Total))
		g.Expect(st.Route).To(Equal(rel))
	}).WithTimeout(cfg.modelTimeout).WithPolling(10 * time.Second).Should(Succeed())

	Eventually(func(g Gomega) {
		out, err := kubectl("-n", cfg.namespace, "get", "modelroute", rel,
			"-o", `jsonpath={.status.conditions[?(@.type=="Ready")].status}`)
		g.Expect(err).NotTo(HaveOccurred(), out)
		g.Expect(out).To(Equal("True"))
	}).WithTimeout(cfg.readyTimeout).WithPolling(2 * time.Second).Should(Succeed())
	showKubectl(rel+" objects", "-n", cfg.namespace, "get", "llmservices,modelroutes,deploy,pods", "-o", "wide")
}

// removeModel uninstalls through swissd and waits until nothing named after
// the release remains. A 404 is a deploy that never created a release.
// The default variant's terminationGracePeriodSeconds is 1200, so the wait
// is E2E_GONE_TIMEOUT (default 30m) rather than the kind suite's few minutes.
func removeModel(token string) {
	rel := cfg.release
	By("uninstalling " + rel)
	code, body := call(http.MethodDelete, fmt.Sprintf("%s/api/releases/%s/%s", swissd.base(), cfg.namespace, rel), token, "", nil, nil)
	Expect(code).To(BeElementOf(http.StatusOK, http.StatusNotFound), body)
	Eventually(func(g Gomega) {
		out, err := kubectl("-n", cfg.namespace, "get", "deploy,sts,svc,pods,llmservices,modelroutes,llmscalers", "-o", "name")
		// A deploy that failed before creating the namespace has nothing to wait for.
		if err != nil && strings.Contains(out, "NotFound") {
			return
		}
		g.Expect(err).NotTo(HaveOccurred(), out)
		for _, obj := range nonEmptyLines(out) {
			name := obj[strings.LastIndex(obj, "/")+1:]
			g.Expect(name == rel || strings.HasPrefix(name, rel+"-")).To(BeFalse(), "%s is still there", obj)
		}
	}).WithTimeout(cfg.goneTimeout).WithPolling(5 * time.Second).Should(Succeed())
}

// assertGPU checks the model pods request and limit nvidia.com/gpu, and that
// the node they landed on advertises at least that many allocatable GPUs.
// The vllm chart writes the resource into limits only; the apiserver copies
// an omitted request from the limit, so a pod that has limits and no requests
// has not been through admission.
func assertGPU() {
	rel := cfg.release
	out, err := kubectl("-n", cfg.namespace, "get", "pods", "-l", "app="+rel+"-vllm", "-o", "json")
	Expect(err).NotTo(HaveOccurred(), out)
	pods := decodePods(out)
	if len(pods.Items) == 0 {
		out = mustKubectl("-n", cfg.namespace, "get", "pods", "-o", "json")
		all := decodePods(out)
		for _, p := range all.Items {
			name := p.Metadata.Name
			if name == rel || strings.HasPrefix(name, rel+"-") {
				pods.Items = append(pods.Items, p)
			}
		}
	}
	Expect(pods.Items).NotTo(BeEmpty(), "no pods for release %s", rel)

	for _, p := range pods.Items {
		Expect(p.Status.Phase).To(Equal("Running"), "pod %s phase %s", p.Metadata.Name, p.Status.Phase)
		Expect(p.Spec.NodeName).NotTo(BeEmpty(), "pod %s has no node", p.Metadata.Name)
		var saw bool
		for _, c := range p.Spec.Containers {
			req := qty(c.Resources.Requests[gpuResource])
			lim := qty(c.Resources.Limits[gpuResource])
			if req == 0 && lim == 0 {
				continue
			}
			Expect(lim).To(BeNumerically(">=", cfg.gpuCount),
				"pod %s container %s limits[%s]=%q", p.Metadata.Name, c.Name, gpuResource, c.Resources.Limits[gpuResource])
			Expect(req).To(BeNumerically(">=", cfg.gpuCount),
				"pod %s container %s requests[%s]=%q (limits %q)", p.Metadata.Name, c.Name, gpuResource,
				c.Resources.Requests[gpuResource], c.Resources.Limits[gpuResource])
			saw = true
		}
		Expect(saw).To(BeTrue(), "pod %s does not request %s", p.Metadata.Name, gpuResource)

		alloc := mustKubectl("get", "node", p.Spec.NodeName, "-o",
			`jsonpath={.status.allocatable['nvidia.com/gpu']}`)
		Expect(qty(alloc)).To(BeNumerically(">=", cfg.gpuCount),
			"node %s allocatable %s=%q", p.Spec.NodeName, gpuResource, alloc)
	}
	showKubectl("gpu pods", "-n", cfg.namespace, "get", "pods", "-o", "wide")
}

type podList struct {
	Items []podItem `json:"items"`
}

type podItem struct {
	Metadata struct {
		Name string `json:"name"`
	} `json:"metadata"`
	Spec struct {
		NodeName   string `json:"nodeName"`
		Containers []struct {
			Name      string `json:"name"`
			Resources struct {
				Requests map[string]string `json:"requests"`
				Limits   map[string]string `json:"limits"`
			} `json:"resources"`
		} `json:"containers"`
	} `json:"spec"`
	Status struct {
		Phase string `json:"phase"`
	} `json:"status"`
}

func decodePods(raw string) podList {
	var list podList
	Expect(json.Unmarshal([]byte(raw), &list)).To(Succeed())
	return list
}

func secretValue(ns, name, key string) string {
	out := mustKubectl("-n", ns, "get", "secret", name, "-o", "jsonpath={.data."+key+"}")
	b, err := base64.StdEncoding.DecodeString(out)
	Expect(err).NotTo(HaveOccurred())
	Expect(b).NotTo(BeEmpty(), "secret %s/%s has no %s", ns, name, key)
	return string(b)
}

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
// ones, and Go does not retry a DELETE that hits the closed socket.
var httpClient = &http.Client{Transport: &http.Transport{DisableKeepAlives: true}}

func call(method, target, token, ctype string, body io.Reader, out any) (int, string) {
	return callTimeout(apiTimeout, method, target, token, ctype, body, out)
}

func callTimeout(d time.Duration, method, target, token, ctype string, body io.Reader, out any) (int, string) {
	ctx, cancel := context.WithTimeout(context.Background(), d)
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

type chatMessage struct {
	Content          string `json:"content"`
	ReasoningContent string `json:"reasoning_content"`
}

func (m chatMessage) text() string {
	if strings.TrimSpace(m.Content) != "" {
		return m.Content
	}
	return m.ReasoningContent
}

type chatResponse struct {
	Choices []struct {
		Message chatMessage `json:"message"`
	} `json:"choices"`
}

func chatBody() map[string]any {
	return map[string]any{
		"model":      cfg.servedName,
		"max_tokens": 64,
		"messages":   []map[string]string{{"role": "user", "content": "Reply with the word pong."}},
		// Qwen3 thinks by default. This is a vLLM request field; with it off
		// the reply is in message.content. reasoning_content is still accepted.
		"chat_template_kwargs": map[string]any{"enable_thinking": false},
	}
}

// postChat posts one completion. bearer is the openresty key when the env
// set one; the gpu environment leaves openresty auth off, so it is empty.
func postChat(target, bearer string) (int, string, chatResponse) {
	var chat chatResponse
	code, body := callTimeout(cfg.chatTimeout, http.MethodPost, target, bearer, "application/json", jsonBody(chatBody()), &chat)
	return code, body, chat
}
