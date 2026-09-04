package cmd

import (
	"bytes"
	"encoding/json"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/catchup"
	"watchtower/internal/db"
)

func TestCatchupCommandRegistered(t *testing.T) {
	found := false
	for _, cmd := range rootCmd.Commands() {
		if cmd.Name() == "catchup" {
			found = true
			break
		}
	}
	assert.True(t, found, "catchup command should be registered")
}

// The absence-recap command is a parent with run/ack/feedback/list/show
// subcommands; the old regen subcommand is folded into `run --regen`.
func TestCatchupSubcommandsRegistered(t *testing.T) {
	want := map[string]bool{"run": false, "ack": false, "feedback": false, "list": false, "show": false}
	for _, sub := range catchupCmd.Commands() {
		if _, ok := want[sub.Name()]; ok {
			want[sub.Name()] = true
		}
	}
	for name, found := range want {
		assert.True(t, found, "catchup subcommand %q should be registered", name)
	}
	for _, sub := range catchupCmd.Commands() {
		assert.NotEqual(t, "regen", sub.Name(), "regen is folded into `run --regen`")
	}
}

func TestCatchupSubcommandFlags(t *testing.T) {
	for _, name := range []string{"preset", "from", "to", "regen", "comment", "json"} {
		assert.NotNil(t, catchupRunCmd.Flags().Lookup(name), "catchup run --%s", name)
	}
	for _, name := range []string{"topic", "rating", "comment"} {
		assert.NotNil(t, catchupFeedbackCmd.Flags().Lookup(name), "catchup feedback --%s", name)
	}
	assert.NotNil(t, catchupListCmd.Flags().Lookup("json"), "catchup list --json")
}

func TestParseRating(t *testing.T) {
	up, err := parseRating("up")
	require.NoError(t, err)
	assert.Equal(t, 1, up)

	down, err := parseRating("down")
	require.NoError(t, err)
	assert.Equal(t, -1, down)

	_, err = parseRating("")
	assert.Error(t, err, "an unset rating is an error, not a neutral 0")
	_, err = parseRating("sideways")
	assert.Error(t, err)
}

func TestCatchupRunRequiresConfig(t *testing.T) {
	resetCatchupRunFlags(t)
	oldFlagConfig := flagConfig
	flagConfig = "/nonexistent/path/config.yaml"
	defer func() { flagConfig = oldFlagConfig }()

	err := catchupRunCmd.RunE(catchupRunCmd, nil)
	assert.Error(t, err)
}

// Flag combinations the pipeline could only silently ignore are rejected before
// the config is even loaded — flagConfig points nowhere, so a config error here
// would mean the check runs too late.
func TestCatchupRunFlagErrorsPrecedeTheDatabase(t *testing.T) {
	oldFlagConfig := flagConfig
	flagConfig = "/nonexistent/path/config.yaml"
	defer func() { flagConfig = oldFlagConfig }()

	cases := []struct {
		name    string
		set     func()
		wantSub string
	}{
		{"regen with preset", func() { catchupRunFlagRegen, catchupRunFlagPreset = 7, "today" }, "--regen"},
		{"regen with from", func() { catchupRunFlagRegen, catchupRunFlagFrom = 7, "2026-09-01" }, "--regen"},
		{"to without from", func() { catchupRunFlagTo = "2026-09-02" }, "--from"},
		{"unparseable from", func() { catchupRunFlagFrom = "last tuesday" }, "last tuesday"},
		{"negative regen", func() { catchupRunFlagRegen = -1 }, "--regen"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			resetCatchupRunFlags(t)
			tc.set()
			err := catchupRunCmd.RunE(catchupRunCmd, nil)
			require.Error(t, err)
			assert.Contains(t, err.Error(), tc.wantSub)
			assert.NotContains(t, err.Error(), "loading config", "flags are validated before the config is loaded")
		})
	}
}

