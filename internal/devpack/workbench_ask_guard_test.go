package devpack

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// The ask guard (spec 2026-10-03 §6): a Stop prompt hook recognised by its
// marker line and a PreToolUse command hook denying AskUserQuestion, both
// installed, recognised and removed under the PROJ-02/04 rules.

// goldenAskGuardPrompt7 is the v3 text (board #478, owner approved
// 2026-10-09) for workbench 7, pinned verbatim: only the marker's <N> is
// substituted. The texts it replaced are testdata/askguard_prompt_v1.md and
// testdata/askguard_prompt_v2.md.
const goldenAskGuardPrompt7 = `[watchtower-workbench ask-guard 7]
You check a coding agent's final message of a turn.
Input (JSON): $ARGUMENTS
Return {"ok": true} unless a failure case below clearly applies. When unsure, return {"ok": true}.
Return {"ok": true} when stop_hook_active is true.
These pass, except that failure case 1 takes priority over this list:
- Unfinished work is never case 2: a progress report, a partial result, a next step the agent itself will take, work
  still left. A question or request to the owner inside a progress report is still case 1.
- A named ask is never a failure: a message that names "ask #<number>", including step-by-step help for the owner on
  that ask.
- A closing summary that says it called finish_session (for example "session finished") and lists what is left on the
  owner is not case 1 (those items are filed as asks separately). This item never affects case 2.
- Rhetorical questions, questions the agent answers itself, and offers such as "say if you want X".
Failure cases (return the first that applies):
1. Request left as text: last_assistant_message asks the owner for something (a question to answer, a decision to
   make, something to try or check by hand, something to review) and names no "ask #<number>". Return {"ok": false,
   "reason": "You asked the owner in plain text. File it with ask_owner (kind question, check or review), name it as
   'ask #<id>' in your text, then stop."}
2. Finished without saying so: last_assistant_message says all of this session's work is complete with nothing left
   for the agent to do, and does not say it called finish_session (for example "session finished"). Return
   {"ok": false, "reason": "Your work in this session looks complete. Call finish_session with a 2-3 line summary for
   the owner (what was done, the PRs, what is left on them), say 'session finished', then stop."}
Otherwise return {"ok": true}.`

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

// The v4 classifier text (spec 2026-10-10-owner-asks-v2 Part 4.4) is the
// golden, byte for byte.
func TestAskGuardClassifier_IsTheV4Golden(t *testing.T) {
	golden, err := os.ReadFile(filepath.Join("testdata", "askguard_classifier_v4.golden"))
	if err != nil {
		t.Fatal(err)
	}
	if AskGuardClassifier != string(golden) {
		t.Fatalf("the ask guard classifier drifted from the v4 golden:\n got %q\nwant %q", AskGuardClassifier, golden)
	}
}

