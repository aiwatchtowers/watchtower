package specreview

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/sessionfeed"
)

// fakeAgent answers out (or err) and runs during, if set, before it returns.
type fakeAgent struct {
	out          string
	err          error
	codeRead     bool
	calls        int
	system, user string
	folder       string
	during       func()
	sawDeadline  bool
}

func (a *fakeAgent) Review(ctx context.Context, folder, system, user string) (string, bool, error) {
	a.calls++
	a.folder = folder
	a.system, a.user = system, user
	_, a.sawDeadline = ctx.Deadline()
	if a.during != nil {
		a.during()
	}
	return a.out, a.codeRead, a.err
}

const runDoc = "# Spec\n\nGoal: the owner can mute a channel for a day.\n\n## Behaviour\n\nMuting lasts twenty-four hours\nand then expires by itself.\n"

// runReply has two agreements: the first quotes the conversation, the second
// cites a quote nobody said.
const runReply = `{
  "summary": "The spec matches the idea.",
  "idea": {"owner_quote": "mute a channel for a day", "goal_quote": "the owner can mute a channel for a day", "verdict": "matches", "note": "Same.",
           "owner_source": {"kind": "conversation", "ref": "entry:e1", "quote": "mute a channel for a day"}},
  "agreements": [
    {"text": "A mute lasts a day", "status": "as_agreed", "note": "ok",
     "source": {"kind": "conversation", "ref": "entry:e1", "quote": "mute a channel for a day"},
     "where": {"heading": "Behaviour", "quote": "Muting lasts twenty-four hours"}},
    {"text": "Mutes sync to the phone", "status": "missing", "note": "invented",
     "source": {"kind": "conversation", "ref": "entry:e1", "quote": "sync every mute to my phone"}, "where": null}
  ],
  "decided_alone": [], "blind_spots": [], "checks": [], "resolved": [], "notes": []
}`

func runFixture(t *testing.T) (*fixture, int64) {
	t.Helper()
	f := newFixture(t)
	f.feed = []sessionfeed.Entry{{ID: "e1", Kind: sessionfeed.KindOwner, Text: "Please let me mute a channel for a day."}}
	return f, f.ask(t, "spec", runDoc).ID
}

func TestRun_StoresValidatedResult(t *testing.T) {
	f, askID := runFixture(t)
	agent := &fakeAgent{out: runReply, codeRead: true}
	require.NoError(t, Run(context.Background(), f.deps(agent), askID))

	assert.Equal(t, 1, agent.calls)
	assert.Equal(t, "SYSTEM", agent.system)
	assert.Contains(t, agent.user, "=== DATA ===")
	assert.True(t, agent.sawDeadline, "the agent runs under RunTimeout")
	row, err := f.d.GetSpecReview(askID)
	require.NoError(t, err)
	assert.Equal(t, "done", row.Status)
	assert.Equal(t, 1, row.Dropped)
	assert.Equal(t, "claude", row.Provider)
	assert.Equal(t, "strong-model", row.Model)
	sum := sha256.Sum256([]byte(runDoc))
	assert.Equal(t, hex.EncodeToString(sum[:]), row.DocSHA)
	var res Result
	require.NoError(t, json.Unmarshal([]byte(row.Result), &res))
	assert.Equal(t, "The spec matches the idea.", res.Summary)
	require.Len(t, res.Agreements, 1)
	assert.Equal(t, "A mute lasts a day", res.Agreements[0].Text)
	assert.True(t, res.CodeRead)
	assert.Equal(t, 1, res.Dropped)
}

func TestRun_LostClaimDoesNothing(t *testing.T) {
	f, askID := runFixture(t)
	ok, err := f.d.ClaimSpecReview(askID, 1, runNow)
	require.NoError(t, err)
	require.True(t, ok)
	agent := &fakeAgent{out: runReply}
	require.NoError(t, Run(context.Background(), f.deps(agent), askID))

	assert.Zero(t, agent.calls)
	assert.Zero(t, f.feedCalls)
	row, err := f.d.GetSpecReview(askID)
	require.NoError(t, err)
	assert.Equal(t, "running", row.Status)
	assert.Equal(t, 1, row.PID)
}

