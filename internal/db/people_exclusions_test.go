package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"sort"
	"strings"
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

// TestInteractionPartners_QueryPlan: every branch of the partner query is
// bounded by the window — no branch range-scans the owner's or the account's
// whole history through idx_messages_user_id, and none scans messages.
func TestInteractionPartners_QueryPlan(t *testing.T) {
	d := openTestDB(t)
	plan := explainDetails(t, d, interactionPartnersSQL,
		sql.Named("owner", "1:UOWN"), sql.Named("from", 1.0), sql.Named("to", 2.0),
		sql.Named("lo", "1:"), sql.Named("hi", "1;"), sql.Named("raw", "UOWN"), sql.Named("rawAt", 3))
	assert.NotContains(t, plan, "idx_messages_user_id")
	// The only scans are of own, the owner's materialized window messages.
	for _, line := range strings.Split(plan, "\n") {
		if strings.HasPrefix(line, "SCAN ") && line != "SCAN o" {
			t.Errorf("unbounded scan: %q\n%s", line, plan)
		}
	}
	assert.Contains(t, plan, "MATERIALIZE own")
	assert.Contains(t, plan, "idx_messages_thread (channel_id=? AND thread_ts=?)")
	assert.Contains(t, plan, "idx_messages_channel_ts_unix (channel_id=? AND ts_unix>? AND ts_unix<?)")
}

// postAt adds a message at a given unix second (outside the fixture's
// in-window clock).
func (f *peopleFixture) postAt(sec int, channel, user, text, threadTS string) string {
	f.ts++
	ts := fmt.Sprintf("%d.%06d", sec, f.ts)
	m := Message{ChannelID: channel, TS: ts, UserID: user, Text: text}
	if threadTS != "" {
		m.ThreadTS = sql.NullString{String: threadTS, Valid: true}
	}
	require.NoError(f.t, f.d.UpsertMessage(m))
	return ts
}

// TestPeopleCards_GroupDMAndThirdThread: a group DM both posted in counts,
// and so does a thread someone else started that both replied in.
func TestPeopleCards_GroupDMAndThirdThread(t *testing.T) {
	d := openTestDB(t)
	f := &peopleFixture{t: t, d: d}
	f.users("1:UOWN", "1:UP1", "1:UP2", "1:UP3")
	f.channel("1:CGEN", "public")
	f.channel("1:GDM", "group_dm")
	for _, u := range []string{"1:UOWN", "1:UP1", "1:UP2", "1:UP3"} {
		f.post("1:CGEN", u, "status update", "")
	}
	f.post("1:GDM", "1:UOWN", "group ping", "")
	f.post("1:GDM", "1:UP1", "group pong", "")
	parent := f.post("1:CGEN", "1:UP3", "a third person's thread", "")
	f.post("1:CGEN", "1:UOWN", "reply", parent)
	f.post("1:CGEN", "1:UP2", "reply too", parent)

	stats, err := d.ComputeAllUserStats(1000000, 2000000, 1, map[int64]string{1: "1:UOWN"})
	require.NoError(t, err)
	// UP3 started the thread the owner replied in: a partner as well.
	assert.Equal(t, []string{"1:UOWN", "1:UP1", "1:UP2", "1:UP3"}, statIDs(stats))
}

// TestPeopleCards_InteractionOutsideWindowDoesNotCount: each branch's
// interaction happening before the window (or at its end, which is open)
// does not make a partner.
func TestPeopleCards_InteractionOutsideWindowDoesNotCount(t *testing.T) {
	d := openTestDB(t)
	f := &peopleFixture{t: t, d: d}
	f.users("1:UOWN", "1:UDM", "1:UTH", "1:UMEN")
	f.channel("1:CGEN", "public")
	f.channel("1:DDM", "dm")
	for _, u := range []string{"1:UOWN", "1:UDM", "1:UTH", "1:UMEN"} {
		f.post("1:CGEN", u, "status update", "")
	}
	// DM: the owner's half is before the window.
	f.postAt(900000, "1:DDM", "1:UOWN", "old ping", "")
	f.post("1:DDM", "1:UDM", "pong", "")
	// Thread: the partner's reply lands at the window's open end.
	parent := f.post("1:CGEN", "1:UOWN", "thread", "")
	f.postAt(2000000, "1:CGEN", "1:UTH", "late reply", parent)
	// The owner mentioned UMEN before the window.
	f.postAt(900000, "1:CGEN", "1:UOWN", "cc <@UMEN>", "")

	stats, err := d.ComputeAllUserStats(1000000, 2000000, 1, map[int64]string{1: "1:UOWN"})
	require.NoError(t, err)
	assert.Equal(t, []string{"1:UOWN"}, statIDs(stats))
}

// TestUpsertPeopleCard_RefusesExcluded: the exclusion check is inside the
// write, so a card generated for a person excluded meanwhile is not stored.
func TestUpsertPeopleCard_RefusesExcluded(t *testing.T) {
	d := openTestDB(t)
	require.NoError(t, d.UpsertUser(User{ID: "1:UP1", Name: "dana"}))
	require.NoError(t, d.ExcludePerson("1:UP1"))
	_, err := d.UpsertPeopleCard(PeopleCard{UserID: "1:UP1", PeriodFrom: 1, PeriodTo: 2, Summary: "s"})
	require.ErrorIs(t, err, ErrPersonExcluded)
	assert.Equal(t, 0, count(t, d, `SELECT COUNT(*) FROM people_cards`))
}

