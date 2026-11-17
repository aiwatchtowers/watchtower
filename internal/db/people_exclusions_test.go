package db

import (
	"database/sql"
	"errors"
	"fmt"
	"sort"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// peopleFixture seeds users, channels and messages for the interaction tests.
type peopleFixture struct {
	t  *testing.T
	d  *DB
	ts int
}

func (f *peopleFixture) users(ids ...string) {
	for _, id := range ids {
		require.NoError(f.t, f.d.UpsertUser(User{ID: id, Name: id}))
	}
}

func (f *peopleFixture) channel(id, typ string) {
	require.NoError(f.t, f.d.UpsertChannel(Channel{ID: id, Name: id, Type: typ}))
}

// post adds a message in the test window and returns its ts.
func (f *peopleFixture) post(channel, user, text, threadTS string) string {
	f.ts++
	ts := fmt.Sprintf("1500000.%06d", f.ts)
	m := Message{ChannelID: channel, TS: ts, UserID: user, Text: text}
	if threadTS != "" {
		m.ThreadTS = sql.NullString{String: threadTS, Valid: true}
	}
	require.NoError(f.t, f.d.UpsertMessage(m))
	return ts
}

func statIDs(stats []UserStats) []string {
	out := make([]string, 0, len(stats))
	for _, s := range stats {
		out = append(out, s.UserID)
	}
	sort.Strings(out)
	return out
}

// TestPeopleCards_OnlyInteractionPartners: P1 shares a DM with the owner, P2
// replied in the owner's thread, P3 mentioned the owner, P4 only posted 30
// messages in a channel the owner reads → stats for P1–P3 and the owner.
func TestPeopleCards_OnlyInteractionPartners(t *testing.T) {
	d := openTestDB(t)
	f := &peopleFixture{t: t, d: d}
	f.users("1:UOWN", "1:UP1", "1:UP2", "1:UP3", "1:UP4")
	f.channel("1:CGEN", "public")
	f.channel("1:DP1", "dm")

	// Everyone posts in the shared channel (stats count non-DM messages).
	for _, u := range []string{"1:UOWN", "1:UP1", "1:UP2", "1:UP3"} {
		f.post("1:CGEN", u, "status update", "")
	}
	for range 30 {
		f.post("1:CGEN", "1:UP4", "busy channel", "")
	}
	f.post("1:DP1", "1:UOWN", "ping", "")
	f.post("1:DP1", "1:UP1", "pong", "")
	parent := f.post("1:CGEN", "1:UOWN", "thread start", "")
	f.post("1:CGEN", "1:UP2", "reply", parent)
	f.post("1:CGEN", "1:UP3", "cc <@UOWN> please look", "")

	stats, err := d.ComputeAllUserStats(1000000, 2000000, 1, map[int64]string{1: "1:UOWN"})
	require.NoError(t, err)
	assert.Equal(t, []string{"1:UOWN", "1:UP1", "1:UP2", "1:UP3"}, statIDs(stats))
}

// TestPeopleCards_InteractionEachWay covers the remaining directions: the
// owner replied in P's thread, the owner mentioned P (with a label), and
// interactions outside [from, to) do not count.
func TestPeopleCards_InteractionEachWay(t *testing.T) {
	d := openTestDB(t)
	f := &peopleFixture{t: t, d: d}
	f.users("1:UOWN", "1:UP1", "1:UP2", "1:UP3")
	f.channel("1:CGEN", "public")
	for _, u := range []string{"1:UOWN", "1:UP1", "1:UP2", "1:UP3"} {
		f.post("1:CGEN", u, "status update", "")
	}
	parent := f.post("1:CGEN", "1:UP1", "my thread", "")
	f.post("1:CGEN", "1:UOWN", "answer", parent)
	f.post("1:CGEN", "1:UOWN", "thanks <@UP2|dana>", "")
	// UP3 mentioned the owner, but before the window.
	require.NoError(t, d.UpsertMessage(Message{ChannelID: "1:CGEN", TS: "900000.000001", UserID: "1:UP3", Text: "<@UOWN>"}))

	stats, err := d.ComputeAllUserStats(1000000, 2000000, 1, map[int64]string{1: "1:UOWN"})
	require.NoError(t, err)
	assert.Equal(t, []string{"1:UOWN", "1:UP1", "1:UP2"}, statIDs(stats))
}

// TestPeopleCards_TwoAccountsTwoOwners: a person qualifies only through the
// owner of the same account.
func TestPeopleCards_TwoAccountsTwoOwners(t *testing.T) {
	d := openTestDB(t)
	f := &peopleFixture{t: t, d: d}
	f.users("1:UOWN", "1:UP6", "2:UME", "2:UP5", "2:UP7")
	f.channel("1:CGEN", "public")
	f.channel("2:CGEN", "public")
	f.channel("2:DP5", "dm")
	for _, u := range []string{"1:UOWN", "1:UP6"} {
		f.post("1:CGEN", u, "status update", "")
	}
	for _, u := range []string{"2:UME", "2:UP5"} {
		f.post("2:CGEN", u, "status update", "")
	}
	f.post("2:DP5", "2:UME", "ping", "")
	f.post("2:DP5", "2:UP5", "pong", "")
	// Account 1's raw owner id, mentioned inside account 2.
	f.post("2:CGEN", "2:UP7", "cc <@UOWN>", "")

	owners := map[int64]string{1: "1:UOWN", 2: "2:UME"}
	stats, err := d.ComputeAllUserStats(1000000, 2000000, 1, owners)
	require.NoError(t, err)
	assert.Equal(t, []string{"1:UOWN", "2:UME", "2:UP5"}, statIDs(stats))

	// Account 2 without an owner makes no cards there.
	stats, err = d.ComputeAllUserStats(1000000, 2000000, 1, map[int64]string{1: "1:UOWN"})
	require.NoError(t, err)
	assert.Equal(t, []string{"1:UOWN"}, statIDs(stats))
}

func TestPeopleCards_NoOwnerNoStats(t *testing.T) {
	d := openTestDB(t)
	f := &peopleFixture{t: t, d: d}
	f.users("1:UOWN", "1:UP1")
	f.channel("1:CGEN", "public")
	f.post("1:CGEN", "1:UOWN", "hi <@UP1>", "")
	f.post("1:CGEN", "1:UP1", "hello", "")

	stats, err := d.ComputeAllUserStats(1000000, 2000000, 1, map[int64]string{})
	require.NoError(t, err)
	assert.Empty(t, stats)
}

func TestSlackOwnersByAccount(t *testing.T) {
	d := openTestDB(t)
	mustExecAll(t, d,
		`INSERT INTO slack_accounts (id, current_user_id, status) VALUES
			(1, '1:UOWN', 'ok'), (2, '', 'ok'), (3, '3:UREV', 'revoked'), (4, '4:UGONE', 'removed'), (5, '5:UP', 'purged')`)
	got, err := d.SlackOwnersByAccount()
	require.NoError(t, err)
	assert.Equal(t, map[int64]string{1: "1:UOWN", 3: "3:UREV"}, got)
}

func TestPeopleExclude_DeletesCardsAndRoundTrips(t *testing.T) {
	d := openTestDB(t)
	require.NoError(t, d.UpsertUser(User{ID: "1:UP1", Name: "dana"}))
	require.NoError(t, d.UpsertUser(User{ID: "1:UP2", Name: "eli"}))
	for _, id := range []string{"1:UP1", "1:UP2"} {
		_, err := d.UpsertPeopleCard(PeopleCard{UserID: id, PeriodFrom: 1, PeriodTo: 2, Summary: "s"})
		require.NoError(t, err)
	}

	require.NoError(t, d.ExcludePerson("1:UP1"))
	require.NoError(t, d.ExcludePerson("1:UP1"), "excluding twice is a no-op")
	assert.Equal(t, 0, count(t, d, `SELECT COUNT(*) FROM people_cards WHERE user_id = '1:UP1'`))
	assert.Equal(t, 1, count(t, d, `SELECT COUNT(*) FROM people_cards WHERE user_id = '1:UP2'`))
	ex, err := d.PeopleExclusions()
	require.NoError(t, err)
	assert.Equal(t, map[string]bool{"1:UP1": true}, ex)

	require.NoError(t, d.IncludePerson("1:UP1"))
	require.NoError(t, d.IncludePerson("1:UP1"), "including a known person twice is a no-op")
	ex, err = d.PeopleExclusions()
	require.NoError(t, err)
	assert.Empty(t, ex)

	assert.True(t, errors.Is(d.ExcludePerson("1:UNOPE"), ErrPersonNotFound))
	assert.True(t, errors.Is(d.IncludePerson("1:UNOPE"), ErrPersonNotFound))
	assert.Equal(t, 0, count(t, d, `SELECT COUNT(*) FROM people_card_exclusions`))
}