func TestRenderRecapText_Ready(t *testing.T) {
	r := db.CatchupRecap{
		ID: 7, PeriodFrom: 1000, PeriodTo: 2000, Status: "ready", TLDR: "tl",
		CoverageJSON: `{"slack_to":1900,"streams_to":0,"meetings":2,"topup":"ok"}`,
	}
	body := catchup.Body{
		Topics: []catchup.Topic{{
			Title: "Deploy freeze", Narrative: "The release was held back.", Priority: "high",
			Refs: []db.CatchupRef{{Area: "digests", ID: 1, Label: "#eng"}},
		}},
		Decisions: []catchup.Entry{{
			Text: "Ship on Monday instead",
			Refs: []db.CatchupRef{{Area: "decisions", ID: 3, Label: "release date"}},
		}},
		Meetings: []catchup.MeetingEntry{{
			Title: "Weekly sync", Summary: "Went over the freeze.",
			Refs: []db.CatchupRef{{Area: "recaps", ID: 5, Label: "Weekly sync"}},
		}},
		NeedsYou: []catchup.NeedEntry{{
			Text: "Bob asked you about the rollout", Kind: "mention",
			Refs: []db.CatchupRef{{Area: "inbox", ID: 9, Label: "#eng"}},
		}},
	}

	out := renderRecapText(r, body)

	assert.True(t, strings.HasPrefix(out, "Catch-Up "), "header line, got %q", out)
	assert.Contains(t, out, "Slack to ")
	assert.Contains(t, out, "Streams: none", "a zero coverage says none, not a 1970 timestamp")
	assert.Contains(t, out, "2 meetings")
	assert.Contains(t, out, "top-up ok")
	assert.Contains(t, out, "tl")
	assert.Contains(t, out, "What happened")
	assert.Contains(t, out, "[high] Deploy freeze")
	assert.Contains(t, out, "The release was held back.")
	assert.Contains(t, out, "[digests#1 #eng]")
	assert.Contains(t, out, "Decisions")
	assert.Contains(t, out, "Ship on Monday instead")
	assert.Contains(t, out, "Meetings")
	assert.Contains(t, out, "Weekly sync")
	assert.Contains(t, out, "For you")
	assert.Contains(t, out, "[mention] Bob asked you about the rollout")
	assert.Contains(t, out, "[inbox#9 #eng]")
}

// A section with nothing in it is omitted rather than printed empty.
func TestRenderRecapText_OmitsEmptySections(t *testing.T) {
	r := db.CatchupRecap{PeriodFrom: 1000, PeriodTo: 2000, Status: "ready", TLDR: "tl"}
	body := catchup.Body{Topics: []catchup.Topic{{
		Title: "Only topic", Priority: "low",
		Refs: []db.CatchupRef{{Area: "digests", ID: 1, Label: "#eng"}},
	}}}

	out := renderRecapText(r, body)

	assert.Contains(t, out, "What happened")
	assert.NotContains(t, out, "Decisions")
	assert.NotContains(t, out, "Meetings")
	assert.NotContains(t, out, "For you")
}

func TestRenderRecapText_Failed(t *testing.T) {
	r := db.CatchupRecap{
		PeriodFrom: 1000, PeriodTo: 2000, Status: "failed",
		Error: "composing catch-up recap: claude exited 1",
	}

	out := renderRecapText(r, catchup.Body{})

	assert.Contains(t, out, "FAILED: composing catch-up recap: claude exited 1")
	assert.NotContains(t, out, "Quiet")
}

func TestRenderRecapText_EmptyReadyBody(t *testing.T) {
	r := db.CatchupRecap{PeriodFrom: 1000, PeriodTo: 2000, Status: "ready"}

	out := renderRecapText(r, catchup.Body{})

	assert.True(t, strings.HasPrefix(out, "Catch-Up "))
	assert.Contains(t, out, "Quiet — nothing happened in this window.")
	assert.NotContains(t, out, "What happened")
}

func TestRenderRecapText_Building(t *testing.T) {
	r := db.CatchupRecap{PeriodFrom: 1000, PeriodTo: 2000, Status: "building"}

	out := renderRecapText(r, catchup.Body{})

	assert.Contains(t, out, "still building")
}

