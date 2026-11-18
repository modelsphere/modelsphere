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
	modelNS    = "llm-demo"
)

// stackNamespaces are the namespaces whose workloads must all become ready.
var stackNamespaces = []string{consoleNS, routeNS, operatorNS, sloNS}

type suiteConfig struct {
	kubectlBin    string
	helmBin       string
	helmfileBin   string
	kindBin       string
	cluster       string
	context       string
	profile       string // default or cilium, see kindProfile
	skipInstall   bool
	model         string
	readyTimeout  time.Duration
	installTimout time.Duration
}

// forward is one kubectl port-forward the specs talk through.
type forward struct {
	namespace, service string
	localPort, port    int
	health             string // path that answers 200 once the forward works
	cmd                *exec.Cmd
	done               chan struct{}
}

func (f *forward) base() string { return fmt.Sprintf("http://127.0.0.1:%d", f.localPort) }

var (
	cfg  suiteConfig
	root string

	swissd       = &forward{namespace: consoleNS, service: "swissd", localPort: 18080, port: 80, health: "/healthz"}
	console      = &forward{namespace: consoleNS, service: "console-console", localPort: 18081, port: 8080, health: "/"}
	openresty    = &forward{namespace: routeNS, service: "openresty", localPort: 18082, port: 8080, health: "/"}
	victorialogs = &forward{namespace: routeNS, service: "victorialogs", localPort: 18083, port: 9428, health: "/health"}
	forwards     = []*forward{swissd, console, openresty, victorialogs}

	beforeSuiteOK bool
	kubeconfigDir string
)

func TestE2E(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "modelsphere e2e")
}

