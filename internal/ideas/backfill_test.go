package ideas

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// seedDigestTopicIdeasAt is seedDigestTopicIdeas with a caller-controlled
// parent-digest period_to — needed to place a topic precisely before/inside/
// after a backfill window, unlike seedDigestTopicIdeas which always dates
// itself at "now".
func seedDigestTopicIdeasAt(t *testing.T, d *db.DB, channelID, title string, ideas []digest.IdeaCandidate, decisions []digest.Decision, periodTo float64) int64 {
	t.Helper()
	if ideas == nil {
		ideas = []digest.IdeaCandidate{}
	}
	if decisions == nil {
		decisions = []digest.Decision{}
	}
	ideasJSON, err := json.Marshal(ideas)
	require.NoError(t, err)
	decisionsJSON, err := json.Marshal(decisions)
	require.NoError(t, err)

	digestID, err := d.UpsertDigest(db.Digest{
		ChannelID: channelID, Type: "channel", PeriodFrom: periodTo - 60, PeriodTo: periodTo,
		Summary: "s", Topics: "[]", Decisions: "[]", ActionItems: "[]", PeopleSignals: "[]", Situations: "[]",
	})
	require.NoError(t, err)

	require.NoError(t, d.InsertDigestTopics(digestID, []db.DigestTopic{{
		Idx: 0, Title: title, Summary: "s", Decisions: string(decisionsJSON), ActionItems: "[]",
		Situations: "[]", KeyMessages: "[]", Ideas: string(ideasJSON),
	}}))

	var topicID int64
	require.NoError(t, d.QueryRow(`SELECT id FROM digest_topics WHERE digest_id = ?`, digestID).Scan(&topicID))
	return topicID
}

// TestBackfill_DrainRespectsBoundAndRestoresAboveHighWaterMark covers three
// of the Step 1 requirements at once: the drain loop stays bounded by `to`
// (material after it is never rendered into a prompt or consumed), and the
// restore lands on max(saved, reached) — here saved wins, since a
// mid-history backfill must not regress the floor the ordinary daemon had
// already reached past the window.
func TestBackfill_DrainRespectsBoundAndRestoresAboveHighWaterMark(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)

	now := time.Now()
	from := now.Add(-72 * time.Hour)
	to := now.Add(-24 * time.Hour)

	midRef := "CMID|1.1"
	// Inserted first, so it gets the LOWER id — matching a real system where
	// historical topics are older (and thus lower-id) than the "already
	// synced, near now" material the ordinary daemon consumed past already.
	midTopicID := seedDigestTopicIdeasAt(t, d, "CMID", "mid-window",
		[]digest.IdeaCandidate{{Text: "try X", By: "Ann", MessageTS: "1.1"}}, nil,
		float64(from.Add(24*time.Hour).Unix()))
	postToTopicID := seedDigestTopicIdeasAt(t, d, "CAFTER", "after-window",
		[]digest.IdeaCandidate{{Text: "irrelevant", By: "Bob", MessageTS: "9.9"}}, nil,
		float64(to.Add(time.Hour).Unix()))
	require.Greater(t, postToTopicID, midTopicID)

	// Simulate the ordinary daemon having already processed up through (and
	// including) the post-`to` topic before this backfill ever runs.
	require.NoError(t, d.SetIdeasFloors(postToTopicID, 0, 0))

	var captured []string
	gen := &fakeGen{reply: func(user string) (string, error) {
		captured = append(captured, user)
		return fmt.Sprintf(`{"ops":[{"op":"new_idea","title":"Try X","essence":"e",
			"mentions":[{"source":"slack","ref":%q,"quote":"try X","author":"Ann","said_at":"2026-08-01T00:00:00Z"}]}]}`, midRef), nil
	}}
	p := New(d, testCfg(), gen, testLogger())

	result, err := p.Backfill(context.Background(), from, to, nil)
	require.NoError(t, err)
	assert.Equal(t, 1, result.Proposed)
	assert.Equal(t, 1, gen.calls, "only the in-window topic should ever reach the AI")

	for _, u := range captured {
		assert.NotContains(t, u, "CAFTER", "material after `to` must never be rendered into the prompt")
	}

	dFloor, _, _, err := d.GetIdeasFloors()
	require.NoError(t, err)
	assert.Equal(t, postToTopicID, dFloor,
		"restore must land on max(saved, reached) — the pre-backfill high-water mark, not wherever the bounded drain reached")

	ideas, err := d.ListIdeas(db.IdeaFilter{})
	require.NoError(t, err)
	require.Len(t, ideas, 1)
	mentions, err := d.ListIdeaMentions(ideas[0].ID)
	require.NoError(t, err)
	require.Len(t, mentions, 1)
	assert.Equal(t, midRef, mentions[0].Ref)

	// The post-`to` topic's own material must still be there, unconsumed,
	// for the ordinary daemon to find whenever its floor genuinely reaches it.
	after, err := d.ListDigestTopicIdeasAfter(midTopicID, 0)
	require.NoError(t, err)
	require.Len(t, after, 1)
	assert.Equal(t, postToTopicID, after[0].TopicID)
}