// The --json envelope is what the Desktop parses, so its shape is pinned; the
// same run without --json renders the document instead. A window that ended a
// day ago skips the top-up and gathers nothing, so no AI call is made.
func TestCatchupRun_JSONEnvelopeAndText(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	resetCatchupRunFlags(t)
	catchupRunFlagFrom = time.Now().Add(-48 * time.Hour).Format(time.RFC3339)
	catchupRunFlagTo = time.Now().Add(-24 * time.Hour).Format(time.RFC3339)
	catchupRunFlagJSON = true

	buf := new(bytes.Buffer)
	catchupRunCmd.SetOut(buf)
	require.NoError(t, catchupRunCmd.RunE(catchupRunCmd, nil))

	var env map[string]any
	require.NoError(t, json.Unmarshal(buf.Bytes(), &env))
	for _, key := range []string{
		"recap_id", "status", "period_from", "period_to", "source",
		"coverage", "refs_rejected", "error", "tldr", "body",
	} {
		assert.Contains(t, env, key)
	}
	assert.Equal(t, "ready", env["status"])
	assert.Equal(t, "custom", env["source"])
	assert.Empty(t, env["error"])
	cov, ok := env["coverage"].(map[string]any)
	require.True(t, ok, "coverage should be an object, got %#v", env["coverage"])
	assert.Equal(t, "skipped", cov["topup"], "a window that already ended skips the top-up")

	buf.Reset()
	catchupRunFlagJSON = false
	require.NoError(t, catchupRunCmd.RunE(catchupRunCmd, nil))
	assert.True(t, strings.HasPrefix(buf.String(), "Catch-Up "), "got %q", buf.String())
	assert.Contains(t, buf.String(), "Quiet — nothing happened in this window.")
}

// `run --regen` recomposes the source recap's window and links the new row back
// to it, rather than resolving a window of its own.
func TestCatchupRun_RegenReusesTheSourceWindow(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	database, err := openDBFromConfig()
	require.NoError(t, err)
	now := float64(time.Now().Unix())
	from, to := now-7200, now-3600
	sourceID, err := database.InsertCatchupRecap(from, to, 0)
	require.NoError(t, err)
	require.NoError(t, database.FinishCatchupRecap(sourceID, "tl", `{"topics":[]}`, `{"topup":"skipped"}`, "", 0, 0, 0))
	require.NoError(t, database.Close())

	resetCatchupRunFlags(t)
	catchupRunFlagRegen = sourceID
	catchupRunFlagComment = "shorter please"
	catchupRunFlagJSON = true

	buf := new(bytes.Buffer)
	catchupRunCmd.SetOut(buf)
	require.NoError(t, catchupRunCmd.RunE(catchupRunCmd, nil))

	var env map[string]any
	require.NoError(t, json.Unmarshal(buf.Bytes(), &env))
	assert.Equal(t, "regen", env["source"])
	assert.InDelta(t, from, env["period_from"], 0.5)
	assert.InDelta(t, to, env["period_to"], 0.5)
	newID := int64(env["recap_id"].(float64))
	require.NotEqual(t, sourceID, newID, "a regen creates a new recap")

	database, err = openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()
	r, err := database.GetCatchupRecap(newID)
	require.NoError(t, err)
	assert.Equal(t, sourceID, r.RegenOfID, "the regenerated recap links back to its source")
	assert.Equal(t, "ready", r.Status)
}

// Acknowledging through the CLI marks the recap's whole window read (CATCHUP-01
// via the pipeline) and stamps the row.
func TestCatchupAck_MarksTheWindowRead(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	database, err := openDBFromConfig()
	require.NoError(t, err)

	to := float64(time.Now().Unix())
	from := to - 3600
	inWindow := insertTestDigest(t, database, "C001", from+60, to-60)
	outsideWindow := insertTestDigest(t, database, "C002", from-7200, from-3600)
	recapID, err := database.InsertCatchupRecap(from, to, 0)
	require.NoError(t, err)
	require.NoError(t, database.Close())

	buf := new(bytes.Buffer)
	catchupAckCmd.SetOut(buf)
	require.NoError(t, catchupAckCmd.RunE(catchupAckCmd, []string{strconv.FormatInt(recapID, 10)}))
	assert.Contains(t, buf.String(), "Acknowledged")

	database, err = openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()

	assert.True(t, digestRead(t, database, inWindow), "in-window digest should be read")
	assert.False(t, digestRead(t, database, outsideWindow), "digest outside the window should stay unread")

	r, err := database.GetCatchupRecap(recapID)
	require.NoError(t, err)
	assert.NotEmpty(t, r.AcknowledgedAt, "the recap row should be stamped acknowledged")
}

