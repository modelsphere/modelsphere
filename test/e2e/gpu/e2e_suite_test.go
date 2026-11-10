//go:build e2e

package e2e

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

// Namespaces and services as environments/default.yaml and the charts name them.
const (
	consoleNS  = "console"
	routeNS    = "llm-route"
	operatorNS = "llmscaleoperator-system"
	sloNS      = "llm-scaler"
)

// stackNamespaces are the namespaces whose workloads must all become ready.
// llm-canary-operator is installed: false in the gpu environment, so its
// namespace is not one of them.
var stackNamespaces = []string{consoleNS, routeNS, operatorNS, sloNS}

// infraReleaseNames are releases the suite must never apply or destroy.
// The selector check is the real guard; the names are a second one, so a
// label typo cannot take the CNI or the drivers with it.
var infraReleaseNames = map[string]bool{
	"cilium":                true,
	"rook-ceph":             true,
	"rook-ceph-cluster":     true,
	"ceph-csi-drivers":      true,
	"kube-prometheus-stack": true,
	"node-problem-detector": true,
	"descheduler":           true,
	"condition2taint":       true,
	"alert-webhook":         true,
	"gpu-operator":          true,
	"network-operator":      true,
	"ascend-device-plugin":  true,
	"lws":                   true,
	"volcano":               true,
}

const gpuResource = "nvidia.com/gpu"

type suiteConfig struct {
	kubectlBin   string
	helmBin      string
	helmfileBin  string
	context      string
	helmEnv      string
	skipInstall  bool
	keepInstall  bool
	namespace    string
	release      string
	model        string
	variant      string
	servedName   string
	backend      string
	catalog      string
	gpuProducts  []string
	forceGPU     bool
	gpuCount     int
	engineSvc    string
	enginePort   int
	apiKey       string
	readyTimeout time.Duration
	installTO    time.Duration
	modelTimeout time.Duration
	goneTimeout  time.Duration
	chatTimeout  time.Duration
}

// forward is one kubectl port-forward the specs talk through.
type forward struct {
	namespace, service string
	localPort, port    int
	health             string
	anyStatus          bool // any HTTP status means the forward is up
	cmd                *exec.Cmd
	done               chan struct{}
}

func (f *forward) base() string { return fmt.Sprintf("http://127.0.0.1:%d", f.localPort) }

type listedRelease struct {
	Name      string `json:"name"`
	Namespace string `json:"namespace"`
	Installed bool   `json:"installed"`
	Labels    string `json:"labels"`
}

var (
	cfg  suiteConfig
	root string

	swissd = &forward{namespace: consoleNS, service: "swissd", localPort: 18080, port: 80, health: "/healthz"}
	// openresty's probe is /healthz on port 8090. Port 8080 is the dispatch
	// port the specs call, and its `/` is not a probe: any response means the
	// forward reached a pod.
	openresty = &forward{namespace: routeNS, service: "openresty", localPort: 18082, port: 8080, health: "/", anyStatus: true}
	forwards  = []*forward{swissd, openresty}

	// installStarted is set immediately before helmfile apply. AfterSuite
	// destroys part=others only when this suite started that apply.
	installStarted bool
	beforeSuiteOK  bool
	kubeconfigDir  string
)

func TestE2E(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "modelsphere gpu e2e")
}

var _ = BeforeSuite(func() {
	SetDefaultEventuallyTimeout(2 * time.Minute)
	SetDefaultEventuallyPollingInterval(time.Second)

	cfg = loadConfig()
	for _, bin := range []string{cfg.kubectlBin, cfg.helmBin, cfg.helmfileBin} {
		_, err := exec.LookPath(bin)
		Expect(err).NotTo(HaveOccurred(), "%s is not installed", bin)
	}
	var err error
	root, err = filepath.Abs("../../..")
	Expect(err).NotTo(HaveOccurred())

	isolateKubeconfig()
	mustKubectl("get", "nodes")

	if cfg.skipInstall {
		_, _ = fmt.Fprintln(GinkgoWriter, "E2E_SKIP_INSTALL set: not installing or uninstalling part=others")
	} else {
		installOthers()
	}
	waitStackReady()
	if verbose {
		out, err := helm("list", "-A", "-a")
		if err != nil {
			out += "\nerror: " + err.Error()
		}
		show("helm releases", out)
		showKubectl("pods", "get", "pods", "-A", "-o", "wide")
	}
	for _, f := range forwards {
		startPortForward(f)
	}
	beforeSuiteOK = true
})

