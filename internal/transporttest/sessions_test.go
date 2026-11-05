package transporttest

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"watchtower/internal/agentkind"
	"watchtower/internal/agentlog"
	"watchtower/internal/db"
	"watchtower/internal/devpack"
	"watchtower/internal/terminal"
)

// The Workbench session rows (spec §4.1, second table): each drives the
// agent's real hook commands — the ones `integrate` installs — through the
// built watchtower binary against a temp workspace, and reads the
// terminal_sessions row they write. A step is an intent ("prompt", "stop",
// …); the agent turns it into its own hook events and payloads (the hook
// payload fixtures of cmd/testdata), or into a pull signal, which no agent
// has yet (S1, S2: the rollout watch of §3.5 plugs into sessionAgent.pull).

// sessionStep is one intent of a session script.
type sessionStep string

const (
	stepPrompt        sessionStep = "prompt"
	stepTool          sessionStep = "tool"
	stepPermission    sessionStep = "permission"
	stepStop          sessionStep = "stop"
	stepFailure       sessionStep = "failure"
	stepInterrupt     sessionStep = "interrupt"
	stepSubagentStart sessionStep = "subagent-start"
	stepSubagentStop  sessionStep = "subagent-stop"
	stepForeignPrompt sessionStep = "foreign-prompt"
	// Pull-only intents (§3.5): the watch gives up on an unreadable
	// rollout and writes the row's watch issue; an automation's session()
	// waiting on the row ends.
	stepWatchGiveUp    sessionStep = "watch-give-up"
	stepAutomationWait sessionStep = "automation-wait"
)

// sessionStart is the SessionStart intent of one source.
func sessionStart(source string) sessionStep { return sessionStep("session-start:" + source) }

// sessionAgent is a Workbench agent kind as the suite drives it.
type sessionAgent struct {
	kind string
	// hooks returns the installed hook commands per event for the
	// workbench folder dir.
	hooks func(t *testing.T, dir string, workbenchID int64) map[string][]string
	// events maps an intent to the hook events it fires, each with the
	// payload fixture it starts from ("" = a minimal payload) and fields
	// to set.
	events map[sessionStep][]hookCall
	// pull reads the agent's transcript for an intent the hooks do not
	// report (§3.5 Watch) and writes what it finds; nil = no pull signal.
	pull func(t *testing.T, e *sessionEnv, step sessionStep) error
	// transcriptPath is where the agent keeps the session's transcript.
	transcriptPath func(e *sessionEnv) string
	// transcript writes the session's transcript (or rollout) from the
	// fixture of kind at path ("zstd": compressed; "missing": not at all).
	transcript func(t *testing.T, path, kind string)
	// agentHome is the agent's home for terminal.OpenTranscript.
	agentHome func(e *sessionEnv) string
}

type hookCall struct {
	event   string
	payload string // cmd/testdata/<payload>; "" = minimal
	set     map[string]any
}

// sessionEnv is one session cell's workspace.
type sessionEnv struct {
	t          *testing.T
	home       string
	folder     string
	db         *db.DB
	workbench  int64
	row        int64
	sessionID  string
	transcript string
	hooks      map[string][]string
	background []*exec.Cmd
	stderr     []string
}

const (
	sessionID        = "00000000-0000-4000-8000-0000000000a1"
	foreignSessionID = "00000000-0000-4000-8000-0000000000f0"
)

// nextSessionIDs is the conversation a SessionStart of each source moves to.
var nextSessionIDs = map[string]string{
	"resume":  "00000000-0000-4000-8000-0000000000b1",
	"clear":   "00000000-0000-4000-8000-0000000000b2",
	"compact": "00000000-0000-4000-8000-0000000000b3",
}

