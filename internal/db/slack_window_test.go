package db

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const windowOwner = "1:U0OWNER"

// windowSeed seeds account 1 (owner 1:U0OWNER) and the member channel
// 1:C0ACME (#acme-release) and appends messages with unique timestamps.
type windowSeed struct {
	t   *testing.T
	d   *DB
	now time.Time
	seq int
}

func newWindowSeed(t *testing.T) *windowSeed {
	t.Helper()
	d := openTestDB(t)
	acct, err := d.CreateSlackAccount(SlackAccount{TeamID: "T1", TeamName: "acme", TeamDomain: "acme", CurrentUserID: windowOwner})
	require.NoError(t, err)
	require.Equal(t, int64(1), acct)
	s := &windowSeed{t: t, d: d, now: time.Now()}
	s.user(windowOwner, "owner", "Owner", "", "")
	s.channel("1:C0ACME", "acme-release", "public", true)
	return s
}

func (s *windowSeed) channel(id, name, typ string, member bool) {
	s.t.Helper()
	_, err := s.d.Exec(`INSERT INTO channels (id, name, type, is_member) VALUES (?, ?, ?, ?)`, id, name, typ, member)
	require.NoError(s.t, err)
}

func (s *windowSeed) user(id, name, display, realName, extra string) {
	s.t.Helper()
	_, err := s.d.Exec(`INSERT INTO users (id, name, display_name, real_name) VALUES (?, ?, ?, ?)`, id, name, display, realName)
	require.NoError(s.t, err)
	if extra != "" {
		_, err = s.d.Exec(`UPDATE users SET `+extra+` WHERE id = ?`, id)
		require.NoError(s.t, err)
	}
}

