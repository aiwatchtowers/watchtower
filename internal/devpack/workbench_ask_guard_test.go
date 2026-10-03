package devpack

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
)

// The ask guard (spec 2026-10-03 §6): a Stop prompt hook recognised by its
// marker line and a PreToolUse command hook denying AskUserQuestion, both
// installed, recognised and removed under the PROJ-02/04 rules.

// goldenAskGuardPrompt7 is the spec's §6.2 text for workbench 7, pinned
// verbatim: only the marker's <N> is substituted.
const goldenAskGuardPrompt7 = `[watchtower-workbench ask-guard 7]
You check whether a coding agent left a request to its owner as plain text instead of filing it.
Input (JSON): $ARGUMENTS
Return {"ok": true} when ANY of these holds:
- stop_hook_active is true;
- last_assistant_message says it filed an ask, for example by naming "ask #<number>";
- last_assistant_message does not ask the owner to do, decide, check, review or answer anything.
Return {"ok": false, "reason": "You asked the owner in plain text. File it with ask_owner (kind question, check or review), name it as 'ask #<id>' in your text, then stop."}
only when last_assistant_message clearly waits on the owner: a question to them, a decision
they must make, something they must try or check by hand, or a document they must read.
Rhetorical questions, questions the agent answers itself, summaries of finished work and
offers such as "say if you want X" are NOT requests. When unsure, return {"ok": true}.`

// promptHooks returns every hook object of type prompt across groups.
func promptHooks(groups []any) []map[string]any {
	var out []map[string]any
	for _, g := range groups {
		gm, _ := g.(map[string]any)
		hs, _ := gm["hooks"].([]any)
		for _, h := range hs {
			if hm, _ := h.(map[string]any); hm["type"] == "prompt" {
				out = append(out, hm)
			}
		}
	}
	return out
}

func TestAskGuardPrompt_IsTheGoldenWithTheMarkerSubstituted(t *testing.T) {
	if got := askGuardPrompt(7); got != goldenAskGuardPrompt7 {
		t.Fatalf("the ask guard prompt drifted from the spec's text:\n got %q\nwant %q", got, goldenAskGuardPrompt7)
	}
	if !strings.HasPrefix(askGuardPrompt(12), "[watchtower-workbench ask-guard 12]\n") {
		t.Fatalf("the marker names the workbench: %q", askGuardPrompt(12)[:40])
	}
}

// PROJ-13: the Stop prompt hook passes a continued turn and a turn that
// filed an ask, so it can never trap the agent.
func TestProj13_AskGuardPromptPassesAContinuedTurnAndAFiledAsk(t *testing.T) {
	p := askGuardPrompt(7)
	for _, clause := range []string{
		`Return {"ok": true} when ANY of these holds:`,
		"- stop_hook_active is true;",
		`- last_assistant_message says it filed an ask, for example by naming "ask #<number>";`,
		`When unsure, return {"ok": true}.`,
	} {
		if !strings.Contains(p, clause) {
			t.Fatalf("PROJ-13: the prompt lost the pass clause %q", clause)
		}
	}
}

func TestWorkbenchAskGuardHookCommand(t *testing.T) {
	got := WorkbenchAskGuardHookCommand("/tmp/Application Support/watchtower", 3)
	if got != "'/tmp/Application Support/watchtower' workbench ask-guard --workbench 3 --pre-tool-use" {
		t.Fatalf("got %q", got)
	}
}

func TestInstallWorkbenchInstallsTheAskGuardHooks(t *testing.T) {
	folder := fakeRepo(t)
	o := workbenchOpts(folder, newFakeClaude())
	for range 2 {
		if _, err := InstallWorkbench(context.Background(), o); err != nil {
			t.Fatalf("install: %v", err)
		}
	}
	m := decodeSettings(t, folder)

	stop := eventGroups(t, m, "Stop")
	prompts := promptHooks(stop)
	if len(stop) != 2 || len(prompts) != 1 || countCommand(stop, WorkbenchStopHookCommand(o.Bin, 7)) != 1 {
		t.Fatalf("Stop must hold the drift command and one prompt hook, got %#v", stop)
	}
	if p := prompts[0]; p["prompt"] != goldenAskGuardPrompt7 || p["timeout"] != float64(30) || p["async"] != nil {
		t.Fatalf("the prompt hook is %#v", p)
	}

	pre := eventGroups(t, m, "PreToolUse")
	cmd := WorkbenchAskGuardHookCommand(o.Bin, 7)
	if len(pre) != 1 || countCommand(pre, cmd) != 1 {
		t.Fatalf("PreToolUse must hold one group running %q, got %#v", cmd, pre)
	}
	g := pre[0].(map[string]any)
	h := g["hooks"].([]any)[0].(map[string]any)
	if g["matcher"] != "AskUserQuestion" || h["type"] != "command" || h["timeout"] != float64(5) || h["async"] != nil {
		t.Fatalf("the PreToolUse group is %#v", g)
	}

	st, err := StatusWorkbench(context.Background(), o)
	if err != nil || !st.AskGuard || !st.AskToolBlock {
		t.Fatalf("status after install: %+v err=%v", st, err)
	}
	if rep, err := InstallWorkbench(context.Background(), o); err != nil || rep.HookChanged {
		t.Fatalf("reinstall: changed=%v err=%v", rep.HookChanged, err)
	}
}

