//go:build e2e && linux

package e2e

import (
	"os/exec"
	"syscall"
)

func setPortForwardAttr(cmd *exec.Cmd) {
	// Pdeathsig: kubectl dies with the suite when the process is killed.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true, Pdeathsig: syscall.SIGTERM}
}

func killPortForward(cmd *exec.Cmd) error {
	if cmd == nil || cmd.Process == nil {
		return nil
	}
	// Negative pid is the process group started with Setpgid.
	return syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
}