func TestRun_AgentErrorFails(t *testing.T) {
	f, askID := runFixture(t)
	before, err := f.d.GetOwnerAskByID(askID)
	require.NoError(t, err)
	agent := &fakeAgent{err: errors.New("claude exited\nwith status 1")}
	require.Error(t, Run(context.Background(), f.deps(agent), askID))

	row, err := f.d.GetSpecReview(askID)
	require.NoError(t, err)
	assert.Equal(t, "failed", row.Status)
	assert.Contains(t, row.Reason, "claude exited with status 1")
	assert.NotContains(t, row.Reason, "\n")
	assert.Empty(t, row.Result)
	after, err := f.d.GetOwnerAskByID(askID)
	require.NoError(t, err)
	assert.Equal(t, before, after, "the ask is unchanged")
}

func TestRun_BadReplyFails(t *testing.T) {
	f, askID := runFixture(t)
	require.Error(t, Run(context.Background(), f.deps(&fakeAgent{out: "not json"}), askID))
	row, err := f.d.GetSpecReview(askID)
	require.NoError(t, err)
	assert.Equal(t, "failed", row.Status)
	assert.NotEmpty(t, row.Reason)
}

func TestRun_NotASpecFails(t *testing.T) {
	f := newFixture(t)
	a := f.ask(t, "other", runDoc)
	agent := &fakeAgent{out: runReply}
	require.Error(t, Run(context.Background(), f.deps(agent), a.ID))
	assert.Zero(t, agent.calls)
	row, err := f.d.GetSpecReview(a.ID)
	require.NoError(t, err)
	assert.Equal(t, "failed", row.Status)
}

func TestRun_AskWithdrawnMidRun(t *testing.T) {
	f, askID := runFixture(t)
	agent := &fakeAgent{out: runReply, during: func() {
		require.NoError(t, f.d.WithdrawOwnerAsk(f.wb, askID, "agent"))
	}}
	require.NoError(t, Run(context.Background(), f.deps(agent), askID))

	row, err := f.d.GetSpecReview(askID)
	require.NoError(t, err)
	assert.Equal(t, "done", row.Status)
	assert.NotEmpty(t, row.Result)
	a, err := f.d.GetOwnerAskByID(askID)
	require.NoError(t, err)
	assert.Equal(t, "withdrawn", a.Status)
}

func TestRun_FeedErrorIsANote(t *testing.T) {
	f, askID := runFixture(t)
	f.feedErr = errors.New("transcript gone")
	agent := &fakeAgent{out: `{"summary":"ok","agreements":[],"decided_alone":[],"blind_spots":[],"checks":[],"resolved":[],"notes":["model note"]}`}
	require.NoError(t, Run(context.Background(), f.deps(agent), askID))
	row, err := f.d.GetSpecReview(askID)
	require.NoError(t, err)
	var res Result
	require.NoError(t, json.Unmarshal([]byte(row.Result), &res))
	assert.True(t, hasNote(res.Notes, "conversation not read: transcript gone"), "notes = %v", res.Notes)
	assert.True(t, hasNote(res.Notes, "model note"))
}

func TestRun_AgentGetsTheResolvedFolder(t *testing.T) {
	f, askID := runFixture(t)
	agent := &fakeAgent{out: runReply}
	require.NoError(t, Run(context.Background(), f.deps(agent), askID))
	assert.Equal(t, f.folder, agent.folder, "no agent_cwd: the workbench folder")
}

