package instructions

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"watchtower/internal/agentlog"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
	"watchtower/internal/sessionfeed"
)

// TestMain installs the db schema template cache so db.Open(":memory:")
// skips the full migration run per test.
func TestMain(m *testing.M) {
	if err := db.InitTestTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}

var minerNow = time.Date(2026, 10, 17, 12, 0, 0, 0, time.UTC)

type fakeGen struct {
	out            string
	err            error
	calls          int
	source         string
	system, stdin  string
	sessionIDGiven string
}

func (g *fakeGen) Generate(ctx context.Context, system, user, sessionID string) (string, *digest.Usage, string, error) {
	g.calls++
	g.source, _ = digest.SourceFromContext(ctx)
	g.system, g.stdin, g.sessionIDGiven = system, user, sessionID
	if g.err != nil {
		return "", nil, "", g.err
	}
	return g.out, &digest.Usage{InputTokens: 10, OutputTokens: 5}, "", nil
}

type minerFixture struct {
	t     *testing.T
	d     *db.DB
	feeds map[int64][]sessionfeed.Entry
}

func newMinerFixture(t *testing.T) *minerFixture {
	t.Helper()
	d, err := db.Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = d.Close() })
	return &minerFixture{t: t, d: d, feeds: map[int64][]sessionfeed.Entry{}}
}

func (f *minerFixture) workbench(name string) int64 {
	f.t.Helper()
	id, err := f.d.CreateWorkbench(name, f.t.TempDir())
	if err != nil {
		f.t.Fatal(err)
	}
	return id
}