// TestPrunePreUpgradePeopleCards: each card is checked against its own
// window. A partner in week 1 who is silent in week 2 keeps the week-1 card;
// a non-partner's (pre-upgrade) card in its own window goes; the owner's
// cards stay; an account without a known owner is untouched and stays
// pending; a done account is never checked again.
func TestPrunePreUpgradePeopleCards(t *testing.T) {
	d := openTestDB(t)
	f := &peopleFixture{t: t, d: d}
	mustExecAll(t, d, `INSERT INTO slack_accounts (id, current_user_id) VALUES (1, '1:UOWN'), (2, '')`)
	f.users("1:UOWN", "1:UP1", "1:UGONE", "2:UX")
	f.channel("1:CGEN", "public")
	f.post("1:CGEN", "1:UP1", "hi <@UOWN>", "") // week 1 only
	week1, week2 := [2]float64{1000000, 2000000}, [2]float64{2000000, 3000000}
	card := func(id string, w [2]float64) {
		_, err := d.UpsertPeopleCard(PeopleCard{UserID: id, PeriodFrom: w[0], PeriodTo: w[1], Summary: "s"})
		require.NoError(t, err)
	}
	card("1:UOWN", week1)
	card("1:UOWN", week2)
	card("1:UP1", week1)
	card("1:UGONE", week1)
	card("1:UGONE", week2)
	card("2:UX", week1)
	has := func(id string, w [2]float64) bool {
		return count(t, d, `SELECT COUNT(*) FROM people_cards WHERE user_id = ? AND period_from = ? AND period_to = ?`, id, w[0], w[1]) == 1
	}

	n, done, err := d.PrunePreUpgradePeopleCards(context.Background())
	require.NoError(t, err)
	assert.Equal(t, int64(2), n)
	assert.False(t, done, "account 2 has no owner yet")
	assert.True(t, has("1:UP1", week1), "a week-1 partner keeps the week-1 card although silent in week 2")
	assert.False(t, has("1:UGONE", week1), "a non-partner's card in its own window goes")
	assert.False(t, has("1:UGONE", week2))
	assert.True(t, has("1:UOWN", week1))
	assert.True(t, has("1:UOWN", week2))
	assert.True(t, has("2:UX", week1), "an account without an owner is not touched")
	assert.NotEmpty(t, prunedAt(t, d, 1))
	assert.Empty(t, prunedAt(t, d, 2))

	// Account 1 is done: a card added later is not re-checked.
	card("1:UGONE", week1)
	n, done, err = d.PrunePreUpgradePeopleCards(context.Background())
	require.NoError(t, err)
	assert.Equal(t, int64(0), n)
	assert.False(t, done)
	assert.True(t, has("1:UGONE", week1), "a done account is never pruned again")

	// The owner of account 2 becomes known: its pass runs, then all is done.
	mustExecAll(t, d, `UPDATE slack_accounts SET current_user_id = '2:UME' WHERE id = 2`)
	n, done, err = d.PrunePreUpgradePeopleCards(context.Background())
	require.NoError(t, err)
	assert.Equal(t, int64(1), n)
	assert.True(t, done)
	assert.False(t, has("2:UX", week1))
	n, done, err = d.PrunePreUpgradePeopleCards(context.Background())
	require.NoError(t, err)
	assert.Equal(t, int64(0), n)
	assert.True(t, done)
}

// TestPrunePreUpgradePeopleCards_InterruptedResumes: a pass stopped after
// its first window (a crash leaves no marker) or by a cancelled context
// resumes on the next call and ends where an uninterrupted pass would.
func TestPrunePreUpgradePeopleCards_InterruptedResumes(t *testing.T) {
	d := openTestDB(t)
	mustExecAll(t, d, `INSERT INTO slack_accounts (id, current_user_id) VALUES (1, '1:UOWN')`)
	for _, w := range [][2]float64{{1000000, 2000000}, {2000000, 3000000}} {
		for _, id := range []string{"1:UOWN", "1:UGONE"} {
			_, err := d.UpsertPeopleCard(PeopleCard{UserID: id, PeriodFrom: w[0], PeriodTo: w[1], Summary: "s"})
			require.NoError(t, err)
		}
	}

	// A crash after the first window: that window is pruned, no marker.
	lo, hi := prefixRange("1:")
	n, err := d.pruneCardWindow(1, "1:UOWN", lo, hi, [2]float64{1000000, 2000000})
	require.NoError(t, err)
	require.Equal(t, int64(1), n)
	assert.Empty(t, prunedAt(t, d, 1))

	// A cancelled context stops before any window and leaves no marker.
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, done, err := d.PrunePreUpgradePeopleCards(ctx)
	require.ErrorIs(t, err, context.Canceled)
	assert.False(t, done)
	assert.Empty(t, prunedAt(t, d, 1))

	n, done, err = d.PrunePreUpgradePeopleCards(context.Background())
	require.NoError(t, err)
	assert.Equal(t, int64(1), n, "only the window the crash did not reach")
	assert.True(t, done)
	assert.NotEmpty(t, prunedAt(t, d, 1))
	assert.Equal(t, 0, count(t, d, `SELECT COUNT(*) FROM people_cards WHERE user_id = '1:UGONE'`))
	assert.Equal(t, 2, count(t, d, `SELECT COUNT(*) FROM people_cards WHERE user_id = '1:UOWN'`))
}

func prunedAt(t *testing.T, d *DB, acct int64) string {
	t.Helper()
	var at string
	require.NoError(t, d.QueryRow(`SELECT people_prune_done_at FROM slack_accounts WHERE id = ?`, acct).Scan(&at))
	return at
}