func TestRun_AgentCwdWorktreeWins(t *testing.T) {
	f, askID := runFixture(t)
	wt := t.TempDir()
	_, err := f.d.Exec(`UPDATE terminal_sessions SET agent_cwd = ? WHERE id = ?`, wt, f.session)
	require.NoError(t, err)
	agent := &fakeAgent{out: runReply}
	require.NoError(t, Run(context.Background(), f.deps(agent), askID))
	assert.Equal(t, wt, agent.folder)
}

// No readable folder: the run fails before any agent call, never runs the
// agent outside a read folder.
func TestRun_NoReadableFolderFails(t *testing.T) {
	f, askID := runFixture(t)
	_, err := f.d.Exec(`UPDATE projects SET folder_path = ? WHERE id = ?`, f.folder+"/gone", f.wb)
	require.NoError(t, err)
	agent := &fakeAgent{out: runReply}
	require.Error(t, Run(context.Background(), f.deps(agent), askID))
	assert.Zero(t, agent.calls)
	row, err := f.d.GetSpecReview(askID)
	require.NoError(t, err)
	assert.Equal(t, "failed", row.Status)
	assert.Contains(t, row.Reason, "not a readable directory")
}

// dumpTables is every table's rows but spec_reviews', as text, in a stable
// order: what a run must leave untouched.
func dumpTables(t *testing.T, d *db.DB) map[string]string {
	t.Helper()
	out := map[string]string{}
	for _, n := range tableNames(t, d) {
		if n != "spec_reviews" {
			if rows, ok := dumpTable(t, d, n); ok {
				out[n] = rows
			}
		}
	}
	return out
}

func tableNames(t *testing.T, d *db.DB) []string {
	t.Helper()
	rows, err := d.Query(`SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
		AND name NOT LIKE '%\_fts%' ESCAPE '\' ORDER BY name`)
	require.NoError(t, err)
	defer rows.Close()
	var names []string
	for rows.Next() {
		var n string
		require.NoError(t, rows.Scan(&n))
		names = append(names, n)
	}
	require.NoError(t, rows.Err())
	return names
}

// dumpTable is the table's rows as sorted text; false for a table the plain
// engine cannot scan.
func dumpTable(t *testing.T, d *db.DB, name string) (string, bool) {
	t.Helper()
	r, err := d.Query(`SELECT * FROM "` + name + `"`)
	if err != nil {
		return "", false
	}
	defer r.Close()
	cols, err := r.Columns()
	require.NoError(t, err)
	var lines []string
	for r.Next() {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		require.NoError(t, r.Scan(ptrs...))
		lines = append(lines, fmt.Sprint(vals...))
	}
	require.NoError(t, r.Err())
	sort.Strings(lines)
	return strings.Join(lines, "\n"), true
}

// folderState is every entry of the folder with its mtime and size.
func folderState(t *testing.T, root string) []string {
	t.Helper()
	var out []string
	require.NoError(t, filepath.Walk(root, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		out = append(out, fmt.Sprintf("%s %d %d", p, info.ModTime().UnixNano(), info.Size()))
		return nil
	}))
	return out
}

