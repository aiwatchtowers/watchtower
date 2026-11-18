package devpack

import (
	"context"
	"encoding/json"
	"reflect"
	"testing"

	"watchtower/internal/sessionagent"
)

// The outside-bench entry (multi-folder workbench §6.7) is a PostToolUse
// command entry of its own, beside the silent state entry, installed,
// recognised and removed under the PROJ-02/04 rules.

func TestProj04_OutsideTouchHookKeepsOwnerHooks(t *testing.T) {
	folder := fakeRepo(t)
	const owner = `{
  "hooks": {
    "PostToolUse": [
      {"matcher": "Read", "hooks": [{"type": "command", "command": "echo owner-read"}]},
      {"hooks": [{"type": "command", "command": "echo owner-any", "timeout": 3}]}
    ]
  }
}`
	writeTestFile(t, settingsFile(folder), owner)
	before := eventGroups(t, decodeSettings(t, folder), "PostToolUse")
	o := workbenchOpts(folder, newFakeClaude())
	for range 2 {
		if _, err := InstallWorkbench(context.Background(), o); err != nil {
			t.Fatalf("install: %v", err)
		}
	}
	outside := outsideTouchSpec.command(o.Bin, 7)
	state := WorkbenchSessionStateHookCommand(o.Bin, 7)
	groups := eventGroups(t, decodeSettings(t, folder), "PostToolUse")
	if !reflect.DeepEqual(groups[0], before[0]) {
		t.Fatalf("PROJ-04: the owner's Read group changed: %#v", groups[0])
	}
	if countCommand(groups, "echo owner-any") != 1 || countCommand(groups, state) != 1 {
		t.Fatalf("PROJ-04: the owner's entry and the state entry must both stay, once: %#v", groups)
	}
	// Ours, exactly once, alone in its own matcher group (never in the
	// owner's Read group), synchronous.
	if rest := withoutOutsideTouchGroup(t, groups, outside); countCommand(rest, outside) != 0 {
		t.Fatalf("our entry must be in no other group: %#v", rest)
	}
	st, err := StatusWorkbench(context.Background(), o)
	if err != nil || !st.OutsideTouch || !st.StateHooks {
		t.Fatalf("status after install: %+v err=%v", st, err)
	}

	// An entry of ours written by another binary is updated in place, the
	// owner's key on it kept.
	moved := WorkbenchInstallOptions{WorkbenchID: 7, Folder: folder, Bin: "/opt/watchtower", Run: o.Run}
	m := decodeSettings(t, folder)
	for _, g := range eventGroups(t, m, "PostToolUse") {
		gm := g.(map[string]any)
		if gm["matcher"] == sessionagent.OutsideTouchMatcher {
			gm["hooks"].([]any)[0].(map[string]any)["statusMessage"] = "owner's"
		}
	}
	writeSettingsMap(t, folder, m)
	if _, err := InstallWorkbench(context.Background(), moved); err != nil {
		t.Fatalf("reinstall: %v", err)
	}
	groups = eventGroups(t, decodeSettings(t, folder), "PostToolUse")
	movedCmd := outsideTouchSpec.command(moved.Bin, 7)
	if countCommand(groups, outside) != 0 || countCommand(groups, movedCmd) != 1 {
		t.Fatalf("PROJ-04: the stale entry is updated in place, never doubled: %#v", groups)
	}
	for _, g := range groups {
		gm := g.(map[string]any)
		if gm["matcher"] == sessionagent.OutsideTouchMatcher && gm["hooks"].([]any)[0].(map[string]any)["statusMessage"] != "owner's" {
			t.Fatalf("PROJ-04: the owner's key on our entry was dropped: %#v", gm)
		}
	}
}

// writeSettingsMap writes m as folder's settings file.
func writeSettingsMap(t *testing.T, folder string, m map[string]any) {
	t.Helper()
	raw, err := json.Marshal(m)
	if err != nil {
		t.Fatalf("encoding settings: %v", err)
	}
	writeTestFile(t, settingsFile(folder), string(raw))
}

func TestProj02_RemoveDropsTheOutsideTouchHook(t *testing.T) {
	folder := fakeRepo(t)
	const owner = `{"hooks": {"PostToolUse": [{"matcher": "Read", "hooks": [{"type": "command", "command": "echo owner-read"}]}]}}`
	writeTestFile(t, settingsFile(folder), owner)
	before := decodeSettings(t, folder)
	o := workbenchOpts(folder, newFakeClaude())
	if _, err := InstallWorkbench(context.Background(), o); err != nil {
		t.Fatalf("install: %v", err)
	}
	if st, err := StatusWorkbench(context.Background(), o); err != nil || !st.OutsideTouch {
		t.Fatalf("fixture: the outside-bench entry must be installed: %+v err=%v", st, err)
	}
	if err := RemoveWorkbench(context.Background(), o); err != nil {
		t.Fatalf("remove: %v", err)
	}
	after := decodeSettings(t, folder)
	if !reflect.DeepEqual(after["hooks"], before["hooks"]) {
		t.Fatalf("PROJ-02: only the owner's PostToolUse entry may stay, got %#v", after["hooks"])
	}
	if ok, err := HasOutsideTouchHook(folder, 7); err != nil || ok {
		t.Fatalf("PROJ-02: the outside-bench entry survived the removal: ok=%v err=%v", ok, err)
	}
}
