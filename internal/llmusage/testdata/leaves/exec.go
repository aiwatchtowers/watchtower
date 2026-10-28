// Package leaves is TestLLMUsageLeavesCatchesNewLeaf's fixture: parsed, never
// built.
package leaves

import (
	"context"
	"os/exec"

	"watchtower/internal/llmusage"
)

// recordsDirectly runs a model and records it (inside a deferred literal,
// which belongs to the function): not reported.
func recordsDirectly(ctx context.Context) error {
	defer func() { llmusage.Record(ctx, llmusage.Call{}) }()
	return exec.CommandContext(ctx, "claude", "-p").Run()
}

// secondLeaf is a second process start in a file that already records:
// reported.
func secondLeaf() error {
	return exec.Command("claude", "-p").Run()
}

type Client struct{ bin string }

// fromField's binary is a struct field: reported.
func (c *Client) fromField(ctx context.Context, args ...string) error {
	return exec.CommandContext(ctx, c.bin, args...).Run()
}

// fromLocal's binary is a local variable: reported.
func fromLocal() error {
	name := "codex"
	return exec.Command(name, "exec").Run()
}

// throughHelper records through a same-package record* helper: not
// reported.
func throughHelper(ctx context.Context) error {
	err := exec.CommandContext(ctx, "codex", "exec").Run()
	recordRun(ctx, err == nil)
	return err
}

func recordRun(ctx context.Context, ok bool) { llmusage.Record(ctx, llmusage.Call{OK: ok}) }

// recordsNothing calls a record* helper that never reaches llmusage.Record:
// reported.
func recordsNothing() error {
	err := exec.Command("claude", "-p").Run()
	recordLocally(err)
	return err
}

func recordLocally(error) {}

// listedTool is in the test's list: not reported.
func listedTool() error { return exec.Command("git", "status").Run() }
