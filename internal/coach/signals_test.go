package coach

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentlogdb"
	"watchtower/internal/db"
	"watchtower/internal/instructions"
	"watchtower/internal/prompts"
	"watchtower/internal/sessionfeed"
	"watchtower/internal/specreview"
)

var sigNow = time.Date(2026, 10, 26, 12, 0, 0, 0, time.UTC)

func noFeed(db.RecentWorkbenchSession) ([]sessionfeed.Entry, error) { return nil, nil }

// fakeHome points the settings.json reader at a temp dir for the test.
func fakeHome(t *testing.T) string {
	t.Helper()
	home := t.TempDir()
	old := userHomeDir
	userHomeDir = func() (string, error) { return home, nil }
	t.Cleanup(func() { userHomeDir = old })
	return home
}

// specReview plants a done review ask in workbench wb finished at `at`.
func (d dbs) doneReview(t *testing.T, wb int64, at time.Time, res specreview.Result) int64 {
	t.Helper()
	r, err := d.Exec(`INSERT INTO owner_asks (project_id, kind, title, doc_path, doc_type) VALUES (?, 'review', 't', 'spec.md', 'spec')`, wb)
	require.NoError(t, err)
	ask, err := r.LastInsertId()
	require.NoError(t, err)
	raw, err := json.Marshal(res)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO spec_reviews (ask_id, status, result, queued_at, finished_at, findings) VALUES (?, 'done', ?, ?, ?, 3)`,
		ask, string(raw), at.Format(tsLayout), at.Format(tsLayout))
	require.NoError(t, err)
	return ask
}

func (d dbs) mark(t *testing.T, ask int64, key, state, body string) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO spec_review_marks (ask_id, item_key, state, body, updated_at) VALUES (?, ?, ?, ?, ?)`,
		ask, key, state, body, sigNow.Format(tsLayout))
	require.NoError(t, err)
}

func (d dbs) reviewComment(t *testing.T, wb int64, round int64, at time.Time, body string, prev, carried bool) int64 {
	t.Helper()
	if round == 0 {
		var prevID any
		if prev {
			p, err := d.Exec(`INSERT INTO review_rounds (project_id, folder_root, base_sha, tree_sha, created_at) VALUES (?, 'f', 'b', 't', ?)`, wb, at.Format(tsLayout))
			require.NoError(t, err)
			prevID, _ = p.LastInsertId()
		}
		r, err := d.Exec(`INSERT INTO review_rounds (project_id, folder_root, base_sha, tree_sha, prev_round_id, created_at) VALUES (?, 'f', 'b', 't', ?, ?)`,
			wb, prevID, at.Format(tsLayout))
		require.NoError(t, err)
		round, _ = r.LastInsertId()
	}
	var carriedFrom any
	if carried {
		c, err := d.Exec(`INSERT INTO review_comments (round_id, body) VALUES (?, '')`, round)
		require.NoError(t, err)
		carriedFrom, _ = c.LastInsertId()
	}
	r, err := d.Exec(`INSERT INTO review_comments (round_id, body, carried_from, status, created_at) VALUES (?, ?, ?, 'sent', ?)`,
		round, body, carriedFrom, at.Format(tsLayout))
	require.NoError(t, err)
	id, err := r.LastInsertId()
	require.NoError(t, err)
	return id
}

func sigByRef(sigs []Signal) map[string]Signal {
	m := map[string]Signal{}
	for _, s := range sigs {
		m[s.Ref] = s
	}
	return m
}

func TestCollect_SpecMarksMapToKinds(t *testing.T) {
	fakeHome(t)
	d := openDBs(t)
	wb, _ := d.workbench(t, "acme", 0)
	ask := d.doneReview(t, wb, sigNow.Add(-24*time.Hour), specreview.Result{
		Agreements:   []specreview.Agreement{{Key: "ag:aaaaaaaaaaaa", Text: "Retries stay at three", Note: "the doc says five"}},
		DecidedAlone: []specreview.DecidedAlone{{Key: "da:bbbbbbbbbbbb", Text: "Naming of the flag"}},
		BlindSpots:   []specreview.BlindSpot{{Key: "bs:cccccccccccc", Text: "No rollback path", Why: "a failed deploy is stuck"}},
		Checks:       []specreview.Check{{Key: "ck:dddddddddddd", Question: "Is it idempotent?", Note: "yes"}},
	})
	d.mark(t, ask, "bs:cccccccccccc", "comment", "yes, add one")
	d.mark(t, ask, "da:bbbbbbbbbbbb", "not_useful", "")
	d.mark(t, ask, "ag:aaaaaaaaaaaa", "ok", "")
	d.mark(t, ask, "ck:dddddddddddd", "viewed", "")

	in, err := Collect(context.Background(), d.DB, d.al, noFeed, sigNow)
	require.NoError(t, err)

	got := sigByRef(in.Signals)
	require.Len(t, in.Signals, 2)
	comment := got[fmt.Sprintf("ask:%d#bs:cccccccccccc", ask)]
	assert.Equal(t, KindSpecReal, comment.Kind)
	assert.Equal(t, wb, comment.WorkbenchID)
	assert.Equal(t, "No rollback path - a failed deploy is stuck | owner: yes, add one", comment.Text)
	noise := got[fmt.Sprintf("ask:%d#da:bbbbbbbbbbbb", ask)]
	assert.Equal(t, KindSpecNoise, noise.Kind)
	assert.Equal(t, "Naming of the flag", noise.Text)
}

