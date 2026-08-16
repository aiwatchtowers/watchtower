package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func TestInboxCommandRegistered(t *testing.T) {
	found := false
	for _, cmd := range rootCmd.Commands() {
		if cmd.Name() == "inbox" {
			found = true
			break
		}
	}
	assert.True(t, found, "inbox command should be registered")
}

func TestInboxSubcommandsRegistered(t *testing.T) {
	subs := map[string]bool{"show": false, "resolve": false, "dismiss": false, "snooze": false, "generate": false, "task": false, "feedback": false, "style-sample": false, "backfill-mentions": false}
	for _, cmd := range inboxCmd.Commands() {
		if _, ok := subs[cmd.Name()]; ok {
			subs[cmd.Name()] = true
		}
	}
	for name, found := range subs {
		assert.True(t, found, "inbox %s subcommand should be registered", name)
	}
}

func TestInboxFlags(t *testing.T) {
	assert.NotNil(t, inboxCmd.Flags().Lookup("priority"))
	assert.NotNil(t, inboxCmd.Flags().Lookup("type"))
	assert.NotNil(t, inboxCmd.Flags().Lookup("all"))
	assert.NotNil(t, inboxCmd.Flags().Lookup("json"))
	assert.NotNil(t, inboxFeedbackCmd.Flags().Lookup("rating"), "inbox feedback --rating")
	assert.NotNil(t, inboxFeedbackCmd.Flags().Lookup("comment"), "inbox feedback --comment")
	assert.NotNil(t, inboxBackfillMentionsCmd.Flags().Lookup("since"), "inbox backfill-mentions --since")
	assert.NotNil(t, inboxBackfillMentionsCmd.Flags().Lookup("dry-run"), "inbox backfill-mentions --dry-run")
}

func setupInboxTestEnv(t *testing.T) func() {
	t.Helper()
	cleanup := setupWatchTestEnv(t)
	database, err := openDBFromConfig()
	require.NoError(t, err)
	require.NoError(t, database.UpsertWorkspace(db.Workspace{ID: "T001", Name: "test-ws", Domain: "test-ws"}))
	_, acctErr := database.CreateSlackAccount(db.SlackAccount{CurrentUserID: "U001"})
	require.NoError(t, acctErr)
	database.Close()
	return cleanup
}

var inboxTestSeq int

func seedInboxItem(t *testing.T, triggerType, priority, snippet string) {
	t.Helper()
	database, err := openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()

	inboxTestSeq++
	item := db.InboxItem{
		ChannelID:    "C001",
		MessageTS:    fmt.Sprintf("1711000%03d.000100", inboxTestSeq),
		SenderUserID: "U002",
		TriggerType:  triggerType,
		Snippet:      snippet,
		Status:       "pending",
		Priority:     priority,
	}
	_, err = database.CreateInboxItem(item)
	require.NoError(t, err)
}

func TestRunInbox_WithItems(t *testing.T) {
	cleanup := setupInboxTestEnv(t)
	defer cleanup()

	seedInboxItem(t, "mention", "high", "Hey @alice review this PR")
	seedInboxItem(t, "dm", "medium", "Got a minute to chat?")

	buf := new(bytes.Buffer)
	inboxCmd.SetOut(buf)
	inboxFlagPriority = ""
	inboxFlagType = ""
	inboxFlagAll = false
	inboxFlagJSON = false

	err := inboxCmd.RunE(inboxCmd, nil)
	require.NoError(t, err)

	output := buf.String()
	assert.Contains(t, output, "Hey @alice review this PR")
	assert.Contains(t, output, "Got a minute to chat?")
	assert.Contains(t, output, "HIGH")
	assert.Contains(t, output, "DM")
}

func TestRunInbox_Empty(t *testing.T) {
	cleanup := setupInboxTestEnv(t)
	defer cleanup()

	buf := new(bytes.Buffer)
	inboxCmd.SetOut(buf)
	inboxFlagPriority = ""
	inboxFlagType = ""
	inboxFlagAll = false
	inboxFlagJSON = false

	err := inboxCmd.RunE(inboxCmd, nil)
	require.NoError(t, err)
	assert.Contains(t, buf.String(), "No inbox items found")
}