// TestBackfill_SecondIdenticalRun_ProposedZero pins IDEA-05 at the Backfill
// level: re-running the exact same window never duplicates a registry item,
// because the ref-level dedup in applyConsolidateOps catches it even though
// Backfill re-lowers the digest floor on every call.
func TestBackfill_SecondIdenticalRun_ProposedZero(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)

	now := time.Now()
	from := now.Add(-72 * time.Hour)
	to := now.Add(-24 * time.Hour)
	ref := "CBF|1.1"
	seedDigestTopicIdeasAt(t, d, "CBF", "backfill window",
		[]digest.IdeaCandidate{{Text: "try X", By: "Ann", MessageTS: "1.1"}}, nil,
		float64(from.Add(24*time.Hour).Unix()))

	gen := &fakeGen{reply: func(string) (string, error) {
		return fmt.Sprintf(`{"ops":[{"op":"new_idea","title":"Try X","essence":"e",
			"mentions":[{"source":"slack","ref":%q,"quote":"try X","author":"Ann","said_at":"2026-08-01T00:00:00Z"}]}]}`, ref), nil
	}}
	p := New(d, testCfg(), gen, testLogger())

	result1, err := p.Backfill(context.Background(), from, to, nil)
	require.NoError(t, err)
	assert.Equal(t, 1, result1.Proposed)

	result2, err := p.Backfill(context.Background(), from, to, nil)
	require.NoError(t, err)
	assert.Equal(t, 0, result2.Proposed, "re-mining an already-mined window must not duplicate")
	assert.Greater(t, result2.MentionsDeduped, 0, "the already-mined ref must be counted as deduped")

	ideas, err := d.ListIdeas(db.IdeaFilter{})
	require.NoError(t, err)
	assert.Len(t, ideas, 1, "the second run must not create a duplicate idea")
}