// BEHAVIOR SPECREVIEW-01: the reviewer never writes the folder and writes only
// its own spec_reviews row.
func TestSpecReview01_RunWritesOnlyItsRow(t *testing.T) {
	f, askID := runFixture(t)
	f.write(t, "docs/specs/x-design.md", runDoc)
	beforeTables := dumpTables(t, f.d)
	beforeFolder := folderState(t, f.folder)
	require.Greater(t, len(beforeTables), 20, "the dump sees the schema")
	require.NotEmpty(t, beforeTables["owner_asks"])

	require.NoError(t, Run(context.Background(), f.deps(&fakeAgent{out: runReply}), askID))
	row, err := f.d.GetSpecReview(askID)
	require.NoError(t, err)
	require.Equal(t, "done", row.Status)
	assert.Equal(t, beforeTables, dumpTables(t, f.d), "no table but spec_reviews changes")
	assert.Equal(t, beforeFolder, folderState(t, f.folder), "the folder is untouched")

	// A failing run writes only its row too.
	f2, askID2 := runFixture(t)
	before2 := dumpTables(t, f2.d)
	require.Error(t, Run(context.Background(), f2.deps(&fakeAgent{err: errors.New("boom")}), askID2))
	assert.Equal(t, before2, dumpTables(t, f2.d))

	// An author-loop round 2 (with a previous row) writes only its row, when
	// it advances the loop and when it fails and reveals the ask.
	for _, agent := range []*fakeAgent{{out: loopReply2}, {err: errors.New("boom")}} {
		f3 := newFixture(t)
		f3.write(t, "docs/specs/x-design.md", runDoc)
		first, second := loopRound2(t, f3, nil)
		before3 := dumpTables(t, f3.d)
		beforeFolder3 := folderState(t, f3.folder)
		prevRow, err := f3.d.GetSpecReview(first)
		require.NoError(t, err)
		_ = Run(context.Background(), f3.deps(agent), second)
		row, err := f3.d.GetSpecReview(second)
		require.NoError(t, err)
		require.Contains(t, []string{"done", "failed"}, row.Status)
		require.NotEmpty(t, row.Ledger+row.OpenItems, "the loop columns were written")
		assert.Equal(t, before3, dumpTables(t, f3.d), "no table but spec_reviews changes")
		assert.Equal(t, beforeFolder3, folderState(t, f3.folder), "the folder is untouched")
		after, err := f3.d.GetSpecReview(first)
		require.NoError(t, err)
		assert.Equal(t, prevRow, after, "the previous round's row is only read")
	}
}

// A review whose ask was withdrawn (or superseded) before the reviewer
// claimed it does not run: the row fails with "ask withdrawn".
func TestRun_AskWithdrawnBeforeClaimDoesNotRun(t *testing.T) {
	f, askID := runFixture(t)
	require.NoError(t, f.d.WithdrawOwnerAsk(f.wb, askID, "agent"))
	agent := &fakeAgent{out: runReply}
	require.Error(t, Run(context.Background(), f.deps(agent), askID))

	assert.Zero(t, agent.calls)
	assert.Zero(t, f.feedCalls)
	row, err := f.d.GetSpecReview(askID)
	require.NoError(t, err)
	assert.Equal(t, "failed", row.Status)
	assert.Equal(t, "ask withdrawn", row.Reason)
}

func TestRun_CountsFindings(t *testing.T) {
	f, askID := runFixture(t)
	reply := strings.Replace(runReply, `"decided_alone": [], "blind_spots": [], "checks": []`,
		`"decided_alone": [{"text": "d1", "where": null, "note": "n"}, {"text": "d2", "where": null, "note": "n"}],
  "blind_spots": [{"text": "b1", "note": "n"}], "checks": [{"lens": "l", "chapter": "c", "answer": "ok", "note": "n"}]`, 1)
	require.NoError(t, Run(context.Background(), f.deps(&fakeAgent{out: reply}), askID))
	row, err := f.d.GetSpecReview(askID)
	require.NoError(t, err)
	var res Result
	require.NoError(t, json.Unmarshal([]byte(row.Result), &res))
	assert.Equal(t, len(res.DecidedAlone)+len(res.BlindSpots)+len(res.Checks), row.Findings)
	assert.Positive(t, row.Findings, "the reply carries findings that survive validation")
}

// loopPrevOpen is round 1's open items in the loop fixtures.
var loopPrevOpen = []AuthorItem{
	{Key: "bs:aaaaaaaaaaaa", Kind: KindBlindSpot, Text: "Muted threads", Round: 1},
	{Key: "da:bbbbbbbbbbbb", Kind: KindDecidedAlone, Text: "State is local", Round: 1,
		Where: &Anchor{Heading: "Behaviour", Quote: "Muting lasts twenty-four hours"}},
	{Key: "ck:cccccccccccc", Kind: KindCheck, Text: "Does every promise have a task?", Note: "Expiry has none.", Round: 1},
}