func TestRunInbox_FilterByPriority(t *testing.T) {
	cleanup := setupInboxTestEnv(t)
	defer cleanup()

	seedInboxItem(t, "mention", "high", "Urgent blocker")
	seedInboxItem(t, "mention", "low", "Minor question")

	buf := new(bytes.Buffer)
	inboxCmd.SetOut(buf)
	inboxFlagPriority = "high"
	inboxFlagType = ""
	inboxFlagAll = false
	inboxFlagJSON = false

	err := inboxCmd.RunE(inboxCmd, nil)
	require.NoError(t, err)

	output := buf.String()
	assert.Contains(t, output, "Urgent blocker")
	assert.NotContains(t, output, "Minor question")
}

func TestRunInbox_FilterByType(t *testing.T) {
	cleanup := setupInboxTestEnv(t)
	defer cleanup()

	seedInboxItem(t, "mention", "medium", "Hey @alice check")
	seedInboxItem(t, "dm", "medium", "Direct message here")

	buf := new(bytes.Buffer)
	inboxCmd.SetOut(buf)
	inboxFlagPriority = ""
	inboxFlagType = "dm"
	inboxFlagAll = false
	inboxFlagJSON = false

	err := inboxCmd.RunE(inboxCmd, nil)
	require.NoError(t, err)

	output := buf.String()
	assert.Contains(t, output, "Direct message here")
	assert.NotContains(t, output, "Hey @alice check")
}

func TestRunInbox_JSON(t *testing.T) {
	cleanup := setupInboxTestEnv(t)
	defer cleanup()

	seedInboxItem(t, "mention", "high", "JSON test item")

	buf := new(bytes.Buffer)
	inboxCmd.SetOut(buf)
	inboxFlagPriority = ""
	inboxFlagType = ""
	inboxFlagAll = false
	inboxFlagJSON = true

	err := inboxCmd.RunE(inboxCmd, nil)
	require.NoError(t, err)

	output := buf.String()
	assert.Contains(t, output, `"Snippet": "JSON test item"`)
	assert.Contains(t, output, `"Priority": "high"`)
}

func TestRunInboxShow(t *testing.T) {
	cleanup := setupInboxTestEnv(t)
	defer cleanup()

	seedInboxItem(t, "mention", "high", "Show this inbox item")

	buf := new(bytes.Buffer)
	inboxShowCmd.SetOut(buf)

	err := inboxShowCmd.RunE(inboxShowCmd, []string{"1"})
	require.NoError(t, err)

	output := buf.String()
	assert.Contains(t, output, "Inbox Item #1")
	assert.Contains(t, output, "pending")
	assert.Contains(t, output, "high")
	assert.Contains(t, output, "mention")
	assert.Contains(t, output, "Show this inbox item")
}

func TestRunInboxShow_InvalidID(t *testing.T) {
	err := inboxShowCmd.RunE(inboxShowCmd, []string{"abc"})
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "invalid inbox item ID")
}

func TestRunInboxResolve(t *testing.T) {
	cleanup := setupInboxTestEnv(t)
	defer cleanup()

	seedInboxItem(t, "mention", "medium", "To resolve")

	buf := new(bytes.Buffer)
	inboxResolveCmd.SetOut(buf)

	err := inboxResolveCmd.RunE(inboxResolveCmd, []string{"1"})
	require.NoError(t, err)
	assert.Contains(t, buf.String(), "resolved")

	database, err := openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()
	item, err := database.GetInboxItemByID(1)
	require.NoError(t, err)
	assert.Equal(t, "resolved", item.Status)
}

func TestRunInboxDismiss(t *testing.T) {
	cleanup := setupInboxTestEnv(t)
	defer cleanup()

	seedInboxItem(t, "dm", "low", "To dismiss")

	buf := new(bytes.Buffer)
	inboxDismissCmd.SetOut(buf)

	err := inboxDismissCmd.RunE(inboxDismissCmd, []string{"1"})
	require.NoError(t, err)
	assert.Contains(t, buf.String(), "dismissed")

	database, err := openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()
	item, err := database.GetInboxItemByID(1)
	require.NoError(t, err)
	assert.Equal(t, "dismissed", item.Status)
}

