package db

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// livingOut is a living inbox output with key and content hash.
func livingOut(key, title, hash string) AutomationOutput {
	return AutomationOutput{Kind: "inbox", Title: title, Body: "b", OutputKey: key, ContentHash: hash,
		BlocksJSON: `{"v":1,"blocks":[]}`}
}

// runOnce enqueues, claims and finishes one succeeded run of automation a at
// now with c, returning the run id.
func runOnce(t *testing.T, d *DB, a int64, now time.Time, c *RunCommit) int64 {
	t.Helper()
	run, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerManual, Now: now})
	require.True(t, mustClaimAutomationRun(t, d, run), "claim lost")
	mustFinishAutomationRun(t, d, run, RunFinish{Status: RunSucceeded, Now: now}, c)
	return run
}

// outputByKey reads automation a's living output with key.
func outputByKey(t *testing.T, d *DB, a int64, key string) AutomationOutput {
	t.Helper()
	var id int64
	require.NoError(t, d.QueryRow(`SELECT id FROM automation_outputs WHERE automation_id = ? AND output_key = ?`, a, key).Scan(&id))
	o, err := d.GetAutomationOutput(id)
	require.NoError(t, err)
	return *o
}

// markAllStates stamps every Desktop- and CLI-written state column of output id.
func markAllStates(t *testing.T, d *DB, id, pressRun int64, at time.Time) {
	t.Helper()
	s := formatAutomationTime(at)
	_, err := d.Exec(`UPDATE automation_outputs SET read_at = ?, done_at = ?, dismissed_at = ?,
		pressed_action = 0, pressed_run_id = ?, pressed_at = ? WHERE id = ?`, s, s, s, pressRun, s, id)
	require.NoError(t, err)
}

// desktopMarkOpened is the Desktop's guarded markOutputOpened statement
// (AutomationQueries.stampOnce with the drawn content hash): it changes the
// row only when the drawn version is still the stored one.
func desktopMarkOpened(t *testing.T, d *DB, id int64, drawnHash string, now time.Time) int64 {
	t.Helper()
	res, err := d.Exec(`UPDATE automation_outputs SET read_at = ?
		WHERE id = ? AND content_hash = ? AND done_at IS NULL AND dismissed_at IS NULL AND read_at IS NULL`,
		formatAutomationTime(now), id, drawnHash)
	require.NoError(t, err)
	n, err := res.RowsAffected()
	require.NoError(t, err)
	return n
}

func TestAuto04_LivingUpsertCommittedOnlyOnSuccess(t *testing.T) {
	d := openTestDB(t)
	a, prior := seedRunningAutomationRun(t, d)
	mustFinishAutomationRun(t, d, prior, RunFinish{Status: RunSucceeded},
		&RunCommit{Outputs: []AutomationOutput{livingOut("a", "old", "h1"), {Kind: "inbox", Title: "feed", Body: "b"}}})
	markAllStates(t, d, outputByKey(t, d, a, "a").ID, prior, runTestNow)
	before := readAutomationData(t, d, a)

	run, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerManual})
	mustClaimAutomationRun(t, d, run)
	later := runTestNow.Add(time.Hour)
	commit := &RunCommit{Outputs: []AutomationOutput{livingOut("a", "new", "h2"), livingOut("b", "added", "h3")}}
	for _, status := range []string{RunFailed, RunTimedOut, RunBudgetExceeded, RunCancelled} {
		err := d.FinishAutomationRun(run, RunFinish{Status: status, ErrorKind: ErrKindScript, Now: later}, commit)
		wantErrIs(t, status+"+commit", err, ErrCommitOnFailure)
		wantAutomationDataUnchanged(t, d, a, before)
		wantAutomationRun(t, d, run, RunRunning, "")
	}

	// A write failing after the upsert rolls the upsert back too.
	broken := &RunCommit{Outputs: []AutomationOutput{livingOut("a", "new", "h2"), {Kind: "bogus", Title: "t", Body: "b"}}}
	require.Error(t, d.FinishAutomationRun(run, RunFinish{Status: RunSucceeded, Now: later}, broken))
	wantAutomationDataUnchanged(t, d, a, before)
	wantAutomationRun(t, d, run, RunRunning, "")

	mustFinishAutomationRun(t, d, run, RunFinish{Status: RunSucceeded, Now: later}, commit)
	got := outputByKey(t, d, a, "a")
	assert.Equal(t, "new", got.Title)
	assert.Equal(t, run, got.RunID)
	assert.Equal(t, "h2", got.ContentHash)
	assert.Equal(t, "added", outputByKey(t, d, a, "b").Title)
	wantRowCount(t, d, "automation_outputs", 3)
}

