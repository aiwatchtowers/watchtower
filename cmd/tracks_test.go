package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/automations/watch"
	"watchtower/internal/db"
	"watchtower/internal/ownerconfirm"
)

func TestTracksCommandRegistered(t *testing.T) {
	found := false
	for _, cmd := range rootCmd.Commands() {
		if cmd.Name() == "tracks" {
			found = true
			break
		}
	}
	assert.True(t, found, "tracks command should be registered")
}

func TestTracksSubcommandsRegistered(t *testing.T) {
	subs := map[string]bool{"show": false, "read": false, "generate": false}
	for _, cmd := range tracksCmd.Commands() {
		if _, ok := subs[cmd.Name()]; ok {
			subs[cmd.Name()] = true
		}
	}
	for name, found := range subs {
		assert.True(t, found, "tracks %s subcommand should be registered", name)
	}
}

func TestRunTracks_WithTracks(t *testing.T) {
	cleanup := setupTracksTestEnv(t)
	defer cleanup()

	database, err := openDBFromConfig()
	require.NoError(t, err)

	_, err = database.UpsertTrack(db.Track{
		Text:       "Review the PR for auth changes",
		Priority:   "high",
		ChannelIDs: `["C001"]`,
		Tags:       `["api"]`,
	})
	require.NoError(t, err)

	_, err = database.UpsertTrack(db.Track{
		Text:       "Deploy the new version",
		Priority:   "medium",
		ChannelIDs: `["C001"]`,
	})
	require.NoError(t, err)
	database.Close()

	buf := new(bytes.Buffer)
	tracksCmd.SetOut(buf)
	tracksFlagPriority = ""
	tracksFlagOwnership = ""
	tracksFlagChannel = ""
	tracksFlagUpdates = false

	err = tracksCmd.RunE(tracksCmd, nil)
	require.NoError(t, err)

	output := buf.String()
	assert.Contains(t, output, "Review the PR")
	assert.Contains(t, output, "Deploy the new version")
}

func TestRunTracks_ChannelFilter(t *testing.T) {
	cleanup := setupTracksTestEnv(t)
	defer cleanup()

	tracksFlagPriority = ""
	tracksFlagOwnership = ""
	tracksFlagChannel = "nonexistent"
	tracksFlagUpdates = false
	defer func() { tracksFlagChannel = "" }()

	err := tracksCmd.RunE(tracksCmd, nil)
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "not found")
}

func TestRunTracks_RequiresConfig(t *testing.T) {
	oldFlagConfig := flagConfig
	flagConfig = "/nonexistent/config.yaml"
	defer func() { flagConfig = oldFlagConfig }()

	tracksFlagPriority = ""
	tracksFlagOwnership = ""
	tracksFlagChannel = ""
	tracksFlagUpdates = false

	err := tracksCmd.RunE(tracksCmd, nil)
	assert.Error(t, err)
}

func TestTracksFlags(t *testing.T) {
	assert.NotNil(t, tracksCmd.Flags().Lookup("priority"))
	assert.NotNil(t, tracksCmd.Flags().Lookup("ownership"))
	assert.NotNil(t, tracksCmd.Flags().Lookup("channel"))
	assert.NotNil(t, tracksCmd.Flags().Lookup("updates"))
}

func TestPrintTracks(t *testing.T) {
	tmpDir := t.TempDir()
	database, err := db.Open(tmpDir + "/test.db")
	require.NoError(t, err)
	defer database.Close()

	require.NoError(t, database.UpsertChannel(db.Channel{ID: "C001", Name: "general", Type: "public"}))

	tracks := []db.Track{
		{
			ID:         1,
			Text:       "Review PR #42",
			Context:    "Needs reviewer",
			Priority:   "high",
			Ownership:  "mine",
			Category:   "code_review",
			ChannelIDs: `["C001"]`,
			Tags:       `["api","frontend"]`,
			HasUpdates: true,
		},
		{
			ID:        2,
			Text:      "Deploy new version",
			Priority:  "medium",
			Ownership: "mine",
			Category:  "task",
		},
	}

	buf := new(bytes.Buffer)
	printTracks(buf, tracks, database, false, false)

	output := buf.String()
	assert.Contains(t, output, "Review PR #42")
	assert.Contains(t, output, "Deploy new version")
}