var _ = AfterSuite(func() {
	for _, f := range forwards {
		stopPortForward(f)
	}
	if !beforeSuiteOK && cfg.kubectlBin != "" {
		dumpClusterState("BeforeSuite")
	}
	// E2E_SKIP_INSTALL leaves a stack this suite did not install.
	// KEEP_INSTALL keeps one it did, for a look at a failure.
	if installStarted && !cfg.skipInstall && !cfg.keepInstall {
		destroyOthers()
	}
	if kubeconfigDir != "" {
		_ = os.RemoveAll(kubeconfigDir)
	}
})

func loadConfig() suiteConfig {
	c := suiteConfig{
		kubectlBin:   envOr("KUBECTL", "kubectl"),
		helmBin:      envOr("HELM", "helm"),
		helmfileBin:  envOr("HELMFILE", "helmfile"),
		helmEnv:      envOr("E2E_HELM_ENV", "gpu"),
		namespace:    envOr("E2E_NAMESPACE", "llm-demo"),
		release:      envOr("E2E_RELEASE", "e2e-gpu"),
		model:        envOr("E2E_MODEL", "qwen3-8b"),
		variant:      envOr("E2E_VARIANT", "vllm-tp1-a100"),
		servedName:   envOr("E2E_SERVED_NAME", "Qwen3-8B"),
		backend:      envOr("E2E_BACKEND", "helm"),
		catalog:      envOr("E2E_CATALOG", "https://modelsphere.github.io/model-catalog/"),
		gpuCount:     envInt("E2E_GPU_COUNT", 1),
		enginePort:   envInt("E2E_ENGINE_PORT", 8000),
		apiKey:       os.Getenv("E2E_API_KEY"),
		readyTimeout: envDuration("E2E_READY_TIMEOUT", 15*time.Minute),
		installTO:    envDuration("E2E_INSTALL_TIMEOUT", 30*time.Minute),
		modelTimeout: envDuration("E2E_MODEL_TIMEOUT", 90*time.Minute),
		goneTimeout:  envDuration("E2E_GONE_TIMEOUT", 30*time.Minute),
		chatTimeout:  envDuration("E2E_CHAT_TIMEOUT", 3*time.Minute),
	}
	c.context = os.Getenv("E2E_KUBE_CONTEXT")
	c.skipInstall = envBool("E2E_SKIP_INSTALL")
	c.keepInstall = envBool("KEEP_INSTALL")
	c.forceGPU = envBool("E2E_FORCE_GPU_PRODUCTS")
	if raw := os.Getenv("E2E_GPU_PRODUCTS"); raw != "" {
		for _, p := range strings.Split(raw, ",") {
			if p = strings.TrimSpace(p); p != "" {
				c.gpuProducts = append(c.gpuProducts, p)
			}
		}
	}
	if c.engineSvc == "" {
		c.engineSvc = c.release
	}
	if v := os.Getenv("E2E_ENGINE_SERVICE"); v != "" {
		c.engineSvc = v
	}
	Expect(c.gpuCount).To(BeNumerically(">", 0))
	Expect(c.backend).To(BeElementOf("helm", "llmsvc"))
	return c
}

