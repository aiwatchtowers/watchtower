package handlers

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/asks"
	"watchtower/internal/db"
	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/wire"
)

// escPort records every Interrupt (one Esc through InputTo) beside the fake
// port's Deliver lines.
type escPort struct {
	*fakePort
	mu    sync.Mutex
	escs  []int64
	escFn func() error
}

func (p *escPort) Interrupt(_ context.Context, sessionID int64, _ uint64) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.escFn != nil {
		if err := p.escFn(); err != nil {
			return err
		}
	}
	p.escs = append(p.escs, sessionID)
	return nil
}

func (p *escPort) interrupts() []int64 {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]int64(nil), p.escs...)
}

// permEnv is env with an escPort, a fixed clock and a phone holding both the
// typing and the permissions grant.
type permEnv struct {
	*env
	esc *escPort
	now time.Time
	wb  int64
}

func newPermEnv(t *testing.T) *permEnv {
	t.Helper()
	e := &env{t: t, db: db.OpenTestDB(t), port: newFakePort(), disp: actions.NewDispatcher()}
	st, err := state.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	e.store = st
	e.device = secure.ID{0x0a, 0x0b}
	p := &permEnv{env: e, esc: &escPort{fakePort: e.port}, now: time.Now().UTC().Truncate(time.Millisecond)}
	e.h = Register(e.disp, Deps{
		DB: e.db, Store: st, Sessions: p.esc,
		Clock: func() time.Time { return p.now },
	})
	err = st.WithTx(context.Background(), func(tx *sql.Tx) error {
		return state.LinkDevice(tx, state.Device{
			ID: e.device.String(), Name: "iPhone", Scope: "private", LinkedAt: time.Now(),
			TypingAllowed: true, PermissionsAllowed: true,
		})
	})
	if err != nil {
		t.Fatal(err)
	}
	return p
}

// grant sets one of the phone's grants in the sidecar (the Mac's switch).
func (p *permEnv) grant(column string, on bool) {
	p.t.Helper()
	err := p.store.WithTx(context.Background(), func(tx *sql.Tx) error {
		q := map[string]string{
			"permissions_allowed": `UPDATE devices SET permissions_allowed = ? WHERE device_id = ? COLLATE NOCASE`,
			"typing_allowed":      `UPDATE devices SET typing_allowed = ? WHERE device_id = ? COLLATE NOCASE`,
		}[column]
		_, err := tx.Exec(q, on, p.device.String())
		return err
	})
	if err != nil {
		p.t.Fatal(err)
	}
}

