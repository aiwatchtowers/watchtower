package kb

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/slack"
)

const (
	slackRange = 20000
	slackTail  = 48 * time.Hour
)

var slackSkipSubtypes = map[string]bool{
	"channel_join": true, "channel_leave": true, "channel_purpose": true, "channel_topic": true,
	"channel_name": true, "channel_archive": true, "channel_unarchive": true, "group_join": true,
	"group_leave": true, "bot_add": true, "bot_remove": true, "pinned_item": true, "unpinned_item": true,
}

// slackThreadQuery loads one thread's messages. The unary "+" on ts_unix in
// ORDER BY is load-bearing: it disables SQLite's use of
// idx_messages_channel_ts_unix(channel_id, ts_unix) to satisfy the sort,
// which otherwise wins the planner's pick over idx_messages_thread(channel_id,
// thread_ts) and forces a scan of every message in the channel to filter by
// thread_ts — measured 7.2s vs 0.024s per thread on the largest channel of a
// 740k-message DB. See TestSlack_ThreadQueryUsesThreadIndex.
const slackThreadQuery = `SELECT ts, user_id, COALESCE(text,''), COALESCE(subtype,''), permalink, ts_unix
	FROM messages WHERE channel_id = ? AND thread_ts = ? AND is_deleted = 0 ORDER BY +ts_unix, ts`

// slackDayQuery loads one channel-day's top-level messages; the ts_unix range
// already steers the planner onto idx_messages_channel_ts_unix without any
// ORDER BY trick. See TestSlack_DayQueryUsesChannelTsUnixIndex.
const slackDayQuery = `SELECT ts, user_id, COALESCE(text,''), COALESCE(subtype,''), permalink, ts_unix
	FROM messages WHERE channel_id = ? AND (thread_ts IS NULL OR thread_ts = '') AND is_deleted = 0
	AND ts_unix >= ? AND ts_unix < ? ORDER BY ts_unix, ts`

// slackSource renders Slack thread and channel-day documents. Names and
// channel titles are cached per instance so a huge channel-day resolves
// each participant once, not once per message.
type slackSource struct {
	names    map[string]string // namespaced user id -> display name
	channels map[string]string // channel id -> title
}

func newSlackSource() *slackSource {
	return &slackSource{names: map[string]string{}, channels: map[string]string{}}
}

func (*slackSource) Name() string { return "slack" }

// reconcilesDaily: Slack's Keys() scans every message, so its reconcile runs
// once per UTC day (a deleted Slack document leaves search within a day).
func (*slackSource) reconcilesDaily() {}

func slackThreadRef(channelID, threadTS string) string {
	return "slack:thread:" + channelID + ":" + threadTS
}

func slackDayRef(channelID, day string) string { return "slack:day:" + channelID + ":" + day }

// parseSlackRef splits a Slack ref from the right: channel ids contain ':'.
func parseSlackRef(ref string) (kind, channelID, tail string, ok bool) {
	for _, k := range []string{"thread", "day"} {
		if rest, found := splitRef(ref, "slack:"+k+":"); found {
			i := strings.LastIndex(rest, ":")
			if i <= 0 || i == len(rest)-1 {
				return "", "", "", false
			}
			return k, rest[:i], rest[i+1:], true
		}
	}
	return "", "", "", false
}

func slackKeyFor(channelID, threadTS string, tsUnix float64) string {
	if threadTS != "" {
		return slackThreadRef(channelID, threadTS)
	}
	return slackDayRef(channelID, time.Unix(int64(tsUnix), 0).UTC().Format("2006-01-02"))
}

func (s *slackSource) Changed(ctx context.Context, q Queryer, cursor string, now time.Time) ([]string, string, bool, error) {
	lo, _ := strconv.ParseInt(cursor, 10, 64)
	var maxID int64
	if err := q.QueryRowContext(ctx, `SELECT COALESCE(MAX(rowid), 0) FROM messages`).Scan(&maxID); err != nil {
		return nil, cursor, false, err
	}
	if lo > maxID {
		// The messages table was wiped or restored from an older copy: the
		// stored rowid cursor points past every row, so start over (the
		// content-hash gate keeps the re-render write-free).
		lo = 0
	}
	hi := lo + slackRange
	if hi > maxID {
		hi = maxID
	}
	set := map[string]bool{}
	if hi > lo {
		if err := s.collectKeys(ctx, q, set, `SELECT channel_id, COALESCE(thread_ts, ''), ts_unix FROM messages WHERE rowid > ? AND rowid <= ?`, lo, hi); err != nil {
			return nil, cursor, false, err
		}
	}
	done := hi >= maxID
	if done {
		since := float64(now.Add(-slackTail).Unix())
		if err := s.collectKeys(ctx, q, set, `SELECT channel_id, COALESCE(thread_ts, ''), ts_unix FROM messages WHERE ts_unix >= ?`, since); err != nil {
			return nil, cursor, false, err
		}
	}
	keys := make([]string, 0, len(set))
	for k := range set {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys, strconv.FormatInt(hi, 10), done, nil
}

func (s *slackSource) collectKeys(ctx context.Context, q Queryer, set map[string]bool, query string, args ...any) error {
	rows, err := q.QueryContext(ctx, query, args...)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var ch, th string
		var tsUnix float64
		if err := rows.Scan(&ch, &th, &tsUnix); err != nil {
			return err
		}
		set[slackKeyFor(ch, th, tsUnix)] = true
		if th != "" {
			// Thread promotion: when a top-level message gains its first reply,
			// Slack sets the root's thread_ts in place (no new rowid), so the
			// root's channel-day document — which still lists it as top-level —
			// must be re-rendered too. thread_ts is the root's own ts.
			if rootUnix, err := strconv.ParseFloat(th, 64); err == nil {
				set[slackDayRef(ch, time.Unix(int64(rootUnix), 0).UTC().Format("2006-01-02"))] = true
			}
		}
	}
	return rows.Err()
}