// PROJ-13: the classifier passes a continued turn, a turn that filed an ask
// and a finished session that says so, so it can never trap the agent. Since
// v4 (spec 2026-10-10-owner-asks-v2 Part 11.1) each v3 clause this test
// checked maps to a clause of the v4 golden below or to a named Go guard:
// the stop_hook_active pass is Go's (cmd TestProj13_ContinuedTurnNeverBlocks),
// and "names no ask #<number>" is the decision table's covered row (cmd
// TestProj13_StopGuardDecisionTable rows E7, E7a, E7b).
func TestProj13_AskGuardPromptPassesAContinuedTurnAndAFiledAsk(t *testing.T) {
	golden, err := os.ReadFile(filepath.Join("testdata", "askguard_classifier_v4.golden"))
	if err != nil {
		t.Fatal(err)
	}
	p := string(golden)
	for _, clause := range []string{
		// v3 "Return {"ok": true} unless a failure case below clearly applies." and
		// "When unsure, return {"ok": true}." — outline 2.
		`Return the default unless a case below clearly` + "\n" + `   applies, and when unsure.`,
		// v3 "These pass, except that failure case 1 takes priority over this list:" — outline 7.
		`The request check takes priority over the not-complete list in 7`,
		// v3 "- Unfinished work is never case 2 …" — outline 8 and outline 7.
		`Unfinished work is never` + "\n" + `   complete: a progress report, a partial result, a next step the agent itself will take, work still left`,
		`a question or request to the owner inside a` + "\n" + `   progress report is still "chat" or "full".`,
		// v3 "- A named ask is never a failure: … including step-by-step help …" — outline 3.
		`names_ask is true when the message names an ask ("ask #<number>"), including step-by-step help for the owner on` +
			"\n" + `   that ask.`,
		`request_outside_ask is true when the message's request (chat or full) is something other than what a` + "\n" +
			`   named ask carries`,
		// v3 "- A closing summary that says it called finish_session … never affects case 2." — outline 4.
		`closing_summary is true when the message says it called finish_session (for example "session finished") and lists` +
			"\n" + `   what is left on the owner. Those items are filed as asks separately, so such a list is never a request.` +
			"\n" + `   closing_summary never affects complete_unreported.`,
		// v3 "does not say it called finish_session (for example "session finished")" — outline 8.
		`and does not say it called finish_session (for example "session finished")`,
	} {
		if !strings.Contains(p, clause) {
			t.Fatalf("PROJ-13: the classifier lost the pass clause %q", clause)
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
	assertAskGuardStopGroups(t, eventGroups(t, m, "Stop"), o.Bin)
	assertAskToolBlockGroup(t, eventGroups(t, m, "PreToolUse"), o.Bin)

	st, err := StatusWorkbench(context.Background(), o)
	if err != nil || !st.AskGuard || !st.AskToolBlock {
		t.Fatalf("status after install: %+v err=%v", st, err)
	}
	if rep, err := InstallWorkbench(context.Background(), o); err != nil || rep.HookChanged {
		t.Fatalf("reinstall: changed=%v err=%v", rep.HookChanged, err)
	}
}

// assertAskGuardStopGroups: a fresh install's Stop event holds the drift
// command and exactly one prompt hook, the golden prompt with its defaults.
func assertAskGuardStopGroups(t *testing.T, stop []any, bin string) {
	t.Helper()
	prompts := promptHooks(stop)
	if len(stop) != 2 || len(prompts) != 1 || countCommand(stop, WorkbenchStopHookCommand(bin, 7)) != 1 {
		t.Fatalf("Stop must hold the drift command and one prompt hook, got %#v", stop)
	}
	if p := prompts[0]; p["prompt"] != goldenAskGuardPrompt7 || p["timeout"] != float64(30) || p["async"] != nil {
		t.Fatalf("the prompt hook is %#v", p)
	}
}

// assertAskToolBlockGroup: a fresh install's PreToolUse event holds one
// AskUserQuestion group running our synchronous block command.
func assertAskToolBlockGroup(t *testing.T, pre []any, bin string) {
	t.Helper()
	cmd := WorkbenchAskGuardHookCommand(bin, 7)
	if len(pre) != 1 || countCommand(pre, cmd) != 1 {
		t.Fatalf("PreToolUse must hold one group running %q, got %#v", cmd, pre)
	}
	g := pre[0].(map[string]any)
	h := g["hooks"].([]any)[0].(map[string]any)
	if g["matcher"] != "AskUserQuestion" || h["type"] != "command" || h["timeout"] != float64(5) || h["async"] != nil {
		t.Fatalf("the PreToolUse group is %#v", g)
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
			assertAskToolBlockMovedOut(t, eventGroups(t, decodeSettings(t, dir), "PreToolUse"), cmd)
			if ok, err := HasAskToolBlockHook(dir, 7); err != nil || !ok {
				t.Fatalf("after the repair it is installed: ok=%v err=%v", ok, err)
			}
			if changed, err := RemoveAskGuardHooks(dir, 7); err != nil || !changed {
				t.Fatalf("remove: changed=%v err=%v", changed, err)
			}
		})
	}
}

// assertAskToolBlockMovedOut: after a repair the owner's group keeps only the
// owner's hook and ours sits in an AskUserQuestion group of its own after it.
func assertAskToolBlockMovedOut(t *testing.T, pre []any, cmd string) {
	t.Helper()
	if len(pre) != 2 || countCommand(pre[:1], "echo owner-pre") != 1 || countCommand(pre[:1], cmd) != 0 {
		t.Fatalf("the owner's group must keep only the owner's hook, got %#v", pre)
	}
	if g := pre[1].(map[string]any); g["matcher"] != "AskUserQuestion" || countCommand(pre[1:], cmd) != 1 {
		t.Fatalf("ours must move to its own AskUserQuestion group, got %#v", g)
	}
}