// loopReplies is the author's answer to loopPrevOpen.
var loopReplies = []Reply{
	{Key: "bs:aaaaaaaaaaaa", Reply: ReplyFixed, Note: "named threads"},
	{Key: "da:bbbbbbbbbbbb", Reply: ReplyDisagree, Note: "the owner asked for it"},
	{Key: "ck:cccccccccccc", Reply: ReplyFixed},
}

// loopRound2 files round 1 (done, in the author loop, with loopPrevOpen open
// and prevLedger settled) and a queued round 2 on top of it with loopReplies.
func loopRound2(t *testing.T, f *fixture, prevLedger []LedgerEntry) (first, second int64) {
	t.Helper()
	first = f.ask(t, "spec", runDoc).ID
	open, err := encodeList(loopPrevOpen)
	require.NoError(t, err)
	ledger, err := encodeList(prevLedger)
	require.NoError(t, err)
	_, err = f.d.Exec(`UPDATE spec_reviews SET status = 'done', loop = 'author', round = 1, open_items = ?, ledger = ?
		WHERE ask_id = ?`, open, ledger, first)
	require.NoError(t, err)
	replies, err := encodeList(loopReplies)
	require.NoError(t, err)
	require.NoError(t, f.d.WithTx(func(tx *sql.Tx) error {
		second, _, err = f.d.InsertOwnerAsk(tx, db.OwnerAsk{
			WorkbenchID: f.wb, SessionID: sql.NullInt64{Int64: f.session, Valid: true},
			TargetID: sql.NullInt64{Int64: f.tgt, Valid: true}, Kind: "review", Title: "Round 2",
			DocPath: "docs/specs/x-design.md", DocSnapshot: runDoc, DocType: "spec",
			PreviousAskID: sql.NullInt64{Int64: first, Valid: true},
		})
		if err != nil {
			return err
		}
		return f.d.QueueSpecReview(tx, second, runNow, &db.SpecLoopStart{Round: 2, Replies: replies})
	}))
	return first, second
}

// loopReply2 resolves the fixed blind spot, disputes the disagreed decision,
// disputes the "fixed" check (it stays open) and raises one new blind spot.
const loopReply2 = `{"summary":"Round two.","agreements":[],"decided_alone":[],"checks":[],"resolved":[],
  "blind_spots":[{"text":"Expiry after a restart","why":"the timer is in memory","where":null}],
  "verdicts":[
    {"key":"bs:aaaaaaaaaaaa","verdict":"resolved","note":"named now"},
    {"key":"da:bbbbbbbbbbbb","verdict":"disputed","note":"still nobody agreed it"},
    {"key":"ck:cccccccccccc","verdict":"disputed","note":"expiry still has no task"}]}`

func loopColumns(t *testing.T, d *db.DB, askID int64) (*db.SpecReview, []AuthorItem, []LedgerEntry) {
	t.Helper()
	row, err := d.GetSpecReview(askID)
	require.NoError(t, err)
	ledger, open, err := decodeLoop(row)
	require.NoError(t, err)
	return row, open, ledger
}

