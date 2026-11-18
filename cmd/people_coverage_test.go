package cmd

import (
	"bytes"
	"regexp"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func TestShowPeopleList_WithVolumeChange(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	database, err := openDBFromConfig()
	require.NoError(t, err)

	now := time.Now().UTC()
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	from := float64(today.AddDate(0, 0, -7).Unix())
	to := float64(today.Unix())

	_, err = database.UpsertPeopleCard(db.PeopleCard{
		UserID:             "U001",
		PeriodFrom:         from,
		PeriodTo:           to,
		MessageCount:       100,
		ChannelsActive:     5,
		ThreadsInitiated:   10,
		ThreadsReplied:     20,
		VolumeChangePct:    -25.0,
		Summary:            "Activity dropped significantly",
		CommunicationStyle: "terse",
		DecisionRole:       "observer",
		RedFlags:           `["Unresponsive in code reviews"]`,
		Highlights:         `["Quick bug fixes"]`,
		Accomplishments:    `[]`,
		CommunicationGuide: "Be direct and concise",
		DecisionStyle:      "Prefers to observe before deciding",
		Tactics:            `[]`,
		Model:              "haiku",
	})
	require.NoError(t, err)
	database.Close()

	buf := new(bytes.Buffer)
	peopleCmd.SetOut(buf)
	peopleFlagUser = ""
	peopleFlagPrevious = false
	peopleFlagWeeks = 1

	err = peopleCmd.RunE(peopleCmd, nil)
	require.NoError(t, err)

	output := buf.String()
	assert.Contains(t, output, "alice")
}

func TestShowPeopleList_WithTeamSummaryAndAttention(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	database, err := openDBFromConfig()
	require.NoError(t, err)

	now := time.Now().UTC()
	from := float64(now.AddDate(0, 0, -7).Unix())
	to := float64(now.Unix())

	_, err = database.UpsertPeopleCard(db.PeopleCard{
		UserID:             "U001",
		PeriodFrom:         from,
		PeriodTo:           to,
		MessageCount:       50,
		ChannelsActive:     3,
		Summary:            "Normal week",
		CommunicationStyle: "balanced",
		DecisionRole:       "contributor",
		RedFlags:           `[]`,
		Highlights:         `["Shipped feature"]`,
		Accomplishments:    `["Completed project"]`,
		CommunicationGuide: "Keep communication balanced",
		DecisionStyle:      "Collaborative contributor",
		Tactics:            `["If blocked, escalate early"]`,
		Model:              "haiku",
	})
	require.NoError(t, err)

	// Add people card summary with attention items
	err = database.UpsertPeopleCardSummary(db.PeopleCardSummary{
		PeriodFrom: from,
		PeriodTo:   to,
		Summary:    "Team had a productive sprint",
		Attention:  `["Unreviewed PRs piling up","Deployment deadline approaching"]`,
		Tips:       `["Schedule regular 1:1s"]`,
		Model:      "haiku",
	})
	require.NoError(t, err)

	buf := new(bytes.Buffer)
	err = showPeopleList(peopleCmd, buf, database, nil, from, to,
		time.Unix(int64(from), 0), time.Unix(int64(to), 0))
	require.NoError(t, err)

	// Output goes through ui.RenderMarkdown - check for partial strings
	output := buf.String()
	assert.Contains(t, output, "alice")

	database.Close()
}

func TestShowUserDetail_WithAllFields(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	database, err := openDBFromConfig()
	require.NoError(t, err)

	now := time.Now().UTC()
	from := float64(now.AddDate(0, 0, -7).Unix())
	to := float64(now.Unix())

	_, err = database.UpsertPeopleCard(db.PeopleCard{
		UserID:             "U001",
		PeriodFrom:         from,
		PeriodTo:           to,
		MessageCount:       200,
		ChannelsActive:     8,
		ThreadsInitiated:   30,
		ThreadsReplied:     50,
		AvgMessageLength:   120.5,
		VolumeChangePct:    40.0,
		Summary:            "Alice had an exceptionally productive week",
		CommunicationStyle: "detailed",
		DecisionRole:       "driver",
		RedFlags:           `["Working past midnight regularly"]`,
		Highlights:         `["Shipped auth service","Mentored two juniors"]`,
		Accomplishments:    `["Completed OAuth integration","Published architecture doc"]`,
		CommunicationGuide: "Tends to write long, well-structured messages. Provide detailed context.",
		DecisionStyle:      "Drives decisions with data-backed arguments",
		Tactics:            `["If overloaded, delegate code reviews","If working late, set boundaries for work hours"]`,
		Model:              "haiku",
	})
	require.NoError(t, err)

	buf := new(bytes.Buffer)
	err = showUserDetail(buf, database, "alice", from, to)
	require.NoError(t, err)

	output := buf.String()
	assert.Contains(t, output, "alice")
	assert.Contains(t, output, "200")
	assert.Contains(t, output, "detailed")

	database.Close()
}

func TestRunPeopleGenerate_RequiresConfig(t *testing.T) {
	oldFlagConfig := flagConfig
	flagConfig = "/nonexistent/config.yaml"
	defer func() { flagConfig = oldFlagConfig }()

	err := peopleGenerateCmd.RunE(peopleGenerateCmd, nil)
	assert.Error(t, err)
}

func TestRunPeople_WeeksClampedToOne(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	buf := new(bytes.Buffer)
	peopleCmd.SetOut(buf)
	peopleFlagUser = ""
	peopleFlagPrevious = false
	peopleFlagWeeks = -5 // should be clamped to 1

	err := peopleCmd.RunE(peopleCmd, nil)
	require.NoError(t, err)
	assert.Contains(t, buf.String(), "No people cards available")
}

// TestPeopleCLI_NoDroppedPeopleFields (#1769, A12/A24; the CLI half of
// internal/tools' TestNoReaderReturnsDroppedPeopleFields): `watchtower
// people` and `people --user` print a basis line and no dropped field — no
// volume change, red flags, average length or attention list — even for a
// card and a summary written before the clearing migration.
func TestPeopleCLI_NoDroppedPeopleFields(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	database, err := openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()

	now := time.Now().UTC()
	from := float64(now.AddDate(0, 0, -7).Unix())
	to := float64(now.Unix())
	_, err = database.UpsertPeopleCard(db.PeopleCard{
		UserID: "U001", PeriodFrom: from, PeriodTo: to, MessageCount: 42, ChannelsActive: 5,
		ThreadsInitiated: 3, ThreadsReplied: 4, AvgMessageLength: 120.5, ActiveHoursJSON: `{"9":3}`, VolumeChangePct: -40,
		Summary: "Works on auth", CommunicationStyle: "driver", DecisionRole: "decision-maker",
		RedFlags: `["Seems overloaded","A performance dip"]`, Highlights: `["Led auth"]`, Accomplishments: `["Shipped SSO"]`,
		CommunicationGuide: "Be direct", DecisionStyle: "Quick", Tactics: `[]`, Model: "haiku",
	})
	require.NoError(t, err)
	require.NoError(t, database.UpsertPeopleCardSummary(db.PeopleCardSummary{
		PeriodFrom: from, PeriodTo: to, Summary: "Auth work moved", Attention: `["Check the performance of alice"]`,
		Tips: `["Use threads"]`, Model: "haiku",
	}))

	list := new(bytes.Buffer)
	require.NoError(t, showPeopleList(peopleCmd, list, database, nil, from, to,
		time.Unix(int64(from), 0), time.Unix(int64(to), 0)))
	detail := new(bytes.Buffer)
	require.NoError(t, showUserDetail(detail, database, "alice", from, to))

	ansi := regexp.MustCompile(`\x1b\[[0-9;]*m`)
	for name, raw := range map[string]string{"list": list.String(), "detail": detail.String()} {
		out := ansi.ReplaceAllString(raw, "")
		assert.Contains(t, out, "Works on auth", name)
		assert.Contains(t, out, "42 messages in 5 channels", name)
		for _, word := range []string{"RedFlags", "red_flags", "ActiveHours", "active_hours", "VolumeChangePct",
			"Volume change", "volume:", "Red flags", "Red Flags", "overloaded", "performance", "Needs Attention",
			"Avg message length", "-40"} {
			assert.NotContains(t, out, word, name)
		}
	}
}
