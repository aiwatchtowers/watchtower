package db

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

// CatchupItem is one gathered source row, display-ready for the compose prompt
// and resolvable by (Area, ID) for the recap's refs.
type CatchupItem struct {
	Area      string // digests|streams|recaps|transcripts|decisions|inbox|tracks|targets
	ID        int
	Title     string // short label (channel name, subject, meeting title…)
	Body      string // trimmed content for the prompt
	Meta      string // provenance line: "#chan · to 17:40", "gmail · acct", sender name…
	ChannelID string // learned-rule scope hint (digests, inbox)
	SenderID  string // learned-rule scope hint (inbox)
}

// unixToISO renders a Unix timestamp as the UTC ISO8601 form the ISO-dated
// tables (stream_digests, meeting_recaps, inbox_items, tracks…) store.
func unixToISO(ts float64) string {
	return time.Unix(int64(ts), 0).UTC().Format("2006-01-02T15:04:05Z")
}

// ListCatchupDigests returns channel digests overlapping [from, to], newest
// first, each with its topics folded into Body ("Title: summary" lines).
func (db *DB) ListCatchupDigests(from, to float64, limit int) ([]CatchupItem, error) {
	out, err := db.listCatchupDigestRows(from, to, limit)
	if err != nil {
		return nil, err
	}
	// Topics are fetched only after the digest cursor is closed: the pool holds
	// a single SQLite connection (db.Open sets MaxOpenConns(1)), so a nested
	// query inside the row loop would deadlock waiting for itself.
	for i := range out {
		topics, err := db.GetDigestTopics(out[i].ID)
		if err != nil {
			return nil, fmt.Errorf("loading topics for digest %d: %w", out[i].ID, err)
		}
		var b strings.Builder
		b.WriteString(out[i].Body)
		for j, t := range topics {
			if j >= 5 {
				break
			}
			fmt.Fprintf(&b, "\n- %s: %s", t.Title, t.Summary)
		}
		out[i].Body = b.String()
	}
	return out, nil
}

// listCatchupDigestRows gathers the digest rows themselves; Body holds the bare
// summary until ListCatchupDigests folds the topics in.
func (db *DB) listCatchupDigestRows(from, to float64, limit int) ([]CatchupItem, error) {
	rows, err := db.Query(`
		SELECT d.id, d.channel_id, COALESCE(c.name, ''), d.summary, d.period_to, d.message_count
		FROM digests d LEFT JOIN channels c ON c.id = d.channel_id
		WHERE d.type = 'channel' AND d.period_to > ? AND d.period_from < ?
		ORDER BY d.period_to DESC LIMIT ?`, from, to, limit)
	if err != nil {
		return nil, fmt.Errorf("listing catchup digests: %w", err)
	}
	defer rows.Close()
	var out []CatchupItem
	for rows.Next() {
		var it CatchupItem
		var name string
		var periodTo float64
		var msgs int
		if err := rows.Scan(&it.ID, &it.ChannelID, &name, &it.Body, &periodTo, &msgs); err != nil {
			return nil, fmt.Errorf("scanning catchup digest: %w", err)
		}
		it.Area = "digests"
		it.Title = "#" + name
		if name == "" {
			it.Title = it.ChannelID
		}
		it.Meta = fmt.Sprintf("%d messages · to %s", msgs, time.Unix(int64(periodTo), 0).Local().Format("Mon 15:04"))
		out = append(out, it)
	}
	return out, rows.Err()
}

// ListCatchupStreams returns Gmail/Jira stream digests overlapping the window.
// Body is the topics_json rendered as "Title: summary" lines.
func (db *DB) ListCatchupStreams(from, to float64, limit int) ([]CatchupItem, error) {
	rows, err := db.Query(`
		SELECT id, source, account_id, scope, topics_json, period_to
		FROM stream_digests
		WHERE period_to > ? AND period_from < ?
		ORDER BY period_to DESC LIMIT ?`, unixToISO(from), unixToISO(to), limit)
	if err != nil {
		return nil, fmt.Errorf("listing catchup streams: %w", err)
	}
	defer rows.Close()
	var out []CatchupItem
	for rows.Next() {
		var it CatchupItem
		var source, scope, topicsJSON, periodTo string
		var accountID int64
		if err := rows.Scan(&it.ID, &source, &accountID, &scope, &topicsJSON, &periodTo); err != nil {
			return nil, fmt.Errorf("scanning catchup stream: %w", err)
		}
		it.Area = "streams"
		it.Title = source
		if scope != "" {
			it.Title += " · " + scope
		}
		it.Body = renderStreamTopics(topicsJSON)
		it.Meta = fmt.Sprintf("%s account %d · to %s", source, accountID, periodTo)
		out = append(out, it)
	}
	return out, rows.Err()
}