// msg inserts a message at `at` and returns its ts.
func (s *windowSeed) msg(channel, user, text string, at time.Time) string {
	s.t.Helper()
	s.seq++
	ts := fmt.Sprintf("%d.%06d", at.Unix(), s.seq)
	_, err := s.d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, permalink) VALUES (?, ?, ?, ?, ?)`,
		channel, ts, user, text, "https://acme.example.com/archives/"+ts)
	require.NoError(s.t, err)
	return ts
}

func (s *windowSeed) maxRowID() int64 {
	s.t.Helper()
	var id int64
	require.NoError(s.t, s.d.QueryRow(`SELECT COALESCE(MAX(rowid), 0) FROM messages`).Scan(&id))
	return id
}

func (s *windowSeed) read(q SlackWindowQuery) SlackWindow {
	s.t.Helper()
	q.Scope = WindowScopeMemberChannels
	if q.Now.IsZero() {
		q.Now = s.now
	}
	w, err := s.d.ReadSlackWindow(context.Background(), q)
	require.NoError(s.t, err)
	has, err := s.d.SlackWindowHasMaterial(context.Background(), q)
	require.NoError(s.t, err)
	assert.Equal(s.t, len(w.Messages) > 0, has, "SlackWindowHasMaterial agrees with ReadSlackWindow")
	return w
}

func windowTexts(w SlackWindow) []string {
	out := make([]string, 0, len(w.Messages))
	for _, m := range w.Messages {
		out = append(out, m.Text)
	}
	return out
}

func TestSlackWindow_MemberChannelsScope(t *testing.T) {
	s := newWindowSeed(t)
	at := s.now.Add(-time.Hour)
	s.user("1:U0ALICE", "alice", "Alice", "", "")
	s.user("1:U0MUTED", "muted", "Muted", "", "is_muted_for_llm = 1")
	s.channel("1:C0PRIV", "acme-infra", "private", true)
	s.channel("1:C0OUT", "acme-other", "public", false)
	s.channel("1:C0ARCH", "acme-old", "public", true)
	_, err := s.d.Exec(`UPDATE channels SET is_archived = 1 WHERE id = '1:C0ARCH'`)
	require.NoError(t, err)
	s.channel("1:C0MUTE", "acme-noise", "public", true)
	s.channel("1:D0ALICE", "D0ALICE", "dm", false)
	s.channel("1:D0MUTE", "D0MUTE", "dm", false)
	s.channel("1:G0ACME", "mpdm-owner--alice-1", "group_dm", false)
	_, err = s.d.Exec(`INSERT INTO channel_settings (channel_id, is_muted_for_llm) VALUES ('1:C0MUTE', 1), ('1:D0MUTE', 1)`)
	require.NoError(t, err)

	s.msg("1:C0ACME", "1:U0ALICE", "public in", at)
	s.msg("1:C0PRIV", "1:U0ALICE", "private in", at)
	s.msg("1:D0ALICE", "1:U0ALICE", "dm in", at)
	s.msg("1:G0ACME", "1:U0ALICE", "group dm in", at)
	s.msg("1:C0OUT", "1:U0ALICE", "non-member out", at)
	s.msg("1:C0ARCH", "1:U0ALICE", "archived out", at)
	s.msg("1:C0MUTE", "1:U0ALICE", "muted channel out", at)
	s.msg("1:D0MUTE", "1:U0ALICE", "muted dm out", at)
	s.msg("1:C0ACME", "1:U0MUTED", "muted author out", at)
	ts := s.msg("1:C0ACME", "1:U0ALICE", "deleted out", at)
	_, err = s.d.Exec(`UPDATE messages SET is_deleted = 1 WHERE ts = ?`, ts)
	require.NoError(t, err)
	s.msg("1:C0ACME", "1:U0ALICE", "", at)
	ts = s.msg("1:C0ACME", "1:U0ALICE", "joined out", at)
	_, err = s.d.Exec(`UPDATE messages SET subtype = 'channel_join' WHERE ts = ?`, ts)
	require.NoError(t, err)

	w := s.read(SlackWindowQuery{})
	assert.Equal(t, []string{"public in", "private in", "dm in", "group dm in"}, windowTexts(w))
	assert.False(t, w.Truncated)
	assert.Equal(t, s.maxRowID(), w.NextRowID)
	names := map[string]string{}
	for _, m := range w.Messages {
		names[m.ChannelID] = m.ChannelName
		assert.Equal(t, "Alice", m.Author)
	}
	assert.Equal(t, "#acme-release", names["1:C0ACME"])
	assert.Equal(t, "#acme-infra", names["1:C0PRIV"])
	assert.Equal(t, "group_dm", w.Messages[3].ChannelType)
}

func TestSlackWindow_HeadingNames(t *testing.T) {
	s := newWindowSeed(t)
	at := s.now.Add(-time.Hour)
	s.user("1:U0ALICE", "alice", "Alice", "", "")
	s.user("1:U0BOB", "bob", "", "Bob Real", "")
	s.user("1:U0CAROL", "carol", "", "", "")
	s.user("1:U0DAN", "dan", "Dan", "", "")
	s.user("2:U0ALICE", "alice", "Other Account Alice", "", "")
	s.channel("1:D0ALICE", "D0ALICE", "dm", false)
	_, err := s.d.Exec(`UPDATE channels SET dm_user_id = '1:U0ALICE' WHERE id = '1:D0ALICE'`)
	require.NoError(t, err)
	s.channel("1:D0GONE", "D0GONE", "dm", false)
	_, err = s.d.Exec(`UPDATE channels SET dm_user_id = '1:U0GONE' WHERE id = '1:D0GONE'`)
	require.NoError(t, err)
	s.channel("1:G0FOUR", "mpdm-alice--owner--bob--carol--dan-1", "group_dm", false)
	s.channel("1:G0TWO", "mpdm-alice--bob-2", "group_dm", false)
	s.channel("1:G0ODD", "acme-group", "group_dm", false)

	s.msg("1:D0ALICE", "1:U0ALICE", "a", at)
	s.msg("1:D0GONE", "1:U0ALICE", "b", at)
	s.msg("1:G0FOUR", "1:U0ALICE", "c", at)
	s.msg("1:G0TWO", "1:U0ALICE", "d", at)
	s.msg("1:G0ODD", "1:U0ALICE", "e", at)

	w := s.read(SlackWindowQuery{})
	require.Len(t, w.Messages, 5)
	assert.Equal(t, "@Alice", w.Messages[0].ChannelName)
	assert.Equal(t, "@Someone", w.Messages[1].ChannelName, "an unknown DM partner")
	assert.Equal(t, "Alice, Bob Real, carol +1", w.Messages[2].ChannelName, "the owner is left out; first three, then +N")
	assert.Equal(t, "Alice, Bob Real", w.Messages[3].ChannelName)
	assert.Equal(t, "acme-group", w.Messages[4].ChannelName, "a name not in Slack's mpdm form is kept")
}

func TestSlackWindow_BelowFloorPastCursorCounted(t *testing.T) {
	s := newWindowSeed(t)
	now := time.Date(s.now.Year(), s.now.Month(), s.now.Day(), 10, 0, 0, 0, time.Local)
	midnight := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.Local)
	s.msg("1:C0ACME", windowOwner, "read before", midnight.Add(-30*time.Minute))
	cursor := s.maxRowID()
	for i := 0; i < 3; i++ {
		s.msg("1:C0ACME", windowOwner, fmt.Sprintf("late %d", i), midnight.Add(-20*time.Minute+time.Duration(i)*time.Minute))
	}
	s.msg("1:C0ACME", windowOwner, "today", midnight.Add(time.Hour))

	w := s.read(SlackWindowQuery{AfterRowID: cursor, Floor: midnight, Now: now})
	assert.Equal(t, []string{"today"}, windowTexts(w))
	assert.Equal(t, 3, w.BelowFloor)
	assert.Equal(t, 0, w.SkippedOlder)
	assert.Equal(t, s.maxRowID(), w.NextRowID)

	w = s.read(SlackWindowQuery{Floor: midnight, Now: now})
	assert.Equal(t, []string{"today"}, windowTexts(w))
	assert.Equal(t, 0, w.BelowFloor, "no cursor counts nothing")
}

func TestSlackWindow_CursorIsArrivalOrder(t *testing.T) {
	s := newWindowSeed(t)
	s.channel("1:C0OUT", "acme-other", "public", false)
	s.msg("1:C0ACME", windowOwner, "second by time", s.now.Add(-time.Hour))
	s.msg("1:C0ACME", windowOwner, "first by time", s.now.Add(-2*time.Hour))
	s.msg("1:C0OUT", windowOwner, "out of scope", s.now.Add(-time.Minute))

	w := s.read(SlackWindowQuery{})
	assert.Equal(t, []string{"second by time", "first by time"}, windowTexts(w))
	require.Len(t, w.Messages, 2)
	assert.Less(t, w.Messages[0].RowID, w.Messages[1].RowID)
	assert.Equal(t, s.maxRowID(), w.NextRowID, "the cursor passes the out-of-scope row too")
	assert.Greater(t, w.NextRowID, w.Messages[1].RowID)

	again := s.read(SlackWindowQuery{AfterRowID: w.NextRowID})
	assert.Empty(t, again.Messages)
	assert.Equal(t, w.NextRowID, again.NextRowID)
}

func TestSlackWindow_LateSyncedChannelIsNotMissed(t *testing.T) {
	s := newWindowSeed(t)
	s.channel("1:C0LATE", "acme-infra", "public", true)
	day := s.now.Add(-6 * time.Hour)
	s.msg("1:C0ACME", windowOwner, "A at 10:00", day.Add(time.Hour))
	run1 := s.read(SlackWindowQuery{})
	assert.Equal(t, []string{"A at 10:00"}, windowTexts(run1))

	s.msg("1:C0LATE", windowOwner, "B at 09:30", day.Add(30*time.Minute))
	run2 := s.read(SlackWindowQuery{AfterRowID: run1.NextRowID})
	assert.Equal(t, []string{"B at 09:30"}, windowTexts(run2))
}

func TestSlackWindow_CapAt500MovesCursorToLastIncluded(t *testing.T) {
	s := newWindowSeed(t)
	for i := 0; i < 650; i++ {
		s.msg("1:C0ACME", windowOwner, fmt.Sprintf("line %d", i), s.now.Add(-time.Hour))
	}
	w := s.read(SlackWindowQuery{})
	require.Len(t, w.Messages, SlackWindowMaxMessages)
	assert.True(t, w.Truncated)
	assert.Equal(t, w.Messages[499].RowID, w.NextRowID)

	rest := s.read(SlackWindowQuery{AfterRowID: w.NextRowID})
	require.Len(t, rest.Messages, 150)
	assert.False(t, rest.Truncated)
	assert.Equal(t, "line 500", rest.Messages[0].Text)
	assert.Equal(t, s.maxRowID(), rest.NextRowID)
}

// The byte budget is below SlackWindowMaxTextChars for any text, so the char
// cap is exercised with the byte cap lifted.
func TestSlackWindow_CharCapCuts(t *testing.T) {
	s := newWindowSeed(t)
	text := strings.Repeat("a", 3000)
	for i := 0; i < 80; i++ {
		s.msg("1:C0ACME", windowOwner, text, s.now.Add(-time.Hour))
	}
	caps := slackWindowCaps{messages: SlackWindowMaxMessages, textChars: SlackWindowMaxTextChars, bytes: 1 << 30}
	w, err := s.d.readSlackWindow(context.Background(),
		SlackWindowQuery{Scope: WindowScopeMemberChannels, Now: s.now}, caps)
	require.NoError(t, err)
	require.Len(t, w.Messages, 66, "66 × 3000 = 198 000 runes; the 67th would cross 200 000")
	assert.True(t, w.Truncated)
	assert.Equal(t, w.Messages[65].RowID, w.NextRowID)
}

func TestSlackWindow_ByteBudgetCutsBeforeLLMLimit(t *testing.T) {
	s := newWindowSeed(t)
	text := strings.Repeat("ж", 2000)
	for i := 0; i < 500; i++ {
		s.msg("1:C0ACME", windowOwner, text, s.now.Add(-time.Hour))
	}
	w := s.read(SlackWindowQuery{})
	assert.True(t, w.Truncated)
	require.NotEmpty(t, w.Messages)
	// Every row is the same size (fixed-width ts, same text), so the window
	// holds exactly as many rows as fit.
	cost := slackWindowMessageBytes(w.Messages[0])
	total := 0
	for _, m := range w.Messages {
		require.Equal(t, cost, slackWindowMessageBytes(m))
		total += cost
	}
	assert.Len(t, w.Messages, SlackWindowMaxBytes/cost)
	assert.LessOrEqual(t, total, SlackWindowMaxBytes)
	assert.Greater(t, total+cost, SlackWindowMaxBytes, "the next row would have crossed the budget")
	assert.Equal(t, w.Messages[len(w.Messages)-1].RowID, w.NextRowID)
}

// slackWindowLLMRow is the primitive's row shape as llm() receives it.
type slackWindowLLMRow struct {
	ID        string `json:"id"`
	ChannelID string `json:"channel_id"`
	Channel   string `json:"channel"`
	Author    string `json:"author"`
	At        string `json:"at"`
	Time      string `json:"time"`
	Text      string `json:"text"`
	ThreadID  string `json:"thread_id"`
	Permalink string `json:"permalink"`
	ByOwner   bool   `json:"by_owner"`
	ToOwner   bool   `json:"to_owner"`
	Bot       bool   `json:"bot"`
}

func TestSlackWindow_JSONOfEscapedRowsFitsTheBudget(t *testing.T) {
	s := newWindowSeed(t)
	text := strings.Repeat("<@U0OWNER> глянь <https://example.com/a?b=1&c=2|ссылка> \"ок\"\n", 60)
	for i := 0; i < SlackWindowMaxMessages; i++ {
		s.msg("1:C0ACME", windowOwner, text, s.now.Add(-time.Hour))
	}
	w := s.read(SlackWindowQuery{})
	assert.True(t, w.Truncated)
	rows := make([]slackWindowLLMRow, 0, len(w.Messages))
	for _, m := range w.Messages {
		rows = append(rows, slackWindowLLMRow{
			ID: m.ID(), ChannelID: m.ChannelID, Channel: m.ChannelName, Author: m.Author,
			At: m.At.Format(time.RFC3339Nano), Time: m.At.Format("15:04"), Text: m.Text,
			ThreadID: m.ThreadID(), Permalink: m.Permalink, ByOwner: m.ByOwner, ToOwner: m.ToOwner, Bot: m.Bot,
		})
	}
	encoded, err := json.Marshal(rows)
	require.NoError(t, err)
	assert.LessOrEqual(t, len(encoded), SlackWindowMaxBytes)
	raw := 0
	for _, m := range w.Messages {
		raw += len(m.Text)
	}
	assert.Greater(t, len(encoded), raw+raw/4, "escaping makes the JSON well over the raw text")
}

func TestSlackWindow_RowOverheadCoversTheRowShape(t *testing.T) {
	empty, err := json.Marshal(slackWindowLLMRow{
		At: "2026-11-12T10:00:00.123456789+05:30", Time: strings.Repeat("x", 32),
	})
	require.NoError(t, err)
	// The row with every string value empty, plus the array comma; the
	// string values (with their quotes) are counted per field on top.
	assert.LessOrEqual(t, len(empty)+1, SlackWindowRowOverheadBytes)
}

func TestJSONStringBytesMatchesEncodingJSON(t *testing.T) {
	for _, s := range []string{
		"", "plain", "<@U0OWNER>", "<https://example.com/?a=1&b=2>", "quote \" back \\ slash",
		"line\nfeed\r\ttab\b\f", "\x00\x01\x1f\x7f", "кириллица", "emoji \U0001F600", "sep \u2028 \u2029",
		"bad \xff\xfe utf8", string([]byte{0xe2, 0x82}), "…",
	} {
		want, err := json.Marshal(s)
		require.NoError(t, err)
		assert.Equal(t, len(want), jsonStringBytes(s), "%q", s)
	}
}

func TestSlackWindow_SevenDaySkipCounted(t *testing.T) {
	s := newWindowSeed(t)
	s.msg("1:C0ACME", windowOwner, "read before", s.now.Add(-2*time.Hour))
	cursor := s.maxRowID()
	for i := 0; i < 3; i++ {
		s.msg("1:C0ACME", windowOwner, "old", s.now.Add(-9*24*time.Hour))
	}
	s.msg("1:C0ACME", windowOwner, "fresh 1", s.now.Add(-time.Hour))
	s.msg("1:C0ACME", windowOwner, "fresh 2", s.now.Add(-time.Minute))

	w := s.read(SlackWindowQuery{AfterRowID: cursor})
	assert.Equal(t, []string{"fresh 1", "fresh 2"}, windowTexts(w))
	assert.Equal(t, 3, w.SkippedOlder)
	assert.Equal(t, 0, w.BelowFloor)
	assert.Equal(t, s.maxRowID(), w.NextRowID)
}

func TestSlackWindow_SkippedRowsAfterACutAreNotCounted(t *testing.T) {
	s := newWindowSeed(t)
	s.msg("1:C0ACME", windowOwner, "seed", s.now.Add(-time.Hour))
	cursor := s.maxRowID()
	for i := 0; i < SlackWindowMaxMessages; i++ {
		s.msg("1:C0ACME", windowOwner, "fresh", s.now.Add(-time.Hour))
	}
	s.msg("1:C0ACME", windowOwner, "old after the last included", s.now.Add(-9*24*time.Hour))
	s.msg("1:C0ACME", windowOwner, "fresh past the cut", s.now.Add(-time.Hour))

	w := s.read(SlackWindowQuery{AfterRowID: cursor})
	assert.True(t, w.Truncated)
	assert.Equal(t, 0, w.SkippedOlder, "a skipped row past the cursor's new position is counted by the next read")
	next := s.read(SlackWindowQuery{AfterRowID: w.NextRowID})
	assert.Equal(t, 1, next.SkippedOlder)
	assert.Equal(t, []string{"fresh past the cut"}, windowTexts(next))
}

func TestSlackWindow_NoCursorStartsSevenDaysBackSilently(t *testing.T) {
	s := newWindowSeed(t)
	s.msg("1:C0ACME", windowOwner, "old", s.now.Add(-9*24*time.Hour))
	s.msg("1:C0ACME", windowOwner, "fresh", s.now.Add(-time.Hour))
	w := s.read(SlackWindowQuery{})
	assert.Equal(t, []string{"fresh"}, windowTexts(w))
	assert.Equal(t, 0, w.SkippedOlder)
	assert.Equal(t, s.maxRowID(), w.NextRowID)
}

func TestSlackWindow_FloorTodayExcludesEarlierMessages(t *testing.T) {
	s := newWindowSeed(t)
	now := time.Date(s.now.Year(), s.now.Month(), s.now.Day(), 9, 0, 0, 0, time.Local)
	midnight := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.Local)
	s.msg("1:C0ACME", windowOwner, "morning", midnight.Add(time.Hour))
	run1 := s.read(SlackWindowQuery{Floor: midnight, Now: now})
	assert.Equal(t, []string{"morning"}, windowTexts(run1))

	s.msg("1:C0ACME", windowOwner, "23:50 yesterday", midnight.Add(-10*time.Minute))
	run2 := s.read(SlackWindowQuery{AfterRowID: run1.NextRowID, Floor: midnight, Now: now})
	assert.Empty(t, run2.Messages)
	assert.Equal(t, 1, run2.BelowFloor)
	assert.Equal(t, 0, run2.SkippedOlder)
	assert.Equal(t, s.maxRowID(), run2.NextRowID)
}

func TestSlackWindow_TextCutAt4000Runes(t *testing.T) {
	s := newWindowSeed(t)
	s.msg("1:C0ACME", windowOwner, strings.Repeat("я", 5000), s.now.Add(-time.Hour))
	exact := strings.Repeat("b", SlackWindowTextRunes)
	s.msg("1:C0ACME", windowOwner, exact, s.now.Add(-time.Hour))
	w := s.read(SlackWindowQuery{})
	require.Len(t, w.Messages, 2)
	assert.Equal(t, SlackWindowTextRunes, utf8.RuneCountInString(w.Messages[0].Text))
	assert.True(t, strings.HasSuffix(w.Messages[0].Text, "…"))
	assert.True(t, strings.HasPrefix(w.Messages[0].Text, strings.Repeat("я", SlackWindowTextRunes-1)))
	assert.Equal(t, exact, w.Messages[1].Text, "a text at the limit is kept whole")
}

func TestSlackWindow_FlagsAndAuthor(t *testing.T) {
	s := newWindowSeed(t)
	at := s.now.Add(-time.Hour)
	s.user("1:U0REAL", "realonly", "", "Real Name", "")
	s.user("1:U0HANDLE", "handle", "", "", "")
	s.user("1:U0BOT", "deploybot", "Deploy Bot", "", "is_bot = 1")
	s.user("1:U0FORCED", "forced", "Forced", "", "is_bot_override = 1")
	s.user("1:U0NOTBOT", "notbot", "Not Bot", "", "is_bot = 1, is_bot_override = 0")
	s.msg("1:C0ACME", windowOwner, "mine", at)
	s.msg("1:C0ACME", "1:U0REAL", "real", at)
	s.msg("1:C0ACME", "1:U0HANDLE", "handle", at)
	s.msg("1:C0ACME", "1:U0BOT", "bot", at)
	s.msg("1:C0ACME", "1:U0FORCED", "forced", at)
	s.msg("1:C0ACME", "1:U0NOTBOT", "not bot", at)
	s.msg("1:C0ACME", "1:U0UNKNOWN", "unknown", at)
	s.msg("1:C0ACME", "", "no author", at)
	ts := s.msg("1:C0ACME", "1:U0NOTBOT", "integration post", at)
	_, err := s.d.Exec(`UPDATE messages SET subtype = 'bot_message' WHERE ts = ?`, ts)
	require.NoError(t, err)

	w := s.read(SlackWindowQuery{})
	require.Len(t, w.Messages, 9)
	type flags struct {
		author       string
		byOwner, bot bool
	}
	got := make([]flags, 0, len(w.Messages))
	for _, m := range w.Messages {
		got = append(got, flags{m.Author, m.ByOwner, m.Bot})
		assert.Equal(t, "public", m.ChannelType)
		assert.Equal(t, "https://acme.example.com/archives/"+m.TS, m.Permalink)
		assert.Equal(t, s.now.Add(-time.Hour).Unix(), m.At.Unix())
	}
	assert.Equal(t, []flags{
		{"Owner", true, false},
		{"Real Name", false, false},
		{"handle", false, false},
		{"Deploy Bot", false, true},
		{"Forced", false, true},
		{"Not Bot", false, false},
		{"Someone", false, false},
		{"Someone", false, true},
		{"Not Bot", false, true},
	}, got, "a bot_message subtype or no author is a bot whatever the user row says")
}

// History and thread syncs store no permalink: the window builds the link
// from the account's team domain (slack.com's archive link without one), and
// the byte budget counts it.
func TestSlackWindow_EmptyPermalinkGetsAFallbackLink(t *testing.T) {
	s := newWindowSeed(t)
	ts := s.msg("1:C0ACME", windowOwner, "history", s.now.Add(-time.Hour))
	_, err := s.d.Exec(`UPDATE messages SET permalink = ''`)
	require.NoError(t, err)
	w := s.read(SlackWindowQuery{})
	require.Len(t, w.Messages, 1)
	want := "https://acme.slack.com/archives/C0ACME/p" + strings.ReplaceAll(ts, ".", "")
	assert.Equal(t, want, w.Messages[0].Permalink)
	assert.GreaterOrEqual(t, slackWindowMessageBytes(w.Messages[0]), SlackWindowRowOverheadBytes+jsonStringBytes(want))

	_, err = s.d.Exec(`UPDATE slack_accounts SET team_domain = ''`)
	require.NoError(t, err)
	w = s.read(SlackWindowQuery{})
	require.Len(t, w.Messages, 1)
	assert.Equal(t, "https://slack.com/archives/C0ACME/p"+strings.ReplaceAll(ts, ".", ""), w.Messages[0].Permalink)
}

// messages rowids are reused once the table is emptied (ClearSlackData, an
// account purge): a cursor above the newest rowid is reset, not kept, so new
// messages are read.
func TestSlackWindow_CursorAboveNewestRowIDResets(t *testing.T) {
	s := newWindowSeed(t)
	now := time.Date(s.now.Year(), s.now.Month(), s.now.Day(), 10, 0, 0, 0, time.Local)
	midnight := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.Local)
	s.msg("1:C0ACME", windowOwner, "gone", midnight.Add(time.Hour))
	_, err := s.d.Exec(`DELETE FROM messages`)
	require.NoError(t, err)
	s.msg("1:C0ACME", windowOwner, "before midnight", midnight.Add(-time.Hour))
	for i := 0; i < 3; i++ {
		s.msg("1:C0ACME", windowOwner, fmt.Sprintf("new %d", i), midnight.Add(time.Duration(i+1)*time.Hour))
	}
	require.Less(t, s.maxRowID(), int64(1000))

	w := s.read(SlackWindowQuery{AfterRowID: 1000, Floor: midnight, Now: now})
	assert.Equal(t, []string{"new 0", "new 1", "new 2"}, windowTexts(w))
	assert.True(t, w.CursorReset)
	assert.Equal(t, s.maxRowID(), w.NextRowID)
	assert.Equal(t, 0, w.BelowFloor, "a reset cursor counts nothing below the floor")
	assert.Equal(t, 0, w.SkippedOlder)
	has, err := s.d.SlackWindowHasMaterial(context.Background(),
		SlackWindowQuery{Scope: WindowScopeMemberChannels, AfterRowID: 1000, Floor: midnight, Now: now})
	require.NoError(t, err)
	assert.True(t, has)

	w = s.read(SlackWindowQuery{AfterRowID: w.NextRowID, Floor: midnight, Now: now})
	assert.False(t, w.CursorReset, "a cursor at the newest rowid is kept")
	assert.Empty(t, w.Messages)
}

func TestSlackWindow_RemovedAccountReadsNothing(t *testing.T) {
	for _, tc := range []struct{ name, set string }{
		{"removed", "status = 'removed'"},
		{"purged", "status = 'purged'"},
		{"disabled", "enabled = 0"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := newWindowSeed(t)
			s.msg("1:C0ACME", windowOwner, "hidden", s.now.Add(-time.Hour))
			_, err := s.d.Exec(`UPDATE slack_accounts SET ` + tc.set + ` WHERE id = 1`)
			require.NoError(t, err)
			w := s.read(SlackWindowQuery{})
			assert.Empty(t, w.Messages)
			assert.Equal(t, s.maxRowID(), w.NextRowID)
		})
	}
	t.Run("a channel with no account row", func(t *testing.T) {
		s := newWindowSeed(t)
		s.channel("3:C0ACME", "acme-release", "public", true)
		s.msg("3:C0ACME", "3:U0OWNER", "orphan", s.now.Add(-time.Hour))
		assert.Empty(t, s.read(SlackWindowQuery{}).Messages)
	})
}

func TestSlackWindow_HasMaterialMatchesRead(t *testing.T) {
	s := newWindowSeed(t)
	ctx := context.Background()
	q := SlackWindowQuery{Scope: WindowScopeMemberChannels, Now: s.now}
	has, err := s.d.SlackWindowHasMaterial(ctx, q)
	require.NoError(t, err)
	assert.False(t, has, "an empty database")

	s.msg("1:C0ACME", windowOwner, "old", s.now.Add(-9*24*time.Hour))
	assert.Empty(t, s.read(SlackWindowQuery{}).Messages, "older than seven days")
	s.msg("1:C0ACME", windowOwner, "fresh", s.now.Add(-time.Hour))
	w := s.read(SlackWindowQuery{})
	assert.Len(t, w.Messages, 1)
	assert.Empty(t, s.read(SlackWindowQuery{AfterRowID: w.NextRowID}).Messages, "past the cursor")
	assert.Empty(t, s.read(SlackWindowQuery{Floor: s.now}).Messages, "below the floor")

	_, err = s.d.ReadSlackWindow(ctx, SlackWindowQuery{Scope: "narrow", Now: s.now})
	require.Error(t, err, "an unknown scope is refused")
	_, err = s.d.SlackWindowHasMaterial(ctx, SlackWindowQuery{Scope: WindowScopeMemberChannels})
	require.Error(t, err, "a zero Now is refused")
}

func TestLastAutomationRunCreatedAt(t *testing.T) {
	d := openTestDB(t)
	ctx := context.Background()
	id := seedBuiltinRow(t, d, "slack-today", "slack-today", "c1", "a1")
	other := seedBuiltinRow(t, d, "morning-brief", "morning-brief", "c2", "a2")

	_, ok, err := d.LastAutomationRunCreatedAt(ctx, id, TriggerSync)
	require.NoError(t, err)
	assert.False(t, ok, "no runs")

	_, err = d.Exec(`INSERT INTO automation_runs (automation_id, trigger, status, queued_at) VALUES
		(?, 'sync', 'succeeded', '2026-10-22T08:00:00Z'),
		(?, 'sync', 'failed', '2026-10-22T09:00:00Z'),
		(?, 'manual', 'succeeded', '2026-10-22T11:00:00Z'),
		(?, 'sync', 'succeeded', '2026-10-22T12:00:00Z')`, id, id, id, other)
	require.NoError(t, err)

	at, ok, err := d.LastAutomationRunCreatedAt(ctx, id, TriggerSync)
	require.NoError(t, err)
	require.True(t, ok)
	assert.Equal(t, time.Date(2026, 10, 22, 9, 0, 0, 0, time.UTC), at, "newest sync run, any status; other triggers and automations ignored")

	at, ok, err = d.LastAutomationRunCreatedAt(ctx, id, TriggerSync, RunSucceeded)
	require.NoError(t, err)
	require.True(t, ok)
	assert.Equal(t, time.Date(2026, 10, 22, 8, 0, 0, 0, time.UTC), at)

	at, ok, err = d.LastAutomationRunCreatedAt(ctx, id, TriggerSync, RunFailed)
	require.NoError(t, err)
	require.True(t, ok)
	assert.Equal(t, time.Date(2026, 10, 22, 9, 0, 0, 0, time.UTC), at)

	_, ok, err = d.LastAutomationRunCreatedAt(ctx, id, TriggerSync, RunCancelled)
	require.NoError(t, err)
	assert.False(t, ok)
}

func TestSlackWindowMessage_IDs(t *testing.T) {
	root := SlackWindowMessage{ChannelID: "1:C0ACME", TS: "1731400000.000100", ThreadTS: "1731400000.000100"}
	reply := SlackWindowMessage{ChannelID: "1:C0ACME", TS: "1731400100.000200", ThreadTS: "1731400000.000100"}
	plain := SlackWindowMessage{ChannelID: "1:C0ACME", TS: "1731400200.000300"}
	assert.Equal(t, "1:C0ACME/1731400000.000100", root.ID())
	assert.Empty(t, root.ThreadID(), "a thread parent is not a reply")
	assert.Equal(t, root.ID(), reply.ThreadID(), "a reply's thread id is its parent's id")
	assert.Empty(t, plain.ThreadID())
}