func (s *slackSource) Keys(ctx context.Context, q Queryer) ([]string, error) {
	var out []string
	threadKeys, err := func() ([]string, error) {
		rows, err := q.QueryContext(ctx, `SELECT DISTINCT channel_id, thread_ts FROM messages
			WHERE thread_ts IS NOT NULL AND thread_ts != '' AND is_deleted = 0`)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		var keys []string
		for rows.Next() {
			var ch, th string
			if err := rows.Scan(&ch, &th); err != nil {
				return nil, err
			}
			keys = append(keys, slackThreadRef(ch, th))
		}
		return keys, rows.Err()
	}()
	if err != nil {
		return nil, err
	}
	out = append(out, threadKeys...)

	rows, err := q.QueryContext(ctx, `SELECT DISTINCT channel_id, date(ts_unix, 'unixepoch') FROM messages
		WHERE (thread_ts IS NULL OR thread_ts = '') AND is_deleted = 0`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var ch, day string
		if err := rows.Scan(&ch, &day); err != nil {
			return nil, err
		}
		out = append(out, slackDayRef(ch, day))
	}
	return out, rows.Err()
}

func (s *slackSource) Progress(ctx context.Context, q Queryer, cursor string) (float64, error) {
	var maxID int64
	if err := q.QueryRowContext(ctx, `SELECT COALESCE(MAX(rowid), 0) FROM messages`).Scan(&maxID); err != nil {
		return 0, err
	}
	if maxID == 0 {
		return 1, nil
	}
	cur, _ := strconv.ParseInt(cursor, 10, 64)
	if cur >= maxID {
		return 1, nil
	}
	return float64(cur) / float64(maxID), nil
}

// Backfilling reports whether the index is behind sync by more than one
// range — a real backfill, not the handful of messages synced since the last
// cycle — which is when search results carry an "NN% indexed" note.
func (s *slackSource) Backfilling(ctx context.Context, q Queryer, cursor string) (bool, error) {
	var maxID int64
	if err := q.QueryRowContext(ctx, `SELECT COALESCE(MAX(rowid), 0) FROM messages`).Scan(&maxID); err != nil {
		return false, err
	}
	cur, _ := strconv.ParseInt(cursor, 10, 64)
	return maxID-cur > slackRange, nil
}

type slackRow struct {
	ts, userID, text, subtype, permalink string
	tsUnix                               float64
}

func (s *slackSource) Build(ctx context.Context, q Queryer, key string) (*Doc, error) {
	kind, channelID, tail, ok := parseSlackRef(key)
	if !ok {
		return nil, nil
	}
	var rows []slackRow
	var err error
	if kind == "thread" {
		rows, err = s.loadRows(ctx, q, slackThreadQuery, channelID, tail)
	} else {
		day, perr := time.Parse("2006-01-02", tail)
		if perr != nil {
			return nil, nil //nolint:nilerr // malformed day in ref: treat as missing doc, not an error
		}
		from := float64(day.Unix())
		rows, err = s.loadRows(ctx, q, slackDayQuery, channelID, from, from+86400)
	}
	if err != nil {
		return nil, fmt.Errorf("kb slack %s: %w", key, err)
	}
	if len(rows) == 0 {
		return nil, nil
	}
	acct, _, _ := slack.SplitAccountID(channelID)
	chTitle, err := s.channelTitle(ctx, q, channelID)
	if err != nil {
		return nil, err
	}
	doc := &Doc{ID: key, Source: "slack", Link: rows[0].permalink}
	var metaNames []string
	seen := map[string]bool{}
	var latest float64
	// threadHeadline is the first message line with text (a file share root
	// has none); a thread without any text is titled by its author.
	threadHeadline, headlineSet := "", false
	for i, r := range rows {
		name, err := s.userName(ctx, q, r.userID)
		if err != nil {
			return nil, err
		}
		text, err := s.resolveText(ctx, q, acct, r.text)
		if err != nil {
			return nil, err
		}
		if i == 0 {
			threadHeadline = "thread by " + name
		}
		if line := firstLine(strings.TrimSpace(text), 80); !headlineSet && line != "" {
			threadHeadline, headlineSet = line, true
		}
		doc.Sections = append(doc.Sections, Section{Text: name + ": " + text, Anchor: r.ts})
		if !seen[name] {
			seen[name] = true
			metaNames = append(metaNames, name)
		}
		if r.tsUnix > latest {
			latest = r.tsUnix
		}
	}
	doc.Time = time.Unix(int64(latest), 0).UTC()
	doc.Meta = strings.Join(append([]string{chTitle}, metaNames...), " ")
	if kind == "thread" {
		doc.Title = chTitle + " — " + threadHeadline
		doc.Anchor = map[string]string{"channel_id": channelID, "thread_ts": tail}
	} else {
		doc.Title = chTitle + " · " + tail
		doc.Anchor = map[string]string{"channel_id": channelID, "date": tail}
	}
	return doc, nil
}