func TestRunInboxSnooze(t *testing.T) {
	cleanup := setupInboxTestEnv(t)
	defer cleanup()

	seedInboxItem(t, "mention", "medium", "To snooze")

	buf := new(bytes.Buffer)
	inboxSnoozeCmd.SetOut(buf)

	err := inboxSnoozeCmd.RunE(inboxSnoozeCmd, []string{"1", "3d"})
	require.NoError(t, err)
	assert.Contains(t, buf.String(), "snoozed")

	database, err := openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()
	item, err := database.GetInboxItemByID(1)
	require.NoError(t, err)
	assert.Equal(t, "snoozed", item.Status)
	assert.NotEmpty(t, item.SnoozeUntil)
}

func TestRunInboxTask(t *testing.T) {
	cleanup := setupInboxTestEnv(t)
	defer cleanup()

	seedInboxItem(t, "mention", "high", "Create task from this")

	buf := new(bytes.Buffer)
	inboxTaskCmd.SetOut(buf)

	err := inboxTaskCmd.RunE(inboxTaskCmd, []string{"1"})
	require.NoError(t, err)
	assert.Contains(t, buf.String(), "Created target #")

	database, err := openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()

	target, err := database.GetTargetByID(1)
	require.NoError(t, err)
	assert.Equal(t, "Create task from this", target.Text)
	assert.Equal(t, "high", target.Priority)
	assert.Equal(t, "inbox", target.SourceType)
	assert.Equal(t, "1", target.SourceID)
}

func TestParseDuration(t *testing.T) {
	tests := []struct {
		input   string
		wantErr bool
	}{
		{"1d", false},
		{"3d", false},
		{"1w", false},
		{"2w", false},
		{"0d", true},
		{"abc", true},
		{"", true},
		{"1x", true},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			_, err := parseDuration(tt.input)
			if tt.wantErr {
				assert.Error(t, err)
			} else {
				assert.NoError(t, err)
			}
		})
	}
}

func TestRunInbox_RequiresConfig(t *testing.T) {
	oldFlagConfig := flagConfig
	flagConfig = "/nonexistent/config.yaml"
	defer func() { flagConfig = oldFlagConfig }()

	inboxFlagPriority = ""
	inboxFlagType = ""
	inboxFlagAll = false
	inboxFlagJSON = false

	err := inboxCmd.RunE(inboxCmd, nil)
	assert.Error(t, err)
}

// resetInboxBackfillMentionsFlags clears the backfill-mentions command's
// package-level flag vars so one test's values never leak into the next
// (the --kind cleanup precedent in cmd/ideas_test.go).
func resetInboxBackfillMentionsFlags() {
	inboxBackfillMentionsFlagSince = ""
	inboxBackfillMentionsFlagDryRun = false
	inboxBackfillMentionsFlagForce = false
}

// seedBackfillMentionsFixture wires a temp HOME/config/DB (the
// setupWatchTestEnv precedent) plus one enabled Slack account (account id 1,
// so its own id matches the "1:" prefix baked into the fixture's channel/user
// ids) and one message mentioning that account's own user, timestamped 15
// days ago — old enough that a broken/behind detector would already have
// scanned past it, exactly the situation backfill-mentions exists to
// recover. Returns the setupWatchTestEnv cleanup func; callers open their
// own *db.DB via openDBFromConfig() afterward since the fixture closes its
// own handle before returning.
func seedBackfillMentionsFixture(t *testing.T) func() {
	t.Helper()
	cleanup := setupWatchTestEnv(t)

	database, err := openDBFromConfig()
	require.NoError(t, err)
	_, err = database.CreateSlackAccount(db.SlackAccount{CurrentUserID: "1:U_ME"})
	require.NoError(t, err)

	oldTS := fmt.Sprintf("%d.000000", time.Now().Add(-15*24*time.Hour).Unix())
	_, err = database.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', ?, '1:U_OTHER', 'Hey <@U_ME> review please')`, oldTS)
	require.NoError(t, err)
	database.Close()

	return cleanup
}

