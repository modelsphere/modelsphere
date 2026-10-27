//go:build e2e && windows

package e2e

import "os/exec"

// Windows has no process group and no Pdeathsig. The port-forward is killed directly.
func setPortForwardAttr(*exec.Cmd) {}

func killPortForward(cmd *exec.Cmd) error {
	if cmd == nil || cmd.Process == nil {
		return nil
	}
	return cmd.Process.Kill()
}