func TestCollect_SkipsUnmarkedFindings(t *testing.T) {
	fakeHome(t)
	d := openDBs(t)
	wb, _ := d.workbench(t, "acme", 0)
	res := specreview.Result{BlindSpots: []specreview.BlindSpot{{Key: "bs:111111111111", Text: "x"}}}
	d.doneReview(t, wb, sigNow.Add(-time.Hour), res) // no marks at all
	old := d.doneReview(t, wb, sigNow.Add(-signalWindow-time.Hour), res)
	d.mark(t, old, "bs:111111111111", "comment", "") // marked but outside the window

	in, err := Collect(context.Background(), d.DB, d.al, noFeed, sigNow)
	require.NoError(t, err)
	assert.Empty(t, in.Signals)
}

func TestCollect_CodeReviewFirstRoundOnly(t *testing.T) {
	fakeHome(t)
	d := openDBs(t)
	wb, _ := d.workbench(t, "acme", 0)
	first := d.reviewComment(t, wb, 0, sigNow.Add(-time.Hour), "rename this", false, false)
	d.reviewComment(t, wb, 0, sigNow.Add(-time.Hour), "second round remark", true, false)
	d.reviewComment(t, wb, 0, sigNow.Add(-time.Hour), "carried over", false, true)

	in, err := Collect(context.Background(), d.DB, d.al, noFeed, sigNow)
	require.NoError(t, err)
	var refs []string
	for _, s := range in.Signals {
		assert.Equal(t, KindCodeReview, s.Kind)
		refs = append(refs, s.Ref)
	}
	require.Len(t, refs, 1)
	assert.Regexp(t, fmt.Sprintf(`^round:\d+#c%d$`, first), refs[0])
	assert.Equal(t, "rename this", in.Signals[0].Text)
}

func TestCollect_CapsAndNewestFirst(t *testing.T) {
	fakeHome(t)
	d := openDBs(t)
	wb, _ := d.workbench(t, "acme", 0)
	long := strings.Repeat("ж", 700)
	var newest int64
	for i := range maxSignals + 50 {
		newest = d.reviewComment(t, wb, 0, sigNow.Add(-time.Duration(maxSignals+60-i)*time.Minute), long, false, false)
	}

	in, err := Collect(context.Background(), d.DB, d.al, noFeed, sigNow)
	require.NoError(t, err)
	require.Len(t, in.Signals, maxSignals)
	assert.Contains(t, in.Signals[0].Ref, fmt.Sprintf("#c%d", newest))
	for _, s := range in.Signals {
		assert.Equal(t, maxSignalRunes, utf8.RuneCountInString(s.Text))
		assert.True(t, utf8.ValidString(s.Text))
	}
	for i := 1; i < len(in.Signals); i++ {
		assert.False(t, in.Signals[i].at.After(in.Signals[i-1].at))
	}
}