// TestRunInboxBackfillMentions_MissingSince_Errors covers the "--since is
// required" contract: with no default, an omitted --since must fail clearly
// rather than silently sweeping all history.
func TestRunInboxBackfillMentions_MissingSince_Errors(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetInboxBackfillMentionsFlags()
	defer resetInboxBackfillMentionsFlags()

	err := inboxBackfillMentionsCmd.RunE(inboxBackfillMentionsCmd, nil)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "--since is required")
}

// TestRunInboxBackfillMentions_InvalidSinceDate_Errors covers the date parse
// contract: --since must be YYYY-MM-DD, not any other format.
func TestRunInboxBackfillMentions_InvalidSinceDate_Errors(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetInboxBackfillMentionsFlags()
	defer resetInboxBackfillMentionsFlags()

	inboxBackfillMentionsFlagSince = "not-a-date"

	err := inboxBackfillMentionsCmd.RunE(inboxBackfillMentionsCmd, nil)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "invalid --since date")
}

// TestRunInboxBackfillMentions_CreatesItemsMatchingEnvelope covers the
// command's main contract: a valid run recovers the seeded mention, and the
// printed envelope's created count matches exactly what landed in
// inbox_items — not just a number the pipeline reported internally.
func TestRunInboxBackfillMentions_CreatesItemsMatchingEnvelope(t *testing.T) {
	cleanup := seedBackfillMentionsFixture(t)
	defer cleanup()
	resetInboxBackfillMentionsFlags()
	defer resetInboxBackfillMentionsFlags()

	inboxBackfillMentionsFlagSince = time.Now().Add(-20 * 24 * time.Hour).Format("2006-01-02")
	inboxBackfillMentionsFlagDryRun = false

	buf := new(bytes.Buffer)
	inboxBackfillMentionsCmd.SetOut(buf)

	err := inboxBackfillMentionsCmd.RunE(inboxBackfillMentionsCmd, nil)
	require.NoError(t, err)

	var envelope backfillMentionsEnvelope
	require.NoError(t, json.Unmarshal(buf.Bytes(), &envelope))
	assert.False(t, envelope.DryRun)
	assert.Equal(t, 1, envelope.TotalCandidates)
	assert.Equal(t, 1, envelope.TotalCreated)
	assert.Equal(t, 0, envelope.TotalAlreadyAnswered)
	assert.Equal(t, 0, envelope.TotalEmptySnippet)
	assert.Equal(t, 0, envelope.TotalCreateErrors)
	require.Len(t, envelope.Accounts, 1)
	assert.Equal(t, int64(1), envelope.Accounts[0].AccountID)
	assert.Equal(t, 1, envelope.Accounts[0].CandidatesFound)
	assert.Equal(t, 1, envelope.Accounts[0].Created)
	assert.Empty(t, envelope.SkippedAccountIDs)

	database, err := openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()
	items, err := database.GetInboxItems(db.InboxFilter{})
	require.NoError(t, err)
	require.Len(t, items, envelope.TotalCreated, "the envelope's created count must match what was actually inserted")
	assert.Equal(t, "mention", items[0].TriggerType)
}

