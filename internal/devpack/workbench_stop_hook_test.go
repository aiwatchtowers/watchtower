package devpack

import (
	"context"
	"errors"
	"strings"
	"testing"
)

// The Stop hook (board drift check, PROJ-07) is installed, recognised and
// removed under the same PROJ-04 rules as the SessionStart hook.

func stopGroups(t *testing.T, m map[string]any) []any {
	t.Helper()
	hooks, _ := m["hooks"].(map[string]any)
	groups, ok := hooks["Stop"].([]any)
	if !ok {
		t.Fatalf("hooks.Stop is missing or not an array: %#v", m["hooks"])
	}
	return groups
}

func TestProjectStopHookCommand(t *testing.T) {
	got := WorkbenchStopHookCommand("/tmp/Application Support/watchtower", 3)
	if got != "'/tmp/Application Support/watchtower' workbench check --workbench 3 --stop-hook" {
		t.Fatalf("got %q", got)
	}
}

func TestInstallProjectInstallsTheStopHook(t *testing.T) {
	folder := fakeRepo(t)
	o := workbenchOpts(folder, newFakeClaude())
	if _, err := InstallWorkbench(context.Background(), o); err != nil {
		t.Fatalf("install: %v", err)
	}
	groups := stopGroups(t, decodeSettings(t, folder))
	cmd := WorkbenchStopHookCommand(o.Bin, 7)
	if len(groups) != 1 || countCommand(groups, cmd) != 1 {
		t.Fatalf("expected one Stop group running %q, got %#v", cmd, groups)
	}
	h := groups[0].(map[string]any)["hooks"].([]any)[0].(map[string]any)
	if h["timeout"] == nil {
		t.Fatalf("the Stop hook must carry a timeout: %#v", h)
	}
	st, err := StatusWorkbench(context.Background(), o)
	if err != nil || !st.Hook || !st.StopHook {
		t.Fatalf("status after install: %+v err=%v", st, err)
	}
	// Installing again adds nothing.
	rep, err := InstallWorkbench(context.Background(), o)
	if err != nil || rep.HookChanged {
		t.Fatalf("reinstall: changed=%v err=%v", rep.HookChanged, err)
	}
}

// A project installed before the Stop hook existed gets it on the next
// `integrate claude-code --project N`, and the SessionStart entry is untouched.
func TestInstallProjectAddsTheStopHookToAnOldInstall(t *testing.T) {
	folder := fakeRepo(t)
	if _, err := InstallSessionStartHook(folder, WorkbenchHookCommand("/tmp/acme bin/watchtower", 7), 7); err != nil {
		t.Fatal(err)
	}
	rep, err := InstallWorkbench(context.Background(), workbenchOpts(folder, newFakeClaude()))
	if err != nil || !rep.HookChanged {
		t.Fatalf("changed=%v err=%v", rep.HookChanged, err)
	}
	m := decodeSettings(t, folder)
	if len(sessionStartGroups(t, m)) != 1 || len(stopGroups(t, m)) != 1 {
		t.Fatalf("expected one entry per event, got %#v", m["hooks"])
	}
}

func TestProj04_StopHookKeepsOwnerStopHooksAndRemovesOnlyOurs(t *testing.T) {
	dir := t.TempDir()
	writeTestFile(t, settingsFile(dir), `{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo owner-stop"}]}]}}`)
	cmd := WorkbenchStopHookCommand("/tmp/acme bin/watchtower", 7)
	if changed, err := InstallStopHook(dir, cmd, 7); err != nil || !changed {
		t.Fatalf("install: changed=%v err=%v", changed, err)
	}
	groups := stopGroups(t, decodeSettings(t, dir))
	if countCommand(groups, "echo owner-stop") != 1 || countCommand(groups, cmd) != 1 {
		t.Fatalf("both hooks expected, got %#v", groups)
	}
	// Another project's Stop hook is not ours for project 7.
	if ok, _ := HasStopHook(dir, 8); ok {
		t.Fatal("project 8 has no Stop hook here")
	}
	if changed, err := RemoveStopHook(dir, 7); err != nil || !changed {
		t.Fatalf("remove: changed=%v err=%v", changed, err)
	}
	groups = stopGroups(t, decodeSettings(t, dir))
	if countCommand(groups, "echo owner-stop") != 1 || countCommand(groups, cmd) != 0 {
		t.Fatalf("PROJ-04: only our hook may go, got %#v", groups)
	}
}

func TestProj04_MalformedStopLeavesTheFileByteIdentical(t *testing.T) {
	dir := t.TempDir()
	const content = `{"hooks": {"Stop": {"hooks": []}}}`
	writeTestFile(t, settingsFile(dir), content)
	if _, err := InstallWorkbench(context.Background(), workbenchOpts(dir, newFakeClaude())); !errors.Is(err, ErrMalformedSettings) {
		t.Fatalf("expected ErrMalformedSettings, got %v", err)
	}
	if got := readTestFile(t, settingsFile(dir)); got != content {
		t.Fatalf("PROJ-04: a malformed file must be left byte-identical, got %s", got)
	}
	// Reported once, not once per hook.
	if _, err := InstallWorkbench(context.Background(), workbenchOpts(dir, newFakeClaude())); strings.Count(err.Error(), "malformed") != 1 {
		t.Fatalf("the malformed file must be reported once: %v", err)
	}
	if _, err := InstallSessionStartHook(dir, testHookCmd, 7); !errors.Is(err, ErrMalformedSettings) {
		t.Fatalf("a malformed hooks.Stop refuses the SessionStart install too: %v", err)
	}
}