// TestBackfill_CoverageSkip_LeavesCoveredAccountsAlone pins spec §4 layer 2:
// an account whose window is already fully covered by an existing
// stream_digests row must never have its floor lowered, and stage-1 must
// never call the generator for it — even though real, unprocessed-looking
// Gmail/Jira data sits right inside the requested window. Without the
// coverage check, Backfill's lower step would drag both accounts' floors
// down and expose that data, so this test is sensitive to the skip actually
// firing.
func TestBackfill_CoverageSkip_LeavesCoveredAccountsAlone(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)

	now := time.Now()
	from := now.Add(-72 * time.Hour)
	to := now.Add(-24 * time.Hour)

	gmailAcct := seedGoogleAccount(t, d, float64(now.Unix()))
	priorGmailFloor := float64(to.Add(time.Hour).Unix())
	setIdeasEmailFloorRaw(t, d, gmailAcct, priorGmailFloor)
	_, err := d.InsertStreamDigest(db.StreamDigest{
		Source: "gmail", AccountID: gmailAcct,
		PeriodFrom: from.Add(-2 * time.Hour).UTC().Format(time.RFC3339),
		PeriodTo:   to.Add(2 * time.Hour).UTC().Format(time.RFC3339),
		TopicsJSON: "[]",
	})
	require.NoError(t, err)
	seedGmailMessageIdeas(t, d, gmailAcct, "m1", "thr-1", "a@example.com", "Ann", "Subj", "body",
		from.Add(time.Hour).UTC().Format(time.RFC3339))

	jiraAcct := seedJiraAccount(t, d)
	priorJiraFloor := db.FormatJiraTime(to.Add(time.Hour))
	setIdeasJiraFloorRaw(t, d, jiraAcct, priorJiraFloor)
	_, err = d.InsertStreamDigest(db.StreamDigest{
		Source: "jira", AccountID: jiraAcct,
		PeriodFrom: db.FormatJiraTime(from.Add(-2 * time.Hour)),
		PeriodTo:   db.FormatJiraTime(to.Add(2 * time.Hour)),
		TopicsJSON: "[]",
	})
	require.NoError(t, err)
	seedJiraIssueIdeas(t, d, jiraAcct, "WT-1", "WT", "Add caching layer", "Open", "new",
		"We should add a caching layer.", db.FormatJiraTime(from.Add(time.Hour)))

	gen := &fakeGen{reply: func(string) (string, error) { return `{"ops":[]}`, nil }}
	p := New(d, testCfg(), gen, testLogger())

	result, err := p.Backfill(context.Background(), from, to, nil)
	require.NoError(t, err)
	assert.Zero(t, result.Proposed)
	assert.Zero(t, gen.calls, "a fully-covered backfill window must produce zero AI calls at any stage")

	gmailFloor, err := d.IdeasEmailFloor(gmailAcct)
	require.NoError(t, err)
	assert.Equal(t, priorGmailFloor, gmailFloor, "a covered gmail account's floor must be untouched by backfill")

	jiraFloor, err := d.IdeasJiraFloor(jiraAcct)
	require.NoError(t, err)
	assert.Equal(t, priorJiraFloor, jiraFloor, "a covered jira account's floor must be untouched by backfill")
}

// TestBackfill_UncoveredAccounts_ConsumeAndRestoreReachedWins is Phase 1's
// dedicated consumption test — every other account-touching test in this
// file (TestBackfill_CoverageSkip_LeavesCoveredAccountsAlone) asserts ZERO
// generator calls, the covered case. This one drives real, uncovered Gmail
// and Jira material through Backfill and checks the opposite: the generator
// IS called, each account's own floor genuinely advances during the drain,
// and the restore explicitly lands on the REACHED value rather than the
// pre-backfill saved one — the mirror image of
// TestBackfill_DrainRespectsBoundAndRestoresAboveHighWaterMark, where saved
// wins instead because it is the larger of the two there.
func TestBackfill_UncoveredAccounts_ConsumeAndRestoreReachedWins(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)

	now := time.Now()
	from := now.Add(-72 * time.Hour)
	to := now.Add(-24 * time.Hour)

	gmailAcct := seedGoogleAccount(t, d, float64(now.Unix()))
	savedGmailFloor := float64(from.Add(-2 * time.Hour).Unix())
	setIdeasEmailFloorRaw(t, d, gmailAcct, savedGmailFloor)
	msgTS := from.Add(time.Hour).UTC().Format(time.RFC3339)
	seedGmailMessageIdeas(t, d, gmailAcct, "m1", "thr-1", "a@example.com", "Ann", "Subj", "we should try X", msgTS)

	jiraAcct := seedJiraAccount(t, d)
	savedJiraFloor := db.FormatJiraTime(from.Add(-2 * time.Hour))
	setIdeasJiraFloorRaw(t, d, jiraAcct, savedJiraFloor)
	issueUpdated := db.FormatJiraTime(from.Add(2 * time.Hour))
	seedJiraIssueIdeas(t, d, jiraAcct, "WT-1", "WT", "Add caching layer", "Open", "new",
		"We should add a caching layer.", issueUpdated)

	gen := &fakeGen{reply: func(user string) (string, error) {
		switch {
		case strings.Contains(user, "gmail:"):
			return fmt.Sprintf(`{"topics":[{"title":"t","summary":"s","ideas":[{"text":"try X","author":"Ann","ref":"gmail:%d:thr-1"}],"decisions":[]}]}`, gmailAcct), nil
		case strings.Contains(user, "WT-1"):
			return `{"topics":[{"title":"t","summary":"s","ideas":[{"text":"add caching layer","author":"Ann","ref":"WT-1"}],"decisions":[]}]}`, nil
		default:
			return `{"ops":[]}`, nil
		}
	}}
	p := New(d, testCfg(), gen, testLogger())

	_, err := p.Backfill(context.Background(), from, to, nil)
	require.NoError(t, err)
	assert.Greater(t, gen.calls, 0, "an uncovered account's stage-1 pass must call the generator")

	gmailFloor, err := d.IdeasEmailFloor(gmailAcct)
	require.NoError(t, err)
	assert.Equal(t, float64(from.Add(time.Hour).Unix()), gmailFloor, "the gmail floor must advance to the message it actually consumed")
	assert.Greater(t, gmailFloor, savedGmailFloor, "restore must land on the REACHED value, not the pre-backfill saved one, when reached is the larger of the two")

	jiraFloor, err := d.IdeasJiraFloor(jiraAcct)
	require.NoError(t, err)
	assert.Equal(t, issueUpdated, jiraFloor, "the jira floor must advance to the issue it actually consumed")
	reachedUnix, ok := db.ParseJiraTime(jiraFloor)
	require.True(t, ok)
	savedUnix, ok := db.ParseJiraTime(savedJiraFloor)
	require.True(t, ok)
	assert.Greater(t, reachedUnix, savedUnix, "restore must land on the REACHED value, not the pre-backfill saved one, when reached is the larger of the two")
}