// `show` renders the persisted row; `list` reports it with its window, status
// and acknowledgement state, and `--json` emits the raw rows.
func TestCatchupShowAndList(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	database, err := openDBFromConfig()
	require.NoError(t, err)
	recapID, err := database.InsertCatchupRecap(1000, 2000, 0)
	require.NoError(t, err)
	body := catchup.Body{Topics: []catchup.Topic{{
		Title: "Deploy freeze", Narrative: "held back", Priority: "high",
		Refs: []db.CatchupRef{{Area: "digests", ID: 1, Label: "#eng"}},
	}}}
	raw, err := json.Marshal(body)
	require.NoError(t, err)
	require.NoError(t, database.FinishCatchupRecap(recapID, "tl", string(raw),
		`{"slack_to":1900,"streams_to":1800,"meetings":1,"topup":"skipped"}`, "sonnet", 1, 2, 0.01))
	require.NoError(t, database.Close())

	idArg := strconv.FormatInt(recapID, 10)
	buf := new(bytes.Buffer)
	catchupShowCmd.SetOut(buf)
	require.NoError(t, catchupShowCmd.RunE(catchupShowCmd, []string{idArg}))
	assert.Contains(t, buf.String(), "tl")
	assert.Contains(t, buf.String(), "[high] Deploy freeze")
	assert.Contains(t, buf.String(), "[digests#1 #eng]")

	buf.Reset()
	catchupListCmd.SetOut(buf)
	require.NoError(t, catchupListCmd.RunE(catchupListCmd, nil))
	assert.Contains(t, buf.String(), "#"+idArg)
	assert.Contains(t, buf.String(), "ready")
	assert.Contains(t, buf.String(), "-", "an unacknowledged recap shows a dash")

	buf.Reset()
	catchupListFlagJSON = true
	defer func() { catchupListFlagJSON = false }()
	require.NoError(t, catchupListCmd.RunE(catchupListCmd, nil))
	var rows []db.CatchupRecap
	require.NoError(t, json.Unmarshal(buf.Bytes(), &rows))
	require.Len(t, rows, 1)
	assert.Equal(t, recapID, rows[0].ID)
	assert.Equal(t, "ready", rows[0].Status)
}

func TestCatchupFeedbackRequiresTopic(t *testing.T) {
	oldFlagConfig := flagConfig
	flagConfig = "/nonexistent/path/config.yaml"
	defer func() { flagConfig = oldFlagConfig }()

	catchupFeedbackTopic, catchupFeedbackRating = -1, "up"
	defer func() { catchupFeedbackTopic, catchupFeedbackRating = -1, "" }()

	err := catchupFeedbackCmd.RunE(catchupFeedbackCmd, []string{"1"})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "--topic")
	assert.NotContains(t, err.Error(), "loading config")
}

func TestCatchupFeedbackRejectsBadRating(t *testing.T) {
	oldFlagConfig := flagConfig
	flagConfig = "/nonexistent/path/config.yaml"
	defer func() { flagConfig = oldFlagConfig }()

	catchupFeedbackTopic, catchupFeedbackRating = 0, "meh"
	defer func() { catchupFeedbackTopic, catchupFeedbackRating = -1, "" }()

	err := catchupFeedbackCmd.RunE(catchupFeedbackCmd, []string{"1"})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "--rating")
}

// resetCatchupRunFlags zeroes the package-level `catchup run` flag vars and
// restores them after the test, so one case's flags never leak into the next.
func resetCatchupRunFlags(t *testing.T) {
	t.Helper()
	preset, from, to := catchupRunFlagPreset, catchupRunFlagFrom, catchupRunFlagTo
	regen, comment, asJSON := catchupRunFlagRegen, catchupRunFlagComment, catchupRunFlagJSON
	catchupRunFlagPreset, catchupRunFlagFrom, catchupRunFlagTo = "", "", ""
	catchupRunFlagRegen, catchupRunFlagComment, catchupRunFlagJSON = 0, "", false
	t.Cleanup(func() {
		catchupRunFlagPreset, catchupRunFlagFrom, catchupRunFlagTo = preset, from, to
		catchupRunFlagRegen, catchupRunFlagComment, catchupRunFlagJSON = regen, comment, asJSON
	})
}

func insertTestDigest(t *testing.T, d *db.DB, channelID string, from, to float64) int64 {
	t.Helper()
	res, err := d.Exec(
		`INSERT INTO digests (channel_id, period_from, period_to, type, summary, read_at)
		 VALUES (?, ?, ?, 'channel', 'seeded', NULL)`, channelID, from, to)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

func digestRead(t *testing.T, d *db.DB, id int64) bool {
	t.Helper()
	var readAt *string
	err := d.QueryRow(`SELECT read_at FROM digests WHERE id=?`, id).Scan(&readAt)
	require.NoError(t, err)
	return readAt != nil && *readAt != ""
}