// askGuardPromptFixture is an older prompt for workbenchID: the upgrade
// fixture testdata/<file> with its marker substituted, as an install from
// before the current text wrote it.
func askGuardPromptFixture(t *testing.T, file string, workbenchID int64) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", file))
	if err != nil {
		t.Fatal(err)
	}
	body, ok := strings.CutPrefix(strings.TrimSuffix(string(raw), "\n"), askGuardMarkerTemplate)
	if !ok {
		t.Fatalf("the %s fixture must open with %s", file, askGuardMarkerTemplate)
	}
	return askGuardMarker(workbenchID) + body
}

// stopPromptHook returns the prompt text of the Stop prompt hook whose
// first line is marker, "" when there is none.
func stopPromptHook(t *testing.T, folder, marker string) string {
	t.Helper()
	for _, p := range promptHooks(eventGroups(t, decodeSettings(t, folder), "Stop")) {
		if text, _ := p["prompt"].(string); opensWithLine(text, marker) {
			return text
		}
	}
	return ""
}

// PROJ-13 (with PROJ-04): a resync sets our prompt to the current text
// (v3) whether it holds an older text (v1, v2) byte-exact or an owner's edit
// of it; another workbench's older prompt is left as it is; a second resync
// changes nothing.
func TestProj13_OlderPromptsAreUpgradedToTheCurrent(t *testing.T) {
	for _, file := range []string{"askguard_prompt_v1.md", "askguard_prompt_v2.md"} {
		if askGuardPromptFixture(t, file, 7) == askGuardPrompt(7) {
			t.Fatalf("the shipped prompt must differ from %s, or there is nothing to upgrade", file)
		}
	}
	for _, tc := range []struct{ name, file, ours string }{
		{"v1", "askguard_prompt_v1.md", askGuardPromptFixture(t, "askguard_prompt_v1.md", 7)},
		{"edited v1", "askguard_prompt_v1.md", askGuardPromptFixture(t, "askguard_prompt_v1.md", 7) + "\nAlso check the tests ran."},
		{"v2", "askguard_prompt_v2.md", askGuardPromptFixture(t, "askguard_prompt_v2.md", 7)},
		{"edited v2", "askguard_prompt_v2.md", askGuardPromptFixture(t, "askguard_prompt_v2.md", 7) + "\nAlso check the tests ran."},
	} {
		t.Run(tc.name, func(t *testing.T) {
			folder := fakeRepo(t)
			other := askGuardPromptFixture(t, tc.file, 8)
			settings := map[string]any{"hooks": map[string]any{"Stop": []any{
				map[string]any{"hooks": []any{map[string]any{"type": "prompt", "prompt": tc.ours, "timeout": 30}}},
				map[string]any{"hooks": []any{map[string]any{"type": "prompt", "prompt": other, "timeout": 30}}},
			}}}
			raw, err := json.MarshalIndent(settings, "", "  ")
			if err != nil {
				t.Fatal(err)
			}
			writeTestFile(t, settingsFile(folder), string(raw))
			o := workbenchOpts(folder, newFakeClaude())
			if _, err := InstallWorkbench(context.Background(), o); err != nil {
				t.Fatalf("install: %v", err)
			}
			if got := stopPromptHook(t, folder, askGuardMarker(7)); got != goldenAskGuardPrompt7 {
				t.Fatalf("our prompt must be set to the current text, got %q", got)
			}
			if got := stopPromptHook(t, folder, askGuardMarker(8)); got != other {
				t.Fatalf("another workbench's prompt must stay as it was, got %q", got)
			}
			once := readTestFile(t, settingsFile(folder))
			rep, err := InstallWorkbench(context.Background(), o)
			if err != nil || rep.HookChanged {
				t.Fatalf("a second resync must change no hook: %+v err=%v", rep, err)
			}
			if twice := readTestFile(t, settingsFile(folder)); twice != once {
				t.Fatalf("a second resync rewrote the settings:\n%s\nwas\n%s", twice, once)
			}
		})
	}
}