func TestRun_LoopRoundTwoFinishes(t *testing.T) {
	f := newFixture(t)
	prevLedger := []LedgerEntry{{AuthorItem: AuthorItem{Key: "ag:zzzzzzzzzzzz", Kind: KindAgreement, Text: "old", Round: 1}, Verdict: VerdictResolved, Settled: 1}}
	_, second := loopRound2(t, f, prevLedger)
	agent := &fakeAgent{out: loopReply2}
	require.NoError(t, Run(context.Background(), f.deps(agent), second))

	assert.Contains(t, agent.user, "[bs:aaaaaaaaaaaa] blind_spot: Muted threads — author: fixed (named threads)")
	assert.Contains(t, agent.user, "[da:bbbbbbbbbbbb] decided_alone: State is local — author: disagree: the owner asked for it")
	assert.Contains(t, agent.user, "[ck:cccccccccccc] check: Does every promise have a task? — author: fixed\n")
	assert.NotContains(t, agent.user, "<<<previous_findings")

	row, open, ledger := loopColumns(t, f.d, second)
	assert.Equal(t, "done", row.Status)
	assert.Equal(t, "author", row.Loop, "an item is still open: the loop goes on")
	assert.Equal(t, "", row.LoopEnd)
	assert.Equal(t, 0, row.Dropped)
	require.Len(t, open, 2)
	assert.Equal(t, "ck:cccccccccccc", open[0].Key)
	assert.Equal(t, ReplyFixed, open[0].Reply.Reply)
	assert.Equal(t, KindBlindSpot, open[1].Kind)
	assert.Equal(t, "Expiry after a restart", open[1].Text)
	assert.Equal(t, 2, open[1].Round)
	require.Len(t, ledger, 3)
	assert.Equal(t, "ag:zzzzzzzzzzzz", ledger[0].Key)
	assert.Equal(t, [2]string{"bs:aaaaaaaaaaaa", VerdictResolved}, [2]string{ledger[1].Key, ledger[1].Verdict})
	assert.Equal(t, [2]string{"da:bbbbbbbbbbbb", VerdictDisputed}, [2]string{ledger[2].Key, ledger[2].Verdict})
	assert.Equal(t, "still nobody agreed it", ledger[2].VerdictNote)
	assert.Equal(t, 2, ledger[2].Settled)
	var res Result
	require.NoError(t, json.Unmarshal([]byte(row.Result), &res))
	assert.Len(t, res.Verdicts, 3)

	// A round that leaves nothing open ends the loop for the owner.
	f2 := newFixture(t)
	_, second2 := loopRound2(t, f2, nil)
	settle := `{"summary":"All settled.","verdicts":[
		{"key":"bs:aaaaaaaaaaaa","verdict":"resolved"},{"key":"da:bbbbbbbbbbbb","verdict":"disputed"},
		{"key":"ck:cccccccccccc","verdict":"resolved"}]}`
	require.NoError(t, Run(context.Background(), f2.deps(&fakeAgent{out: settle}), second2))
	row2, open2, ledger2 := loopColumns(t, f2.d, second2)
	assert.Equal(t, "owner", row2.Loop)
	assert.Equal(t, EndSettled, row2.LoopEnd)
	assert.Empty(t, open2)
	assert.Empty(t, row2.OpenItems)
	assert.Len(t, ledger2, 3)
}

func TestRun_LoopFailureReveals(t *testing.T) {
	f := newFixture(t)
	prevLedger := []LedgerEntry{{AuthorItem: AuthorItem{Key: "ag:zzzzzzzzzzzz", Kind: KindAgreement, Text: "old", Round: 1}, Verdict: VerdictResolved, Settled: 1}}
	_, second := loopRound2(t, f, prevLedger)
	require.Error(t, Run(context.Background(), f.deps(&fakeAgent{err: errors.New("boom")}), second))

	row, open, ledger := loopColumns(t, f.d, second)
	assert.Equal(t, "failed", row.Status)
	assert.Equal(t, "owner", row.Loop)
	assert.Equal(t, EndReviewerFailed, row.LoopEnd)
	assert.Empty(t, open)
	require.Len(t, ledger, 4, "the previous ledger plus the previous open items")
	assert.Equal(t, "ag:zzzzzzzzzzzz", ledger[0].Key)
	notes := map[string]string{}
	for _, e := range ledger[1:] {
		assert.Equal(t, VerdictUnsettled, e.Verdict)
		notes[e.Key] = e.VerdictNote
	}
	assert.Equal(t, map[string]string{
		"bs:aaaaaaaaaaaa": "The fix was not checked: the reviewer failed",
		"da:bbbbbbbbbbbb": "the owner asked for it",
		"ck:cccccccccccc": "The fix was not checked: the reviewer failed",
	}, notes)

	// Round 1 of a loop failing: nothing was found yet, the ask shows with an
	// empty ledger.
	f2 := newFixture(t)
	var askID int64
	require.NoError(t, f2.d.WithTx(func(tx *sql.Tx) error {
		var err error
		askID, _, err = f2.d.InsertOwnerAsk(tx, db.OwnerAsk{
			WorkbenchID: f2.wb, SessionID: sql.NullInt64{Int64: f2.session, Valid: true}, Kind: "review",
			Title: "Review", DocPath: "docs/specs/x-design.md", DocSnapshot: runDoc, DocType: "spec",
		})
		if err != nil {
			return err
		}
		return f2.d.QueueSpecReview(tx, askID, runNow, &db.SpecLoopStart{Round: 1})
	}))
	require.Error(t, Run(context.Background(), f2.deps(&fakeAgent{out: "not json"}), askID))
	row2, err := f2.d.GetSpecReview(askID)
	require.NoError(t, err)
	assert.Equal(t, "owner", row2.Loop)
	assert.Equal(t, EndReviewerFailed, row2.LoopEnd)
	assert.Empty(t, row2.Ledger)
}

