package db

import (
	"database/sql"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func sampleUserAnalysis(userID string, from, to float64) UserAnalysis {
	return UserAnalysis{
		UserID:             userID,
		PeriodFrom:         from,
		PeriodTo:           to,
		MessageCount:       100,
		ChannelsActive:     5,
		ThreadsInitiated:   10,
		ThreadsReplied:     20,
		AvgMessageLength:   42.5,
		ActiveHoursJSON:    `{"9":12,"10":8}`,
		VolumeChangePct:    15.5,
		Summary:            "Active communicator",
		CommunicationStyle: "direct",
		DecisionRole:       "driver",
		RedFlags:           `["late night activity"]`,
		Highlights:         `["quick responder"]`,
		StyleDetails:       "Concise and focused",
		Recommendations:    `["delegate more"]`,
		Concerns:           `["burnout risk"]`,
		Accomplishments:    `["launched API v2"]`,
		Model:              "haiku",
		InputTokens:        1000,
		OutputTokens:       200,
		CostUSD:            0.001,
	}
}

func TestUpsertUserAnalysis(t *testing.T) {
	db := openTestDB(t)

	a := sampleUserAnalysis("U1", 1000000, 2000000)
	id, err := db.UpsertUserAnalysis(a)
	require.NoError(t, err)
	assert.Greater(t, id, int64(0))
}

func TestUpsertUserAnalysis_Update(t *testing.T) {
	db := openTestDB(t)

	a := sampleUserAnalysis("U1", 1000000, 2000000)
	id1, err := db.UpsertUserAnalysis(a)
	require.NoError(t, err)

	a.Summary = "Updated summary"
	a.MessageCount = 200
	id2, err := db.UpsertUserAnalysis(a)
	require.NoError(t, err)
	assert.Equal(t, id1, id2) // Same row updated

	analyses, err := db.GetUserAnalyses(UserAnalysisFilter{UserID: "U1"})
	require.NoError(t, err)
	require.Len(t, analyses, 1)
	assert.Equal(t, "Updated summary", analyses[0].Summary)
	assert.Equal(t, 200, analyses[0].MessageCount)
}

func TestGetUserAnalyses_Filters(t *testing.T) {
	db := openTestDB(t)

	_, err := db.UpsertUserAnalysis(sampleUserAnalysis("U1", 1000000, 2000000))
	require.NoError(t, err)
	_, err = db.UpsertUserAnalysis(sampleUserAnalysis("U1", 3000000, 4000000))
	require.NoError(t, err)
	_, err = db.UpsertUserAnalysis(sampleUserAnalysis("U2", 1000000, 2000000))
	require.NoError(t, err)

	// Filter by user
	analyses, err := db.GetUserAnalyses(UserAnalysisFilter{UserID: "U1"})
	require.NoError(t, err)
	assert.Len(t, analyses, 2)

	// Filter by from
	analyses, err = db.GetUserAnalyses(UserAnalysisFilter{FromUnix: 2500000})
	require.NoError(t, err)
	assert.Len(t, analyses, 1)
	assert.Equal(t, "U1", analyses[0].UserID)

	// Filter by to
	analyses, err = db.GetUserAnalyses(UserAnalysisFilter{ToUnix: 2500000})
	require.NoError(t, err)
	assert.Len(t, analyses, 2)

	// With limit
	analyses, err = db.GetUserAnalyses(UserAnalysisFilter{Limit: 1})
	require.NoError(t, err)
	assert.Len(t, analyses, 1)

	// All
	analyses, err = db.GetUserAnalyses(UserAnalysisFilter{})
	require.NoError(t, err)
	assert.Len(t, analyses, 3)
}

func TestGetUserAnalyses_Order(t *testing.T) {
	db := openTestDB(t)

	_, err := db.UpsertUserAnalysis(sampleUserAnalysis("U1", 1000000, 2000000))
	require.NoError(t, err)
	_, err = db.UpsertUserAnalysis(sampleUserAnalysis("U1", 3000000, 4000000))
	require.NoError(t, err)

	analyses, err := db.GetUserAnalyses(UserAnalysisFilter{UserID: "U1"})
	require.NoError(t, err)
	require.Len(t, analyses, 2)
	// Newest first (ordered by period_to DESC)
	assert.Equal(t, 4000000.0, analyses[0].PeriodTo)
	assert.Equal(t, 2000000.0, analyses[1].PeriodTo)
}

func TestGetLatestUserAnalysis(t *testing.T) {
	db := openTestDB(t)

	// No analysis yet
	a, err := db.GetLatestUserAnalysis("U1")
	require.NoError(t, err)
	assert.Nil(t, a)

	// Insert two analyses
	_, err = db.UpsertUserAnalysis(sampleUserAnalysis("U1", 1000000, 2000000))
	require.NoError(t, err)

	a2 := sampleUserAnalysis("U1", 3000000, 4000000)
	a2.Summary = "latest"
	_, err = db.UpsertUserAnalysis(a2)
	require.NoError(t, err)

	a, err = db.GetLatestUserAnalysis("U1")
	require.NoError(t, err)
	require.NotNil(t, a)
	assert.Equal(t, "latest", a.Summary)
	assert.Equal(t, 4000000.0, a.PeriodTo)
}

func TestGetLatestUserAnalysis_DifferentUser(t *testing.T) {
	db := openTestDB(t)

	_, err := db.UpsertUserAnalysis(sampleUserAnalysis("U1", 1000000, 2000000))
	require.NoError(t, err)

	a, err := db.GetLatestUserAnalysis("U2")
	require.NoError(t, err)
	assert.Nil(t, a)
}

func TestGetUserAnalysesForWindow(t *testing.T) {
	db := openTestDB(t)

	a1 := sampleUserAnalysis("U1", 1000000, 2000000)
	a1.MessageCount = 50
	_, err := db.UpsertUserAnalysis(a1)
	require.NoError(t, err)

	a2 := sampleUserAnalysis("U2", 1000000, 2000000)
	a2.MessageCount = 100
	_, err = db.UpsertUserAnalysis(a2)
	require.NoError(t, err)

	// Different window
	_, err = db.UpsertUserAnalysis(sampleUserAnalysis("U1", 3000000, 4000000))
	require.NoError(t, err)

	analyses, err := db.GetUserAnalysesForWindow(1000000, 2000000)
	require.NoError(t, err)
	require.Len(t, analyses, 2)
	// Ordered by message_count DESC
	assert.Equal(t, "U2", analyses[0].UserID)
	assert.Equal(t, "U1", analyses[1].UserID)
}

func TestDeleteUserAnalysesOlderThan(t *testing.T) {
	db := openTestDB(t)

	_, err := db.UpsertUserAnalysis(sampleUserAnalysis("U1", 1000000, 2000000))
	require.NoError(t, err)
	_, err = db.UpsertUserAnalysis(sampleUserAnalysis("U1", 5000000, 6000000))
	require.NoError(t, err)

	deleted, err := db.DeleteUserAnalysesOlderThan(3000000)
	require.NoError(t, err)
	assert.Equal(t, int64(1), deleted)

	analyses, err := db.GetUserAnalyses(UserAnalysisFilter{})
	require.NoError(t, err)
	require.Len(t, analyses, 1)
	assert.Equal(t, 6000000.0, analyses[0].PeriodTo)
}

func TestActiveUsersInWindow(t *testing.T) {
	db := openTestDB(t)

	// Create users
	require.NoError(t, db.UpsertUser(User{ID: "U1", Name: "alice"}))
	require.NoError(t, db.UpsertUser(User{ID: "U2", Name: "bob"}))
	require.NoError(t, db.UpsertUser(User{ID: "UBOT", Name: "bot", IsBot: true}))
	require.NoError(t, db.UpsertUser(User{ID: "UDEL", Name: "deleted", IsDeleted: true}))

	// Create channels
	require.NoError(t, db.UpsertChannel(Channel{ID: "C1", Name: "general", Type: "public"}))
	require.NoError(t, db.UpsertChannel(Channel{ID: "CDM", Name: "dm", Type: "dm"}))

	// Messages in window
	require.NoError(t, db.UpsertMessage(Message{ChannelID: "C1", TS: "1500000.000001", UserID: "U1", Text: "hello"}))
	require.NoError(t, db.UpsertMessage(Message{ChannelID: "C1", TS: "1500000.000002", UserID: "U2", Text: "hi"}))
	// Bot message — should be excluded
	require.NoError(t, db.UpsertMessage(Message{ChannelID: "C1", TS: "1500000.000003", UserID: "UBOT", Text: "alert"}))
	// Deleted user — should be excluded
	require.NoError(t, db.UpsertMessage(Message{ChannelID: "C1", TS: "1500000.000004", UserID: "UDEL", Text: "old"}))
	// DM message — should be excluded
	require.NoError(t, db.UpsertMessage(Message{ChannelID: "CDM", TS: "1500000.000005", UserID: "U1", Text: "dm"}))

	users, err := db.ActiveUsersInWindow(1000000, 2000000)
	require.NoError(t, err)
	assert.Equal(t, []string{"U1", "U2"}, users)
}

func TestActiveUsersInWindow_Empty(t *testing.T) {
	db := openTestDB(t)

	users, err := db.ActiveUsersInWindow(1000000, 2000000)
	require.NoError(t, err)
	assert.Empty(t, users)
}

func TestComputeUserStats(t *testing.T) {
	db := openTestDB(t)

	// Setup
	require.NoError(t, db.UpsertUser(User{ID: "U1", Name: "alice"}))
	require.NoError(t, db.UpsertChannel(Channel{ID: "C1", Name: "general", Type: "public"}))
	require.NoError(t, db.UpsertChannel(Channel{ID: "C2", Name: "random", Type: "public"}))

	// Messages in window (1000000 - 2000000)
	require.NoError(t, db.UpsertMessage(Message{ChannelID: "C1", TS: "1500000.000001", UserID: "U1", Text: "hello world"}))
	require.NoError(t, db.UpsertMessage(Message{ChannelID: "C1", TS: "1500000.000002", UserID: "U1", Text: "another msg", ReplyCount: 2}))
	require.NoError(t, db.UpsertMessage(Message{ChannelID: "C2", TS: "1500000.000003", UserID: "U1", Text: "in random"}))
	// Thread reply
	require.NoError(t, db.UpsertMessage(Message{
		ChannelID: "C1", TS: "1500000.000004", UserID: "U1", Text: "replying",
		ThreadTS: sql.NullString{String: "1500000.000002", Valid: true},
	}))

	stats, err := db.ComputeUserStats("U1", 1000000, 2000000)
	require.NoError(t, err)
	require.NotNil(t, stats)
	assert.Equal(t, "U1", stats.UserID)
	assert.Equal(t, 4, stats.MessageCount)
	assert.Equal(t, 2, stats.ChannelsActive) // C1, C2
	assert.Equal(t, 1, stats.ThreadsInitiated)
	assert.Equal(t, 1, stats.ThreadsReplied)
	assert.Greater(t, stats.AvgMessageLength, 0.0)
}

func TestComputeUserStats_VolumeChange(t *testing.T) {
	db := openTestDB(t)

	require.NoError(t, db.UpsertUser(User{ID: "U1", Name: "alice"}))
	require.NoError(t, db.UpsertChannel(Channel{ID: "C1", Name: "general", Type: "public"}))

	// Previous window (0 - 1000000): 2 messages
	require.NoError(t, db.UpsertMessage(Message{ChannelID: "C1", TS: "500000.000001", UserID: "U1", Text: "old1"}))
	require.NoError(t, db.UpsertMessage(Message{ChannelID: "C1", TS: "500000.000002", UserID: "U1", Text: "old2"}))

	// Current window (1000000 - 2000000): 4 messages — 100% increase
	require.NoError(t, db.UpsertMessage(Message{ChannelID: "C1", TS: "1500000.000001", UserID: "U1", Text: "new1"}))
	require.NoError(t, db.UpsertMessage(Message{ChannelID: "C1", TS: "1500000.000002", UserID: "U1", Text: "new2"}))
	require.NoError(t, db.UpsertMessage(Message{ChannelID: "C1", TS: "1500000.000003", UserID: "U1", Text: "new3"}))
	require.NoError(t, db.UpsertMessage(Message{ChannelID: "C1", TS: "1500000.000004", UserID: "U1", Text: "new4"}))

	stats, err := db.ComputeUserStats("U1", 1000000, 2000000)
	require.NoError(t, err)
	assert.Equal(t, 100.0, stats.VolumeChangePct) // (4-2)/2 * 100 = 100%
}

func TestComputeAllUserStats(t *testing.T) {
	db := openTestDB(t)

	require.NoError(t, db.UpsertUser(User{ID: "U1", Name: "alice"}))
	require.NoError(t, db.UpsertUser(User{ID: "U2", Name: "bob"}))
	require.NoError(t, db.UpsertUser(User{ID: "UBOT", Name: "bot", IsBot: true}))
	require.NoError(t, db.UpsertChannel(Channel{ID: "C1", Name: "general", Type: "public"}))

	// U1: 3 messages
	for i := 0; i < 3; i++ {
		ts := "1500000.00000" + string(rune('1'+i))
		require.NoError(t, db.UpsertMessage(Message{ChannelID: "C1", TS: ts, UserID: "U1", Text: "msg from U1"}))
	}

	// U2: 2 messages
	require.NoError(t, db.UpsertMessage(Message{ChannelID: "C1", TS: "1500000.000011", UserID: "U2", Text: "msg from U2"}))
	require.NoError(t, db.UpsertMessage(Message{ChannelID: "C1", TS: "1500000.000012", UserID: "U2", Text: "msg2 from U2"}))

	// Bot: should be excluded
	require.NoError(t, db.UpsertMessage(Message{ChannelID: "C1", TS: "1500000.000021", UserID: "UBOT", Text: "bot msg"}))

	stats, err := db.ComputeAllUserStats(1000000, 2000000, 1)
	require.NoError(t, err)
	require.Len(t, stats, 2)

	// minMessages=3 should filter out U2
	stats, err = db.ComputeAllUserStats(1000000, 2000000, 3)
	require.NoError(t, err)
	require.Len(t, stats, 1)
	assert.Equal(t, "U1", stats[0].UserID)
}

func TestComputeAllUserStats_Empty(t *testing.T) {
	db := openTestDB(t)

	stats, err := db.ComputeAllUserStats(1000000, 2000000, 1)
	require.NoError(t, err)
	assert.Nil(t, stats)
}

func TestUpsertAndGetUserInteractions(t *testing.T) {
	db := openTestDB(t)

	interactions := []UserInteraction{
		{
			UserA: "U1", UserB: "U2",
			PeriodFrom: 1000000, PeriodTo: 2000000,
			MessagesTo: 10, MessagesFrom: 5,
			SharedChannels: 2, ThreadRepliesTo: 3, ThreadRepliesFrom: 1,
			SharedChannelIDs: `["C1","C2"]`,
			DMMessagesTo:     2, DMMessagesFrom: 1,
			MentionsTo: 1, MentionsFrom: 0,
			ReactionsTo: 3, ReactionsFrom: 2,
			InteractionScore: 50.0, ConnectionType: "peer",
		},
		{
			UserA: "U1", UserB: "U3",
			PeriodFrom: 1000000, PeriodTo: 2000000,
			MessagesTo: 20, MessagesFrom: 15,
			SharedChannels: 1, ThreadRepliesTo: 0, ThreadRepliesFrom: 2,
			SharedChannelIDs: `["C1"]`,
			InteractionScore: 80.0, ConnectionType: "i_depend",
		},
	}

	err := db.UpsertUserInteractions(interactions)
	require.NoError(t, err)

	got, err := db.GetUserInteractions("U1", 1000000, 2000000)
	require.NoError(t, err)
	require.Len(t, got, 2)
	// Ordered by interaction_score DESC
	assert.Equal(t, "U3", got[0].UserB) // score=80
	assert.Equal(t, "U2", got[1].UserB) // score=50

	// Verify new fields persisted
	assert.Equal(t, 2, got[1].DMMessagesTo)
	assert.Equal(t, 1, got[1].DMMessagesFrom)
	assert.Equal(t, 1, got[1].MentionsTo)
	assert.Equal(t, 3, got[1].ReactionsTo)
	assert.Equal(t, 2, got[1].ReactionsFrom)
	assert.Equal(t, 50.0, got[1].InteractionScore)
	assert.Equal(t, "peer", got[1].ConnectionType)
	assert.Equal(t, "i_depend", got[0].ConnectionType)
}

func TestUpsertUserInteractions_ReplacesOld(t *testing.T) {
	db := openTestDB(t)

	interactions1 := []UserInteraction{{
		UserA: "U1", UserB: "U2",
		PeriodFrom: 1000000, PeriodTo: 2000000,
		MessagesTo: 10, SharedChannelIDs: `["C1"]`,
	}}
	err := db.UpsertUserInteractions(interactions1)
	require.NoError(t, err)

	// Replace with new data
	interactions2 := []UserInteraction{{
		UserA: "U1", UserB: "U2",
		PeriodFrom: 1000000, PeriodTo: 2000000,
		MessagesTo: 20, SharedChannelIDs: `["C1","C2"]`,
	}}
	err = db.UpsertUserInteractions(interactions2)
	require.NoError(t, err)

	got, err := db.GetUserInteractions("U1", 1000000, 2000000)
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.Equal(t, 20, got[0].MessagesTo)
}

func TestUpsertUserInteractions_Empty(t *testing.T) {
	db := openTestDB(t)

	err := db.UpsertUserInteractions(nil)
	require.NoError(t, err)
}

func TestGetUserInteractions_NoResults(t *testing.T) {
	db := openTestDB(t)

	got, err := db.GetUserInteractions("U1", 1000000, 2000000)
	require.NoError(t, err)
	assert.Empty(t, got)
}

func TestUpsertPeriodSummary(t *testing.T) {
	db := openTestDB(t)

	s := PeriodSummary{
		PeriodFrom:   1000000,
		PeriodTo:     2000000,
		Summary:      "Team was very active",
		Attention:    `["burnout risk for @alice"]`,
		Model:        "haiku",
		InputTokens:  500,
		OutputTokens: 100,
		CostUSD:      0,
	}
	err := db.UpsertPeriodSummary(s)
	require.NoError(t, err)

	got, err := db.GetPeriodSummary(1000000, 2000000)
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, "Team was very active", got.Summary)
	assert.Equal(t, `["burnout risk for @alice"]`, got.Attention)
	assert.Equal(t, "haiku", got.Model)
}

