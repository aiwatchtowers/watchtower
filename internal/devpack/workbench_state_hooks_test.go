package devpack

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
)

// The session state hooks (UserPromptSubmit, Notification, PostToolUse,
// StopFailure) are installed, recognised and removed under the same
// PROJ-02/04 rules as the SessionStart and Stop hooks.

var stateEvents = []string{"UserPromptSubmit", "Notification", "PostToolUse", "StopFailure"}

func eventGroups(t *testing.T, m map[string]any, event string) []any {
	t.Helper()
	hooks, _ := m["hooks"].(map[string]any)
	groups, ok := hooks[event].([]any)
	if !ok {
		t.Fatalf("hooks.%s is missing or not an array: %#v", event, m["hooks"])
	}
	return groups
}

func TestWorkbenchSessionStateHookCommand(t *testing.T) {
	got := WorkbenchSessionStateHookCommand("/tmp/Application Support/watchtower", 3)
	if got != "'/tmp/Application Support/watchtower' workbench session-state --workbench 3" {
		t.Fatalf("got %q", got)
	}
}

func TestInstallWorkbenchInstallsTheStateHooks(t *testing.T) {
	folder := fakeRepo(t)
	o := workbenchOpts(folder, newFakeClaude())
	for range 2 {
		if _, err := InstallWorkbench(context.Background(), o); err != nil {
			t.Fatalf("install: %v", err)
		}
	}
	cmd := WorkbenchSessionStateHookCommand(o.Bin, 7)
	m := decodeSettings(t, folder)
	for _, event := range stateEvents {
		groups := eventGroups(t, m, event)
		if len(groups) != 1 || countCommand(groups, cmd) != 1 {
			t.Fatalf("expected one %s group running %q, got %#v", event, cmd, groups)
		}
		g := groups[0].(map[string]any)
		if _, ok := g["matcher"]; ok {
			t.Fatalf("%s: our group has no matcher (every notification type): %#v", event, g)
		}
		h := g["hooks"].([]any)[0].(map[string]any)
		if h["async"] != true || h["timeout"] != float64(5) || h["type"] != "command" {
			t.Fatalf("%s: entry %#v, want an async command with timeout 5", event, h)
		}
	}
	// Stop keeps its one synchronous entry; the state is written by it.
	stop := eventGroups(t, m, "Stop")[0].(map[string]any)["hooks"].([]any)[0].(map[string]any)
	if _, ok := stop["async"]; ok || len(eventGroups(t, m, "Stop")) != 1 {
		t.Fatalf("the Stop entry must stay one synchronous entry: %#v", stop)
	}
	st, err := StatusWorkbench(context.Background(), o)
	if err != nil || !st.StateHooks {
		t.Fatalf("status after install: %+v err=%v", st, err)
	}
	rep, err := InstallWorkbench(context.Background(), o)
	if err != nil || rep.HookChanged {
		t.Fatalf("reinstall: changed=%v err=%v", rep.HookChanged, err)
	}
}

func TestProj04_StateHooksKeepOwnerHooksAndKeys(t *testing.T) {
	folder := fakeRepo(t)
	const owner = `{
  "model": "sonnet",
  "hooks": {
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "echo owner-prompt", "timeout": 2}]}],
    "Notification": [{"matcher": "permission_prompt", "hooks": [{"type": "command", "command": "say hi", "async": false}], "x-owner": 1.50}]
  }
}`
	writeTestFile(t, settingsFile(folder), owner)
	before := decodeSettings(t, folder)
	o := workbenchOpts(folder, newFakeClaude())
	if _, err := InstallWorkbench(context.Background(), o); err != nil {
		t.Fatalf("install: %v", err)
	}
	cmd := WorkbenchSessionStateHookCommand(o.Bin, 7)
	after := decodeSettings(t, folder)
	if after["model"] != "sonnet" {
		t.Fatalf("PROJ-04: the owner's model changed: %#v", after["model"])
	}
	for _, event := range []string{"UserPromptSubmit", "Notification"} {
		groups := eventGroups(t, after, event)
		ownerGroup := eventGroups(t, before, event)[0]
		if len(groups) != 2 || !reflect.DeepEqual(groups[0], ownerGroup) || countCommand(groups, cmd) != 1 {
			t.Fatalf("PROJ-04: %s must hold the owner's group as it was plus ours, got %#v", event, groups)
		}
	}
	if raw := readTestFile(t, settingsFile(folder)); !strings.Contains(raw, `"x-owner": 1.50`) {
		t.Fatalf("PROJ-04: the owner's number literal changed:\n%s", raw)
	}

	if changed, err := RemoveStateHooks(folder, 7); err != nil || !changed {
		t.Fatalf("remove: changed=%v err=%v", changed, err)
	}
	removed := decodeSettings(t, folder)
	for _, event := range []string{"UserPromptSubmit", "Notification"} {
		if got := eventGroups(t, removed, event); !reflect.DeepEqual(got, eventGroups(t, before, event)) {
			t.Fatalf("PROJ-04: only our %s entry may go, got %#v", event, got)
		}
	}
	hooks := removed["hooks"].(map[string]any)
	for _, event := range []string{"PostToolUse", "StopFailure"} {
		if _, ok := hooks[event]; ok {
			t.Fatalf("an event left empty is dropped: %s in %#v", event, hooks)
		}
	}
}