func TestAuto04_RemoveCommittedOnlyOnSuccess(t *testing.T) {
	d := openTestDB(t)
	a, prior := seedRunningAutomationRun(t, d)
	mustFinishAutomationRun(t, d, prior, RunFinish{Status: RunSucceeded},
		&RunCommit{Outputs: []AutomationOutput{livingOut("a", "gone soon", "h1"), livingOut("b", "stays", "h2")}})
	before := readAutomationData(t, d, a)

	run, _ := mustEnqueueAutomationRun(t, d, EnqueueRequest{AutomationID: a, Trigger: TriggerManual})
	mustClaimAutomationRun(t, d, run)
	commit := &RunCommit{Removals: []string{"a"}}
	for _, status := range []string{RunFailed, RunTimedOut, RunBudgetExceeded, RunCancelled} {
		err := d.FinishAutomationRun(run, RunFinish{Status: status, ErrorKind: ErrKindScript, Now: runTestNow}, commit)
		wantErrIs(t, status+"+remove", err, ErrCommitOnFailure)
		wantAutomationDataUnchanged(t, d, a, before)
	}

	// A write failing after the removal brings the removed row back.
	broken := &RunCommit{Removals: []string{"a"}, Outputs: []AutomationOutput{{Kind: "bogus", Title: "t", Body: "b"}}}
	require.Error(t, d.FinishAutomationRun(run, RunFinish{Status: RunSucceeded, Now: runTestNow}, broken))
	wantAutomationDataUnchanged(t, d, a, before)
	wantAutomationRun(t, d, run, RunRunning, "")

	mustFinishAutomationRun(t, d, run, RunFinish{Status: RunSucceeded}, &RunCommit{Removals: []string{"a", "missing"}})
	wantRowCount(t, d, "automation_outputs", 1)
	assert.Equal(t, "stays", outputByKey(t, d, a, "b").Title, "a missing key is a no-op")
}

func TestLivingUpsert_SameHashKeepsReadStateAndPress(t *testing.T) {
	d := openTestDB(t)
	a := seedRunAutomation(t, d, "digest", 1)
	first := runOnce(t, d, a, runTestNow, &RunCommit{Outputs: []AutomationOutput{livingOut("a", "card", "h1")}})
	orig := outputByKey(t, d, a, "a")
	markAllStates(t, d, orig.ID, first, runTestNow.Add(time.Minute))
	marked := outputByKey(t, d, a, "a")

	later := runTestNow.Add(time.Hour)
	second := runOnce(t, d, a, later, &RunCommit{Outputs: []AutomationOutput{livingOut("a", "card", "h1")}})
	got := outputByKey(t, d, a, "a")
	assert.Equal(t, orig.ID, got.ID, "id kept")
	assert.True(t, got.CreatedAt.Equal(runTestNow), "created_at kept")
	assert.Equal(t, second, got.RunID, "the row names the last run that wrote it")
	assert.True(t, got.WrittenAt.Equal(later), "written_at moves on every write")
	assert.True(t, got.ChangedAt.Equal(runTestNow), "changed_at stays on a same-hash write")
	assert.Equal(t, marked.ReadAt, got.ReadAt)
	assert.Equal(t, marked.DoneAt, got.DoneAt)
	assert.Equal(t, marked.DismissedAt, got.DismissedAt)
	assert.Equal(t, marked.PressedAction, got.PressedAction)
	assert.Equal(t, first, got.PressedRunID)
	assert.Equal(t, marked.PressedAt, got.PressedAt)
}