// sessionResult is what a session cell observed.
type sessionResult struct {
	// States is the row's agent_state after each step ("" = none).
	States []string
	Row    *db.TerminalSession
	// PendingPermissions counts the row's pending permission_requests.
	PendingPermissions int
	// SessionIDs is the row's agent session id after each step.
	SessionIDs []string
	// OpenTurns is the number of open subagent turns after each step.
	OpenTurns []int
	// PullErr is the pull signal's error for a step only it reports.
	PullErr error
	// WatchIssue is the row's agent_watch_issue after the steps (§3.5).
	WatchIssue string
	// WaitStatus and WaitReason are an automation session() wait's end,
	// filled by the stepAutomationWait pull.
	WaitStatus, WaitReason string
	// FeedEntries, FeedLiveOK and FeedErr are `workbench session-feed
	// --json`'s; Title and TitleErr the AI title's owner text
	// (terminal.OpenTranscript).
	FeedEntries int
	FeedLiveOK  bool
	FeedErr     error
	Title       string
	TitleErr    error
	// OlderWrote says a write stamped before the stored state landed.
	OlderWrote bool
	Stderr     []string
}

var claudeSession = &sessionAgent{
	kind: "claude",
	hooks: func(t *testing.T, dir string, wb int64) map[string][]string {
		for _, install := range []func() (bool, error){
			func() (bool, error) {
				return devpack.InstallSessionStartHook(dir, devpack.WorkbenchHookCommand(bins.watchtower, wb), wb)
			},
			func() (bool, error) {
				return devpack.InstallStopHook(dir, devpack.WorkbenchStopHookCommand(bins.watchtower, wb), wb)
			},
			func() (bool, error) { return devpack.InstallStateHooks(dir, bins.watchtower, wb) },
		} {
			if _, err := install(); err != nil {
				t.Fatal(err)
			}
		}
		return claudeSettingsHooks(t, filepath.Join(dir, ".claude", "settings.local.json"))
	},
	events: map[sessionStep][]hookCall{
		stepPrompt: {{event: "UserPromptSubmit"}},
		stepTool:   {{event: "PostToolUse", set: map[string]any{"tool_name": "Read", "tool_use_id": "toolu_fixture_1"}}},
		stepPermission: {
			{event: "PermissionRequest", set: map[string]any{"tool_name": "Bash", "tool_input": map[string]any{"command": "touch example.txt"}}},
			{event: "Notification", set: map[string]any{"notification_type": "permission_prompt", "message": "Claude needs your permission"}},
		},
		stepStop:    {{event: "Stop", payload: "stop_no_background_tasks.json"}},
		stepFailure: {{event: "StopFailure", payload: "stopfailure_rate_limit.json"}},
		// An Esc fires no Stop in Claude Code; the idle notice moves the row.
		stepInterrupt:     {{event: "Notification", set: map[string]any{"notification_type": "idle_prompt", "message": "Claude is waiting for your input"}}},
		stepSubagentStart: {{event: "SubagentStart", payload: "subagentstart_teammate.json"}},
		stepSubagentStop:  {{event: "SubagentStop", payload: "subagentstop_teammate.json"}},
		stepForeignPrompt: {{event: "UserPromptSubmit", set: map[string]any{"session_id": foreignSessionID}}},
	},
	transcriptPath: func(e *sessionEnv) string {
		return filepath.Join(e.home, ".claude", "projects", agentlog.Slug(e.folder), sessionID+".jsonl")
	},
	transcript: writeClaudeTranscript,
	agentHome:  func(e *sessionEnv) string { return filepath.Join(e.home, ".claude") },
}

var codexSession = &sessionAgent{
	kind: "codex",
	hooks: func(t *testing.T, _ string, _ int64) map[string][]string {
		out := map[string][]string{}
		for _, h := range devpack.CodexHookSet(bins.watchtower) {
			if strings.Contains(h.Command, "ask-guard") {
				continue // the ask guard calls a model; it records no state
			}
			out[h.Event] = append(out[h.Event], h.Command)
		}
		return out
	},
	events: map[sessionStep][]hookCall{
		stepPrompt:        {{event: "UserPromptSubmit", payload: "codex_hooks/user_prompt_submit.json"}},
		stepTool:          {{event: "PostToolUse", payload: "codex_hooks/post_tool_use.json"}},
		stepPermission:    {{event: "PermissionRequest", payload: "codex_hooks/permission_request.json"}},
		stepStop:          {{event: "Stop", payload: "codex_hooks/stop.json"}},
		stepSubagentStart: {{event: "SubagentStart", payload: "codex_hooks/subagent_start.json"}},
		stepSubagentStop:  {{event: "SubagentStop", payload: "codex_hooks/subagent_stop.json"}},
		stepForeignPrompt: {{event: "UserPromptSubmit", payload: "codex_hooks/user_prompt_submit.json",
			set: map[string]any{"session_id": foreignSessionID}}},
		// stepFailure and stepInterrupt: no hook (S1, S2) — the pull signal.
	},
	transcriptPath: func(e *sessionEnv) string {
		return filepath.Join(e.home, ".codex", "sessions", "2026", "11", "05", "rollout-2026-11-05T12-00-00-"+sessionID+".jsonl")
	},
	transcript: writeCodexRollout,
	agentHome:  func(e *sessionEnv) string { return filepath.Join(e.home, ".codex") },
}