func TestProj04_AskGuardReplacesOurEditedPromptAndKeepsOwnerHooks(t *testing.T) {
	folder := fakeRepo(t)
	const owner = `{
  "model": "sonnet",
  "hooks": {
    "Stop": [
      {"hooks": [{"type": "command", "command": "echo owner-stop"}]},
      {"hooks": [{"type": "prompt", "prompt": "[watchtower-workbench ask-guard 7]\nthe owner rewrote this", "timeout": 12, "x-owner": 1.50}]},
      {"hooks": [{"type": "prompt", "prompt": "[watchtower-workbench ask-guard 8]\nanother workbench"}]},
      {"hooks": [{"type": "prompt", "prompt": "Is the work done? [watchtower-workbench ask-guard 7]"}]}
    ],
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo owner-pre"}]}]
  }
}`
	writeTestFile(t, settingsFile(folder), owner)
	before := decodeSettings(t, folder)
	o := workbenchOpts(folder, newFakeClaude())
	if _, err := InstallWorkbench(context.Background(), o); err != nil {
		t.Fatalf("install: %v", err)
	}
	after := decodeSettings(t, folder)
	if after["model"] != "sonnet" {
		t.Fatalf("PROJ-04: the owner's model changed: %#v", after["model"])
	}
	stop, stopBefore := eventGroups(t, after, "Stop"), eventGroups(t, before, "Stop")
	// Ours is replaced in place; its other keys stay.
	ours := stop[1].(map[string]any)["hooks"].([]any)[0].(map[string]any)
	if ours["prompt"] != goldenAskGuardPrompt7 || ours["type"] != "prompt" || ours["timeout"] != float64(12) {
		t.Fatalf("our edited prompt hook must be replaced in place, got %#v", ours)
	}
	for _, i := range []int{0, 2, 3} {
		if !reflect.DeepEqual(stop[i], stopBefore[i]) {
			t.Fatalf("PROJ-04: Stop group %d changed: %#v", i, stop[i])
		}
	}
	if len(stop) != 5 || len(promptHooks(stop)) != 3 {
		t.Fatalf("Stop must hold the owner's groups, ours and the drift command, got %#v", stop)
	}
	pre := eventGroups(t, after, "PreToolUse")
	if len(pre) != 2 || !reflect.DeepEqual(pre[0], eventGroups(t, before, "PreToolUse")[0]) {
		t.Fatalf("PROJ-04: the owner's PreToolUse group must stay first and as it was, got %#v", pre)
	}
	if raw := readTestFile(t, settingsFile(folder)); !strings.Contains(raw, `"x-owner": 1.50`) {
		t.Fatalf("PROJ-04: a number literal on our entry changed:\n%s", raw)
	}
}