// loadRows reads all matching rows, dropping skip-listed subtypes.
func (s *slackSource) loadRows(ctx context.Context, q Queryer, query string, args ...any) ([]slackRow, error) {
	rs, err := q.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rs.Close()
	var out []slackRow
	for rs.Next() {
		var r slackRow
		if err := rs.Scan(&r.ts, &r.userID, &r.text, &r.subtype, &r.permalink, &r.tsUnix); err != nil {
			return nil, err
		}
		if slackSkipSubtypes[r.subtype] {
			continue
		}
		out = append(out, r)
	}
	return out, rs.Err()
}

func (s *slackSource) userName(ctx context.Context, q Queryer, id string) (string, error) {
	if id == "" {
		return "unknown", nil
	}
	if n, ok := s.names[id]; ok {
		return n, nil
	}
	names, err := queryStrings(ctx, q, `SELECT COALESCE(NULLIF(display_name,''), NULLIF(real_name,''), name) FROM users WHERE id = ?`, id)
	if err != nil {
		return "", err
	}
	name := id
	if _, raw, ok := slack.SplitAccountID(id); ok {
		name = raw
	}
	if len(names) > 0 && names[0] != "" {
		name = names[0]
	}
	s.names[id] = name
	return name, nil
}

// resolveText resolves mention markup; ids are looked up (and cached) before
// the regex replacement so the callback never queries.
func (s *slackSource) resolveText(ctx context.Context, q Queryer, acct int64, text string) (string, error) {
	resolved := map[string]string{}
	for _, m := range reUserMention.FindAllStringSubmatch(text, -1) {
		raw := m[1]
		if _, done := resolved[raw]; done || m[2] != "" {
			continue
		}
		id := slack.Namespace(acct, raw)
		if acct == 0 {
			id = raw
		}
		cached, ok := s.names[id]
		if !ok {
			names, err := queryStrings(ctx, q, `SELECT COALESCE(NULLIF(display_name,''), NULLIF(real_name,''), name) FROM users WHERE id = ? OR id LIKE '%:' || ? ORDER BY id = ? DESC LIMIT 1`, id, raw, id)
			if err != nil {
				return "", err
			}
			if len(names) > 0 {
				cached = names[0]
			}
			s.names[id] = cached
		}
		if cached == id || cached == raw {
			cached = ""
		}
		resolved[raw] = cached
	}
	return ResolveSlackMarkup(text, func(raw string) string { return resolved[raw] }), nil
}

func (s *slackSource) channelTitle(ctx context.Context, q Queryer, channelID string) (string, error) {
	if t, ok := s.channels[channelID]; ok {
		return t, nil
	}
	var name, typ, dmUser string
	err := q.QueryRowContext(ctx, `SELECT COALESCE(name,''), COALESCE(type,''), COALESCE(dm_user_id,'') FROM channels WHERE id = ?`, channelID).
		Scan(&name, &typ, &dmUser)
	title := "#" + channelID
	switch {
	case errors.Is(err, sql.ErrNoRows):
		// unknown channel: keep the id
	case err != nil:
		// a real DB error (busy, canceled ctx, I/O) must not be swallowed
		// into a degraded title that the content-hash gate then persists.
		return "", fmt.Errorf("kb slack channel %s: %w", channelID, err)
	case typ == "dm" || typ == "im": // "im" is defensive: channels.type CHECK only allows dm/group_dm today
		who, uerr := s.userName(ctx, q, dmUser)
		if uerr != nil {
			return "", uerr
		}
		title = "DM with " + who
	case name != "":
		title = "#" + name
	}
	s.channels[channelID] = title
	return title, nil
}

func firstLine(s string, maxRunes int) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	r := []rune(strings.TrimSpace(s))
	if len(r) > maxRunes {
		r = r[:maxRunes]
	}
	return string(r)
}