// TestBackfill_EmptyWindow_CleanNoOpFloorsRestored is the degenerate case: a
// one-second window with no material anywhere lowers, drains (finding
// nothing), and restores the floors right back to their starting values —
// no AI call, no cycle wasted beyond the minimum.
func TestBackfill_EmptyWindow_CleanNoOpFloorsRestored(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)

	from := time.Now().Add(-time.Hour)
	to := from.Add(time.Second)

	gen := &fakeGen{reply: func(string) (string, error) {
		t.Fatal("an empty window must never call the generator")
		return "", nil
	}}
	p := New(d, testCfg(), gen, testLogger())

	beforeDigest, beforeStream, beforeTranscript, err := d.GetIdeasFloors()
	require.NoError(t, err)

	result, err := p.Backfill(context.Background(), from, to, nil)
	require.NoError(t, err)
	assert.Zero(t, result.Proposed)
	assert.Zero(t, result.MentionsDeduped)
	assert.Zero(t, gen.calls)

	afterDigest, afterStream, afterTranscript, err := d.GetIdeasFloors()
	require.NoError(t, err)
	assert.Equal(t, beforeDigest, afterDigest)
	assert.Equal(t, beforeStream, afterStream)
	assert.Equal(t, beforeTranscript, afterTranscript)
}

// TestBackfill_ToDefaultsToNow covers the CLI's "flagless --to" contract at
// the engine level: a zero `to` behaves as "now" rather than an unbounded
// zero-value bound.
func TestBackfill_ToDefaultsToNow(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)

	from := time.Now().Add(-time.Hour)
	ref := "CNOW|1.1"
	seedDigestTopicIdeasAt(t, d, "CNOW", "recent",
		[]digest.IdeaCandidate{{Text: "try X", By: "Ann", MessageTS: "1.1"}}, nil,
		float64(from.Add(30*time.Minute).Unix()))

	gen := &fakeGen{reply: func(string) (string, error) {
		return fmt.Sprintf(`{"ops":[{"op":"new_idea","title":"Try X","essence":"e",
			"mentions":[{"source":"slack","ref":%q,"quote":"try X","author":"Ann","said_at":"2026-08-01T00:00:00Z"}]}]}`, ref), nil
	}}
	p := New(d, testCfg(), gen, testLogger())

	result, err := p.Backfill(context.Background(), from, time.Time{}, nil)
	require.NoError(t, err)
	assert.Equal(t, 1, result.Proposed, "a zero `to` must still reach material up through now")
}