// isolateKubeconfig points KUBECONFIG at a mode-0600 copy of one context, so
// helmfile hooks cannot follow whatever context the runner had selected. The
// copy is removed in AfterSuite. Its contents are never written to the log.
func isolateKubeconfig() {
	var err error
	kubeconfigDir, err = os.MkdirTemp("", "modelsphere-e2e-gpu-")
	Expect(err).NotTo(HaveOccurred())
	args := []string{"config", "view", "--minify", "--flatten", "--raw"}
	if cfg.context != "" {
		args = append([]string{"--context", cfg.context}, args...)
	}
	cmd := exec.Command(cfg.kubectlBin, args...)
	out, err := cmd.Output()
	if err != nil {
		// Stdout can hold a partial kubeconfig. Do not include it.
		msg := err.Error()
		if ee, ok := err.(*exec.ExitError); ok && len(ee.Stderr) > 0 {
			msg = string(ee.Stderr)
		}
		Expect(err).NotTo(HaveOccurred(), "kubectl config view failed: %s", msg)
	}
	Expect(out).NotTo(BeEmpty())
	kubeconfig := filepath.Join(kubeconfigDir, "kubeconfig")
	Expect(os.WriteFile(kubeconfig, out, 0o600)).To(Succeed())
	Expect(os.Setenv("KUBECONFIG", kubeconfig)).To(Succeed())

	current, err := exec.Command(cfg.kubectlBin, "config", "current-context").Output()
	Expect(err).NotTo(HaveOccurred(), "isolated kubeconfig has no current context")
	cfg.context = strings.TrimSpace(string(current))
	Expect(cfg.context).NotTo(BeEmpty())
	By("using kube context " + cfg.context)
}

// installOthers applies helmfile -e gpu -l part=others. --skip-needs is the
// default and is passed anyway: needs edges point at kube-prometheus-stack,
// which is part=infra and must not be pulled into a per-run apply.
func installOthers() {
	rows := listOthers()
	By(fmt.Sprintf("installing part=others (%d releases): helmfile -e %s apply", len(rows), cfg.helmEnv))
	installStarted = true
	ctx, cancel := context.WithTimeout(context.Background(), cfg.installTO)
	defer cancel()
	cmd := exec.CommandContext(ctx, cfg.helmfileBin, helmfileArgs(
		"apply", "--skip-needs", "--skip-diff-on-install", "--suppress-diff")...)
	cmd.Dir = root
	out, err := run(cmd)
	Expect(err).NotTo(HaveOccurred(), tail(out, 80))
}

// destroyOthers uninstalls part=others only. destroy has no --skip-needs;
// the selector is what keeps infra out, and listOthers checks it first.
func destroyOthers() {
	rows := listOthers()
	By(fmt.Sprintf("uninstalling part=others (%d releases)", len(rows)))
	ctx, cancel := context.WithTimeout(context.Background(), cfg.installTO)
	defer cancel()
	cmd := exec.CommandContext(ctx, cfg.helmfileBin, helmfileArgs(
		"destroy", "--deleteTimeout", "900")...)
	cmd.Dir = root
	out, err := run(cmd)
	Expect(err).NotTo(HaveOccurred(), tail(out, 80))
}

func helmfileArgs(extra ...string) []string {
	args := []string{
		"-f", "helmfile.yaml.gotmpl",
		"-e", cfg.helmEnv,
		"--kube-context", cfg.context,
		"-l", "part=others",
	}
	return append(args, extra...)
}

// listOthers is the fail-closed check in front of apply and destroy.
func listOthers() []listedRelease {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, cfg.helmfileBin, helmfileArgs("list", "--output", "json", "--skip-deps")...)
	cmd.Dir = root
	stdout, stderr, err := runSplit(cmd)
	Expect(err).NotTo(HaveOccurred(), stderr)
	var rows []listedRelease
	Expect(json.Unmarshal([]byte(stdout), &rows)).To(Succeed(), stdout)
	Expect(rows).NotTo(BeEmpty(), "part=others selected no releases")
	installed := 0
	for _, r := range rows {
		labels := parseLabels(r.Labels)
		Expect(labels["part"]).To(Equal("others"),
			"refusing to touch %s/%s: labels %q", r.Namespace, r.Name, r.Labels)
		Expect(infraReleaseNames).NotTo(HaveKey(r.Name),
			"refusing to touch infra release %s", r.Name)
		if r.Installed {
			installed++
		}
	}
	Expect(installed).To(BeNumerically(">", 0),
		"part=others has no installed: true release in environment %s", cfg.helmEnv)
	return rows
}

