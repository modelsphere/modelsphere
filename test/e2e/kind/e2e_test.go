//go:build e2e

package e2e

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const (
	apiTimeout   = 60 * time.Second
	readyTimeout = 5 * time.Minute
	goneTimeout  = 3 * time.Minute
)

var _ = Describe("stack", Ordered, func() {
	AfterEach(func() {
		if CurrentSpecReport().Failed() {
			dumpClusterState(CurrentSpecReport().FullText())
		}
	})

	// The releases environments/kind.yaml leaves on.
	DescribeTable("has the release deployed",
		func(namespace, release string) {
			out, err := helm("status", release, "-n", namespace, "-o", "json")
			Expect(err).NotTo(HaveOccurred(), out)
			var st struct {
				Info struct {
					Status string `json:"status"`
				} `json:"info"`
			}
			Expect(json.Unmarshal([]byte(out), &st)).To(Succeed())
			Expect(st.Info.Status).To(Equal("deployed"))
		},
		Entry(nil, routeNS, "openresty"),
		Entry(nil, routeNS, "autoconfig"),
		Entry(nil, routeNS, "bodylog"),
		Entry(nil, routeNS, "bodylog-exporter"),
		Entry(nil, routeNS, "bodylog-victorialogs"),
		Entry(nil, operatorNS, "llmscaleoperator"),
		Entry(nil, sloNS, "llm-slo"),
		Entry(nil, consoleNS, "swissd"),
		Entry(nil, consoleNS, "console"),
	)

	// Only in the cilium profile: the Services every other spec goes through
	// are served by cilium's eBPF kube-proxy replacement, not kube-proxy.
	if kindProfile() == "cilium" {
		It("has the cilium release deployed", func() {
			out, err := helm("status", "cilium", "-n", "kube-system", "-o", "json")
			Expect(err).NotTo(HaveOccurred(), out)
			Expect(out).To(ContainSubstring(`"status":"deployed"`))
		})

		It("runs without kube-proxy", func() {
			out, err := kubectl("-n", "kube-system", "get", "daemonset", "-o", "name")
			Expect(err).NotTo(HaveOccurred(), out)
			Expect(nonEmptyLines(out)).To(ContainElement("daemonset.apps/cilium"))
			Expect(nonEmptyLines(out)).NotTo(ContainElement("daemonset.apps/kube-proxy"))
			mustKubectl("-n", "kube-system", "rollout", "status", "daemonset/cilium", "--timeout=2m")
		})

		It("replaces kube-proxy with cilium's eBPF datapath", func() {
			out := mustKubectl("-n", "kube-system", "exec", "daemonset/cilium", "-c", "cilium-agent", "--",
				"cilium-dbg", "status")
			show("cilium-dbg status", out)
			Expect(out).To(MatchRegexp(`(?m)^KubeProxyReplacement:\s+True`), out)
		})
	}

	It("logs in to console with the default admin", func() {
		form := url.Values{
			"grant_type": {"password"},
			"username":   {"admin"},
			"password":   {"P@88w0rd"},
		}
		var tok struct {
			AccessToken string `json:"access_token"`
		}
		code, body := call(http.MethodPost, console.base()+"/oauth/token", "", "application/x-www-form-urlencoded",
			strings.NewReader(form.Encode()), &tok)
		Expect(code).To(Equal(http.StatusOK), body)
		Expect(tok.AccessToken).NotTo(BeEmpty())
	})

	Describe("swissd", Ordered, func() {
		var token string

		DescribeTable("answers its probes",
			func(path string) {
				code, body := call(http.MethodGet, swissd.base()+path, "", "", nil, nil)
				Expect(code).To(Equal(http.StatusOK), body)
			},
			Entry(nil, "/healthz"),
			Entry(nil, "/readyz"),
		)

		It("logs in with the swissd-auth Secret", func() {
			user := secretValue(consoleNS, "swissd-auth", "username")
			pass := secretValue(consoleNS, "swissd-auth", "password")
			var resp struct {
				Token string `json:"token"`
			}
			mustAPI(token, http.MethodPost, "/api/login", map[string]string{"username": user, "password": pass}, &resp)
			Expect(resp.Token).NotTo(BeEmpty())
			token = resp.Token
		})

		It("saves the kind site profile", func() {
			b, err := os.ReadFile(filepath.Join(root, "test/e2e/kind/testdata/profile.yaml"))
			Expect(err).NotTo(HaveOccurred())
			mustAPI(token, http.MethodPut, "/api/profile", map[string]string{"yaml": string(b)}, nil)

			Eventually(func(g Gomega) {
				var info struct {
					Name       string   `json:"name"`
					Warnings   []string `json:"warnings"`
					LLMService *struct {
						Available bool `json:"available"`
					} `json:"llmservice"`
				}
				code, body := call(http.MethodGet, swissd.base()+"/api/cluster", token, "", nil, &info)
				g.Expect(code).To(Equal(http.StatusOK), body)
				g.Expect(info.Name).To(Equal("kind-e2e"), "warnings: %v", info.Warnings)
				g.Expect(info.LLMService).NotTo(BeNil(), "warnings: %v", info.Warnings)
				g.Expect(info.LLMService.Available).To(BeTrue(),
					"llm-operator's LLMService CRD is not available; warnings: %v", info.Warnings)
			}).WithTimeout(apiTimeout).Should(Succeed())
		})

		It("lists the mock model in the catalog", func() {
			Eventually(func(g Gomega) {
				var list struct {
					Models []struct {
						Name string `json:"name"`
					} `json:"models"`
				}
				code, body := call(http.MethodGet, swissd.base()+"/api/catalog", token, "", nil, &list)
				g.Expect(code).To(Equal(http.StatusOK), body)
				var names []string
				for _, m := range list.Models {
					names = append(names, m.Name)
				}
				g.Expect(names).To(ContainElement(cfg.model))
			}).WithTimeout(apiTimeout).Should(Succeed())
		})

		// Each backend: install through swissd, chat with the engine directly
		// and through openresty, find the routed request in victorialogs,
		// then uninstall.
		DescribeTable("deploys, serves and removes the mock model",
			func(backend string) {
				rel := "e2e-mock-" + backend
				DeferCleanup(func() { removeModel(token, rel) })
				deployModel(token, backend, rel)

				By("chatting with the engine Service")
				proxy := fmt.Sprintf("/api/v1/namespaces/%s/services/http:%s:8081/proxy", modelNS, rel)
				var models modelList
				Expect(json.Unmarshal([]byte(mustKubectl("get", "--raw", proxy+"/v1/models")), &models)).To(Succeed())
				Expect(models.ids()).To(ContainElement(cfg.model))

				By("chatting through openresty at /" + rel + "/")
				nonce := fmt.Sprintf("e2e%s%d", strings.ReplaceAll(backend, "-", ""), time.Now().UnixNano())
				Eventually(func(g Gomega) {
					var got modelList
					code, body := call(http.MethodGet, openresty.base()+"/"+rel+"/v1/models", apiKey, "", nil, &got)
					g.Expect(code).To(Equal(http.StatusOK), body)
					g.Expect(got.ids()).To(ContainElement(cfg.model))
				}).WithTimeout(readyTimeout).WithPolling(2 * time.Second).Should(Succeed())
				var chat chatResponse
				code, body := call(http.MethodPost, openresty.base()+"/"+rel+"/v1/chat/completions", apiKey, "application/json",
					jsonBody(chatRequest(cfg.model, nonce)), &chat)
				showHTTP("POST /"+rel+"/v1/chat/completions", code, body)
				Expect(code).To(Equal(http.StatusOK), body)
				Expect(chat.Choices).NotTo(BeEmpty())
				Expect(chat.Choices[0].Message.Content).NotTo(BeEmpty())

				// Each poll sends the request again: the bodylog-victorialogs Vector
				// was seen holding the newest record until the next one was appended
				// (minutes, on a quiet cluster), so a single request can sit unshipped.
				By("finding the request in victorialogs")
				Eventually(func(g Gomega) {
					code, body := call(http.MethodPost, openresty.base()+"/"+rel+"/v1/chat/completions", apiKey, "application/json",
						jsonBody(chatRequest(cfg.model, nonce)), nil)
					g.Expect(code).To(Equal(http.StatusOK), body)
					q := url.Values{"query": {"req_body:" + nonce}, "limit": {"5"}}
					code, body = call(http.MethodPost, victorialogs.base()+"/select/logsql/query", "",
						"application/x-www-form-urlencoded", strings.NewReader(q.Encode()), nil)
					g.Expect(code).To(Equal(http.StatusOK), body)
					g.Expect(body).To(ContainSubstring(nonce))
					g.Expect(body).To(ContainSubstring(`"model":"` + cfg.model + `"`))
				}).WithTimeout(2 * time.Minute).WithPolling(5 * time.Second).Should(Succeed())
			},
			Entry(nil, "helm"),
			Entry(nil, "llmsvc"),
		)

		// One more mock release, for what openresty does in front of it: the
		// three inference APIs streamed and not, API keys, concurrency and the
		// ModelRoute's per-peer limit.
		Describe("openresty in front of the mock model", Ordered, func() {
			const rel = "e2e-mock-api"
			var route string

			BeforeAll(func() {
				DeferCleanup(func() { removeModel(token, rel) })
				deployModel(token, "helm", rel)
				route = openresty.base() + "/" + rel
				Eventually(func(g Gomega) {
					code, body := call(http.MethodGet, route+"/v1/models", apiKey, "", nil, nil)
					g.Expect(code).To(Equal(http.StatusOK), body)
				}).WithTimeout(readyTimeout).WithPolling(2 * time.Second).Should(Succeed())
			})

			It("lists the model at /v1/models", func() {
				var got modelList
				code, body := call(http.MethodGet, route+"/v1/models", apiKey, "", nil, &got)
				showHTTP("GET /"+rel+"/v1/models", code, body)
				Expect(code).To(Equal(http.StatusOK), body)
				Expect(got.ids()).To(ContainElement(cfg.model))
			})

			DescribeTable("refuses a request without a valid API key",
				func(key string) {
					code, body := call(http.MethodPost, route+"/v1/chat/completions", key, "application/json",
						jsonBody(chatRequest(cfg.model, "no key")), nil)
					showHTTP(fmt.Sprintf("POST /%s/v1/chat/completions, key %q", rel, key), code, body)
					Expect(code).To(Equal(http.StatusUnauthorized), body)
				},
				Entry("missing", ""),
				Entry("wrong", "sk-wrong"),
			)

			DescribeTable("answers",
				func(path string, stream bool, req map[string]any, want string) {
					req["model"] = cfg.model
					req["stream"] = stream
					resp := post(route+path, req, nil)
					showHTTP(fmt.Sprintf("POST /%s%s, stream %t (%s)", rel, path, stream, resp.ctype), resp.code, resp.body)
					Expect(resp.code).To(Equal(http.StatusOK), resp.body)
					if stream {
						Expect(resp.ctype).To(HavePrefix("text/event-stream"))
					} else {
						Expect(resp.ctype).To(HavePrefix("application/json"))
					}
					Expect(resp.body).To(ContainSubstring(want))
				},
				Entry("/v1/chat/completions", "/v1/chat/completions", false,
					chatRequest("", "hi"), `"object":"chat.completion"`),
				Entry("/v1/chat/completions, streamed", "/v1/chat/completions", true,
					chatRequest("", "hi"), "data: [DONE]"),
				Entry("/v1/completions", "/v1/completions", false,
					map[string]any{"prompt": "hi"}, `"object":"text_completion"`),
				Entry("/v1/completions, streamed", "/v1/completions", true,
					map[string]any{"prompt": "hi"}, "data: [DONE]"),
				Entry("/v1/messages", "/v1/messages", false,
					messagesRequest("hi"), `"type":"message"`),
				Entry("/v1/messages, streamed", "/v1/messages", true,
					messagesRequest("hi"), "event: message_stop"),
			)

			It("serves concurrent requests", func() {
				codes := burst(route+"/v1/chat/completions", 16, map[string]string{"X-Mock-TTFT-Ms": "500"})
				show("16 concurrent requests", fmt.Sprint(codes))
				Expect(codes).To(HaveEach(http.StatusOK))
			})

			// Last: it leaves the route limited until AfterAll removes it.
			It("answers 429 past the ModelRoute's maxConcurrency", func() {
				By("limiting every peer group of ModelRoute " + rel + " to 1 request in flight")
				out := mustKubectl("-n", modelNS, "get", "modelroute", rel, "-o", "jsonpath={.spec.nginx.peers[*].use}")
				var patch []map[string]any
				for i := range strings.Fields(out) {
					patch = append(patch, map[string]any{
						"op": "add", "path": fmt.Sprintf("/spec/nginx/peers/%d/maxConcurrency", i), "value": 1,
					})
				}
				b, err := json.Marshal(patch)
				Expect(err).NotTo(HaveOccurred())
				mustKubectl("-n", modelNS, "patch", "modelroute", rel, "--type=json", "-p", string(b))
				showKubectl("modelroute "+rel+" peers", "-n", modelNS, "get", "modelroute", rel, "-o", "jsonpath={.spec.nginx.peers}")

				// autoconfig re-renders the route and openresty reloads; until then
				// the old limit of 100 lets the whole burst through.
				Eventually(func(g Gomega) {
					codes := burst(route+"/v1/chat/completions", 6, map[string]string{"X-Mock-TTFT-Ms": "3000"})
					show("6 concurrent requests, maxConcurrency 1", fmt.Sprint(codes))
					g.Expect(codes).To(ContainElement(http.StatusTooManyRequests))
					g.Expect(codes).To(ContainElement(http.StatusOK))
					g.Expect(codes).To(HaveEach(BeElementOf(http.StatusOK, http.StatusTooManyRequests)))
				}).WithTimeout(2 * time.Minute).WithPolling(time.Second).Should(Succeed())
			})
		})
	})
})
