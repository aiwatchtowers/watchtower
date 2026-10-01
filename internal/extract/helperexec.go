package extract

import "os/exec"

// runHelper runs a helper subprocess (the PDF parser, the OCR helper) like
// cmd.Run, but moves it into the background priority band right after it
// starts: extraction is batch work inside the daemon's sync cycle and must
// not compete with the owner's foreground apps for CPU or disk. Failing to
// lower the priority is logged and the helper runs at its default
// priority.
func runHelper(cmd *exec.Cmd, logf logFunc) error {
	if err := cmd.Start(); err != nil {
		return err
	}
	if err := setBackgroundPriority(cmd.Process.Pid); err != nil {
		logf("%s: lowering the helper's priority: %v", cmd.Path, err)
	}
	return cmd.Wait()
}