// renderStreamTopics turns stream_digests.topics_json into "Title: summary" lines.
func renderStreamTopics(topicsJSON string) string {
	var topics []struct {
		Title   string `json:"title"`
		Summary string `json:"summary"`
	}
	if err := json.Unmarshal([]byte(topicsJSON), &topics); err != nil {
		return ""
	}
	lines := make([]string, 0, len(topics))
	for _, t := range topics {
		lines = append(lines, t.Title+": "+t.Summary)
	}
	return strings.Join(lines, "\n")
}

// ListCatchupMeetings returns meeting recaps (area "recaps") followed by ad-hoc
// transcript summaries (area "transcripts") created inside the window. Meetings
// are keyed on the recap's created_at because calendar_events retains only ~24h
// of past events while recaps survive (spec §5.2). Title resolution for a recap:
// calendar event title → linked transcript title → "Meeting".
func (db *DB) ListCatchupMeetings(from, to float64, limit int) ([]CatchupItem, error) {
	fromISO, toISO := unixToISO(from), unixToISO(to)
	recaps, err := db.listCatchupRecaps(fromISO, toISO, limit)
	if err != nil {
		return nil, err
	}
	transcripts, err := db.listCatchupTranscripts(fromISO, toISO, limit)
	if err != nil {
		return nil, err
	}
	return append(recaps, transcripts...), nil
}

func (db *DB) listCatchupRecaps(fromISO, toISO string, limit int) ([]CatchupItem, error) {
	rows, err := db.Query(`
		SELECT r.id, COALESCE(e.title, ''), COALESCE(t.title, ''), r.recap_json, r.created_at
		FROM meeting_recaps r
		LEFT JOIN calendar_events e ON e.id = r.event_id
		LEFT JOIN meeting_transcripts t ON t.id = r.transcript_id
		WHERE r.created_at > ? AND r.created_at <= ?
		ORDER BY r.created_at ASC LIMIT ?`, fromISO, toISO, limit)
	if err != nil {
		return nil, fmt.Errorf("listing catchup recaps: %w", err)
	}
	defer rows.Close()
	var out []CatchupItem
	for rows.Next() {
		var it CatchupItem
		var eventTitle, transcriptTitle, recapJSON, createdAt string
		if err := rows.Scan(&it.ID, &eventTitle, &transcriptTitle, &recapJSON, &createdAt); err != nil {
			return nil, fmt.Errorf("scanning catchup recap: %w", err)
		}
		it.Area = "recaps"
		it.Title = firstNonEmpty(eventTitle, transcriptTitle, "Meeting")
		it.Body = renderRecapJSON(recapJSON)
		it.Meta = "meeting · " + createdAt
		out = append(out, it)
	}
	return out, rows.Err()
}

func (db *DB) listCatchupTranscripts(fromISO, toISO string, limit int) ([]CatchupItem, error) {
	rows, err := db.Query(`
		SELECT id, title, COALESCE(summary_json, ''), created_at
		FROM meeting_transcripts
		WHERE event_id IS NULL AND summary_json IS NOT NULL AND created_at > ? AND created_at <= ?
		ORDER BY created_at ASC LIMIT ?`, fromISO, toISO, limit)
	if err != nil {
		return nil, fmt.Errorf("listing catchup transcripts: %w", err)
	}
	defer rows.Close()
	var out []CatchupItem
	for rows.Next() {
		var it CatchupItem
		var summaryJSON, createdAt string
		if err := rows.Scan(&it.ID, &it.Title, &summaryJSON, &createdAt); err != nil {
			return nil, fmt.Errorf("scanning catchup transcript: %w", err)
		}
		it.Area = "transcripts"
		it.Body = renderRecapJSON(summaryJSON)
		it.Meta = "ad-hoc recording · " + createdAt
		out = append(out, it)
	}
	return out, rows.Err()
}

// firstNonEmpty returns the first non-empty value, "" when all are empty.
func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}