func TestReveal_DoneRowUsesItsOpenItems(t *testing.T) {
	f := newFixture(t)
	first, _ := loopRound2(t, f, []LedgerEntry{{AuthorItem: AuthorItem{Key: "ag:zzzzzzzzzzzz", Round: 1}, Verdict: VerdictResolved, Settled: 1}})
	// Round 1's open items carry no reply; give one a disagree carried over.
	open := append([]AuthorItem{}, loopPrevOpen...)
	open[1].Reply = &Reply{Key: open[1].Key, Reply: ReplyDisagree, Note: "kept on purpose"}
	js, err := encodeList(open)
	require.NoError(t, err)
	_, err = f.d.Exec(`UPDATE spec_reviews SET open_items = ? WHERE ask_id = ?`, js, first)
	require.NoError(t, err)

	require.NoError(t, Reveal(f.d, first, EndTimeout, runNow))
	row, gotOpen, ledger := loopColumns(t, f.d, first)
	assert.Equal(t, "owner", row.Loop)
	assert.Equal(t, EndTimeout, row.LoopEnd)
	assert.Empty(t, gotOpen)
	require.Len(t, ledger, 4)
	assert.Equal(t, "ag:zzzzzzzzzzzz", ledger[0].Key)
	assert.Equal(t, "The author did not answer", ledger[1].VerdictNote)
	assert.Equal(t, "kept on purpose", ledger[2].VerdictNote)
	assert.Equal(t, "The author did not answer", ledger[3].VerdictNote)
	for _, e := range ledger[1:] {
		assert.Equal(t, VerdictUnsettled, e.Verdict)
		assert.Equal(t, 1, e.Settled)
	}
}

func TestReveal_FailedRowUsesPrevious(t *testing.T) {
	f := newFixture(t)
	_, second := loopRound2(t, f, nil)
	ok, err := f.d.ClaimSpecReview(second, 7, runNow)
	require.NoError(t, err)
	require.True(t, ok)
	require.NoError(t, f.d.FailSpecReview(second, 7, "boom", runNow))

	require.NoError(t, Reveal(f.d, second, EndSessionGone, runNow))
	row, _, ledger := loopColumns(t, f.d, second)
	assert.Equal(t, "owner", row.Loop)
	assert.Equal(t, EndSessionGone, row.LoopEnd)
	require.Len(t, ledger, 3)
	assert.Equal(t, "The fix was not checked: the author's session ended", ledger[0].VerdictNote)
	assert.Equal(t, "named threads", ledger[0].Reply.Note, "this round's reply is kept")
	assert.Equal(t, "the owner asked for it", ledger[1].VerdictNote)
	assert.Equal(t, 2, ledger[1].Settled)
}