func TestCollect_OwnerLinesBecomeSignals(t *testing.T) {
	fakeHome(t)
	d := openDBs(t)
	wb, _ := d.workbench(t, "acme", 0)
	res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id, last_active_at)
		VALUES (?, 'claude', 't', '/tmp/acme', 'uuid', ?)`, wb, sigNow.Add(-time.Hour).Format(time.RFC3339))
	require.NoError(t, err)
	sid, _ := res.LastInsertId()
	read := func(s db.RecentWorkbenchSession) ([]sessionfeed.Entry, error) {
		return []sessionfeed.Entry{{Kind: sessionfeed.KindOwner, Text: "stop adding comments", At: sigNow.Add(-time.Hour)}}, nil
	}
	in, err := Collect(context.Background(), d.DB, d.al, read, sigNow)
	require.NoError(t, err)
	require.Len(t, in.Signals, 1)
	assert.Equal(t, Signal{Ref: fmt.Sprintf("s%d", sid), Kind: KindOwnerLine, WorkbenchID: wb, Text: "stop adding comments", at: in.Signals[0].at}, in.Signals[0])
}

func findText(texts []CurrentText, dest string, wb int64, prompt string) (CurrentText, bool) {
	for _, c := range texts {
		if c.Destination == dest && c.WorkbenchID == wb && c.PromptID == prompt {
			return c, true
		}
	}
	return CurrentText{}, false
}

func TestCollect_Texts(t *testing.T) {
	home := fakeHome(t)
	require.NoError(t, os.MkdirAll(filepath.Join(home, ".claude"), 0o700))
	require.NoError(t, os.WriteFile(filepath.Join(home, ".claude", "settings.json"),
		[]byte(`{"theme":"x","permissions":{"allow":["Bash(go test:*)","Read"]}}`), 0o600))
	d := openDBs(t)
	wb, _ := d.workbench(t, "acme", 0)
	require.NoError(t, d.SetOwnerInstruction(db.InstructionSession, "be brief"))
	require.NoError(t, d.SetOwnerInstruction(db.InstructionChat, "answer in Russian"))
	require.NoError(t, d.SetWorkbenchInstruction(wb, db.InstructionProcedure, "run lint first"))
	_, err := d.AddPromptAddition(prompts.SpecReview, "do not flag naming", 0, sigNow)
	require.NoError(t, err)
	_, err = d.AddPromptAddition(prompts.SpecReview, "skip typos", 0, sigNow)
	require.NoError(t, err)

	in, err := Collect(context.Background(), d.DB, d.al, noFeed, sigNow)
	require.NoError(t, err)

	c, ok := findText(in.Texts, DestSession, 0, "")
	require.True(t, ok)
	assert.Equal(t, CurrentText{Destination: DestSession, Text: "be brief", Budget: instructions.MaxRunes}, c)
	c, _ = findText(in.Texts, DestChat, 0, "")
	assert.Equal(t, "answer in Russian", c.Text)
	c, ok = findText(in.Texts, DestProcedure, wb, "")
	require.True(t, ok)
	assert.Equal(t, "run lint first", c.Text)
	_, ok = findText(in.Texts, DestSession, wb, "")
	assert.True(t, ok, "an empty text is still listed so it can be filled")
	c, ok = findText(in.Texts, DestPromptAdd, 0, prompts.SpecReview)
	require.True(t, ok)
	assert.Equal(t, "do not flag naming\nskip typos", c.Text)
	assert.Equal(t, prompts.MaxAdditionRunes, c.Budget)
	c, ok = findText(in.Texts, DestSettingsAllow, 0, "")
	require.True(t, ok)
	assert.Equal(t, "Bash(go test:*)\nRead", c.Text)
	assert.Zero(t, c.Budget)
}

func TestCollect_SettingsMissingOrSymlinkIsEmpty(t *testing.T) {
	home := fakeHome(t)
	d := openDBs(t)
	in, err := Collect(context.Background(), d.DB, d.al, noFeed, sigNow)
	require.NoError(t, err)
	c, ok := findText(in.Texts, DestSettingsAllow, 0, "")
	require.True(t, ok)
	assert.Empty(t, c.Text)

	target := filepath.Join(t.TempDir(), "real.json")
	require.NoError(t, os.WriteFile(target, []byte(`{"permissions":{"allow":["Read"]}}`), 0o600))
	require.NoError(t, os.MkdirAll(filepath.Join(home, ".claude"), 0o700))
	require.NoError(t, os.Symlink(target, filepath.Join(home, ".claude", "settings.json")))
	assert.Empty(t, readAllowList())
}

func TestCollect_ProposalBuckets(t *testing.T) {
	fakeHome(t)
	d := openDBs(t)
	mk := func(fp, status, verdict string) {
		id, err := d.InsertCoachProposal(db.CoachProposal{Fingerprint: fp, Kind: "add", Destination: "session",
			Title: fp, Metric: "corrections", AfterText: fp, Sources: 3}, sigNow)
		require.NoError(t, err)
		_, err = d.Exec(`UPDATE coach_proposals SET status = ?, verdict = ? WHERE id = ?`, status, verdict, id)
		require.NoError(t, err)
	}
	mk("open1", "open", "")
	mk("declined1", "declined", "")
	mk("works1", "accepted", "works")
	mk("noeff1", "accepted", "no_effect")
	mk("noeff2", "rolled_back", "no_effect")
	mk("super1", "superseded", "")

	in, err := Collect(context.Background(), d.DB, d.al, noFeed, sigNow)
	require.NoError(t, err)
	titles := func(ps []db.CoachProposal) []string {
		var out []string
		for _, p := range ps {
			out = append(out, p.Title)
		}
		return out
	}
	assert.Equal(t, []string{"open1"}, titles(in.Open))
	assert.Equal(t, []string{"declined1"}, titles(in.Declined))
	assert.Equal(t, []string{"works1"}, titles(in.Accepted))
	assert.ElementsMatch(t, []string{"noeff1", "noeff2"}, titles(in.NoEffect))
}

func TestCollect_DraftAndOutdatedCommentsAreNotEvidence(t *testing.T) {
	fakeHome(t)
	d := openDBs(t)
	wb, _ := d.workbench(t, "acme", 0)
	sent := d.reviewComment(t, wb, 0, sigNow.Add(-time.Hour), "sent one", false, false)
	var round int64
	require.NoError(t, d.QueryRow(`SELECT round_id FROM review_comments WHERE id = ?`, sent).Scan(&round))
	for _, st := range []string{"draft", "outdated"} {
		_, err := d.Exec(`INSERT INTO review_comments (round_id, body, status, created_at) VALUES (?, ?, ?, ?)`,
			round, st+" one", st, sigNow.Add(-time.Hour).Format(tsLayout))
		require.NoError(t, err)
	}
	in, err := Collect(context.Background(), d.DB, d.al, noFeed, sigNow)
	require.NoError(t, err)
	require.Len(t, in.Signals, 1)
	assert.Equal(t, "sent one", in.Signals[0].Text)
}

func TestCollect_MalformedSpecReviewIsSkipped(t *testing.T) {
	fakeHome(t)
	d := openDBs(t)
	wb, _ := d.workbench(t, "acme", 0)
	good := d.doneReview(t, wb, sigNow.Add(-2*time.Hour), specreview.Result{
		BlindSpots: []specreview.BlindSpot{{Key: "bs:111111111111", Text: "no rollback"}}})
	d.mark(t, good, "bs:111111111111", "comment", "")
	bad := d.doneReview(t, wb, sigNow.Add(-time.Hour), specreview.Result{})
	_, err := d.Exec(`UPDATE spec_reviews SET result = 'not json {secret text' WHERE ask_id = ?`, bad)
	require.NoError(t, err)
	d.mark(t, bad, "bs:222222222222", "comment", "")

	in, err := Collect(context.Background(), d.DB, d.al, noFeed, sigNow)
	require.NoError(t, err)
	require.Len(t, in.Signals, 1)
	assert.Equal(t, fmt.Sprintf("ask:%d#bs:111111111111", good), in.Signals[0].Ref)
}

func TestCollect_HintBecomesSignal(t *testing.T) {
	fakeHome(t)
	d := openDBs(t)
	wb, _ := d.workbench(t, "acme", 0)
	// Three failing "go test" calls in a row in one session: hint H5.
	uuid, path := "s1", "/tmp/x/s1.jsonl"
	at := func(s int) string { return sigNow.Add(-time.Hour).Add(time.Duration(s) * time.Second).Format(tsLayout) }
	evs := []agentlogdb.AgentLogEvent{{Kind: "owner_turn", Trigger: "owner", TS: at(0)}}
	for i := range 3 {
		evs = append(evs, agentlogdb.AgentLogEvent{Kind: "tool", Name: "Bash", Target: "go test", Outcome: "error", TS: at(10 + i)})
	}
	for i := range evs {
		evs[i].SessionUUID, evs[i].SrcPath, evs[i].SrcOffset, evs[i].Key = uuid, path, int64(i), fmt.Sprintf("%s:%d", uuid, i)
	}
	_, err := d.al.ApplyAgentLogBatch(agentlogdb.AgentLogBatch{
		File: agentlogdb.AgentLogFile{Path: path, Agent: "claude", ReadOffset: 10, ParserVersion: 4}, ExpectOffset: -1,
		Sessions: []agentlogdb.AgentLogSession{{SessionUUID: uuid, Agent: "claude", ProjectID: &wb, FolderPath: "/w", HomeCWD: "/w",
			SourcePath: path, StartedAt: at(0), EndedAt: at(60), Model: "claude-opus-5-5"}},
		Events: evs,
	})
	require.NoError(t, err)
	_, err = d.al.Exec(`UPDATE agent_log_events SET duration_ms = 4000 WHERE kind = 'tool'`)
	require.NoError(t, err)

	in, err := Collect(context.Background(), d.DB, d.al, noFeed, sigNow)
	require.NoError(t, err)
	var hints []Signal
	for _, s := range in.Signals {
		if s.Kind == KindHint {
			hints = append(hints, s)
		}
	}
	require.NotEmpty(t, hints)
	h := sigByRef(hints)[fmt.Sprintf("hint:H5@wb%d", wb)]
	assert.Equal(t, KindHint, h.Kind)
	assert.Equal(t, wb, h.WorkbenchID)
	assert.Contains(t, h.Text, " Action: ")
	assert.NotContains(t, h.Text, "Action: \n")
}