// renderRecapJSON renders a meeting recap (summary + key_decisions +
// action_items, the internal/meeting RecapResult shape) as prompt text.
func renderRecapJSON(raw string) string {
	var r struct {
		Summary      string   `json:"summary"`
		KeyDecisions []string `json:"key_decisions"`
		ActionItems  []string `json:"action_items"`
	}
	if err := json.Unmarshal([]byte(raw), &r); err != nil {
		return ""
	}
	var b strings.Builder
	b.WriteString(r.Summary)
	if len(r.KeyDecisions) > 0 {
		b.WriteString("\nDecisions: " + strings.Join(r.KeyDecisions, "; "))
	}
	if len(r.ActionItems) > 0 {
		b.WriteString("\nAction items: " + strings.Join(r.ActionItems, "; "))
	}
	return b.String()
}

// ListCatchupDecisions returns ledger decisions with a mention inside the window
// (said_at, or created_at when said_at is empty), newest mention first. Body is
// the essence; Meta carries the latest in-window quote and author.
//
// The MAX() over the mention timestamp sits in the SELECT list, not only in the
// ORDER BY: that is what makes SQLite's bare-column rule resolve m.quote,
// m.author and m.source from the LATEST in-window mention of each decision.
func (db *DB) ListCatchupDecisions(from, to float64, limit int) ([]CatchupItem, error) {
	fromISO, toISO := unixToISO(from), unixToISO(to)
	rows, err := db.Query(`
		SELECT i.id, i.title, i.essence, m.quote, m.author, m.source,
		       MAX(CASE WHEN m.said_at <> '' THEN m.said_at ELSE m.created_at END) AS last_at
		FROM ideas i
		JOIN idea_mentions m ON m.idea_id = i.id
		WHERE i.kind = 'decision'
		  AND CASE WHEN m.said_at <> '' THEN m.said_at ELSE m.created_at END > ?
		  AND CASE WHEN m.said_at <> '' THEN m.said_at ELSE m.created_at END <= ?
		GROUP BY i.id
		ORDER BY MAX(CASE WHEN m.said_at <> '' THEN m.said_at ELSE m.created_at END) DESC
		LIMIT ?`, fromISO, toISO, limit)
	if err != nil {
		return nil, fmt.Errorf("listing catchup decisions: %w", err)
	}
	defer rows.Close()
	var out []CatchupItem
	for rows.Next() {
		var it CatchupItem
		var quote, author, source, lastAt string
		if err := rows.Scan(&it.ID, &it.Title, &it.Body, &quote, &author, &source, &lastAt); err != nil {
			return nil, fmt.Errorf("scanning catchup decision: %w", err)
		}
		it.Area = "decisions"
		it.Meta = fmt.Sprintf("%s · %s: %q", source, author, quote)
		out = append(out, it)
	}
	return out, rows.Err()
}

// ListCatchupInbox returns actionable, still-open inbox items created inside
// the window: the things that arrived for the owner while away.
func (db *DB) ListCatchupInbox(from, to float64, limit int) ([]CatchupItem, error) {
	rows, err := db.Query(`
		SELECT i.id, i.trigger_type, i.snippet, i.channel_id, i.sender_user_id,
		       COALESCE(NULLIF(u.display_name, ''), NULLIF(u.real_name, ''), u.name, i.sender_user_id),
		       COALESCE(c.name, '')
		FROM inbox_items i
		LEFT JOIN users u ON u.id = i.sender_user_id
		LEFT JOIN channels c ON c.id = i.channel_id
		WHERE i.item_class = 'actionable' AND i.status IN ('pending','snoozed')
		  AND i.created_at > ? AND i.created_at <= ?
		ORDER BY CASE i.priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END, i.created_at DESC
		LIMIT ?`, unixToISO(from), unixToISO(to), limit)
	if err != nil {
		return nil, fmt.Errorf("listing catchup inbox: %w", err)
	}
	defer rows.Close()
	var out []CatchupItem
	for rows.Next() {
		var it CatchupItem
		var sender, channel string
		if err := rows.Scan(&it.ID, &it.Title, &it.Body, &it.ChannelID, &it.SenderID, &sender, &channel); err != nil {
			return nil, fmt.Errorf("scanning catchup inbox item: %w", err)
		}
		it.Area = "inbox"
		it.Meta = "from " + sender
		if channel != "" {
			it.Meta += " in #" + channel
		}
		out = append(out, it)
	}
	return out, rows.Err()
}