func parseLabels(s string) map[string]string {
	out := map[string]string{}
	for _, item := range strings.Split(s, ",") {
		k, v, ok := strings.Cut(item, ":")
		if ok {
			out[k] = v
		}
	}
	return out
}

func requireGPUNodes() {
	out := mustKubectl("get", "nodes", "-o", "json")
	var list struct {
		Items []struct {
			Metadata struct {
				Name string `json:"name"`
			} `json:"metadata"`
			Status struct {
				Allocatable map[string]string `json:"allocatable"`
			} `json:"status"`
		} `json:"items"`
	}
	Expect(json.Unmarshal([]byte(out), &list)).To(Succeed())
	var have []string
	for _, n := range list.Items {
		if qty(n.Status.Allocatable[gpuResource]) >= cfg.gpuCount {
			have = append(have, n.Metadata.Name)
		}
	}
	Expect(have).NotTo(BeEmpty(),
		"no node has allocatable %s >= %d. Install the cluster base first (`make helm-apply-infra ENV=%s`); this suite does not install part=infra",
		gpuResource, cfg.gpuCount, cfg.helmEnv)
	show("gpu nodes", strings.Join(have, "\n"))
}

func waitStackReady() {
	deadline := time.Now().Add(cfg.readyTimeout)
	for _, ns := range stackNamespaces {
		names, err := kubectl("-n", ns, "get", "deploy,statefulset", "-o", "name")
		Expect(err).NotTo(HaveOccurred(), names)
		Expect(nonEmptyLines(names)).NotTo(BeEmpty(), "no workloads in %s", ns)
		for _, name := range nonEmptyLines(names) {
			By(fmt.Sprintf("waiting for %s/%s", ns, name))
			left := time.Until(deadline).Round(time.Second)
			Expect(left).To(BeNumerically(">", 0), "E2E_READY_TIMEOUT %s exceeded", cfg.readyTimeout)
			mustKubectl("-n", ns, "rollout", "status", name, "--timeout="+left.String())
		}
	}
}

func startPortForward(f *forward) {
	By(fmt.Sprintf("port-forwarding svc/%s.%s to %d", f.service, f.namespace, f.localPort))
	cmd := exec.Command(cfg.kubectlBin, "--context", cfg.context,
		"-n", f.namespace, "port-forward", "svc/"+f.service,
		fmt.Sprintf("%d:%d", f.localPort, f.port))
	setPortForwardAttr(cmd)
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	Expect(cmd.Start()).To(Succeed())
	f.cmd = cmd
	f.done = make(chan struct{})
	go func() {
		_ = cmd.Wait()
		close(f.done)
	}()

	Eventually(func(g Gomega) {
		select {
		case <-f.done:
			g.Expect(true).To(BeFalse(), "port-forward to %s exited; is port %d free?", f.service, f.localPort)
		default:
		}
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, f.base()+f.health, nil)
		g.Expect(err).NotTo(HaveOccurred())
		resp, err := http.DefaultClient.Do(req)
		g.Expect(err).NotTo(HaveOccurred())
		defer resp.Body.Close()
		if f.anyStatus {
			g.Expect(resp.StatusCode).NotTo(BeZero())
		} else {
			g.Expect(resp.StatusCode).To(Equal(http.StatusOK))
		}
	}).WithTimeout(60 * time.Second).Should(Succeed())
}

func stopPortForward(f *forward) {
	if f.cmd == nil || f.cmd.Process == nil {
		return
	}
	_ = killPortForward(f.cmd)
	select {
	case <-f.done:
	case <-time.After(5 * time.Second):
	}
	f.cmd = nil
}

func run(cmd *exec.Cmd) (string, error) {
	command := strings.Join(cmd.Args, " ")
	_, _ = fmt.Fprintf(GinkgoWriter, "running: %s\n", command)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return string(out), fmt.Errorf("%s failed: %w\n%s", command, err, out)
	}
	return string(out), nil
}