func TestLivingUpsert_ChangedHashClearsReadStateAndPress(t *testing.T) {
	d := openTestDB(t)
	a := seedRunAutomation(t, d, "digest", 1)
	first := runOnce(t, d, a, runTestNow, &RunCommit{Outputs: []AutomationOutput{livingOut("a", "card", "h1")}})
	orig := outputByKey(t, d, a, "a")
	markAllStates(t, d, orig.ID, first, runTestNow.Add(time.Minute))

	later := runTestNow.Add(time.Hour)
	actions := []InboxAction{{Label: "Open", Kind: InboxActionLink, Open: "https://example.com/x"}}
	changed := AutomationOutput{Kind: "inbox", Title: "card v2", Body: "b2", Priority: "high", Link: "https://example.com/x",
		Actions: actions, OutputKey: "a", ContentHash: "h2", BlocksJSON: `{"v":1,"blocks":[{"type":"text","text":"x"}]}`}
	runOnce(t, d, a, later, &RunCommit{Outputs: []AutomationOutput{changed}})
	got := outputByKey(t, d, a, "a")
	assert.Equal(t, orig.ID, got.ID)
	assert.True(t, got.CreatedAt.Equal(runTestNow))
	assert.True(t, got.WrittenAt.Equal(later))
	assert.True(t, got.ChangedAt.Equal(later), "changed_at moves with the hash")
	assert.Nil(t, got.ReadAt)
	assert.Nil(t, got.DoneAt)
	assert.Nil(t, got.DismissedAt)
	assert.Nil(t, got.PressedAction)
	assert.Zero(t, got.PressedRunID)
	assert.Nil(t, got.PressedAt)
	assert.Equal(t, []any{"card v2", "b2", "high", "https://example.com/x", "h2", changed.BlocksJSON},
		[]any{got.Title, got.Body, got.Priority, got.Link, got.ContentHash, got.BlocksJSON})
	assert.Equal(t, actions, got.Actions)
}

func TestLivingUpsert_StaleMarkMissesChangedVersion(t *testing.T) {
	d := openTestDB(t)
	a := seedRunAutomation(t, d, "digest", 1)
	runOnce(t, d, a, runTestNow, &RunCommit{Outputs: []AutomationOutput{livingOut("a", "card", "h1")}})
	id := outputByKey(t, d, a, "a").ID

	// The owner drew h1; a same-hash rewrite lands before the mark: it still marks.
	runOnce(t, d, a, runTestNow.Add(time.Hour), &RunCommit{Outputs: []AutomationOutput{livingOut("a", "card", "h1")}})
	assert.EqualValues(t, 1, desktopMarkOpened(t, d, id, "h1", runTestNow.Add(2*time.Hour)))

	// A changed rewrite clears read_at; a mark with the old hash changes nothing.
	runOnce(t, d, a, runTestNow.Add(3*time.Hour), &RunCommit{Outputs: []AutomationOutput{livingOut("a", "card v2", "h2")}})
	assert.EqualValues(t, 0, desktopMarkOpened(t, d, id, "h1", runTestNow.Add(4*time.Hour)))
	assert.Nil(t, outputByKey(t, d, a, "a").ReadAt)
	assert.EqualValues(t, 1, desktopMarkOpened(t, d, id, "h2", runTestNow.Add(4*time.Hour)))
}