// TestBackfill_ProgressCallback_ReportsEachCycle pins the CLI's per-cycle
// progress contract: progress is called once per drain cycle with
// increasing, 1-based cycle numbers, and Cycles matches the last one seen.
func TestBackfill_ProgressCallback_ReportsEachCycle(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)

	from := time.Now().Add(-time.Hour)
	to := from.Add(30 * time.Minute)

	gen := &fakeGen{reply: func(string) (string, error) { return `{"ops":[]}`, nil }}
	p := New(d, testCfg(), gen, testLogger())

	var seen []int
	result, err := p.Backfill(context.Background(), from, to, func(cycle int) {
		seen = append(seen, cycle)
	})
	require.NoError(t, err)
	require.NotEmpty(t, seen)
	for i, c := range seen {
		assert.Equal(t, i+1, c, "progress cycles must be 1-based and strictly increasing")
	}
	assert.Equal(t, seen[len(seen)-1], result.Cycles)
}

// --- lock.go -----------------------------------------------------------

func TestBackfillLock_AcquireThenFresh(t *testing.T) {
	dir := t.TempDir()
	release, err := AcquireBackfillLock(dir)
	require.NoError(t, err)
	defer release()

	assert.True(t, BackfillLockFresh(dir))
}

func TestBackfillLock_SecondAcquireWhileFreshErrors(t *testing.T) {
	dir := t.TempDir()
	release, err := AcquireBackfillLock(dir)
	require.NoError(t, err)
	defer release()

	_, err = AcquireBackfillLock(dir)
	require.Error(t, err)
}

func TestBackfillLock_ReleaseClearsFreshness(t *testing.T) {
	dir := t.TempDir()
	release, err := AcquireBackfillLock(dir)
	require.NoError(t, err)
	release()

	assert.False(t, BackfillLockFresh(dir))
}

// TestBackfillLock_StaleLockIsNotFreshAndCanBeReacquired covers the
// stale-vs-fresh distinction spec §5 relies on: a lock older than the
// freshness window reads as not-fresh and does not block a new acquire — the
// crashed-backfill recovery path.
func TestBackfillLock_StaleLockIsNotFreshAndCanBeReacquired(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, backfillLockFilename)
	stale := fmt.Sprintf("pid=1 started=%s\n", time.Now().Add(-3*time.Hour).UTC().Format(time.RFC3339))
	require.NoError(t, os.WriteFile(path, []byte(stale), 0o644))

	assert.False(t, BackfillLockFresh(dir), "a lock older than the freshness window must read as stale")

	release, err := AcquireBackfillLock(dir)
	require.NoError(t, err, "a stale lock must not block a new acquire")
	defer release()
	assert.True(t, BackfillLockFresh(dir))
}

// TestBackfillLock_StaleLockReclaimIsExactlyOnce covers the O_EXCL
// exclusive-create fix directly: the create itself (not a prior freshness
// check) is what decides ownership, so reclaiming a stale lock installs a
// genuinely fresh one — this process's own pid/timestamp, not the stale
// content left behind — in a single retry. A further acquire attempt right
// after, with no release in between, must see that freshly-reclaimed lock as
// held rather than reclaiming it again (the "second IsExist = held, error
// out" half of the fix).
func TestBackfillLock_StaleLockReclaimIsExactlyOnce(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, backfillLockFilename)
	stale := fmt.Sprintf("pid=999999 started=%s\n", time.Now().Add(-3*time.Hour).UTC().Format(time.RFC3339))
	require.NoError(t, os.WriteFile(path, []byte(stale), 0o644))

	release, err := AcquireBackfillLock(dir)
	require.NoError(t, err, "a stale lock must be reclaimed in a single retry")

	data, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.NotContains(t, string(data), "pid=999999",
		"the reclaimed lock must be rewritten with this process's own pid/timestamp, not the stale one left behind")
	assert.Contains(t, string(data), fmt.Sprintf("pid=%d", os.Getpid()))

	_, err = AcquireBackfillLock(dir)
	require.Error(t, err, "a lock this process just reclaimed must not be reclaimable again without a release")

	release()
	assert.False(t, BackfillLockFresh(dir))
}

func TestBackfillLock_MissingLockIsNotFresh(t *testing.T) {
	dir := t.TempDir()
	assert.False(t, BackfillLockFresh(dir))
}

func TestBackfillLock_MalformedLockIsNotFresh(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, backfillLockFilename)
	require.NoError(t, os.WriteFile(path, []byte("not a lock file"), 0o644))

	assert.False(t, BackfillLockFresh(dir), "an unparseable lock must read as stale, not permanently fresh")
}