var _ = BeforeSuite(func() {
	SetDefaultEventuallyTimeout(2 * time.Minute)
	SetDefaultEventuallyPollingInterval(time.Second)

	cfg = loadConfig()
	for _, bin := range []string{cfg.kindBin, cfg.kubectlBin, cfg.helmBin, cfg.helmfileBin} {
		_, err := exec.LookPath(bin)
		Expect(err).NotTo(HaveOccurred(), "%s is not installed", bin)
	}
	var err error
	root, err = filepath.Abs("../../..")
	Expect(err).NotTo(HaveOccurred())

	// helmfile's hooks run plain kubectl on the current context, so every
	// child process gets a kubeconfig holding only the kind cluster.
	By("using kube context " + cfg.context)
	kubeconfigDir, err = os.MkdirTemp("", "modelsphere-e2e-")
	Expect(err).NotTo(HaveOccurred())
	kc, err := run(exec.Command(cfg.kindBin, "get", "kubeconfig", "--name", cfg.cluster))
	Expect(err).NotTo(HaveOccurred(), kc)
	kubeconfig := filepath.Join(kubeconfigDir, "kubeconfig")
	Expect(os.WriteFile(kubeconfig, []byte(kc), 0o600)).To(Succeed())
	Expect(os.Setenv("KUBECONFIG", kubeconfig)).To(Succeed())
	mustKubectl("get", "nodes")

	if cfg.skipInstall {
		_, _ = fmt.Fprintln(GinkgoWriter, "E2E_SKIP_INSTALL set: not running helmfile apply")
	} else {
		installStack()
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
	if !beforeSuiteOK && cfg.context != "" {
		dumpClusterState("BeforeSuite")
	}
	if kubeconfigDir != "" {
		_ = os.RemoveAll(kubeconfigDir)
	}
})

func loadConfig() suiteConfig {
	c := suiteConfig{
		kindBin:       envOr("KIND", "kind"),
		kubectlBin:    envOr("KUBECTL", "kubectl"),
		helmBin:       envOr("HELM", "helm"),
		helmfileBin:   envOr("HELMFILE", "helmfile"),
		cluster:       envOr("KIND_CLUSTER", "modelsphere-e2e"),
		model:         envOr("MODEL", "mock-llm"),
		readyTimeout:  time.Duration(envInt("READY_TIMEOUT", 600)) * time.Second,
		installTimout: time.Duration(envInt("INSTALL_TIMEOUT", 900)) * time.Second,
	}
	c.context = "kind-" + c.cluster
	c.profile = kindProfile()
	c.skipInstall = os.Getenv("E2E_SKIP_INSTALL") == "1" || os.Getenv("E2E_SKIP_INSTALL") == "true"
	return c
}

// kindProfile is KIND_PROFILE: "default" (kind's CNI and kube-proxy) or
// "cilium" (no kube-proxy; cilium with kubeProxyReplacement). It is read at
// package init too, since it decides which specs exist.
func kindProfile() string {
	p := envOr("KIND_PROFILE", "default")
	if p != "default" && p != "cilium" {
		panic(fmt.Sprintf("KIND_PROFILE must be default or cilium, not %q", p))
	}
	return p
}

// installStack applies the repo's helmfile, environment kind (kind-cilium for
// the cilium profile). environments/kind.yaml sets llmGateway.bodylogNodeSelector;
// this labels the kind node with it before apply. Without kube-proxy, cilium
// reaches the apiserver at that same node.
func installStack() {
	env := "kind"
	node := cfg.cluster + "-control-plane"
	mustKubectl("label", "node", node, "modelsphere.dev/bodylog=true", "--overwrite")
	var sets []string
	if cfg.profile == "cilium" {
		env = "kind-cilium"
		sets = append(sets, "--state-values-set", "cilium.k8sServiceHost="+node)
	}
	By("installing the stack: helmfile -e " + env + " apply")
	ctx, cancel := context.WithTimeout(context.Background(), cfg.installTimout)
	defer cancel()
	args := append([]string{"-f", "helmfile.yaml.gotmpl", "-e", env, "--kube-context", cfg.context}, sets...)
	args = append(args, "apply", "--skip-diff-on-install", "--suppress-diff")
	cmd := exec.CommandContext(ctx, cfg.helmfileBin, args...)
	cmd.Dir = root
	out, err := run(cmd)
	Expect(err).NotTo(HaveOccurred(), tail(out, 80))
}

// waitStackReady waits for every Deployment and StatefulSet in the stack
// namespaces to finish rolling out. Images are pulled here, so this is the slow part.
func waitStackReady() {
	deadline := time.Now().Add(cfg.readyTimeout)
	for _, ns := range stackNamespaces {
		names, err := kubectl("-n", ns, "get", "deploy,statefulset", "-o", "name")
		Expect(err).NotTo(HaveOccurred(), names)
		Expect(nonEmptyLines(names)).NotTo(BeEmpty(), "no workloads in %s", ns)
		for _, name := range nonEmptyLines(names) {
			By(fmt.Sprintf("waiting for %s/%s", ns, name))
			left := time.Until(deadline).Round(time.Second)
			Expect(left).To(BeNumerically(">", 0), "READY_TIMEOUT %s exceeded", cfg.readyTimeout)
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
		g.Expect(resp.StatusCode).To(Equal(http.StatusOK))
	}).WithTimeout(30 * time.Second).Should(Succeed())
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

// run executes cmd and returns its combined output.
func run(cmd *exec.Cmd) (string, error) {
	command := strings.Join(cmd.Args, " ")
	_, _ = fmt.Fprintf(GinkgoWriter, "running: %s\n", command)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return string(out), fmt.Errorf("%s failed: %w\n%s", command, err, out)
	}
	return string(out), nil
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
	dump("pods", "get", "pods", "-A", "-o", "wide")
	dump("events", "get", "events", "-A", "--sort-by=.lastTimestamp")
	dump("model objects", "-n", modelNS, "get", "llmservices,llmscalers,modelroutes,deploy,svc", "-o", "wide")
	dump("swissd logs", "-n", consoleNS, "logs", "deploy/swissd", "--tail=100")
	dump("autoconfig logs", "-n", routeNS, "logs", "deploy/autoconfig", "--tail=50")
	dump("operator logs", "-n", operatorNS, "logs", "deploy/llmscaleoperator-controller-manager", "--tail=50")
	dumpUnhealthyPods(dump, append(append([]string{}, stackNamespaces...), modelNS)...)
	if out, err := helm("list", "-A", "-a"); err == nil {
		_, _ = fmt.Fprintf(GinkgoWriter, "\n--- helm releases\n%s\n", out)
	}
}

type podDiagList struct {
	Items []podDiag `json:"items"`
}

type podDiag struct {
	Metadata struct {
		Name string `json:"name"`
	} `json:"metadata"`
	Status struct {
		Phase                 string            `json:"phase"`
		Reason                string            `json:"reason"`
		Message               string            `json:"message"`
		Conditions            []podCondition    `json:"conditions"`
		InitContainerStatuses []containerStatus `json:"initContainerStatuses"`
		ContainerStatuses     []containerStatus `json:"containerStatuses"`
	} `json:"status"`
}

type podCondition struct {
	Type    string `json:"type"`
	Status  string `json:"status"`
	Reason  string `json:"reason"`
	Message string `json:"message"`
}

type containerStatus struct {
	Name         string         `json:"name"`
	Ready        bool           `json:"ready"`
	RestartCount int            `json:"restartCount"`
	State        containerState `json:"state"`
	LastState    containerState `json:"lastState"`
}

type containerState struct {
	Waiting *struct {
		Reason  string `json:"reason"`
		Message string `json:"message"`
	} `json:"waiting"`
	Terminated *struct {
		Reason   string `json:"reason"`
		Message  string `json:"message"`
		ExitCode int    `json:"exitCode"`
	} `json:"terminated"`
}

// dumpUnhealthyPods inspects every pod in the given namespaces and dumps status,
// describe output, and per-container logs (including --previous) for any pod
// that is not healthy (ignoring Completed/Succeeded pods).
func dumpUnhealthyPods(dump func(string, ...string), namespaces ...string) {
	seen := map[string]bool{}
	for _, ns := range namespaces {
		if ns == "" || seen[ns] {
			continue
		}
		seen[ns] = true
		out, err := kubectl("-n", ns, "get", "pods", "-o", "json")
		if err != nil {
			continue
		}
		var list podDiagList
		if json.Unmarshal([]byte(out), &list) != nil {
			continue
		}
		for _, p := range list.Items {
			if isPodHealthy(p) {
				continue
			}
			// Printed before describe because tail(..., 80) drops container state when events are long.
			printPodSummary(ns, p)
			dump(fmt.Sprintf("describe %s/%s", ns, p.Metadata.Name), "-n", ns, "describe", "pod", p.Metadata.Name)
			for _, cs := range allContainerStatuses(p) {
				if cs.State.Waiting == nil {
					dump(fmt.Sprintf("%s/%s[%s] logs", ns, p.Metadata.Name, cs.Name),
						"-n", ns, "logs", p.Metadata.Name, "-c", cs.Name, "--tail=50")
				}
				if cs.RestartCount > 0 || cs.LastState.Terminated != nil {
					dump(fmt.Sprintf("%s/%s[%s] previous logs", ns, p.Metadata.Name, cs.Name),
						"-n", ns, "logs", p.Metadata.Name, "-c", cs.Name, "--previous", "--tail=50")
				}
			}
		}
	}
}

func isPodHealthy(p podDiag) bool {
	if p.Status.Phase == "Succeeded" || p.Status.Reason == "Completed" {
		return true
	}
	if p.Status.Phase != "Running" {
		return false
	}
	return isPodReady(p) && !hasPodRestarts(p)
}

func allContainerStatuses(p podDiag) []containerStatus {
	out := make([]containerStatus, 0, len(p.Status.InitContainerStatuses)+len(p.Status.ContainerStatuses))
	out = append(out, p.Status.InitContainerStatuses...)
	out = append(out, p.Status.ContainerStatuses...)
	return out
}

func isPodReady(p podDiag) bool {
	for _, c := range p.Status.Conditions {
		if c.Type == "Ready" {
			return c.Status == "True"
		}
	}
	return false
}

func hasPodRestarts(p podDiag) bool {
	for _, cs := range allContainerStatuses(p) {
		if cs.RestartCount > 0 || cs.LastState.Terminated != nil {
			return true
		}
	}
	return false
}

func printPodSummary(ns string, p podDiag) {
	_, _ = fmt.Fprintf(GinkgoWriter, "\n--- pod %s/%s (phase=%s ready=%t)\n", ns, p.Metadata.Name, p.Status.Phase, isPodReady(p))
	if p.Status.Reason != "" || p.Status.Message != "" {
		_, _ = fmt.Fprintf(GinkgoWriter, "status: %s %s\n", p.Status.Reason, p.Status.Message)
	}
	for _, c := range p.Status.Conditions {
		if c.Status != "True" {
			_, _ = fmt.Fprintf(GinkgoWriter, "condition %s=%s (%s): %s\n", c.Type, c.Status, c.Reason, c.Message)
		}
	}
	for _, cs := range allContainerStatuses(p) {
		parts := []string{fmt.Sprintf("ready=%t restarts=%d", cs.Ready, cs.RestartCount)}
		if cs.State.Waiting != nil {
			parts = append(parts, fmt.Sprintf("waiting=%s (%s)", cs.State.Waiting.Reason, cs.State.Waiting.Message))
		}
		if cs.State.Terminated != nil {
			parts = append(parts, fmt.Sprintf("terminated=%s exit=%d (%s)", cs.State.Terminated.Reason, cs.State.Terminated.ExitCode, cs.State.Terminated.Message))
		}
		if cs.LastState.Terminated != nil {
			parts = append(parts, fmt.Sprintf("last=%s exit=%d (%s)", cs.LastState.Terminated.Reason, cs.LastState.Terminated.ExitCode, cs.LastState.Terminated.Message))
		}
		_, _ = fmt.Fprintf(GinkgoWriter, "container %s: %s\n", cs.Name, strings.Join(parts, " "))
	}
}

func envOr(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return fallback
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