func TestProj04_MalformedStateEventLeavesTheFileByteIdentical(t *testing.T) {
	for _, event := range stateEvents {
		t.Run(event, func(t *testing.T) {
			dir := t.TempDir()
			content := `{"hooks": {"` + event + `": {"hooks": []}}}`
			writeTestFile(t, settingsFile(dir), content)
			_, err := InstallWorkbench(context.Background(), workbenchOpts(dir, newFakeClaude()))
			if !errors.Is(err, ErrMalformedSettings) {
				t.Fatalf("expected ErrMalformedSettings, got %v", err)
			}
			if strings.Count(err.Error(), "malformed") != 1 {
				t.Fatalf("the malformed file must be reported once: %v", err)
			}
			if err := RemoveWorkbench(context.Background(), workbenchOpts(dir, newFakeClaude())); strings.Count(err.Error(), "malformed") != 1 {
				t.Fatalf("the removal reports the malformed file once: %v", err)
			}
			if _, err := StatusWorkbench(context.Background(), workbenchOpts(dir, newFakeClaude())); strings.Count(err.Error(), "malformed") != 1 {
				t.Fatalf("the status reports the malformed file once: %v", err)
			}
			if got := readTestFile(t, settingsFile(dir)); got != content {
				t.Fatalf("PROJ-04: a malformed file must be left byte-identical, got %s", got)
			}
			if _, err := InstallSessionStartHook(dir, testHookCmd, 7); !errors.Is(err, ErrMalformedSettings) {
				t.Fatalf("a malformed hooks.%s refuses the SessionStart install too: %v", event, err)
			}
		})
	}
}

func TestStatusWorkbench_StateHooksFalseWithOneMissing(t *testing.T) {
	folder := fakeRepo(t)
	o := workbenchOpts(folder, newFakeClaude())
	if _, err := InstallWorkbench(context.Background(), o); err != nil {
		t.Fatalf("install: %v", err)
	}
	for _, spec := range stateHookSpecs {
		t.Run(spec.event, func(t *testing.T) {
			if changed, err := removeHook(folder, spec, 7); err != nil || !changed {
				t.Fatalf("remove %s: changed=%v err=%v", spec.event, changed, err)
			}
			st, err := StatusWorkbench(context.Background(), o)
			if err != nil || st.StateHooks || !st.Hook || !st.StopHook {
				t.Fatalf("status with %s missing: %+v err=%v", spec.event, st, err)
			}
			rep, err := InstallWorkbench(context.Background(), o)
			if err != nil || !rep.HookChanged {
				t.Fatalf("the repair re-adds %s: changed=%v err=%v", spec.event, rep.HookChanged, err)
			}
		})
	}
}

// The state hooks have no pre-rename spelling: the empty legacy suffix must
// match nothing — not " " + "" + " 7", not a bare binary.
func TestLooksLikeOurHook_StateHookHasNoLegacyForm(t *testing.T) {
	spec := stateHookSpecs[0]
	for _, cmd := range []string{
		"/usr/local/bin/watchtower  7",
		"watchtower  7",
		"/usr/local/bin/watchtower",
		"'/tmp/acme bin/watchtower' project session-state --project 7",
	} {
		if looksLikeOurHook(cmd, spec, 7) || looksLikeLegacyHook(cmd, spec, 7) {
			t.Fatalf("%q must not be recognised as our state hook", cmd)
		}
	}
	if !looksLikeOurHook("/usr/local/bin/watchtower workbench session-state --workbench 7", spec, 7) {
		t.Fatal("the current command must be ours")
	}
	if looksLikeOurHook("/usr/local/bin/watchtower workbench session-state --workbench 8", spec, 7) {
		t.Fatal("another workbench's entry is not ours")
	}
}