func TestLivingUpsert_SameHashIsNotNew(t *testing.T) {
	d := openTestDB(t)
	a := seedRunAutomation(t, d, "digest", 1)
	runOnce(t, d, a, runTestNow, &RunCommit{Outputs: []AutomationOutput{livingOut("a", "card", "h1")}})
	id := outputByKey(t, d, a, "a").ID
	require.EqualValues(t, 1, desktopMarkOpened(t, d, id, "h1", runTestNow.Add(time.Minute)))
	before := outputByKey(t, d, a, "a")

	runOnce(t, d, a, runTestNow.Add(time.Hour), &RunCommit{Outputs: []AutomationOutput{livingOut("a", "card", "h1")}})
	after := outputByKey(t, d, a, "a")
	assert.True(t, after.ChangedAt.Equal(before.ChangedAt), "changed_at unchanged")
	assert.Equal(t, before.ReadAt, after.ReadAt, "still read")
	assert.Equal(t, 0, countWhere(t, d, `SELECT COUNT(*) FROM automation_outputs WHERE kind = 'inbox' AND read_at IS NULL`),
		"no unread card")
}

func TestLivingUpsert_FeedAndOtherAutomationsUntouched(t *testing.T) {
	d := openTestDB(t)
	a := seedRunAutomation(t, d, "digest", 1)
	other := seedRunAutomation(t, d, "other", 1)
	runOnce(t, d, a, runTestNow, &RunCommit{Outputs: []AutomationOutput{{Kind: "inbox", Title: "feed", Body: "b", ContentHash: "f1"}}})
	runOnce(t, d, other, runTestNow, &RunCommit{Outputs: []AutomationOutput{livingOut("a", "theirs", "o1")}})
	before, err := d.ListAutomationOutputs("", 0)
	require.NoError(t, err)

	runOnce(t, d, a, runTestNow.Add(time.Hour), &RunCommit{Outputs: []AutomationOutput{livingOut("a", "mine", "m1")}})
	after, err := d.ListAutomationOutputs("", 0)
	require.NoError(t, err)
	require.Len(t, after, 3)
	assert.Equal(t, before, after[1:], "the feed row and the other automation's key are untouched")
	assert.Equal(t, "mine", after[0].Title)

	feed := before[1]
	assert.Equal(t, "feed", feed.Title)
	assert.Empty(t, feed.OutputKey)
	assert.Equal(t, "f1", feed.ContentHash)
	assert.True(t, feed.WrittenAt.Equal(runTestNow) && feed.ChangedAt.Equal(runTestNow), "a feed row: written = changed = created")
}

func TestLivingUpsert_RawSecondKeyRefusedByIndex(t *testing.T) {
	d := openTestDB(t)
	a := seedRunAutomation(t, d, "digest", 1)
	run := runOnce(t, d, a, runTestNow, &RunCommit{Outputs: []AutomationOutput{livingOut("a", "card", "h1")}})
	_, err := d.Exec(`INSERT INTO automation_outputs (automation_id, run_id, kind, title, body, output_key)
		VALUES (?, ?, 'inbox', 't', 'b', 'a')`, a, run)
	require.Error(t, err, "a second row for one key")
	_, err = d.Exec(`INSERT INTO automation_outputs (automation_id, run_id, kind, title, body)
		VALUES (?, ?, 'inbox', 't', 'b'), (?, ?, 'inbox', 't', 'b')`, a, run, a, run)
	require.NoError(t, err, "feed rows (NULL key) are not unique")
}

func TestLivingCommit_RefusesMalformed(t *testing.T) {
	d := openTestDB(t)
	a, run := seedRunningAutomationRun(t, d)
	before := readAutomationData(t, d, a)
	report := livingOut("a", "r", "h1")
	report.Kind = "report"
	for name, c := range map[string]*RunCommit{
		"living report":       {Outputs: []AutomationOutput{report}},
		"living without hash": {Outputs: []AutomationOutput{livingOut("a", "t", "")}},
		"empty removal key":   {Removals: []string{""}},
		"written and removed": {Outputs: []AutomationOutput{livingOut("a", "t", "h1")}, Removals: []string{"a"}},
	} {
		err := d.FinishAutomationRun(run, RunFinish{Status: RunSucceeded, Now: runTestNow}, c)
		wantErrIs(t, name, err, ErrInvalidRunFinish)
		wantAutomationDataUnchanged(t, d, a, before)
		wantAutomationRun(t, d, run, RunRunning, "")
	}
}

