//go:build e2e && !linux && !windows

package e2e

import (
	"os/exec"
	"syscall"
)

func setPortForwardAttr(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

func killPortForward(cmd *exec.Cmd) error {
	if cmd == nil || cmd.Process == nil {
		return nil
	}
	// Negative pid is the process group started with Setpgid.
	return syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
}