func TestUpsertPeriodSummary_Update(t *testing.T) {
	db := openTestDB(t)

	s := PeriodSummary{PeriodFrom: 1000000, PeriodTo: 2000000, Summary: "v1"}
	err := db.UpsertPeriodSummary(s)
	require.NoError(t, err)

	s.Summary = "v2"
	err = db.UpsertPeriodSummary(s)
	require.NoError(t, err)

	got, err := db.GetPeriodSummary(1000000, 2000000)
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, "v2", got.Summary)
}

func TestGetPeriodSummary_NotFound(t *testing.T) {
	db := openTestDB(t)

	got, err := db.GetPeriodSummary(1000000, 2000000)
	require.NoError(t, err)
	assert.Nil(t, got)
}

func TestComputeAllUserStats_WithThreadsHoursVolume(t *testing.T) {
	db := openTestDB(t)

	require.NoError(t, db.UpsertUser(User{ID: "U1", Name: "alice"}))
	require.NoError(t, db.UpsertUser(User{ID: "U2", Name: "bob"}))
	require.NoError(t, db.UpsertChannel(Channel{ID: "C1", Name: "general", Type: "public"}))

	// U1: thread initiator — a parent message with reply_count > 0
	require.NoError(t, db.UpsertMessage(Message{
		ChannelID: "C1", TS: "1500000.000001", UserID: "U1",
		Text: "starting a thread", ReplyCount: 3,
	}))
	// U1: regular messages at different hours
	// ts 1500000 = 2017-07-14 02:40:00 UTC (hour 2)
	// ts 1500036000 = 2017-07-14 12:40:00 UTC (hour 12)
	require.NoError(t, db.UpsertMessage(Message{
		ChannelID: "C1", TS: "1500036.000001", UserID: "U1",
		Text: "afternoon message",
	}))

	// U2: reply in thread (thread_ts set = non-null)
	require.NoError(t, db.UpsertMessage(Message{
		ChannelID: "C1", TS: "1500000.000002", UserID: "U2",
		Text: "reply", ThreadTS: sql.NullString{String: "1500000.000001", Valid: true},
	}))
	// U2: another message
	require.NoError(t, db.UpsertMessage(Message{
		ChannelID: "C1", TS: "1500000.000003", UserID: "U2",
		Text: "another",
	}))

	// Previous window messages for volume change (window 1000000-2000000, prev 0-1000000)
	require.NoError(t, db.UpsertMessage(Message{
		ChannelID: "C1", TS: "500000.000001", UserID: "U1",
		Text: "old message",
	}))

	stats, err := db.ComputeAllUserStats(1000000, 2000000, 1)
	require.NoError(t, err)
	require.Len(t, stats, 2)

	// Find U1 stats
	var u1Stats *UserStats
	for i := range stats {
		if stats[i].UserID == "U1" {
			u1Stats = &stats[i]
			break
		}
	}
	require.NotNil(t, u1Stats)
	assert.Equal(t, 2, u1Stats.MessageCount)
	assert.Equal(t, 1, u1Stats.ThreadsInitiated) // the parent message
	assert.NotEmpty(t, u1Stats.ActiveHoursJSON)
	assert.NotEqual(t, "{}", u1Stats.ActiveHoursJSON)
	// Volume change: 2 msgs now vs 1 msg prev = +100%
	assert.InDelta(t, 100.0, u1Stats.VolumeChangePct, 1.0)

	// Find U2 stats
	var u2Stats *UserStats
	for i := range stats {
		if stats[i].UserID == "U2" {
			u2Stats = &stats[i]
			break
		}
	}
	require.NotNil(t, u2Stats)
	assert.Equal(t, 2, u2Stats.MessageCount)
	assert.Equal(t, 1, u2Stats.ThreadsReplied) // replied to 1 thread
}

func TestBuildHoursJSON(t *testing.T) {
	// Empty
	assert.Equal(t, "{}", buildHoursJSON(nil))
	assert.Equal(t, "{}", buildHoursJSON(map[int]int{}))

	// Single hour
	result := buildHoursJSON(map[int]int{9: 12})
	assert.Equal(t, `{"9":12}`, result)

	// Multiple hours — ordered by hour
	result = buildHoursJSON(map[int]int{14: 5, 9: 12, 10: 8})
	assert.Contains(t, result, `"9":12`)
	assert.Contains(t, result, `"10":8`)
	assert.Contains(t, result, `"14":5`)
}