func TestReveal_NoOpOnOwnerRow(t *testing.T) {
	f := newFixture(t)
	first, _ := loopRound2(t, f, nil)
	_, err := f.d.Exec(`UPDATE spec_reviews SET loop = 'owner', loop_end = 'settled', ledger = '[]' WHERE ask_id = ?`, first)
	require.NoError(t, err)
	before, err := f.d.GetSpecReview(first)
	require.NoError(t, err)
	require.NoError(t, Reveal(f.d, first, EndTimeout, runNow))
	after, err := f.d.GetSpecReview(first)
	require.NoError(t, err)
	assert.Equal(t, before, after)

	// A row outside any loop is left alone too.
	plain := f.ask(t, "spec", runDoc).ID
	require.NoError(t, Reveal(f.d, plain, EndTimeout, runNow))
	r, err := f.d.GetSpecReview(plain)
	require.NoError(t, err)
	assert.Equal(t, "", r.Loop)
	assert.Equal(t, "", r.LoopEnd)
}

// Show Now on a finished round: its open items go to the owner as unsettled,
// with the owner's note.
func TestReveal_OwnerShowNow(t *testing.T) {
	f := newFixture(t)
	first, _ := loopRound2(t, f, nil)
	require.NoError(t, Reveal(f.d, first, EndOwner, runNow))
	row, _, ledger := loopColumns(t, f.d, first)
	assert.Equal(t, "owner", row.Loop)
	assert.Equal(t, EndOwner, row.LoopEnd)
	require.NotEmpty(t, ledger)
	for _, e := range ledger {
		assert.Contains(t, []string{ownerEarlyNote, "kept on purpose"}, e.VerdictNote)
	}

	// A running round with fixes: the fixes were not checked.
	f2 := newFixture(t)
	_, second := loopRound2(t, f2, nil)
	ok, err := f2.d.ClaimSpecReview(second, 7, runNow)
	require.NoError(t, err)
	require.True(t, ok)
	require.NoError(t, Reveal(f2.d, second, EndOwner, runNow))
	_, _, ledger2 := loopColumns(t, f2.d, second)
	require.NotEmpty(t, ledger2)
	assert.Equal(t, "The fix was not checked: you opened the review before it was", ledger2[0].VerdictNote)
}

// Show Now before round 1 finished: the ask becomes a plain review, and the
// reviewer's result lands as one.
func TestReveal_OwnerShowNowFirstRoundRunning(t *testing.T) {
	f := newFixture(t)
	var askID int64
	require.NoError(t, f.d.WithTx(func(tx *sql.Tx) error {
		var err error
		askID, _, err = f.d.InsertOwnerAsk(tx, db.OwnerAsk{
			WorkbenchID: f.wb, SessionID: sql.NullInt64{Int64: f.session, Valid: true}, Kind: "review",
			Title: "Review", DocPath: "docs/specs/x-design.md", DocSnapshot: runDoc, DocType: "spec",
		})
		if err != nil {
			return err
		}
		return f.d.QueueSpecReview(tx, askID, runNow, &db.SpecLoopStart{Round: 1})
	}))
	ok, err := f.d.ClaimSpecReview(askID, 7, runNow)
	require.NoError(t, err)
	require.True(t, ok)
	require.NoError(t, Reveal(f.d, askID, EndOwner, runNow))
	row, err := f.d.GetSpecReview(askID)
	require.NoError(t, err)
	assert.Equal(t, "", row.Loop)
	assert.Equal(t, EndOwner, row.LoopEnd)

	require.NoError(t, f.d.FinishSpecReview(askID, 7, db.SpecReview{Result: `{}`, Loop: "author", LoopEnd: "", OpenItems: "[]"}, runNow))
	row, err = f.d.GetSpecReview(askID)
	require.NoError(t, err)
	assert.Equal(t, "done", row.Status)
	assert.Equal(t, "", row.Loop, "the finished reviewer leaves it a plain review")
	assert.Empty(t, row.OpenItems)
}