func TestTracksCustomSubcommandsRegistered(t *testing.T) {
	subs := map[string]bool{"create": false, "watch": false, "scan": false, "events": false, "enable": false, "disable": false,
		"start": false, "instruction": false}
	for _, cmd := range tracksCmd.Commands() {
		if _, ok := subs[cmd.Name()]; ok {
			subs[cmd.Name()] = true
		}
	}
	for name, found := range subs {
		assert.True(t, found, "tracks %s subcommand should be registered", name)
	}
}

func TestRunTracksEvents(t *testing.T) {
	cleanup := setupTracksTestEnv(t)
	defer cleanup()

	database, err := openDBFromConfig()
	require.NoError(t, err)
	tid, err := database.CreateCustomTrack(db.Track{
		AssigneeUserID: "U001", Text: "Watch the release cut",
		Instruction: "watch release", Context: "release cut",
	})
	require.NoError(t, err)
	_, err = database.InsertTrackEvent(db.TrackEvent{
		TrackID: int(tid), Summary: "release branch cut", SourceType: "digest",
	})
	require.NoError(t, err)
	database.Close()

	buf := new(bytes.Buffer)
	tracksEventsCmd.SetOut(buf)
	err = tracksEventsCmd.RunE(tracksEventsCmd, []string{strconv.Itoa(int(tid))})
	require.NoError(t, err)
	assert.Contains(t, buf.String(), "release branch cut")
}

func TestRunTracksEnableDisable(t *testing.T) {
	cleanup := setupTracksTestEnv(t)
	defer cleanup()

	database, err := openDBFromConfig()
	require.NoError(t, err)
	tid, err := database.CreateCustomTrack(db.Track{
		AssigneeUserID: "U001", Text: "Watch refund", Instruction: "watch refund",
	})
	require.NoError(t, err)
	database.Close()

	buf := new(bytes.Buffer)
	tracksDisableCmd.SetOut(buf)
	err = tracksDisableCmd.RunE(tracksDisableCmd, []string{strconv.Itoa(int(tid))})
	require.NoError(t, err)
	assert.Contains(t, buf.String(), "enabled=false")

	database, err = openDBFromConfig()
	require.NoError(t, err)
	enabled, err := database.GetEnabledCustomTracks()
	require.NoError(t, err)
	assert.Empty(t, enabled)
	database.Close()

	buf.Reset()
	tracksEnableCmd.SetOut(buf)
	err = tracksEnableCmd.RunE(tracksEnableCmd, []string{strconv.Itoa(int(tid))})
	require.NoError(t, err)
	assert.Contains(t, buf.String(), "enabled=true")
}

func TestRunTracksEventsInvalidID(t *testing.T) {
	cleanup := setupTracksTestEnv(t)
	defer cleanup()
	err := tracksEventsCmd.RunE(tracksEventsCmd, []string{"not-a-number"})
	assert.Error(t, err)
	assert.True(t, strings.Contains(err.Error(), "invalid"))
}

func setupTracksTestEnv(t *testing.T) func() {
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

// seedTracksDigest seeds one channel digest whose topic asks the owner for a
// review, created an hour ago, and returns the tracks batch reply for it.
func seedTracksDigest(t *testing.T, d *db.DB) string {
	t.Helper()
	now := time.Now()
	digestID, err := d.UpsertDigest(db.Digest{
		ChannelID: "C1", Type: "channel",
		PeriodFrom: float64(now.Add(-2 * time.Hour).Unix()), PeriodTo: float64(now.Unix()),
		Summary: "Discussion about API PR review", MessageCount: 5, Model: "test",
	})
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO digest_topics (digest_id, idx, title, summary, decisions, action_items, situations, key_messages)
		VALUES (?, 0, 'API PR Review', 'Bob asked Alice to review the API pull request.', '[]',
		'[{"text":"Review API PR","assignee":"@alice","status":"open"}]', '[]', '[]')`, digestID)
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE digests SET created_at = ? WHERE id = ?`,
		now.Add(-time.Hour).UTC().Format("2006-01-02T15:04:05Z"), digestID)
	require.NoError(t, err)
	ts := fmt.Sprintf("%d.000000", now.Add(-30*time.Minute).Unix())
	return `[{"channel_id": "C1", "items": [{
		"text": "Review API PR", "context": "Bob asked Alice to review the API pull request.",
		"category": "code_review", "ownership": "mine", "priority": "medium",
		"requester": {"name": "@bob", "user_id": "U002"},
		"participants": [{"name":"Bob","user_id":"U002","stance":"requester"}],
		"source_refs": [{"ts":"` + ts + `","author":"@bob","text":"can you review the API PR?"}],
		"tags": ["api"]}]}]`
}