func TestListAutomationOutputs_OrderedByChangedAt(t *testing.T) {
	d := openTestDB(t)
	a := seedRunAutomation(t, d, "digest", 1)
	runOnce(t, d, a, runTestNow, &RunCommit{Outputs: []AutomationOutput{livingOut("a", "old living", "h1")}})
	runOnce(t, d, a, runTestNow.Add(time.Hour), &RunCommit{Outputs: []AutomationOutput{{Kind: "inbox", Title: "feed", Body: "b"}}})
	titles := func() []string {
		outs, err := d.ListAutomationOutputs("inbox", 0)
		require.NoError(t, err)
		var ts []string
		for _, o := range outs {
			ts = append(ts, o.Title)
		}
		return ts
	}

	// A same-hash rewrite does not move the card up.
	runOnce(t, d, a, runTestNow.Add(2*time.Hour), &RunCommit{Outputs: []AutomationOutput{livingOut("a", "old living", "h1")}})
	assert.Equal(t, []string{"feed", "old living"}, titles())
	// A changed one does.
	runOnce(t, d, a, runTestNow.Add(3*time.Hour), &RunCommit{Outputs: []AutomationOutput{livingOut("a", "new living", "h2")}})
	assert.Equal(t, []string{"new living", "feed"}, titles())
}

func TestMigration00173_BackfillsWrittenAndChangedAt(t *testing.T) {
	d := openTestDB(t)
	require.NoError(t, gooseDownTo(d.DB, "migrations", 172))
	a := seedAutomationRow(t, d, "digest", "/acme/automations/digest.md", "h1")
	_, err := d.Exec(`INSERT INTO automation_runs (id, automation_id, trigger, status) VALUES (1, ?, 'manual', 'succeeded')`, a)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO automation_outputs (id, automation_id, run_id, kind, title, body, created_at, read_at) VALUES
		(1, ?, 1, 'inbox', 'card', 'b', '2026-10-20T09:00:00Z', '2026-10-20T10:00:00Z'),
		(2, ?, 1, 'report', 'r', 'b', '2026-10-21T09:00:00Z', NULL)`, a, a)
	require.NoError(t, err)

	require.NoError(t, gooseUp(d.DB, "migrations"))

	assert.Equal(t, 2, countWhere(t, d, `SELECT COUNT(*) FROM automation_outputs
		WHERE written_at = created_at AND changed_at = created_at AND output_key IS NULL
		AND content_hash = '' AND blocks_json = ''`))
	o, err := d.GetAutomationOutput(1)
	require.NoError(t, err)
	assert.True(t, o.ChangedAt.Equal(time.Date(2026, 10, 20, 9, 0, 0, 0, time.UTC)))
	require.NotNil(t, o.ReadAt, "read state survives")

	// Down and up again leave the same table.
	require.NoError(t, gooseDownTo(d.DB, "migrations", 172))
	require.NoError(t, gooseUp(d.DB, "migrations"))
	assert.Equal(t, 2, countWhere(t, d, `SELECT COUNT(*) FROM automation_outputs WHERE changed_at = created_at`))
}

// A row inserted without the 00173 columns (an older writer, a test fixture)
// reads with written_at = changed_at = created_at.
func TestAutomationOutput_NullTimesReadAsCreatedAt(t *testing.T) {
	d := openTestDB(t)
	a := seedRunAutomation(t, d, "digest", 1)
	run := runOnce(t, d, a, runTestNow, nil)
	_, err := d.Exec(`INSERT INTO automation_outputs (id, automation_id, run_id, kind, title, body, created_at)
		VALUES (9, ?, ?, 'inbox', 't', 'b', '2026-10-20T09:00:00Z')`, a, run)
	require.NoError(t, err)
	o, err := d.GetAutomationOutput(9)
	require.NoError(t, err)
	assert.True(t, o.WrittenAt.Equal(o.CreatedAt) && o.ChangedAt.Equal(o.CreatedAt))
}