func runSplit(cmd *exec.Cmd) (stdout, stderr string, err error) {
	command := strings.Join(cmd.Args, " ")
	_, _ = fmt.Fprintf(GinkgoWriter, "running: %s\n", command)
	var outBuf, errBuf strings.Builder
	cmd.Stdout = &outBuf
	cmd.Stderr = &errBuf
	err = cmd.Run()
	if err != nil {
		err = fmt.Errorf("%s failed: %w", command, err)
	}
	return outBuf.String(), errBuf.String(), err
}

func kubectl(args ...string) (string, error) {
	return run(exec.Command(cfg.kubectlBin, append([]string{"--context", cfg.context}, args...)...))
}

func mustKubectl(args ...string) string {
	out, err := kubectl(args...)
	Expect(err).NotTo(HaveOccurred(), out)
	return out
}

func helm(args ...string) (string, error) {
	return run(exec.Command(cfg.helmBin, append([]string{"--kube-context", cfg.context}, args...)...))
}

func dumpClusterState(spec string) {
	_, _ = fmt.Fprintf(GinkgoWriter, "\n==> dumping cluster state (%s)\n", spec)
	dump := func(title string, args ...string) {
		out, err := kubectl(args...)
		_, _ = fmt.Fprintf(GinkgoWriter, "\n--- %s\n%s\n", title, tail(out, 80))
		if err != nil {
			_, _ = fmt.Fprintf(GinkgoWriter, "error: %v\n", err)
		}
	}
	dump("nodes", "get", "nodes", "-o", "wide")
	dump("pods", "get", "pods", "-A", "-o", "wide")
	dump("events", "get", "events", "-A", "--sort-by=.lastTimestamp")
	dump("model objects", "-n", cfg.namespace, "get", "llmservices,llmscalers,modelroutes,deploy,svc,pods", "-o", "wide")
	dump("swissd logs", "-n", consoleNS, "logs", "deploy/swissd", "--tail=100")
	dump("autoconfig logs", "-n", routeNS, "logs", "deploy/autoconfig", "--tail=50")
	dump("operator logs", "-n", operatorNS, "logs", "deploy/llmscaleoperator-controller-manager", "--tail=50")
	if out, err := helm("list", "-A", "-a"); err == nil {
		_, _ = fmt.Fprintf(GinkgoWriter, "\n--- helm releases\n%s\n", out)
	}
}

func envOr(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return fallback
}

func envBool(key string) bool {
	v := os.Getenv(key)
	return v == "1" || v == "true"
}

func envInt(key string, fallback int) int {
	v, ok := os.LookupEnv(key)
	if !ok || v == "" {
		return fallback
	}
	n, err := strconv.Atoi(v)
	Expect(err).NotTo(HaveOccurred(), "%s=%q is not an integer", key, v)
	return n
}

// envDuration accepts a Go duration (90m) or a bare number of seconds.
func envDuration(key string, fallback time.Duration) time.Duration {
	v, ok := os.LookupEnv(key)
	if !ok || v == "" {
		return fallback
	}
	if d, err := time.ParseDuration(v); err == nil {
		return d
	}
	n, err := strconv.Atoi(v)
	Expect(err).NotTo(HaveOccurred(), "%s=%q is not a duration or a number of seconds", key, v)
	return time.Duration(n) * time.Second
}

func nonEmptyLines(s string) []string {
	var res []string
	for line := range strings.SplitSeq(s, "\n") {
		if line = strings.TrimSpace(line); line != "" {
			res = append(res, line)
		}
	}
	return res
}

func tail(s string, n int) string {
	lines := strings.Split(s, "\n")
	if len(lines) <= n {
		return s
	}
	return strings.Join(lines[len(lines)-n:], "\n")
}

// qty reads a resource quantity that is a whole number. nvidia.com/gpu is
// advertised that way; anything else fails the assertion at the call site
// by returning -1.
func qty(s string) int {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		return -1
	}
	return n
}