// seedInbox adds one inbox item stamped a minute ago and returns its id.
func seedInbox(t *testing.T, d *db.DB, snippet string) int64 {
	t.Helper()
	at := time.Now().UTC().Add(-time.Minute).Format("2006-01-02T15:04:05Z")
	res, err := d.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, snippet, created_at)
		VALUES ('C1', ?, 'U002', 'mention', ?, ?)`, snippet, snippet, at)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

// watchedTrack creates a custom track and starts its confirmed watch
// recipe; the track id and the recipe's row.
func (c *c3CLI) watchedTrack(t *testing.T, instruction string) (int, *db.Automation) {
	t.Helper()
	id, err := c.d.CreateCustomTrack(db.Track{AssigneeUserID: "U001", Text: "Refund decision", Instruction: instruction})
	require.NoError(t, err)
	a, err := startTrackWatch(context.Background(), c.cfg, c.d, int(id), true)
	require.NoError(t, err)
	require.True(t, a.Confirmed())
	return int(id), a
}

// handEdit rewrites watch recipe a's file to data and reindexes it.
func (c *c3CLI) handEdit(t *testing.T, a *db.Automation, data []byte) *db.Automation {
	t.Helper()
	require.NoError(t, os.WriteFile(a.Path, data, 0o644))
	ix := automations.NewIndexer(c.d, c.ws, automations.RealClock{})
	got, err := ix.IndexedRecipeAt(context.Background(), automations.Scope{Kind: automations.ScopePersonal}, filepath.Dir(a.Path), a.Path)
	require.NoError(t, err)
	return got
}

func (c *c3CLI) track(t *testing.T, id int) *db.Track {
	t.Helper()
	tr, err := c.d.GetTrackByID(id)
	require.NoError(t, err)
	return tr
}

func (c *c3CLI) automation(t *testing.T, id int64) *db.Automation {
	t.Helper()
	a, err := c.d.GetAutomation(id)
	require.NoError(t, err)
	return a
}

func TestTracksGenerate_UsesOwnerCopyPrompt(t *testing.T) {
	c := newC3CLI(t)
	c.gen.Replies = []string{seedTracksDigest(t, c.d)}
	c.moved(t, trackMyThreadsID)
	a := c.writeBuiltinCopy(t, trackMyThreadsID, "extract", "OWNER COPY MARKER", true)

	code, stdout, stderr := runCLI(t, "tracks", "generate")
	require.Equal(t, 0, code, stderr)
	assert.Contains(t, stdout, "Tracks: created 1, updated 0")
	require.Len(t, c.gen.Calls, 1)
	assert.Contains(t, c.prompts()[0], "OWNER COPY MARKER", "the prompt is the confirmed copy's")
	runs := c.runs(t, a.ID)
	require.Len(t, runs, 1)
	assert.Equal(t, db.TriggerManual, runs[0].Trigger)
	assert.Equal(t, db.RunSucceeded, runs[0].Status, runs[0].Error)
	assert.Equal(t, 1, countRows(t, c.d, `SELECT COUNT(*) FROM pipeline_runs WHERE pipeline = 'tracks' AND source = 'cli'`),
		"the CLI's pipeline_runs row comes through ThreadsHooks")
}

func TestTracksGenerate_RefusedForUnconfirmedCopy(t *testing.T) {
	c := newC3CLI(t)
	seedTracksDigest(t, c.d)
	c.moved(t, trackMyThreadsID)
	a := c.writeBuiltinCopy(t, trackMyThreadsID, "extract", "EDITED", false)

	code, _, stderr := runCLI(t, "tracks", "generate")
	assert.NotEqual(t, 0, code)
	assert.Equal(t, "Track my threads: your edited copy is not confirmed yet — confirm it in Automations → Built in\n", stderr)

	require.NoError(t, c.d.ConfirmAutomation(a.ID, a.ApprovalHash, time.Now()))
	c.claim(t, c.builtinRow(t, trackMyThreadsID))
	code, _, stderr = runCLI(t, "tracks", "generate", "--progress-json")
	assert.NotEqual(t, 0, code)
	assert.Equal(t, "Track my threads is running now — try again in a minute\n", stderr)
	assert.Zero(t, c.gen.CallCount())
}

// With Slack Digests off Track my threads would find nothing and write an
// empty succeeded run: tracks generate and Run Now refuse it instead.
func TestTracksGenerate_RefusedWithDigestsOff(t *testing.T) {
	c := newC3CLI(t)
	c.moved(t, trackMyThreadsID)
	raw, err := os.ReadFile(flagConfig)
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(flagConfig, []byte(strings.Replace(string(raw), "digest:\n  enabled: true", "digest:\n  enabled: false", 1)), 0o600))
	a := c.builtinRow(t, trackMyThreadsID)

	code, _, stderr := runCLI(t, "tracks", "generate")
	assert.NotEqual(t, 0, code)
	assert.Equal(t, "Track my threads needs Slack Digests on\n", stderr)
	_, err = runAutomations(t, "run", idArg(a.ID))
	require.Error(t, err)
	assert.Equal(t, "Track my threads needs Slack Digests on", err.Error())
	assert.Empty(t, c.runs(t, a.ID))
}

// Before Track my threads moved, tracks generate runs the pipeline as it
// always did: no automation run.
func TestTracksGenerate_LegacyBeforeTheMove(t *testing.T) {
	c := newC3CLI(t)
	c.gen.Replies = []string{seedTracksDigest(t, c.d)}
	code, stdout, stderr := runCLI(t, "tracks", "generate")
	require.Equal(t, 0, code, stderr)
	assert.Contains(t, stdout, "Tracks: created 1, updated 0")
	assert.Empty(t, c.runs(t, c.builtinRow(t, trackMyThreadsID).ID))
	assert.Equal(t, 1, countRows(t, c.d, `SELECT COUNT(*) FROM pipeline_runs WHERE pipeline = 'tracks' AND source = 'cli'`))
}

func TestTracksScan_BoundRunsRecipeWithSince(t *testing.T) {
	c := newC3CLI(t)
	inbox := seedInbox(t, c.d, "the refund was approved")
	c.gen.Replies = []string{fmt.Sprintf(`{"refs":[{"kind":"inbox","id":%d}]}`, inbox), `{"events":[{"summary":"refund approved"}]}`}
	id, a := c.watchedTrack(t, "watch the refund decision")
	since := time.Now().UTC().Add(-48 * time.Hour).Format(time.RFC3339)

	code, stdout, stderr := runCLI(t, "tracks", "scan", strconv.Itoa(id), "--since", since)
	require.Equal(t, 0, code, stderr)
	var events []db.TrackEvent
	require.NoError(t, json.Unmarshal([]byte(stdout), &events), stdout)
	require.Len(t, events, 1)
	assert.Equal(t, "refund approved", events[0].Summary)
	assert.Equal(t, 2, c.gen.CallCount(), "a Scan from is a backfill: shortlist + extract")
	assert.Contains(t, c.prompts()[1], "watch the refund decision")
	runs := c.runs(t, a.ID)
	require.Len(t, runs, 1)
	assert.Equal(t, db.TriggerManual, runs[0].Trigger)
	assert.Equal(t, db.RunSucceeded, runs[0].Status, runs[0].Error)
	assert.Contains(t, runs[0].EventJSON, `"since"`)
}

func TestTracksScan_RefusedWhileSlotScans(t *testing.T) {
	c := newC3CLI(t, `{"events":[]}`)
	seedInbox(t, c.d, "the refund was approved")
	id, a := c.watchedTrack(t, "watch the refund decision")
	c.claim(t, a)

	code, _, stderr := runCLI(t, "tracks", "scan", strconv.Itoa(id))
	assert.NotEqual(t, 0, code)
	assert.Equal(t, "this watch is scanning now — try again in a minute\n", stderr)
	assert.Zero(t, c.gen.CallCount())
	assert.Equal(t, 1, countRows(t, c.d, `SELECT COUNT(*) FROM automation_runs WHERE status = 'running'`))
	assert.Zero(t, countRows(t, c.d, `SELECT COUNT(*) FROM automation_runs WHERE status = 'queued'`),
		"the refused run was cancelled, not left queued for the slot")
}

func TestTracksScan_UnboundPointsToStart(t *testing.T) {
	c := newC3CLI(t, `{"events":[]}`)
	seedInbox(t, c.d, "the refund was approved")
	c.moved(t, customTracksID)
	id, err := c.d.CreateCustomTrack(db.Track{AssigneeUserID: "U001", Text: "Refund", Instruction: "watch the refund"})
	require.NoError(t, err)

	code, _, stderr := runCLI(t, "tracks", "scan", strconv.Itoa(int(id)))
	assert.NotEqual(t, 0, code)
	assert.Equal(t, fmt.Sprintf("track #%d is not watched — run `watchtower tracks start %d`\n", id, id), stderr)
	assert.Zero(t, c.gen.CallCount())
}

// A bound track is scanned only through its recipe, never with the old
// instruction (RunForTrack): a hand edit the owner has not confirmed scans
// nothing, before and after the custom-track move alike.
func TestTracksScan_BoundUnconfirmedRecipeNeverScanned(t *testing.T) {
	c := newC3CLI(t, `{"events":[{"summary":"must not happen"}]}`)
	seedInbox(t, c.d, "the refund was approved")
	id, a := c.watchedTrack(t, "watch the refund decision")
	data, err := watch.SetInstruction([]byte(a.RecipeText), "watch everything and more")
	require.NoError(t, err)
	edited := c.handEdit(t, a, data)
	require.False(t, edited.Confirmed())

	for _, moved := range []bool{false, true} {
		if moved {
			c.moved(t, customTracksID)
		}
		code, _, stderr := runCLI(t, "tracks", "scan", strconv.Itoa(id))
		assert.NotEqual(t, 0, code, "moved=%v", moved)
		assert.Equal(t, "confirm this watch in Automations first\n", stderr, "moved=%v", moved)
	}
	code, stdout, stderr := runCLI(t, "tracks", "scan")
	require.Equal(t, 0, code, stderr)
	assert.Contains(t, stdout, "0 new event(s)")
	assert.Zero(t, c.gen.CallCount(), "no scan with any instruction")
	events, err := c.d.GetTrackEvents(id, 10)
	require.NoError(t, err)
	assert.Empty(t, events)
}

// tracks scan with no id runs every enabled, confirmed watch recipe inline.
func TestTracksScan_AllRunsEachConfirmedWatch(t *testing.T) {
	c := newC3CLI(t, `{"events":[{"summary":"seen"}]}`)
	seedInbox(t, c.d, "the refund was approved")
	c.moved(t, customTracksID)
	_, on := c.watchedTrack(t, "watch the refund decision")
	offID, off := c.watchedTrack(t, "watch the hiring")
	code, _, stderr := runCLI(t, "tracks", "disable", strconv.Itoa(offID))
	require.Equal(t, 0, code, stderr)

	code, stdout, stderr := runCLI(t, "tracks", "scan")
	require.Equal(t, 0, code, stderr)
	assert.Contains(t, stdout, "scanned enabled custom tracks: 1 new event(s)")
	assert.Len(t, c.runs(t, on.ID), 1)
	assert.Empty(t, c.runs(t, off.ID), "a paused watch is not scanned")
}

func TestTracksCreate_WritesConfirmedWatch(t *testing.T) {
	c := newC3CLI(t, `{"title":"Refund decision","instruction":"watch the refund decision"}`)
	code, stdout, stderr := runCLI(t, "tracks", "create", "--text", "the refund for acme")
	require.Equal(t, 0, code, stderr)
	var m map[string]any
	require.NoError(t, json.Unmarshal([]byte(stdout), &m), stdout)
	wantKeys(t, m, "id", "title", "instruction")
	tr := c.track(t, int(m["id"].(float64)))
	require.NotZero(t, tr.AutomationID, "the track is bound to its watch recipe")
	a := c.automation(t, tr.AutomationID)
	assert.True(t, a.Confirmed(), "the owner's command confirms the recipe it rendered")
	assert.True(t, a.Enabled)
	got, ok := watch.Instruction([]byte(a.RecipeText))
	require.True(t, ok)
	assert.Equal(t, "watch the refund decision", got)
}

func TestTracksWatch_TakesTextAndLinksTarget(t *testing.T) {
	c := newC3CLI(t, `{"title":"Refund decision","instruction":"watch the refund decision"}`)
	t.Cleanup(func() { tracksCreateFlagTarget, tracksCreateFlagText = 0, "" })
	targetID, err := c.d.CreateTarget(db.Target{Text: "Ship the refund", Status: "todo",
		Level: "week", PeriodStart: "2026-10-19", PeriodEnd: "2026-10-25", Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)
	code, stdout, stderr := runCLI(t, "tracks", "watch", strconv.Itoa(int(targetID)), "--text", "the refund for acme")
	require.Equal(t, 0, code, stderr)
	var m map[string]any
	require.NoError(t, json.Unmarshal([]byte(stdout), &m), stdout)
	tr := c.track(t, int(m["id"].(float64)))
	assert.Equal(t, int(targetID), tr.LinkedTargetID, "the track watches the target it was made for")
	assert.NotZero(t, tr.AutomationID)
}

func TestTracksCreate_UnderAgentLeavesUnconfirmed(t *testing.T) {
	c := newC3CLI(t, `{"title":"Refund decision","instruction":"watch the refund decision"}`)
	t.Setenv("CLAUDECODE", "1")
	for _, args := range [][]string{{"tracks", "create", "--text", "the refund for acme"}} {
		code, stdout, stderr := runCLI(t, args...)
		require.Equal(t, 0, code, stderr)
		var m map[string]any
		require.NoError(t, json.Unmarshal([]byte(stdout), &m), stdout)
		wantKeys(t, m, "id", "title", "instruction", "confirmed", "note")
		assert.Equal(t, false, m["confirmed"])
		assert.Equal(t, "Confirm it in Automations.", m["note"])
		tr := c.track(t, int(m["id"].(float64)))
		require.NotZero(t, tr.AutomationID)
		assert.False(t, c.automation(t, tr.AutomationID).Confirmed(), "an agent never confirms a watch")
	}
}

func TestTracksStart_RefusedUnderAgentMarkers(t *testing.T) {
	c := newC3CLI(t)
	id, err := c.d.CreateCustomTrack(db.Track{AssigneeUserID: "U001", Text: "Refund", Instruction: "watch the refund"})
	require.NoError(t, err)
	for _, marker := range agentEnvMarkers {
		t.Run(marker, func(t *testing.T) {
			t.Setenv(marker, "1")
			code, _, stderr := runCLI(t, "tracks", "start", strconv.Itoa(int(id)))
			assert.NotEqual(t, 0, code)
			assert.Contains(t, stderr, "under an AI agent")
			assert.Zero(t, c.track(t, int(id)).AutomationID, "no recipe is written")
		})
	}
	code, stdout, stderr := runCLI(t, "tracks", "start", strconv.Itoa(int(id)), "--json")
	require.Equal(t, 0, code, stderr)
	var m map[string]any
	require.NoError(t, json.Unmarshal([]byte(stdout), &m), stdout)
	wantKeys(t, m, "track_id", "automation_id")
	tr := c.track(t, int(id))
	assert.Equal(t, float64(tr.AutomationID), m["automation_id"])
	assert.True(t, c.automation(t, tr.AutomationID).Confirmed())
}

func TestTracksInstruction_RewritesAndConfirms(t *testing.T) {
	c := newC3CLI(t)
	id, a := c.watchedTrack(t, "watch the refund decision")
	code, _, stderr := runCLI(t, "tracks", "instruction", strconv.Itoa(id), "--text", "watch the refund and the invoice")
	require.Equal(t, 0, code, stderr)
	after := c.automation(t, a.ID)
	assert.True(t, after.Confirmed(), "the owner's Save is the confirmation")
	assert.NotEqual(t, a.ApprovalHash, after.ApprovalHash)
	got, ok := watch.Instruction([]byte(after.RecipeText))
	require.True(t, ok)
	assert.Equal(t, "watch the refund and the invoice", got)
	onDisk, err := os.ReadFile(a.Path)
	require.NoError(t, err)
	assert.Equal(t, after.RecipeText, string(onDisk))
	assert.Equal(t, "watch the refund and the invoice", c.track(t, id).Instruction, "the track mirrors it")

	t.Setenv("CLAUDECODE", "1")
	code, _, stderr = runCLI(t, "tracks", "instruction", strconv.Itoa(id), "--text", "watch nothing")
	assert.NotEqual(t, 0, code)
	assert.Contains(t, stderr, "under an AI agent")
}

func TestTracksInstruction_RefusesEditedRecipe(t *testing.T) {
	c := newC3CLI(t)
	id, a := c.watchedTrack(t, "watch the refund decision")

	// A hand edit of the template's line, not confirmed yet.
	data, err := watch.SetInstruction([]byte(a.RecipeText), "watch something else")
	require.NoError(t, err)
	c.handEdit(t, a, data)
	code, _, stderr := runCLI(t, "tracks", "instruction", strconv.Itoa(id), "--text", "watch the invoice")
	assert.NotEqual(t, 0, code)
	assert.Equal(t, "confirm this watch in Automations first\n", stderr)

	// Changed in the chat into another shape, and confirmed.
	other := strings.Replace(a.RecipeText, "const instruction = ", "const instruction2 = ", 1)
	other = strings.Replace(other, "track.scan({ instruction });", "track.scan({ instruction: instruction2 });", 1)
	edited := c.handEdit(t, a, []byte(other))
	require.Empty(t, edited.ParseError)
	require.NoError(t, c.d.ConfirmAutomation(edited.ID, edited.ApprovalHash, time.Now()))
	code, _, stderr = runCLI(t, "tracks", "instruction", strconv.Itoa(id), "--text", "watch the invoice")
	assert.NotEqual(t, 0, code)
	assert.Equal(t, "This watch was changed in the chat — change it there.\n", stderr)
	assert.Equal(t, other, c.automation(t, a.ID).RecipeText, "nothing was written")
}

// A Save while a scan runs is not refused; the next scan uses the new text.
func TestTracksInstruction_SavedWhileScanning(t *testing.T) {
	c := newC3CLI(t, `{"events":[]}`)
	seedInbox(t, c.d, "the refund was approved")
	id, a := c.watchedTrack(t, "watch the refund decision")
	running := c.claim(t, a)

	code, _, stderr := runCLI(t, "tracks", "instruction", strconv.Itoa(id), "--text", "watch the invoice instead")
	require.Equal(t, 0, code, stderr)
	_, err := c.d.CancelAutomationRun(running, time.Now())
	require.NoError(t, err)

	code, _, stderr = runCLI(t, "tracks", "scan", strconv.Itoa(id))
	require.Equal(t, 0, code, stderr)
	require.Equal(t, 1, c.gen.CallCount())
	assert.Contains(t, c.prompts()[0], "watch the invoice instead")
	assert.NotContains(t, c.prompts()[0], "watch the refund decision")
}

func TestTracksEnableDisable_BoundTogglesRecipe(t *testing.T) {
	c := newC3CLI(t)
	id, a := c.watchedTrack(t, "watch the refund decision")

	code, _, stderr := runCLI(t, "tracks", "disable", strconv.Itoa(id))
	require.Equal(t, 0, code, stderr)
	assert.False(t, c.automation(t, a.ID).Enabled, "the recipe is paused")
	assert.False(t, c.track(t, id).Enabled, "the track mirrors it")

	t.Setenv("CLAUDECODE", "1")
	code, _, stderr = runCLI(t, "tracks", "enable", strconv.Itoa(id))
	assert.NotEqual(t, 0, code)
	assert.Contains(t, stderr, "under an AI agent")
	assert.False(t, c.automation(t, a.ID).Enabled)
	require.NoError(t, os.Unsetenv("CLAUDECODE"))

	code, _, stderr = runCLI(t, "tracks", "enable", strconv.Itoa(id))
	require.Equal(t, 0, code, stderr)
	assert.True(t, c.automation(t, a.ID).Enabled)
	assert.True(t, c.track(t, id).Enabled)
}

func TestTracksRestore_UnboundCustomTrackHintsStart(t *testing.T) {
	c := newC3CLI(t)
	id, err := c.d.CreateCustomTrack(db.Track{AssigneeUserID: "U001", Text: "Refund", Instruction: "watch the refund"})
	require.NoError(t, err)
	require.NoError(t, c.d.DismissTrack(int(id)))
	code, stdout, stderr := runCLI(t, "tracks", "restore", strconv.Itoa(int(id)))
	require.Equal(t, 0, code, stderr)
	assert.Contains(t, stdout, fmt.Sprintf("Run `watchtower tracks start %d` to watch it again.", id))

	bound, _ := c.watchedTrack(t, "watch the hiring")
	require.NoError(t, c.d.DismissTrack(bound))
	_, stdout, _ = runCLI(t, "tracks", "restore", strconv.Itoa(bound))
	assert.NotContains(t, stdout, "tracks start")
}

// AUTO-06: tracks start confirms an already-bound recipe only while it is
// still the untouched template; a hand-edited one stays unconfirmed.
func TestTracksStart_BoundRecipeConfirmedOnlyWhenUntouched(t *testing.T) {
	c := newC3CLI(t)
	untouched, err := c.d.CreateCustomTrack(db.Track{AssigneeUserID: "U001", Text: "Refund", Instruction: "watch the refund"})
	require.NoError(t, err)
	a, err := startTrackWatch(context.Background(), c.cfg, c.d, int(untouched), false)
	require.NoError(t, err)
	code, _, stderr := runCLI(t, "tracks", "start", strconv.Itoa(int(untouched)))
	require.Equal(t, 0, code, stderr)
	assert.True(t, c.automation(t, a.ID).Confirmed(), "the untouched template is confirmed")

	edited, err := c.d.CreateCustomTrack(db.Track{AssigneeUserID: "U001", Text: "Hiring", Instruction: "watch the hiring"})
	require.NoError(t, err)
	b, err := startTrackWatch(context.Background(), c.cfg, c.d, int(edited), false)
	require.NoError(t, err)
	c.handEdit(t, b, []byte(strings.Replace(b.RecipeText, "budget: {tokens: 200000, minutes: 10}", "budget: {tokens: 900000, minutes: 30}", 1)))
	code, _, stderr = runCLI(t, "tracks", "start", strconv.Itoa(int(edited)))
	assert.NotEqual(t, 0, code)
	assert.Equal(t, "confirm this watch in Automations first\n", stderr)
	assert.False(t, c.automation(t, b.ID).Confirmed(), "edited text the owner never saw stays unconfirmed")
}

// AGENT-07: with no agent marker, the owner-only watch verbs still run only
// after the owner confirms in the Desktop; tracks create, denied, writes
// nothing (the window is asked before its compose call).
func TestTracksOwnerVerbs_NeedTheDesktopsConfirmation(t *testing.T) {
	c := newC3CLI(t, `{"title":"Refund decision","instruction":"watch the refund decision"}`)
	watchedID, watched := c.watchedTrack(t, "watch the hiring")
	code, _, stderr := runCLI(t, "tracks", "disable", strconv.Itoa(watchedID))
	require.Equal(t, 0, code, stderr)
	unbound, err := c.d.CreateCustomTrack(db.Track{AssigneeUserID: "U001", Text: "Launch", Instruction: "watch the launch"})
	require.NoError(t, err)
	reqs := withOwnerDesktop(t, ownerconfirm.Reply{Decision: ownerconfirm.Denied}, nil)

	code, _, stderr = runCLI(t, "tracks", "start", strconv.Itoa(int(unbound)))
	assert.NotEqual(t, 0, code)
	assert.Contains(t, stderr, "refusing to start watching a track")
	assert.Zero(t, c.track(t, int(unbound)).AutomationID, "no recipe is written")

	code, _, stderr = runCLI(t, "tracks", "instruction", strconv.Itoa(watchedID), "--text", "watch the payroll")
	assert.NotEqual(t, 0, code)
	assert.Contains(t, stderr, "refusing to change a watch's instruction")
	assert.Equal(t, watched.RecipeText, c.automation(t, watched.ID).RecipeText, "nothing was written")

	code, _, stderr = runCLI(t, "tracks", "enable", strconv.Itoa(watchedID))
	assert.NotEqual(t, 0, code)
	assert.Contains(t, stderr, "refusing to turn a watch on")
	assert.False(t, c.automation(t, watched.ID).Enabled)

	before := c.watchFiles(t)
	tracksBefore := countRows(t, c.d, `SELECT COUNT(*) FROM tracks`)
	code, _, stderr = runCLI(t, "tracks", "create", "--text", "the refund for acme")
	assert.NotEqual(t, 0, code)
	assert.Contains(t, stderr, "refusing to start watching a track")
	assert.Zero(t, c.gen.CallCount(), "a denial is asked before the compose call")
	assert.Equal(t, before, c.watchFiles(t), "a denial writes nothing")
	assert.Equal(t, tracksBefore, countRows(t, c.d, `SELECT COUNT(*) FROM tracks`), "no track is created")

	require.Len(t, *reqs, 4)
	assert.Contains(t, (*reqs)[3].Detail, "the refund for acme", "the window shows the text the owner gave")
	assert.Contains(t, (*reqs)[0].Detail, "watch the launch", "the window shows the recipe Start would write")
	assert.Contains(t, (*reqs)[1].Detail, "watch the payroll", "the window shows the new instruction")
}
