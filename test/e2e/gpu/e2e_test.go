//go:build e2e

package e2e

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("stack", Ordered, func() {
	AfterEach(func() {
		if CurrentSpecReport().Failed() {
			dumpClusterState(CurrentSpecReport().FullText())
		}
	})

	// The releases environments/gpu.yaml leaves installed (default.yaml's
	// product set; llm-canary-operator stays off). part=infra is not checked
	// here beyond the GPU nodes BeforeSuite already required.
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

	Describe("swissd", Ordered, func() {
		var token string

		It("logs in with the swissd-auth Secret", func() {
			user := secretValue(consoleNS, "swissd-auth", "username")
			pass := secretValue(consoleNS, "swissd-auth", "password")
			var resp struct {
				Token string `json:"token"`
			}
			mustAPI("", http.MethodPost, "/api/login", map[string]string{"username": user, "password": pass}, &resp)
			Expect(resp.Token).NotTo(BeEmpty())
			token = resp.Token
		})

		It("saves the gpu site profile", func() {
			b, err := os.ReadFile(filepath.Join(root, "test/e2e/gpu/testdata/profile.yaml"))
			Expect(err).NotTo(HaveOccurred())
			profile := strings.ReplaceAll(string(b), "@CATALOG@", cfg.catalog)
			Expect(profile).NotTo(ContainSubstring("@CATALOG@"))
			mustAPI(token, http.MethodPut, "/api/profile", map[string]string{"yaml": profile}, nil)

			Eventually(func(g Gomega) {
				var info struct {
					Name     string   `json:"name"`
					Warnings []string `json:"warnings"`
				}
				code, body := call(http.MethodGet, swissd.base()+"/api/cluster", token, "", nil, &info)
				g.Expect(code).To(Equal(http.StatusOK), body)
				g.Expect(info.Name).To(Equal("gpu-e2e"), "warnings: %v", info.Warnings)
			}).WithTimeout(apiTimeout).Should(Succeed())
		})

		It("lists the model in the catalog", func() {
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

				code, body = call(http.MethodGet, swissd.base()+"/api/catalog/"+cfg.model, token, "", nil, nil)
				g.Expect(code).To(Equal(http.StatusOK), body)
				g.Expect(body).To(ContainSubstring(cfg.variant))
			}).WithTimeout(apiTimeout).Should(Succeed())
		})

		It("deploys the model on a GPU, serves it, and removes it", func() {
			DeferCleanup(func() { removeModel(token) })
			requireGPUNodes()
			deployModel(token)
			assertGPU()

			engine := &forward{
				namespace: cfg.namespace,
				service:   cfg.engineSvc,
				localPort: 18084,
				port:      cfg.enginePort,
				health:    "/health",
			}
			DeferCleanup(func() { stopPortForward(engine) })
			startPortForward(engine)

			By("chatting with the engine Service")
			Eventually(func(g Gomega) {
				code, body, chat := postChat(engine.base()+"/v1/chat/completions", "")
				showHTTP("POST engine /v1/chat/completions", code, body)
				g.Expect(code).To(Equal(http.StatusOK), body)
				g.Expect(chat.Choices).NotTo(BeEmpty())
				g.Expect(chat.Choices[0].Message.text()).NotTo(BeEmpty())
			}).WithTimeout(cfg.chatTimeout).WithPolling(5 * time.Second).Should(Succeed())

			By("chatting through openresty at /" + cfg.release + "/")
			Eventually(func(g Gomega) {
				code, body, chat := postChat(openresty.base()+"/"+cfg.release+"/v1/chat/completions", cfg.apiKey)
				showHTTP("POST /"+cfg.release+"/v1/chat/completions", code, body)
				g.Expect(code).To(Equal(http.StatusOK), body)
				g.Expect(chat.Choices).NotTo(BeEmpty())
				g.Expect(chat.Choices[0].Message.text()).NotTo(BeEmpty())
			}).WithTimeout(cfg.chatTimeout).WithPolling(5 * time.Second).Should(Succeed())
		})
	})
})