// session plants a claude session active at activeAt whose feed is entries.
func (f *minerFixture) session(wb int64, activeAt time.Time, entries ...sessionfeed.Entry) int64 {
	f.t.Helper()
	res, err := f.d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id, last_active_at)
		VALUES (?, 'claude', 't', '/tmp/acme', 'uuid', ?)`, wb, activeAt.UTC().Format(time.RFC3339))
	if err != nil {
		f.t.Fatal(err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		f.t.Fatal(err)
	}
	f.feeds[id] = entries
	return id
}

func (f *minerFixture) miner(gen *fakeGen) *Miner {
	return &Miner{DB: f.d, Gen: gen, Now: func() time.Time { return minerNow },
		Read: func(s db.RecentWorkbenchSession) ([]sessionfeed.Entry, error) { return f.feeds[s.ID], nil }}
}

func owner(text string) sessionfeed.Entry {
	return sessionfeed.Entry{Kind: sessionfeed.KindOwner, Text: text, At: minerNow.Add(-time.Hour)}
}

func reply(sugs ...string) string {
	return `{"suggestions":[` + strings.Join(sugs, ",") + `]}`
}

func sug(text, field string, sessions ...int64) string {
	labels := make([]string, len(sessions))
	for i, s := range sessions {
		labels[i] = fmt.Sprintf("%q", fmt.Sprintf("s%d", s))
	}
	return fmt.Sprintf(`{"text":%q,"field":%q,"sessions":[%s]}`, text, field, strings.Join(labels, ","))
}

func (f *minerFixture) suggestions() []db.InstructionSuggestion {
	f.t.Helper()
	var n int64
	if err := f.d.QueryRow(`SELECT COALESCE(MAX(id), 0) FROM instruction_suggestions`).Scan(&n); err != nil {
		f.t.Fatal(err)
	}
	var out []db.InstructionSuggestion
	for id := int64(1); id <= n; id++ {
		s, err := f.d.GetInstructionSuggestion(id)
		if err != nil {
			f.t.Fatal(err)
		}
		out = append(out, s)
	}
	return out
}

func TestMiner_WritesValidatedSuggestion(t *testing.T) {
	f := newMinerFixture(t)
	wb := f.workbench("acme")
	recent := minerNow.Add(-24 * time.Hour)
	s1 := f.session(wb, recent, owner("please run the linter before you commit"),
		sessionfeed.Entry{Kind: sessionfeed.KindAgent, Text: "agent says hello"})
	s2 := f.session(wb, recent, owner("run the linter first"),
		sessionfeed.Entry{Kind: sessionfeed.KindAskAnswer, Text: "answer text from an ask"})
	s3 := f.session(wb, recent, owner("lint before commit, as always"),
		sessionfeed.Entry{Kind: sessionfeed.KindBrief, Text: "the session brief"})
	f.session(wb, minerNow.Add(-15*24*time.Hour), owner("too old to count")) // outside the 14 days

	gen := &fakeGen{out: "```json\n" + reply(sug("  Run the linter before every commit ", "session", s1, s2, s3)) + "\n```"}
	written, usage, err := f.miner(gen).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if written != 1 || usage == nil || usage.InputTokens != 10 {
		t.Fatalf("written=%d usage=%+v", written, usage)
	}
	if gen.calls != 1 || gen.source != "instructions.suggest" || gen.sessionIDGiven != "" {
		t.Fatalf("calls=%d source=%q session=%q", gen.calls, gen.source, gen.sessionIDGiven)
	}
	if gen.system != prompts.Defaults[prompts.InstructionSuggestions] {
		t.Fatalf("system prompt is not the registered default")
	}
	for _, want := range []string{fmt.Sprintf("s%d: please run the linter before you commit", s1), fmt.Sprintf("s%d: run the linter first", s2)} {
		if !strings.Contains(gen.stdin, want) {
			t.Errorf("stdin lacks %q:\n%s", want, gen.stdin)
		}
	}
	for _, unwanted := range []string{"agent says hello", "answer text from an ask", "the session brief", "too old to count"} {
		if strings.Contains(gen.stdin, unwanted) {
			t.Errorf("stdin carries non-owner or old text %q", unwanted)
		}
	}
	got := f.suggestions()
	if len(got) != 1 {
		t.Fatalf("got %d suggestions", len(got))
	}
	s := got[0]
	want := "Run the linter before every commit"
	if s.Text != want || s.Field != db.InstructionSession || s.Status != "open" ||
		s.WorkbenchID != (sql.NullInt64{Int64: wb, Valid: true}) || s.SessionCount != 3 || s.WorkbenchCount != 1 ||
		s.Fingerprint != Fingerprint(want) || s.FirstSeenAt != "2026-10-17T12:00:00Z" {
		t.Fatalf("suggestion = %+v", s)
	}
}

func TestMiner_OwnerLinesTruncatedAndPastesSkipped(t *testing.T) {
	f := newMinerFixture(t)
	wb := f.workbench("acme")
	recent := minerNow.Add(-time.Hour)
	long := strings.Repeat("ж", 600)
	f.session(wb, recent, owner(long))
	f.session(wb, recent, owner("look:\n```\npanic: boom\n```"), owner("keep answers short"))
	f.session(wb, recent, owner(strings.Repeat("trace line\n", 16)), owner("second\nline"))

	gen := &fakeGen{out: reply()}
	if _, _, err := f.miner(gen).Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(gen.stdin, strings.Repeat("ж", 500)+"…") || strings.Contains(gen.stdin, strings.Repeat("ж", 501)) {
		t.Errorf("a long entry is not truncated to 500 runes")
	}
	if strings.Contains(gen.stdin, "panic: boom") || strings.Contains(gen.stdin, "trace line") {
		t.Errorf("a pasted block reached the model:\n%s", gen.stdin)
	}
	if !strings.Contains(gen.stdin, "keep answers short") || !strings.Contains(gen.stdin, "second / line") {
		t.Errorf("owner lines missing or not on one line:\n%s", gen.stdin)
	}
}

func TestCleanOwnerText_DropsAppStartPrompts(t *testing.T) {
	for _, in := range []string{
		"Work on target #12 using the watchtower-workbench skill.",
		"Work on group #7 using the watchtower-workbench skill.",
		"Work on target #12 using the watchtower-workbench skill.\n\nPlan first: put the plan on the board, then ask me with ask_owner before you change any code.",
	} {
		if got, ok := cleanOwnerText(in); ok {
			t.Errorf("app start prompt kept: %q", got)
		}
	}
	got, ok := cleanOwnerText("Work on target #12 using the watchtower-workbench skill.\nalways run lint first")
	if !ok || got != "always run lint first" {
		t.Errorf("owner text after the start prompt: got %q, %v", got, ok)
	}
	got, ok = cleanOwnerText("Plan first: sketch the API")
	if !ok || got != "Plan first: sketch the API" {
		t.Errorf("owner-typed Plan first line dropped: got %q, %v", got, ok)
	}
}

func TestMiner_DropsUnknownSessionsAndUnderThree(t *testing.T) {
	f := newMinerFixture(t)
	wb := f.workbench("acme")
	recent := minerNow.Add(-time.Hour)
	s1 := f.session(wb, recent, owner("a"))
	s2 := f.session(wb, recent, owner("b"))
	s3 := f.session(wb, recent, owner("c"))
	const unknown = 9999

	gen := &fakeGen{out: reply(
		sug("Keep three known", "procedure", s1, s2, s3, unknown), // unknown dropped, 3 remain
		sug("Two known only", "session", s1, s2, unknown),         // under three
		sug("Repeated label", "session", s1, s1, s2, s2),          // two distinct
		sug(strings.Repeat("x", MaxSuggestionRunes+1), "session", s1, s2, s3),
		sug("Bad field", "other", s1, s2, s3),
		sug("   ", "session", s1, s2, s3),
		sug("keep three known!", "procedure", s1, s2, s3), // same fingerprint as the first
	)}
	written, _, err := f.miner(gen).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	got := f.suggestions()
	if written != 1 || len(got) != 1 {
		t.Fatalf("written=%d got=%+v", written, got)
	}
	if got[0].Text != "Keep three known" || got[0].Field != db.InstructionProcedure || got[0].SessionCount != 3 {
		t.Fatalf("suggestion = %+v", got[0])
	}
}

func TestMiner_ScopeOneWorkbenchVsGlobal(t *testing.T) {
	f := newMinerFixture(t)
	a, b := f.workbench("acme"), f.workbench("beta")
	recent := minerNow.Add(-time.Hour)
	a1 := f.session(a, recent, owner("x"))
	a2 := f.session(a, recent, owner("y"))
	a3 := f.session(a, recent, owner("z"))
	b1 := f.session(b, recent, owner("w"))

	gen := &fakeGen{out: reply(sug("Only acme", "session", a1, a2, a3), sug("Everywhere", "session", a1, a2, b1))}
	written, _, err := f.miner(gen).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	got := f.suggestions()
	if written != 2 || len(got) != 2 {
		t.Fatalf("written=%d got=%+v", written, got)
	}
	if got[0].WorkbenchID != (sql.NullInt64{Int64: a, Valid: true}) || got[0].WorkbenchCount != 1 {
		t.Errorf("one-workbench scope = %+v", got[0])
	}
	if got[1].WorkbenchID.Valid || got[1].WorkbenchCount != 2 || got[1].SessionCount != 3 {
		t.Errorf("global scope = %+v", got[1])
	}
}

func TestMiner_DismissedFingerprintStaysDismissed(t *testing.T) {
	f := newMinerFixture(t)
	wb := f.workbench("acme")
	recent := minerNow.Add(-time.Hour)
	s1 := f.session(wb, recent, owner("a"))
	s2 := f.session(wb, recent, owner("b"))
	s3 := f.session(wb, recent, owner("c"))
	const text = "Write tests first"
	if err := f.d.UpsertInstructionSuggestion(db.InstructionSuggestion{Text: text, Field: db.InstructionSession,
		SessionCount: 3, WorkbenchCount: 1, Fingerprint: Fingerprint(text)}, minerNow.Add(-48*time.Hour)); err != nil {
		t.Fatal(err)
	}
	old := f.suggestions()[0]
	if err := f.d.DecideInstructionSuggestion(old.ID, "dismissed", minerNow.Add(-24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if err := f.d.SetOwnerInstruction(db.InstructionProcedure, "open a branch per target"); err != nil {
		t.Fatal(err)
	}

	gen := &fakeGen{out: reply(sug("write tests FIRST.", "session", s1, s2, s3))}
	written, _, err := f.miner(gen).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(gen.stdin, text) || !strings.Contains(gen.stdin, "open a branch per target") {
		t.Errorf("stdin lacks the dismissed suggestion or the current texts:\n%s", gen.stdin)
	}
	got := f.suggestions()
	if written != 0 || len(got) != 1 || got[0].Status != "dismissed" || got[0].Text != text || got[0].LastSeenAt != old.LastSeenAt {
		t.Fatalf("written=%d got=%+v", written, got)
	}
}

func TestMiner_NoModelCallUnderThreeSessions(t *testing.T) {
	f := newMinerFixture(t)
	wb := f.workbench("acme")
	recent := minerNow.Add(-time.Hour)
	f.session(wb, recent, owner("a"))
	f.session(wb, recent, owner("b"))
	f.session(wb, recent, sessionfeed.Entry{Kind: sessionfeed.KindAgent, Text: "agent only"})
	f.session(wb, recent, owner("```\ncode only\n```"))

	gen := &fakeGen{out: reply()}
	written, usage, err := f.miner(gen).Run(context.Background())
	if err != nil || written != 0 || usage != nil || gen.calls != 0 {
		t.Fatalf("written=%d usage=%v err=%v calls=%d", written, usage, err, gen.calls)
	}
}

func TestMiner_ModelErrorWritesNothing(t *testing.T) {
	for name, gen := range map[string]*fakeGen{
		"generate error": {err: errors.New("provider down")},
		"not json":       {out: "I could not find anything"},
		"no list":        {out: `{"other": []}`},
	} {
		t.Run(name, func(t *testing.T) {
			f := newMinerFixture(t)
			wb := f.workbench("acme")
			recent := minerNow.Add(-time.Hour)
			f.session(wb, recent, owner("a"))
			f.session(wb, recent, owner("b"))
			f.session(wb, recent, owner("c"))
			written, _, err := f.miner(gen).Run(context.Background())
			if err == nil || written != 0 || len(f.suggestions()) != 0 {
				t.Fatalf("written=%d err=%v rows=%d", written, err, len(f.suggestions()))
			}
		})
	}
}

func TestMiner_UnreadableSessionIsSkipped(t *testing.T) {
	f := newMinerFixture(t)
	wb := f.workbench("acme")
	recent := minerNow.Add(-time.Hour)
	s1 := f.session(wb, recent, owner("a"))
	s2 := f.session(wb, recent, owner("b"))
	s3 := f.session(wb, recent, owner("c"))
	bad := f.session(wb, recent, owner("never read"))
	m := f.miner(&fakeGen{out: reply(sug("Keep going", "session", s1, s2, s3))})
	read := m.Read
	m.Read = func(s db.RecentWorkbenchSession) ([]sessionfeed.Entry, error) {
		if s.ID == bad {
			return nil, errors.New("transcript unreadable")
		}
		return read(s)
	}
	written, _, err := m.Run(context.Background())
	if err != nil || written != 1 {
		t.Fatalf("written=%d err=%v", written, err)
	}
}

func TestNewFeedReader_ReadsClaudeTranscript(t *testing.T) {
	f := newMinerFixture(t)
	folder, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	wb, err := f.d.CreateWorkbench("acme", folder)
	if err != nil {
		t.Fatal(err)
	}
	res, err := f.d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
		VALUES (?, 'claude', 't', ?, 'conv-1')`, wb, folder)
	if err != nil {
		t.Fatal(err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		t.Fatal(err)
	}
	projects := t.TempDir()
	dir := filepath.Join(projects, agentlog.Slug(folder))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	rec := `{"type":"user","uuid":"u1","timestamp":"2026-10-17T10:00:00Z","message":{"role":"user","content":"always run the tests"}}` + "\n"
	if err := os.WriteFile(filepath.Join(dir, "conv-1.jsonl"), []byte(rec), 0o600); err != nil {
		t.Fatal(err)
	}

	read := NewFeedReader(context.Background(), f.d, sessionfeed.Dirs{ClaudeProjects: projects, CodexHome: t.TempDir()})
	entries, err := read(db.RecentWorkbenchSession{ID: id, WorkbenchID: wb, Kind: "claude", FolderPath: folder, AgentSessionID: "conv-1"})
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Kind != sessionfeed.KindOwner || entries[0].Text != "always run the tests" {
		t.Fatalf("entries = %+v", entries)
	}
}
