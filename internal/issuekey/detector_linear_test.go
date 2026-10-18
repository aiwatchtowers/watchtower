package issuekey

import (
	"bytes"
	"log"
	"testing"

	"watchtower/internal/config"
	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// The gate lives in one place so a new call site cannot invent a different one:
// cfg.Jira.Enabled || cfg.Linear.Enabled and nothing else, both false by
// default and flipped true by `jira add`/`jira login` and `linear add`. Off must
// be the pre-wiring behaviour exactly — no detector constructed, no key set
// ever loaded.
func TestNewKeyDetectorIfEnabled_GatedOnATracker(t *testing.T) {
	database := openTestDB(t)

	assert.Nil(t, NewKeyDetectorIfEnabled(&config.Config{}, database),
		"an install without a tracker must get no detector")
	assert.NotNil(t, NewKeyDetectorIfEnabled(&config.Config{Jira: config.JiraConfig{Enabled: true}}, database),
		"an install with Jira connected must get a detector")
	assert.NotNil(t, NewKeyDetectorIfEnabled(&config.Config{Linear: config.LinearConfig{Enabled: true}}, database),
		"an install with only Linear connected must get a detector")
}

// seedLinearTeam makes one Linear team key known to the detector.
func seedLinearTeam(t *testing.T, database *db.DB, teamKey string) {
	t.Helper()
	acct := db.SeedLinearTestAccount(t, database)
	require.NoError(t, database.UpsertLinearTeams(acct, []db.LinearTeam{{ID: "team-" + teamKey, Key: teamKey, Name: teamKey}}, nil))
}

func linksFor(t *testing.T, database *db.DB, tracker, key string) []db.IssueSlackLink {
	t.Helper()
	links, err := database.GetIssueSlackLinksByKeys(tracker, []string{key})
	require.NoError(t, err)
	return links
}

// A key whose prefix is a Linear team key is linked to Linear, never to Jira.
func TestKeyDetector_LinearTeamKeyLinksToLinear(t *testing.T) {
	database := openTestDB(t)
	seedLinearTeam(t, database, "ENG")
	d := NewKeyDetector(database)

	assert.Equal(t, []string{"ENG-12"}, d.DetectKeys("see ENG-12 and OTHER-3"))

	n, err := d.ProcessMessage("1:C1", "1000.001", "Fixing ENG-12")
	require.NoError(t, err)
	assert.Equal(t, 1, n)

	got := linksFor(t, database, "linear", "ENG-12")
	require.Len(t, got, 1)
	assert.Equal(t, "linear", got[0].Tracker)
	assert.Equal(t, "mention", got[0].LinkType)
	assert.Empty(t, linksFor(t, database, "jira", "ENG-12"), "a Linear key is not a Jira link")
}

// A prefix known to both trackers writes one link per tracker, on every path.
func TestKeyDetector_PrefixKnownToBothWritesOneLinkPerTracker(t *testing.T) {
	database := openTestDB(t)
	seedProjectKey(t, database, "ABC")
	seedLinearTeam(t, database, "ABC")
	d := NewKeyDetector(database)

	assert.Equal(t, []string{"ABC-7"}, d.DetectKeys("ABC-7"), "DetectKeys lists the key once")

	n, err := d.ProcessMessageBatch([]db.Message{{ChannelID: "1:C1", TS: "1.1", Text: "ABC-7 again"}})
	require.NoError(t, err)
	assert.Equal(t, 2, n, "one mention per tracker")

	n, err = d.ProcessTrack(5, "ABC-7", "", `["1:C1"]`)
	require.NoError(t, err)
	assert.Equal(t, 2, n)

	n, err = d.ProcessDigestDecision(9, "1:C1", "Decided ABC-7")
	require.NoError(t, err)
	assert.Equal(t, 2, n)

	for _, tracker := range []string{"jira", "linear"} {
		kinds := map[string]bool{}
		for _, l := range linksFor(t, database, tracker, "ABC-7") {
			assert.Equal(t, tracker, l.Tracker)
			kinds[l.LinkType] = true
		}
		assert.Equal(t, map[string]bool{"mention": true, "track": true, "decision": true}, kinds, tracker)
	}

	// Re-processing is idempotent per tracker.
	_, err = d.ProcessMessageBatch([]db.Message{{ChannelID: "1:C1", TS: "1.1", Text: "ABC-7 again"}})
	require.NoError(t, err)
	assert.Len(t, linksFor(t, database, "linear", "ABC-7"), 3)
}

// A Linear team key that appears only on stored issues (the team row not
// synced) is known too.
func TestKeyDetector_LinearIssueTeamKeyIsKnown(t *testing.T) {
	database := openTestDB(t)
	acct := db.SeedLinearTestAccount(t, database)
	require.NoError(t, database.UpsertLinearIssue(db.LinearIssue{AccountID: acct, ID: "u1", Key: "OPS-4", TeamKey: "OPS"}))
	d := NewKeyDetector(database)

	assert.Equal(t, []string{"OPS-4"}, d.DetectKeys("OPS-4"))
}

// A failed Linear key load keeps the detector fail-closed, like a Jira one.
func TestKeyDetector_LinearKeyLoadFailureDetectsNothing(t *testing.T) {
	database := openTestDB(t)
	seedProjectKey(t, database, "PROJ")
	_, err := database.Exec(`DROP TABLE linear_teams`)
	require.NoError(t, err)
	d := NewKeyDetector(database)

	assert.Nil(t, d.DetectKeys("PROJ-1"), "a partial load is no load: unknown means no")
}

// The daemon routes the detector's output into its own rotated watchtower.log
// through SetLogger; a default that still wins after SetLogger would land the
// line in daemon.log, which cannot be rotated while the daemon runs.
func TestKeyDetector_SetLoggerReceivesOutput(t *testing.T) {
	database := openTestDB(t)
	d := NewKeyDetector(database)
	var buf bytes.Buffer
	d.SetLogger(log.New(&buf, "", 0))

	// A closed database makes the known-key load fail, which the detector logs.
	_ = database.Close()
	assert.Empty(t, d.DetectKeys("see PROJ-1"))
	assert.Contains(t, buf.String(), "failed to load known issue-key prefixes")
}