// TestRunInboxBackfillMentions_DryRunInsertsNothing covers the --dry-run
// contract: the reported counts match exactly what a real run would create,
// but nothing is written to inbox_items.
func TestRunInboxBackfillMentions_DryRunInsertsNothing(t *testing.T) {
	cleanup := seedBackfillMentionsFixture(t)
	defer cleanup()
	resetInboxBackfillMentionsFlags()
	defer resetInboxBackfillMentionsFlags()

	inboxBackfillMentionsFlagSince = time.Now().Add(-20 * 24 * time.Hour).Format("2006-01-02")
	inboxBackfillMentionsFlagDryRun = true

	buf := new(bytes.Buffer)
	inboxBackfillMentionsCmd.SetOut(buf)

	err := inboxBackfillMentionsCmd.RunE(inboxBackfillMentionsCmd, nil)
	require.NoError(t, err)

	var envelope backfillMentionsEnvelope
	require.NoError(t, json.Unmarshal(buf.Bytes(), &envelope))
	assert.True(t, envelope.DryRun)
	assert.Equal(t, 1, envelope.TotalCandidates, "dry run must still report what it would have created")
	assert.Equal(t, 1, envelope.TotalCreated)

	database, err := openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM inbox_items`).Scan(&n))
	assert.Equal(t, 0, n, "dry run must not insert any row")
}

// TestRunInboxBackfillMentions_SinceOlderThan90Days_RequiresForce covers the
// safety floor: a --since more than backfillMentionsMaxLookbackDays in the
// past is rejected before any DB work happens, so a mistyped year cannot
// silently sweep the entire messages table.
func TestRunInboxBackfillMentions_SinceOlderThan90Days_RequiresForce(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetInboxBackfillMentionsFlags()
	defer resetInboxBackfillMentionsFlags()

	inboxBackfillMentionsFlagSince = time.Now().Add(-200 * 24 * time.Hour).Format("2006-01-02")

	err := inboxBackfillMentionsCmd.RunE(inboxBackfillMentionsCmd, nil)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "more than 90 days ago")
	assert.Contains(t, err.Error(), "--force")
}

// TestRunInboxBackfillMentions_SinceOlderThan90Days_ForceAllows covers the
// override half of the same floor: --force lets a --since further back than
// 90 days proceed normally.
func TestRunInboxBackfillMentions_SinceOlderThan90Days_ForceAllows(t *testing.T) {
	cleanup := seedBackfillMentionsFixture(t)
	defer cleanup()
	resetInboxBackfillMentionsFlags()
	defer resetInboxBackfillMentionsFlags()

	inboxBackfillMentionsFlagSince = time.Now().Add(-200 * 24 * time.Hour).Format("2006-01-02")
	inboxBackfillMentionsFlagForce = true

	buf := new(bytes.Buffer)
	inboxBackfillMentionsCmd.SetOut(buf)

	err := inboxBackfillMentionsCmd.RunE(inboxBackfillMentionsCmd, nil)
	require.NoError(t, err)

	var envelope backfillMentionsEnvelope
	require.NoError(t, json.Unmarshal(buf.Bytes(), &envelope))
	assert.Equal(t, 1, envelope.TotalCreated, "--force must let a >90-day --since recover the fixture's 15-day-old mention")
}

// TestRunInboxBackfillMentions_CancelledContextStillPrintsEnvelope covers
// the Ctrl-C/SIGTERM contract: BackfillMentions checks ctx.Err() between
// accounts and between candidates and stops promptly, but the CLI must
// still print whatever partial envelope resulted — not die with no output
// — while still exiting non-zero so the caller can tell the sweep did not
// finish. A pre-cancelled context standing in for cmd.Context() is the
// deterministic way to exercise this without sending a real OS signal.
func TestRunInboxBackfillMentions_CancelledContextStillPrintsEnvelope(t *testing.T) {
	cleanup := seedBackfillMentionsFixture(t)
	defer cleanup()
	resetInboxBackfillMentionsFlags()
	defer resetInboxBackfillMentionsFlags()

	inboxBackfillMentionsFlagSince = time.Now().Add(-20 * 24 * time.Hour).Format("2006-01-02")

	ctx, cancel := context.WithCancel(context.Background())
	cancel() // pre-cancelled: stands in for a Ctrl-C/SIGTERM that lands before any work starts
	inboxBackfillMentionsCmd.SetContext(ctx)
	// Reset to a fresh Background rather than nil: that's the state Execute
	// would leave it in, and a nil context here would leak the cancellation
	// into whichever test runs next (and trips staticcheck SA1012).
	defer inboxBackfillMentionsCmd.SetContext(context.Background())

	buf := new(bytes.Buffer)
	inboxBackfillMentionsCmd.SetOut(buf)

	err := inboxBackfillMentionsCmd.RunE(inboxBackfillMentionsCmd, nil)
	require.Error(t, err, "a cancelled run must still exit non-zero")
	assert.Contains(t, err.Error(), "context canceled")

	var envelope backfillMentionsEnvelope
	require.NoError(t, json.Unmarshal(buf.Bytes(), &envelope), "the envelope must still be printed despite the error")
	assert.Empty(t, envelope.Accounts, "cancelled before any account was reached")
}