func TestProj04_MalformedPreToolUseLeavesTheFileByteIdentical(t *testing.T) {
	dir := t.TempDir()
	const content = `{"hooks": {"PreToolUse": {"matcher": "Bash"}}}`
	writeTestFile(t, settingsFile(dir), content)
	_, err := InstallWorkbench(context.Background(), workbenchOpts(dir, newFakeClaude()))
	if !errors.Is(err, ErrMalformedSettings) || strings.Count(err.Error(), "malformed") != 1 {
		t.Fatalf("expected ErrMalformedSettings reported once, got %v", err)
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
}

func TestRemoveAskGuardHooksKeepsTheOwnerEntries(t *testing.T) {
	dir := t.TempDir()
	const owner = `{"hooks": {
  "Stop": [{"hooks": [{"type": "prompt", "prompt": "Check the work: $ARGUMENTS"}]}],
  "PreToolUse": [{"matcher": "AskUserQuestion", "hooks": [{"type": "command", "command": "echo owner-pre"}]}]
}}`
	writeTestFile(t, settingsFile(dir), owner)
	before := decodeSettings(t, dir)
	if changed, err := InstallAskGuardHooks(dir, "/tmp/acme bin/watchtower", 7); err != nil || !changed {
		t.Fatalf("install: changed=%v err=%v", changed, err)
	}
	if changed, err := RemoveAskGuardHooks(dir, 7); err != nil || !changed {
		t.Fatalf("remove: changed=%v err=%v", changed, err)
	}
	if got := decodeSettings(t, dir); !reflect.DeepEqual(got, before) {
		t.Fatalf("PROJ-04: only our entries may go, got %#v", got)
	}
}

func TestStatusWorkbench_AskGuardFlagsEachMissingHook(t *testing.T) {
	folder := fakeRepo(t)
	o := workbenchOpts(folder, newFakeClaude())
	if _, err := InstallWorkbench(context.Background(), o); err != nil {
		t.Fatalf("install: %v", err)
	}
	for _, spec := range []hookSpec{askGuardSpec, askToolBlockSpec} {
		t.Run(spec.event, func(t *testing.T) {
			if changed, err := removeHook(folder, spec, 7); err != nil || !changed {
				t.Fatalf("remove %s: changed=%v err=%v", spec.event, changed, err)
			}
			st, err := StatusWorkbench(context.Background(), o)
			if err != nil || st.AskGuard == (spec == askGuardSpec) || st.AskToolBlock == (spec == askToolBlockSpec) || !st.StopHook {
				t.Fatalf("status with the %s entry missing: %+v err=%v", spec.event, st, err)
			}
			rep, err := InstallWorkbench(context.Background(), o)
			if err != nil || !rep.HookChanged {
				t.Fatalf("the repair re-adds it: changed=%v err=%v", rep.HookChanged, err)
			}
		})
	}
}

// The prompt hook is ours only when its first line is exactly the marker of
// this workbench.
func TestIsOurHook_AskGuardPromptMarker(t *testing.T) {
	for _, tc := range []struct {
		prompt string
		ours   bool
	}{
		{"[watchtower-workbench ask-guard 7]\nanything", true},
		{"[watchtower-workbench ask-guard 7]", true},
		{"[watchtower-workbench ask-guard 7]\r\nanything", true},
		{"[watchtower-workbench ask-guard 70]\nanything", false},
		{"[watchtower-workbench ask-guard 7] and more\nanything", false},
		{" [watchtower-workbench ask-guard 7]\nanything", false},
		{"text\n[watchtower-workbench ask-guard 7]", false},
		{"", false},
	} {
		h := map[string]any{"type": "prompt", "prompt": tc.prompt}
		if got := isOurHook(h, askGuardSpec, 7); got != tc.ours {
			t.Errorf("%q: ours=%v, want %v", tc.prompt, got, tc.ours)
		}
	}
	// A command hook is never the prompt hook, and the prompt hook never a
	// command one.
	if isOurHook(map[string]any{"type": "command", "command": "/usr/local/bin/watchtower workbench ask-guard --workbench 7 --pre-tool-use"}, askGuardSpec, 7) {
		t.Fatal("a command hook matched the prompt spec")
	}
	if isOurHook(map[string]any{"type": "prompt", "prompt": "[watchtower-workbench ask-guard 7]"}, askToolBlockSpec, 7) {
		t.Fatal("a prompt hook matched the command spec")
	}
}

// Our AskUserQuestion block sitting in a group with another matcher ("" or
// "*" would deny every tool) is not reported installed, and an install
// moves it into a group of its own; the owner's hook in that group stays.
func TestAskToolBlock_InAnotherMatcherGroupIsRepaired(t *testing.T) {
	for _, matcher := range []string{`"matcher": "",`, `"matcher": "*",`, ``, `"matcher": "Bash",`} {
		t.Run(matcher, func(t *testing.T) {
			dir := t.TempDir()
			cmd := WorkbenchAskGuardHookCommand("/tmp/acme bin/watchtower", 7)
			writeTestFile(t, settingsFile(dir), `{"hooks": {"PreToolUse": [{`+matcher+` "hooks": [`+
				`{"type": "command", "command": "echo owner-pre"}, {"type": "command", "command": "'/tmp/acme bin/watchtower' workbench ask-guard --workbench 7 --pre-tool-use"}]}]}}`)
			if ok, err := HasAskToolBlockHook(dir, 7); err != nil || ok {
				t.Fatalf("an entry outside an AskUserQuestion group must not count: ok=%v err=%v", ok, err)
			}
			if changed, err := InstallAskGuardHooks(dir, "/tmp/acme bin/watchtower", 7); err != nil || !changed {
				t.Fatalf("install: changed=%v err=%v", changed, err)
			}
			pre := eventGroups(t, decodeSettings(t, dir), "PreToolUse")
			if len(pre) != 2 || countCommand(pre[:1], "echo owner-pre") != 1 || countCommand(pre[:1], cmd) != 0 {
				t.Fatalf("the owner's group must keep only the owner's hook, got %#v", pre)
			}
			if g := pre[1].(map[string]any); g["matcher"] != "AskUserQuestion" || countCommand(pre[1:], cmd) != 1 {
				t.Fatalf("ours must move to its own AskUserQuestion group, got %#v", g)
			}
			if ok, err := HasAskToolBlockHook(dir, 7); err != nil || !ok {
				t.Fatalf("after the repair it is installed: ok=%v err=%v", ok, err)
			}
			if changed, err := RemoveAskGuardHooks(dir, 7); err != nil || !changed {
				t.Fatalf("remove: changed=%v err=%v", changed, err)
			}
		})
	}
}