// ListCatchupTracks returns non-dismissed tracks updated inside the window.
func (db *DB) ListCatchupTracks(from, to float64, limit int) ([]CatchupItem, error) {
	rows, err := db.Query(`
		SELECT id, text, substr(context, 1, 280), priority, ownership
		FROM tracks
		WHERE dismissed_at = '' AND updated_at > ? AND updated_at <= ?
		ORDER BY CASE priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END, updated_at DESC
		LIMIT ?`, unixToISO(from), unixToISO(to), limit)
	if err != nil {
		return nil, fmt.Errorf("listing catchup tracks: %w", err)
	}
	defer rows.Close()
	var out []CatchupItem
	for rows.Next() {
		var it CatchupItem
		var priority, ownership string
		if err := rows.Scan(&it.ID, &it.Title, &it.Body, &priority, &ownership); err != nil {
			return nil, fmt.Errorf("scanning catchup track: %w", err)
		}
		it.Area = "tracks"
		it.Meta = priority + " · " + ownership
		out = append(out, it)
	}
	return out, rows.Err()
}

// ListCatchupTargets returns open targets due inside the window or already
// overdue at its start. targets.due_date is "YYYY-MM-DDTHH:MM" in UTC (the
// targets.go convention — see GetTargetCounts/UnsnoozeExpiredTargets and the
// Desktop writer in WatchtowerCore/Models/Target.swift), or "".
func (db *DB) ListCatchupTargets(from, to float64, limit int) ([]CatchupItem, error) {
	fromUTC := time.Unix(int64(from), 0).UTC().Format("2006-01-02T15:04")
	toUTC := time.Unix(int64(to), 0).UTC().Format("2006-01-02T15:04")
	rows, err := db.Query(`
		SELECT id, text, intent, due_date, status, priority
		FROM targets
		WHERE status NOT IN ('done','dismissed') AND due_date <> ''
		  AND ((due_date > ? AND due_date <= ?) OR due_date < ?)
		ORDER BY due_date ASC LIMIT ?`, fromUTC, toUTC, fromUTC, limit)
	if err != nil {
		return nil, fmt.Errorf("listing catchup targets: %w", err)
	}
	defer rows.Close()
	var out []CatchupItem
	for rows.Next() {
		var it CatchupItem
		var due, status, priority string
		if err := rows.Scan(&it.ID, &it.Title, &it.Body, &due, &status, &priority); err != nil {
			return nil, fmt.Errorf("scanning catchup target: %w", err)
		}
		it.Area = "targets"
		it.Meta = fmt.Sprintf("due %s · %s · %s", due, status, priority)
		out = append(out, it)
	}
	return out, rows.Err()
}

// CatchupCoverage reports how far into the window the summaries actually reach:
// the latest channel-digest period_to and the latest stream-digest period_to
// inside [from, to] (0 when none).
func (db *DB) CatchupCoverage(from, to float64) (slackTo, streamsTo float64, err error) {
	var s sql.NullFloat64
	if err = db.QueryRow(`SELECT MAX(period_to) FROM digests WHERE type='channel' AND period_to > ? AND period_to <= ?`, from, to).Scan(&s); err != nil {
		return 0, 0, fmt.Errorf("catchup slack coverage: %w", err)
	}
	var st sql.NullString
	if err = db.QueryRow(`SELECT MAX(period_to) FROM stream_digests WHERE period_to > ? AND period_to <= ?`, unixToISO(from), unixToISO(to)).Scan(&st); err != nil {
		return 0, 0, fmt.Errorf("catchup streams coverage: %w", err)
	}
	if st.Valid {
		if ts, perr := time.Parse("2006-01-02T15:04:05Z", st.String); perr == nil {
			streamsTo = float64(ts.Unix())
		}
	}
	return s.Float64, streamsTo, nil
}

// FetchItemScopeHints resolves the Slack ids the learning interpreter builds
// scope keys from. Only digests (channel) and inbox (channel + sender) carry
// hints; every other recap area yields none. Unknown areas are an error.
func (db *DB) FetchItemScopeHints(area string, id int) (channelID, senderID string, err error) {
	switch area {
	case "digests":
		err = db.QueryRow(`SELECT channel_id FROM digests WHERE id=?`, id).Scan(&channelID)
	case "inbox":
		err = db.QueryRow(`SELECT channel_id, sender_user_id FROM inbox_items WHERE id=?`, id).Scan(&channelID, &senderID)
	case "streams", "recaps", "transcripts", "decisions", "tracks", "targets":
		return "", "", nil
	default:
		return "", "", fmt.Errorf("fetching scope hints: unknown area %q", area)
	}
	if errors.Is(err, sql.ErrNoRows) {
		return "", "", nil // item gone → no hints; best-effort, not an error
	}
	if err != nil {
		return "", "", fmt.Errorf("fetching %s#%d scope hints: %w", area, id, err)
	}
	return channelID, senderID, nil
}