// liveSession is a running session of kind on the test workbench (a codex
// row is only created: its scope check comes first).
func (p *permEnv) liveSession(kind string) int64 {
	p.t.Helper()
	if p.wb == 0 {
		p.wb = p.workbench()
	}
	res, err := p.db.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
		VALUES (?, ?, 'Ship it', '/tmp/acme', CASE WHEN ? = 'claude' THEN lower(hex(randomblob(16))) END)`, p.wb, kind, kind)
	if err != nil {
		p.t.Fatal(err)
	}
	sid, _ := res.LastInsertId()
	if kind == "claude" {
		p.port.start(sid)
	}
	return sid
}

// setState writes the hooks' state for the current run: working, approval,
// waiting (stopped) or background (waiting with a running background agent).
func (p *permEnv) setState(sid int64, st string) {
	p.t.Helper()
	stamp := db.AgentStateStamp(p.now.Add(-time.Second))
	if st == "background" {
		p.exec(`UPDATE terminal_sessions SET agent_state = 'waiting', agent_state_at = ?,
			agent_background = 1, agent_background_at = ? WHERE id = ?`, stamp, stamp, sid)
		return
	}
	p.exec(`UPDATE terminal_sessions SET agent_state = ?, agent_state_at = ? WHERE id = ?`, st, stamp, sid)
}

type reqOpt struct {
	status, tool, summary string
	clipped               bool
}

func (p *permEnv) permRequest(sid int64, o reqOpt) int64 {
	p.t.Helper()
	if o.status == "" {
		o.status = "pending"
	}
	if o.tool == "" {
		o.tool = "Bash"
	}
	if o.summary == "" {
		o.summary = "make test"
	}
	res, err := p.db.Exec(`INSERT INTO permission_requests
		(terminal_session_id, workbench_id, tool_name, summary, summary_clipped, status, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)`, sid, p.wb, o.tool, o.summary, o.clipped, o.status,
		db.AgentStateStamp(p.now.Add(-5*time.Second)))
	if err != nil {
		p.t.Fatal(err)
	}
	rid, _ := res.LastInsertId()
	return rid
}

func (p *permEnv) rowStatus(rid int64) string {
	return p.scalar(`SELECT status FROM permission_requests WHERE id = ?`, rid)
}

func (p *permEnv) answer(sid, rid int64, behavior string) actions.Outcome {
	r := p.request("permission_answer", id(sid), map[string]any{"request_id": rid, "behavior": behavior})
	r.Action.CreatedAt = wire.Time{Time: p.now}
	return p.h.permissionAnswer(context.Background(), r)
}

func (p *permEnv) interrupt(sid int64, age time.Duration) actions.Outcome {
	r := p.request("session_interrupt", id(sid), nil)
	r.Action.CreatedAt = wire.Time{Time: p.now.Add(-age)}
	return p.h.sessionInterrupt(context.Background(), r)
}

func wantMessage(t *testing.T, got actions.Outcome, msg string) {
	t.Helper()
	if got.Message != msg {
		t.Fatalf("message = %q, want %q", got.Message, msg)
	}
}

// --- permission_answer ---

func TestProj21_AnUngrantedDeviceCannotAnswer(t *testing.T) {
	p := newPermEnv(t)
	sid := p.liveSession("claude")
	rid := p.permRequest(sid, reqOpt{})
	p.grant("permissions_allowed", false)

	wantOutcome(t, p.answer(sid, rid, "allow"), wire.StatusFailed, reasonDeviceNotAllowed)
	if got := p.rowStatus(rid); got != "pending" {
		t.Fatalf("status = %q, want pending", got)
	}
	if got := p.scalar(`SELECT decided_by FROM permission_requests WHERE id = ?`, rid); got != "" {
		t.Fatalf("decided_by = %q, want NULL", got)
	}
}

// The typing grant does not imply the permission grant.
func TestTheTypingGrantAloneCannotAnswer(t *testing.T) {
	p := newPermEnv(t)
	sid := p.liveSession("claude")
	rid := p.permRequest(sid, reqOpt{})
	p.grant("permissions_allowed", false)
	p.grant("typing_allowed", true)

	wantOutcome(t, p.answer(sid, rid, "allow"), wire.StatusFailed, reasonDeviceNotAllowed)
	if got := p.rowStatus(rid); got != "pending" {
		t.Fatalf("status = %q", got)
	}
}

func TestAnUnlinkedDeviceCannotAnswer(t *testing.T) {
	p := newPermEnv(t)
	sid := p.liveSession("claude")
	rid := p.permRequest(sid, reqOpt{})
	r := p.request("permission_answer", id(sid), map[string]any{"request_id": rid, "behavior": "allow"})
	r.Device = secure.ID{0x0c}

	wantOutcome(t, p.h.permissionAnswer(context.Background(), r), wire.StatusFailed, reasonDeviceNotAllowed)
}

func TestProj21_AnAllowDecidesThePendingRowOnce(t *testing.T) {
	p := newPermEnv(t)
	sid := p.liveSession("claude")
	rid := p.permRequest(sid, reqOpt{})

	first := p.answer(sid, rid, "allow")
	second := p.answer(sid, rid, "deny")

	wantOutcome(t, first, wire.StatusApplied, "")
	if first.Result["status"] != "allowed" {
		t.Fatalf("result = %v", first.Result)
	}
	wantOutcome(t, second, wire.StatusFailed, reasonNotPending)
	wantMessage(t, second, "Already allowed")
	if got := p.rowStatus(rid); got != "allowed" {
		t.Fatalf("status = %q", got)
	}
	if got := p.scalar(`SELECT decided_by FROM permission_requests WHERE id = ?`, rid); got != "iPhone" {
		t.Fatalf("decided_by = %q", got)
	}
	if got := p.scalar(`SELECT decided_at FROM permission_requests WHERE id = ?`, rid); got != db.AgentStateStamp(p.now) {
		t.Fatalf("decided_at = %q", got)
	}
}

func TestADenyDecidesThePendingRow(t *testing.T) {
	p := newPermEnv(t)
	sid := p.liveSession("claude")
	rid := p.permRequest(sid, reqOpt{})

	wantOutcome(t, p.answer(sid, rid, "deny"), wire.StatusApplied, "")
	if got := p.rowStatus(rid); got != "denied" {
		t.Fatalf("status = %q", got)
	}
}

func TestAnUnnamedDeviceDecidesAsPhone(t *testing.T) {
	p := newPermEnv(t)
	err := p.store.WithTx(context.Background(), func(tx *sql.Tx) error {
		_, err := tx.Exec(`UPDATE devices SET name = '' WHERE device_id = ? COLLATE NOCASE`, p.device.String())
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	sid := p.liveSession("claude")
	rid := p.permRequest(sid, reqOpt{})

	wantOutcome(t, p.answer(sid, rid, "deny"), wire.StatusApplied, "")
	if got := p.scalar(`SELECT decided_by FROM permission_requests WHERE id = ?`, rid); got != "phone" {
		t.Fatalf("decided_by = %q", got)
	}
}

func TestAnAnswerToAClosedRequestIsNotPending(t *testing.T) {
	for status, msg := range map[string]string{
		"answered_on_mac": "Answered on the Mac",
		"expired":         "Too late — answer on the Mac",
		"denied":          "Already denied",
	} {
		t.Run(status, func(t *testing.T) {
			p := newPermEnv(t)
			sid := p.liveSession("claude")
			rid := p.permRequest(sid, reqOpt{status: status})

			got := p.answer(sid, rid, "allow")
			wantOutcome(t, got, wire.StatusFailed, reasonNotPending)
			wantMessage(t, got, msg)
			if s := p.rowStatus(rid); s != status {
				t.Fatalf("status = %q", s)
			}
		})
	}
}

// Two prompts in a row: a late answer to the first never decides the second.
func TestALateAnswerToAnOlderPromptNeverDecidesTheNewerOne(t *testing.T) {
	p := newPermEnv(t)
	sid := p.liveSession("claude")
	older := p.permRequest(sid, reqOpt{status: "answered_on_mac"})
	newer := p.permRequest(sid, reqOpt{})

	wantOutcome(t, p.answer(sid, older, "allow"), wire.StatusFailed, reasonNotPending)
	if got := p.rowStatus(newer); got != "pending" {
		t.Fatalf("newer = %q", got)
	}
}

func TestProj21_RevokeBlocksAnswers(t *testing.T) {
	p := newPermEnv(t)
	sid := p.liveSession("claude")
	first := p.permRequest(sid, reqOpt{})
	wantOutcome(t, p.answer(sid, first, "allow"), wire.StatusApplied, "")
	second := p.permRequest(sid, reqOpt{})

	p.grant("permissions_allowed", false)

	wantOutcome(t, p.answer(sid, second, "allow"), wire.StatusFailed, reasonDeviceNotAllowed)
	if got := p.rowStatus(second); got != "pending" {
		t.Fatalf("status = %q", got)
	}
}

func TestAnAnswerForAnotherSessionsRequestIsNotFound(t *testing.T) {
	p := newPermEnv(t)
	sid := p.liveSession("claude")
	other := p.liveSession("claude")
	rid := p.permRequest(other, reqOpt{})

	got := p.answer(sid, rid, "allow")
	wantOutcome(t, got, wire.StatusFailed, reasonNotFound)
	wantMessage(t, got, requestGoneMessage)
	if s := p.rowStatus(rid); s != "pending" {
		t.Fatalf("status = %q", s)
	}
}

func TestAnAnswerForASessionNoLongerRunningFails(t *testing.T) {
	p := newPermEnv(t)
	sid := p.liveSession("claude")
	rid := p.permRequest(sid, reqOpt{})
	p.port.mu.Lock()
	delete(p.port.live, sid)
	p.port.mu.Unlock()

	got := p.answer(sid, rid, "allow")
	wantOutcome(t, got, wire.StatusFailed, reasonSessionNotRunning)
	wantMessage(t, got, notRunningMessage)
	if s := p.rowStatus(rid); s != "pending" {
		t.Fatalf("status = %q", s)
	}
}

func TestAnAnswerForAnExitedRunFails(t *testing.T) {
	p := newPermEnv(t)
	sid := p.liveSession("claude")
	rid := p.permRequest(sid, reqOpt{})
	p.port.mu.Lock()
	l := p.port.live[sid]
	l.Exited = true
	p.port.live[sid] = l
	p.port.mu.Unlock()

	wantOutcome(t, p.answer(sid, rid, "deny"), wire.StatusFailed, reasonSessionNotRunning)
}

// Owner decision (ask #268): a shortened request is Deny only — the hub
// refuses the allow and leaves the row for the Mac.
func TestProj21_AClippedRequestCannotBeAllowed(t *testing.T) {
	p := newPermEnv(t)
	sid := p.liveSession("claude")
	rid := p.permRequest(sid, reqOpt{clipped: true})

	allow := p.answer(sid, rid, "allow")
	wantOutcome(t, allow, wire.StatusFailed, reasonAnswerOnMac)
	wantMessage(t, allow, "Shortened — answer on the Mac to allow")
	if s := p.rowStatus(rid); s != "pending" {
		t.Fatalf("status = %q", s)
	}
	wantOutcome(t, p.answer(sid, rid, "deny"), wire.StatusApplied, "")
	if s := p.rowStatus(rid); s != "denied" {
		t.Fatalf("status = %q, deny still works", s)
	}
}

// A summary longer than the wire's cap was shortened for the phone too.
func TestAnAllowOfASummaryPastTheWireCapIsRefused(t *testing.T) {
	p := newPermEnv(t)
	sid := p.liveSession("claude")
	rid := p.permRequest(sid, reqOpt{summary: strings.Repeat("a", AllowSummaryCap+1)})
	atCap := p.permRequest(sid, reqOpt{summary: strings.Repeat("a", AllowSummaryCap)})

	wantOutcome(t, p.answer(sid, rid, "allow"), wire.StatusFailed, reasonAnswerOnMac)
	wantOutcome(t, p.answer(sid, atCap, "allow"), wire.StatusApplied, "")
}

// A file linked into .claude is a settings path on the Mac too.
func TestASettingsFileBehindASymlinkCannotBeAllowed(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, ".claude", "settings.json")
	if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "cfg.json")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	p := newPermEnv(t)
	sid := p.liveSession("claude")
	rid := p.permRequest(sid, reqOpt{tool: "Edit", summary: link})

	wantOutcome(t, p.answer(sid, rid, "allow"), wire.StatusFailed, reasonAnswerOnMac)
	if s := p.rowStatus(rid); s != "pending" {
		t.Fatalf("status = %q", s)
	}
}

// A folder linked to .claude is a settings path on the Mac too, for a file
// a Write creates there.
func TestASettingsPathBehindASymlinkCannotBeAllowed(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, ".claude")
	if err := os.MkdirAll(target, 0o700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "cfg")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	p := newPermEnv(t)
	sid := p.liveSession("claude")
	rid := p.permRequest(sid, reqOpt{tool: "Write", summary: filepath.Join(link, "settings.json")})

	wantOutcome(t, p.answer(sid, rid, "allow"), wire.StatusFailed, reasonAnswerOnMac)
}

// Owner decision (ask #268): an Edit/Write/NotebookEdit of a settings path is
// Deny only; every other path keeps Allow once.
func TestProj21_ASettingsPathEditCannotBeAllowed(t *testing.T) {
	p := newPermEnv(t)
	sid := p.liveSession("claude")
	settings := p.permRequest(sid, reqOpt{tool: "Write", summary: "/tmp/acme/.claude/settings.local.json"})

	refused := p.answer(sid, settings, "allow")
	wantOutcome(t, refused, wire.StatusFailed, reasonAnswerOnMac)
	wantMessage(t, refused, "Changes Watchtower or shell settings — answer on the Mac to allow")
	if s := p.rowStatus(settings); s != "pending" {
		t.Fatalf("status = %q", s)
	}
	plain := p.permRequest(sid, reqOpt{tool: "Edit", summary: "/tmp/acme/main.go"})
	wantOutcome(t, p.answer(sid, plain, "allow"), wire.StatusApplied, "")
	if s := p.rowStatus(plain); s != "allowed" {
		t.Fatalf("status = %q", s)
	}
}

// The Mac answers between the handler's read and its write: the
// compare-and-set changes nothing, and the outcome names the Mac.
func TestAnAnswerThatLosesTheRaceIsNotPending(t *testing.T) {
	p := newPermEnv(t)
	sid := p.liveSession("claude")
	rid := p.permRequest(sid, reqOpt{})
	p.exec(`CREATE TRIGGER mac_answers_first BEFORE UPDATE OF status ON permission_requests
		WHEN NEW.status IN ('allowed', 'denied')
		BEGIN
			UPDATE permission_requests SET status = 'answered_on_mac' WHERE id = OLD.id;
			SELECT RAISE(IGNORE);
		END`)

	got := p.answer(sid, rid, "allow")
	wantOutcome(t, got, wire.StatusFailed, reasonNotPending)
	wantMessage(t, got, "Answered on the Mac")
	if s := p.rowStatus(rid); s != "answered_on_mac" {
		t.Fatalf("status = %q", s)
	}
	if s := p.scalar(`SELECT decided_by FROM permission_requests WHERE id = ?`, rid); s != "" {
		t.Fatalf("decided_by = %q", s)
	}
}

// Codex keeps "Needs approval on the Mac": its rows are not the phone's.
func TestAnAnswerForACodexSessionIsNotFound(t *testing.T) {
	p := newPermEnv(t)
	sid := p.liveSession("codex")
	rid := p.permRequest(sid, reqOpt{})

	wantOutcome(t, p.answer(sid, rid, "allow"), wire.StatusFailed, reasonNotFound)
	if s := p.rowStatus(rid); s != "pending" {
		t.Fatalf("status = %q", s)
	}
}

func TestAnAnswerWithBadParamsIsInvalid(t *testing.T) {
	p := newPermEnv(t)
	sid := p.liveSession("claude")
	rid := p.permRequest(sid, reqOpt{})

	wantOutcome(t, p.answer(sid, rid, "always"), wire.StatusFailed, reasonInvalidParams)
	missing := p.request("permission_answer", id(sid), map[string]any{"behavior": "allow"})
	wantOutcome(t, p.h.permissionAnswer(context.Background(), missing), wire.StatusFailed, reasonInvalidParams)
	if s := p.rowStatus(rid); s != "pending" {
		t.Fatalf("status = %q", s)
	}
}

// Only the hook's JSON decides a prompt: an answer writes no byte to the
// terminal, whatever its state (PROJ-16 holds).
func TestProj21_AnAnswerTypesNothing(t *testing.T) {
	p := newPermEnv(t)
	sid := p.liveSession("claude")
	p.setState(sid, "approval")
	first := p.permRequest(sid, reqOpt{})
	wantOutcome(t, p.answer(sid, first, "allow"), wire.StatusApplied, "")
	second := p.permRequest(sid, reqOpt{})
	wantOutcome(t, p.answer(sid, second, "deny"), wire.StatusApplied, "")

	if p.rowStatus(first) != "allowed" || p.rowStatus(second) != "denied" {
		t.Fatalf("statuses = %q, %q", p.rowStatus(first), p.rowStatus(second))
	}
	if n, m := len(p.port.lines()), len(p.esc.interrupts()); n != 0 || m != 0 {
		t.Fatalf("typed: %d Deliver, %d InputTo calls; want none", n, m)
	}
}

// --- session_interrupt ---

func TestInterruptSendsOneEscWhileWorking(t *testing.T) {
	p := newPermEnv(t)
	sid := p.liveSession("claude")
	p.setState(sid, "working")

	wantOutcome(t, p.interrupt(sid, time.Second), wire.StatusApplied, "")
	if got := p.esc.interrupts(); len(got) != 1 || got[0] != sid {
		t.Fatalf("interrupts = %v, want one into %d", got, sid)
	}
	if n := len(p.port.lines()); n != 0 {
		t.Fatalf("Deliver calls = %d", n)
	}
}

// Agents working counts as Working.
func TestInterruptSendsOneEscWhileAgentsWork(t *testing.T) {
	p := newPermEnv(t)
	sid := p.liveSession("claude")
	p.setState(sid, "background")

	wantOutcome(t, p.interrupt(sid, time.Second), wire.StatusApplied, "")
	if got := p.esc.interrupts(); len(got) != 1 {
		t.Fatalf("interrupts = %v", got)
	}
}

func TestInterruptAtNeedsApprovalFailsNotWorking(t *testing.T) {
	p := newPermEnv(t)
	sid := p.liveSession("claude")
	p.setState(sid, "approval")

	wantOutcome(t, p.interrupt(sid, time.Second), wire.StatusFailed, reasonNotWorking)
	if got := p.esc.interrupts(); len(got) != 0 {
		t.Fatalf("interrupts = %v", got)
	}
}

// The prompt is drawn before its hook reports: the state still says Working,
// but a pending request means an Esc would reject the prompt.
func TestInterruptWithAPendingRequestFailsNotWorking(t *testing.T) {
	p := newPermEnv(t)
	sid := p.liveSession("claude")
	p.setState(sid, "working")
	rid := p.permRequest(sid, reqOpt{})

	got := p.interrupt(sid, time.Second)
	wantOutcome(t, got, wire.StatusFailed, reasonNotWorking)
	wantMessage(t, got, promptMayBeOpenMessage)
	if s := p.rowStatus(rid); s != "pending" {
		t.Fatalf("status = %q", s)
	}
	if got := p.esc.interrupts(); len(got) != 0 {
		t.Fatalf("interrupts = %v", got)
	}
}

func TestInterruptWhenIdleFailsNotWorking(t *testing.T) {
	p := newPermEnv(t)
	sid := p.liveSession("claude")
	// running (no hook state this run), stopped, finished, waiting on an
	// ask, ready to check, error.
	got := p.interrupt(sid, time.Second)
	wantOutcome(t, got, wire.StatusFailed, reasonNotWorking)
	wantMessage(t, got, notWorkingMessage)
	p.setState(sid, "waiting")
	wantOutcome(t, p.interrupt(sid, time.Second), wire.StatusFailed, reasonNotWorking)
	p.exec(`UPDATE terminal_sessions SET finished_at = ? WHERE id = ?`, db.AgentStateStamp(p.now), sid)
	wantOutcome(t, p.interrupt(sid, time.Second), wire.StatusFailed, reasonNotWorking)
	p.exec(`UPDATE terminal_sessions SET finished_at = NULL, agent_failed_at = agent_state_at WHERE id = ?`, sid)
	wantOutcome(t, p.interrupt(sid, time.Second), wire.StatusFailed, reasonNotWorking)
	p.exec(`UPDATE terminal_sessions SET agent_failed_at = NULL WHERE id = ?`, sid)
	for kind, payload := range map[string]string{asks.KindQuestion: questions, asks.KindReview: "{}"} {
		p.exec(`DELETE FROM owner_asks`)
		a := db.OwnerAsk{WorkbenchID: p.wb, SessionID: sql.NullInt64{Int64: sid, Valid: true}, Kind: kind, Payload: payload}
		if kind == asks.KindReview {
			a.DocPath = "docs/spec.md"
		}
		p.ask(a)
		wantOutcome(t, p.interrupt(sid, time.Second), wire.StatusFailed, reasonNotWorking)
	}
	// A working state from an earlier run is not this run's.
	p.exec(`UPDATE terminal_sessions SET agent_state = 'working', agent_state_at = ? WHERE id = ?`,
		db.AgentStateStamp(p.now.Add(-time.Hour)), sid)
	p.exec(`DELETE FROM owner_asks`)
	wantOutcome(t, p.interrupt(sid, time.Second), wire.StatusFailed, reasonNotWorking)
	if got := p.esc.interrupts(); len(got) != 0 {
		t.Fatalf("interrupts = %v", got)
	}
}

func TestAStaleInterruptExpires(t *testing.T) {
	p := newPermEnv(t)
	sid := p.liveSession("claude")
	p.setState(sid, "working")

	got := p.interrupt(sid, 121*time.Second)
	if got.Status != wire.StatusExpired || got.Reason != reasonExpired {
		t.Fatalf("outcome = %+v, want expired", got)
	}
	wantOutcome(t, p.interrupt(sid, InterruptMaxAge), wire.StatusApplied, "")
	if got := p.esc.interrupts(); len(got) != 1 {
		t.Fatalf("interrupts = %v, want only the fresh one", got)
	}
}

func TestInterruptOfACodexSessionIsNotFound(t *testing.T) {
	p := newPermEnv(t)
	sid := p.liveSession("codex")
	p.port.start(sid)
	p.setState(sid, "working")

	got := p.interrupt(sid, time.Second)
	wantOutcome(t, got, wire.StatusFailed, reasonNotFound)
	wantMessage(t, got, sessionGoneMessage)
	if got := p.esc.interrupts(); len(got) != 0 {
		t.Fatalf("interrupts = %v", got)
	}
}

func TestInterruptNeedsTheTypingGrant(t *testing.T) {
	p := newPermEnv(t)
	sid := p.liveSession("claude")
	p.setState(sid, "working")
	p.grant("typing_allowed", false)

	wantOutcome(t, p.interrupt(sid, time.Second), wire.StatusFailed, reasonDeviceNotAllowed)
	if got := p.esc.interrupts(); len(got) != 0 {
		t.Fatalf("interrupts = %v", got)
	}
}

// The permissions grant alone does not let a phone press Esc.
func TestThePermissionsGrantAloneCannotInterrupt(t *testing.T) {
	p := newPermEnv(t)
	sid := p.liveSession("claude")
	p.setState(sid, "working")
	p.grant("typing_allowed", false)
	p.grant("permissions_allowed", true)

	wantOutcome(t, p.interrupt(sid, time.Second), wire.StatusFailed, reasonDeviceNotAllowed)
}

func TestInterruptOfASessionNoLongerRunningFails(t *testing.T) {
	p := newPermEnv(t)
	sid := p.liveSession("claude")
	p.setState(sid, "working")
	p.port.mu.Lock()
	delete(p.port.live, sid)
	p.port.mu.Unlock()

	wantOutcome(t, p.interrupt(sid, time.Second), wire.StatusFailed, reasonSessionNotRunning)
	if got := p.esc.interrupts(); len(got) != 0 {
		t.Fatalf("interrupts = %v", got)
	}
}

// A failed InputTo whose session is gone is not running; any other failure
// may have written the Esc, so the phone is told to check on the Mac.
func TestAFailedInterruptIsNotRunningOrUnknown(t *testing.T) {
	p := newPermEnv(t)
	sid := p.liveSession("claude")
	p.setState(sid, "working")
	p.esc.escFn = func() error { return errors.New("socket closed") }

	wantOutcome(t, p.interrupt(sid, time.Second), wire.StatusFailed, reasonOutcomeUnknown)

	p.esc.escFn = func() error {
		p.port.mu.Lock()
		delete(p.port.live, sid)
		p.port.mu.Unlock()
		return errors.New("no session")
	}
	wantOutcome(t, p.interrupt(sid, time.Second), wire.StatusFailed, reasonSessionNotRunning)
}

// A hub that dies after the Esc never replays it: both kinds are claimed
// begun before their handler.
func TestBothKindsAreClaimedBeforeTheirHandler(t *testing.T) {
	for _, k := range []string{"permission_answer", "session_interrupt"} {
		found := false
		for _, n := range actions.NonIdempotentKinds {
			found = found || n == k
		}
		if !found {
			t.Fatalf("%s is not in actions.NonIdempotentKinds", k)
		}
		if len(NudgeTable[k]) == 0 {
			t.Fatalf("%s has no NudgeTable entry", k)
		}
	}
}