// claudeSettingsHooks reads the command hooks of a Claude Code settings file.
func claudeSettingsHooks(t *testing.T, path string) map[string][]string {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var settings struct {
		Hooks map[string][]struct {
			Hooks []struct {
				Type    string `json:"type"`
				Command string `json:"command"`
			} `json:"hooks"`
		} `json:"hooks"`
	}
	if err := json.Unmarshal(raw, &settings); err != nil {
		t.Fatal(err)
	}
	out := map[string][]string{}
	for event, groups := range settings.Hooks {
		for _, g := range groups {
			for _, h := range g.Hooks {
				if h.Type == "command" {
					out[event] = append(out[event], h.Command)
				}
			}
		}
	}
	return out
}

// newSessionEnv makes the cell's workspace: a config naming workspace
// "test" under a fresh HOME, a workbench on a temp folder with the agent's
// hooks installed, and the agent's terminal_sessions row.
func newSessionEnv(t *testing.T, ag *sessionAgent) *sessionEnv {
	e := &sessionEnv{t: t, home: t.TempDir(), folder: t.TempDir(), sessionID: sessionID}
	writeFile(t, filepath.Join(e.home, ".config", "watchtower", "config.yaml"), "active_workspace: test\n")
	path := filepath.Join(e.home, ".local", "share", "watchtower", "test", "watchtower.db")
	raw, err := os.ReadFile(migratedDB(t))
	if err != nil {
		t.Fatal(err)
	}
	writeFile(t, path, string(raw))
	d, err := db.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = d.Close() })
	e.db = d
	if e.workbench, err = d.CreateWorkbench("acme", e.folder); err != nil {
		t.Fatal(err)
	}
	e.transcript = ag.transcriptPath(e)
	res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id, agent_transcript_path)
		VALUES (?, ?, 's', ?, ?, ?)`, e.workbench, ag.kind, e.folder, sessionID, e.transcript)
	if err != nil {
		t.Fatal(err)
	}
	e.row, _ = res.LastInsertId()
	e.hooks = ag.hooks(t, e.folder, e.workbench)
	t.Cleanup(e.stopBackground)
	return e
}

// payload builds a hook input: the fixture (or a minimal one) with the
// row's session id, folder and transcript, then the call's own fields.
func (e *sessionEnv) payload(c hookCall) []byte {
	m := map[string]any{}
	if c.payload != "" {
		raw, err := os.ReadFile(filepath.Join("..", "..", "cmd", "testdata", c.payload))
		if err != nil {
			e.t.Fatal(err)
		}
		if err := json.Unmarshal(raw, &m); err != nil {
			e.t.Fatal(err)
		}
	}
	m["session_id"] = e.sessionID
	m["cwd"] = e.folder
	m["transcript_path"] = e.transcript
	m["hook_event_name"] = c.event
	for k, v := range c.set {
		m[k] = v
	}
	b, err := json.Marshal(m)
	if err != nil {
		e.t.Fatal(err)
	}
	return b
}

// fire runs every installed command of the call's event with its payload.
// A PermissionRequest hook holds its prompt open for an answer, so it runs
// in the background until the cell ends.
func (e *sessionEnv) fire(c hookCall) {
	for _, command := range e.hooks[c.event] {
		cmd := exec.Command("/bin/sh", "-c", command)
		cmd.Dir = e.folder
		cmd.Env = append(e.environ(), "WATCHTOWER_TERMINAL_SESSION_ID="+strconv.FormatInt(e.row, 10))
		cmd.Stdin = bytes.NewReader(e.payload(c))
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		var stderr bytes.Buffer
		cmd.Stderr = &stderr
		if c.event == "PermissionRequest" && strings.Contains(command, "permission-wait") {
			if err := cmd.Start(); err != nil {
				e.t.Fatal(err)
			}
			e.background = append(e.background, cmd)
			continue
		}
		done := make(chan error, 1)
		if err := cmd.Start(); err != nil {
			e.t.Fatal(err)
		}
		go func() { done <- cmd.Wait() }()
		select {
		case err := <-done:
			if err != nil {
				e.t.Errorf("%s hook %q: %v", c.event, command, err)
			}
		case <-time.After(30 * time.Second):
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
			<-done
			e.t.Errorf("%s hook %q did not finish", c.event, command)
		}
		if s := strings.TrimSpace(stderr.String()); s != "" {
			e.stderr = append(e.stderr, s)
		}
	}
}

// environ is the hooks' environment: the cell's own HOME and CODEX_HOME,
// so session cells run in parallel.
func (e *sessionEnv) environ() []string {
	var env []string
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "HOME=") && !strings.HasPrefix(kv, "CODEX_HOME=") &&
			!strings.HasPrefix(kv, "WATCHTOWER_TERMINAL_SESSION_ID=") {
			env = append(env, kv)
		}
	}
	return append(env, "HOME="+e.home, "CODEX_HOME="+filepath.Join(e.home, ".codex"))
}

func (e *sessionEnv) stopBackground() {
	for _, cmd := range e.background {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
		done := make(chan struct{})
		go func() { _ = cmd.Wait(); close(done) }()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
			<-done
		}
	}
	e.background = nil
}

func (e *sessionEnv) rowNow() *db.TerminalSession {
	s, err := e.db.GetTerminalSession(e.row)
	if err != nil {
		e.t.Fatal(err)
	}
	return s
}

// openTurns counts the row's subagent turns still open (agent_turns JSON:
// start > stop).
func (e *sessionEnv) openTurns() int {
	var raw sql.NullString
	if err := e.db.QueryRow(`SELECT agent_turns FROM terminal_sessions WHERE id = ?`, e.row).Scan(&raw); err != nil {
		e.t.Fatal(err)
	}
	var turns struct {
		Turns map[string]struct{ Start, Stop string } `json:"turns"`
	}
	if raw.Valid {
		_ = json.Unmarshal([]byte(raw.String), &turns)
	}
	n := 0
	for _, tr := range turns.Turns {
		if tr.Start > tr.Stop {
			n++
		}
	}
	return n
}

// watchIssue is the row's agent_watch_issue, or the read's error text
// while the column does not exist (before G5's migration).
func (e *sessionEnv) watchIssue() string {
	var v sql.NullString
	if err := e.db.QueryRow(`SELECT agent_watch_issue FROM terminal_sessions WHERE id = ?`, e.row).Scan(&v); err != nil {
		return "unreadable column: " + err.Error()
	}
	return v.String
}

func (e *sessionEnv) pendingPermissions() int {
	var n int
	if err := e.db.QueryRow(`SELECT COUNT(*) FROM permission_requests WHERE terminal_session_id = ? AND status = 'pending'`, e.row).Scan(&n); err != nil {
		e.t.Fatal(err)
	}
	return n
}

// run plays a session scenario's script and reports what the row went
// through.
func (ag *sessionAgent) run(t *testing.T, s *Scenario) *sessionResult {
	e := newSessionEnv(t, ag)
	res := &sessionResult{}
	if s.Fixture.File != "" {
		ag.transcript(t, e.transcript, s.Fixture.File)
	}
	for _, step := range s.Fixture.Session {
		ag.play(e, step, res)
		if step == stepPermission {
			e.waitFor(func() bool { return e.pendingPermissions() > 0 })
			res.PendingPermissions = e.pendingPermissions()
		}
		row := e.rowNow()
		res.States = append(res.States, row.AgentState.String)
		res.SessionIDs = append(res.SessionIDs, row.ClaudeSessionID.String)
		res.OpenTurns = append(res.OpenTurns, e.openTurns())
	}
	switch s.Name {
	case "session-older-event":
		// A write stamped before the stored state writes nothing, through
		// the one writer both hook paths share.
		row := e.rowNow()
		wrote, err := e.db.SetTerminalAgentState(e.row, e.workbench, e.sessionID, "working",
			row.AgentStateAt.Add(-time.Minute), "", nil, true, db.AgentOrder{})
		if err != nil {
			t.Fatal(err)
		}
		res.OlderWrote = wrote
	case "session-transcript", "session-compressed-transcript":
		res.FeedEntries, res.FeedLiveOK, res.FeedErr = e.feed()
		res.Title, res.TitleErr = e.title(ag)
	}
	e.stopBackground()
	res.Row = e.rowNow()
	res.WatchIssue = e.watchIssue()
	res.Stderr = e.stderr
	return res
}

// play fires one intent: its hook events, or the pull signal when the
// agent's hooks do not report it.
func (ag *sessionAgent) play(e *sessionEnv, step sessionStep, res *sessionResult) {
	if source, ok := strings.CutPrefix(string(step), "session-start:"); ok {
		payload := "codex_hooks/session_start_" + source + ".json"
		if ag.kind == "claude" {
			payload = ""
		}
		if id, ok := nextSessionIDs[source]; ok {
			e.sessionID = id // a new conversation per source
		}
		e.fire(hookCall{event: "SessionStart", payload: payload, set: map[string]any{"source": source}})
		return
	}
	calls, ok := ag.events[step]
	if !ok {
		if ag.pull == nil {
			res.PullErr = fmt.Errorf("%s: no hook reports %q and no pull signal reads it", ag.kind, step)
			return
		}
		if err := ag.pull(e.t, e, step); err != nil {
			res.PullErr = err
		}
		return
	}
	for _, c := range calls {
		e.fire(c)
	}
}

func (e *sessionEnv) waitFor(cond func() bool) {
	deadline := time.Now().Add(5 * time.Second)
	for !cond() && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
}

// feed runs `workbench session-feed --json` for the row and counts its
// entries.
func (e *sessionEnv) feed() (int, bool, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, bins.watchtower, "workbench", "session-feed", "--session", strconv.FormatInt(e.row, 10), "--json")
	cmd.Dir = e.folder
	cmd.Env = e.environ()
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		return 0, false, fmt.Errorf("session-feed: %v: %s", err, strings.TrimSpace(stderr.String()))
	}
	var out struct {
		Entries []json.RawMessage `json:"entries"`
		LiveOK  bool              `json:"live_ok"`
	}
	if err := json.Unmarshal(stdout.Bytes(), &out); err != nil {
		return 0, false, fmt.Errorf("session-feed output: %v", err)
	}
	return len(out.Entries), out.LiveOK, nil
}

// title is the owner text the AI title is made from.
func (e *sessionEnv) title(ag *sessionAgent) (string, error) {
	tr, err := terminal.OpenTranscript(agentkind.Kind(ag.kind), e.sessionID, e.transcript, ag.agentHome(e))
	if err != nil {
		return "", err
	}
	return tr.OwnerText(400)
}

// writeClaudeTranscript writes a two-line Claude Code transcript (owner
// prompt, assistant answer) at path, zstd-compressed for kind "zstd".
func writeClaudeTranscript(t *testing.T, path, kind string) {
	writeTranscript(t, path, kind, filepath.Join("testdata", "claude", "session_transcript.jsonl"))
}

// writeCodexRollout writes a codex rollout at path from the fixture of
// kind: "rollout_ok", "rollout_failed", "rollout_aborted" or "zstd".
func writeCodexRollout(t *testing.T, path, kind string) {
	src := kind
	if kind == "zstd" || kind == "plain" {
		src = "rollout_ok"
	}
	writeTranscript(t, path, kind, filepath.Join("testdata", "codex", "session_"+src+".jsonl"))
}

func writeTranscript(t *testing.T, path, kind, src string) {
	t.Helper()
	if kind == "missing" {
		return
	}
	raw, err := os.ReadFile(src)
	if err != nil {
		t.Fatal(err)
	}
	raw = bytes.ReplaceAll(raw, []byte("SESSION"), []byte(sessionID))
	if kind == "zstd" {
		cmd := exec.Command("zstd", "-q", "-c")
		cmd.Stdin = bytes.NewReader(raw)
		out, err := cmd.Output()
		if err != nil {
			t.Fatalf("zstd: %v", err)
		}
		raw = out
	}
	writeFile(t, path, string(raw))
}

// ---- session scenarios -----------------------------------------------------

var sessionLevel = []Level{LevelSession}

func sessionScenario(name string, requires []Cap, file string, steps []sessionStep, assert func(c *Cell, r *sessionResult) error) *Scenario {
	return &Scenario{Name: name, Levels: sessionLevel, Requires: requires,
		Fixture: Fixture{File: file, Session: steps},
		Assert:  func(c *Cell) error { return assert(c, c.O.Session) }}
}

// wantStates checks the row's state after each step.
func wantStates(want ...string) func(c *Cell, r *sessionResult) error {
	return func(_ *Cell, r *sessionResult) error {
		if r.PullErr != nil {
			return r.PullErr
		}
		for i, w := range want {
			if i >= len(r.States) {
				return fmt.Errorf("no step %d", i+1)
			}
			if w != "*" && r.States[i] != w {
				return fmt.Errorf("after step %d the row is %q, want %q (%s)", i+1, r.States[i], w, strings.Join(r.Stderr, "; "))
			}
		}
		return nil
	}
}

var sessionScenarios = []*Scenario{
	sessionScenario("session-prompt", nil, "", []sessionStep{stepPrompt}, wantStates("working")),
	sessionScenario("session-tool", nil, "", []sessionStep{stepPrompt, stepTool}, wantStates("working", "working")),
	sessionScenario("session-permission", []Cap{CapPermissionWait}, "", []sessionStep{stepPrompt, stepPermission},
		func(c *Cell, r *sessionResult) error {
			if !c.Supported {
				return wantStates("working", "approval")(c, r)
			}
			if err := wantStates("working", "approval")(c, r); err != nil {
				return err
			}
			if r.PendingPermissions != 1 {
				return fmt.Errorf("%d pending permission requests, want 1: the prompt cannot be answered off the TUI", r.PendingPermissions)
			}
			return nil
		}),
	sessionScenario("session-stop", nil, "", []sessionStep{stepPrompt, stepStop}, wantStates("working", "waiting")),
	sessionScenario("session-failure", []Cap{CapFailureSignal}, "rollout_failed", []sessionStep{stepPrompt, stepFailure},
		func(c *Cell, r *sessionResult) error {
			if err := wantStates("working", "waiting")(c, r); err != nil {
				return err
			}
			if r.Row.AgentFailure == nil {
				return errors.New("no agent_failed_at")
			}
			return nil
		}),
	sessionScenario("session-interrupt", []Cap{CapInterruptSignal}, "rollout_aborted", []sessionStep{stepPrompt, stepInterrupt},
		wantStates("working", "waiting")),
	sessionScenario("session-subagents", nil, "", []sessionStep{stepPrompt, stepSubagentStart, stepSubagentStop},
		func(c *Cell, r *sessionResult) error {
			if err := wantStates("working", "*", "*")(c, r); err != nil {
				return err
			}
			if r.OpenTurns[1] != 1 || r.OpenTurns[2] != 0 {
				return fmt.Errorf("open subagent turns %v, want 1 after the start and 0 after the stop", r.OpenTurns[1:])
			}
			return nil
		}),
	sessionScenario("session-start-sources", nil, "",
		[]sessionStep{sessionStart("startup"), stepPrompt, sessionStart("resume"), sessionStart("clear"), sessionStart("compact")},
		func(_ *Cell, r *sessionResult) error {
			if r.SessionIDs[0] != sessionID {
				return fmt.Errorf("startup moved the row to %q", r.SessionIDs[0])
			}
			for i, source := range []string{"resume", "clear", "compact"} {
				if got := r.SessionIDs[2+i]; got == r.SessionIDs[1+i] {
					return fmt.Errorf("after %s the row still names session %q", source, got)
				}
			}
			return nil
		}),
	sessionScenario("session-foreign-id", nil, "", []sessionStep{stepForeignPrompt}, wantStates("")),
	sessionScenario("session-older-event", nil, "", []sessionStep{stepPrompt, stepStop},
		func(c *Cell, r *sessionResult) error {
			if err := wantStates("working", "waiting")(c, r); err != nil {
				return err
			}
			if r.OlderWrote || r.Row.AgentState.String != "waiting" {
				return errors.New("an older event was written over a newer state")
			}
			return nil
		}),
	sessionScenario("session-transcript", nil, "plain", nil,
		func(_ *Cell, r *sessionResult) error {
			switch {
			case r.FeedErr != nil:
				return r.FeedErr
			case r.FeedEntries == 0:
				return errors.New("no feed entries")
			case !r.FeedLiveOK:
				return errors.New("no live line")
			case r.TitleErr != nil || !strings.Contains(r.Title, "please add a flag"):
				return fmt.Errorf("no title text (%v)", r.TitleErr)
			}
			return nil
		}),
	sessionScenario("session-compressed-transcript", []Cap{CapCompressedTranscript}, "zstd", nil,
		func(c *Cell, r *sessionResult) error {
			if !c.Supported {
				return nil // the agent never compresses its transcript
			}
			if r.FeedErr != nil {
				return r.FeedErr
			}
			if r.FeedEntries == 0 {
				return errors.New("no feed entries from a compressed transcript")
			}
			if !r.FeedLiveOK {
				return errors.New("no live line from a compressed transcript")
			}
			if r.TitleErr != nil || !strings.Contains(r.Title, "please add a flag") {
				return fmt.Errorf("no title text from a compressed transcript (%v)", r.TitleErr)
			}
			return nil
		}),
	// A rollout the watch cannot read: the row never stays a silent
	// working (§3.5). Without a transcript watch the hooks alone drive
	// the row, which is the unsupported branch.
	sessionScenario("session-unreadable-rollout", []Cap{CapTranscriptWatch}, "missing",
		[]sessionStep{stepPrompt, stepWatchGiveUp},
		func(c *Cell, r *sessionResult) error {
			if !c.Supported {
				return hooksOnly(r)
			}
			if r.PullErr != nil {
				return r.PullErr
			}
			if r.WatchIssue != "missing" {
				return fmt.Errorf("watch issue %q, want missing", r.WatchIssue)
			}
			return nil
		}),
	sessionScenario("session-not-watched", []Cap{CapTranscriptWatch}, "missing",
		[]sessionStep{stepPrompt, stepWatchGiveUp, stepAutomationWait},
		func(c *Cell, r *sessionResult) error {
			if !c.Supported {
				return hooksOnly(r)
			}
			if r.PullErr != nil {
				return r.PullErr
			}
			if r.WaitStatus != "not_watched" || r.WaitReason != "missing" {
				return fmt.Errorf("session() ended %q (%q), want not_watched (missing)", r.WaitStatus, r.WaitReason)
			}
			return nil
		}),
}

// hooksOnly is the unsupported branch of the transcript-watch rows: an
// agent with no watch has its row driven by its hooks alone, and nothing
// marks it unwatched.
func hooksOnly(r *sessionResult) error {
	if len(r.States) == 0 || r.States[0] != "working" {
		return fmt.Errorf("the prompt hook left the row %v", r.States)
	}
	if r.WatchIssue != "" && !strings.HasPrefix(r.WatchIssue, "unreadable column") {
		return fmt.Errorf("a hook-driven row got watch issue %q", r.WatchIssue)
	}
	return nil
}

var migrated struct {
	once sync.Once
	path string
	err  error
}

// migratedDB is a workspace database migrated once for the whole run:
// every session cell starts from a copy, so the migrations (slow under
// -race) run once, not per cell.
func migratedDB(t *testing.T) string {
	t.Helper()
	migrated.once.Do(func() {
		migrated.path = filepath.Join(bins.dir, "migrated.db")
		d, err := db.Open(migrated.path)
		if err != nil {
			migrated.err = err
			return
		}
		// One file to copy: the WAL folded in.
		if _, err := d.Exec(`PRAGMA wal_checkpoint(TRUNCATE)`); err != nil {
			migrated.err = err
		}
		if err := d.Close(); err != nil && migrated.err == nil {
			migrated.err = err
		}
	})
	if migrated.err != nil {
		t.Fatalf("migrating the template database: %v", migrated.err)
	}
	return migrated.path
}
