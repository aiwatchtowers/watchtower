package kb

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"
)

// splitIDIdx splits "<id>:<idx>" from the right.
func splitIDIdx(rest string) (id, idx string, ok bool) {
	i := strings.LastIndex(rest, ":")
	if i <= 0 || i == len(rest)-1 {
		return "", "", false
	}
	return rest[:i], rest[i+1:], true
}

// addIndexedChildren adds to set every already-indexed document id under
// prefix whose parent ("<prefix><parent>:<idx>") is in parents, so a child
// dropped by a parent's re-upsert is rebuilt (→ nil → deleted) in the same
// run instead of lingering until the daily reconcile.
func addIndexedChildren(ctx context.Context, q Queryer, prefix string, parents, set map[string]bool) error {
	if len(parents) == 0 {
		return nil
	}
	ids, err := docIDsWithPrefix(ctx, q, prefix)
	if err != nil {
		return err
	}
	for _, id := range ids {
		if parent, _, ok := splitIDIdx(id[len(prefix):]); ok && parents[parent] {
			set[id] = true
		}
	}
	return nil
}

func sortedKeys(set map[string]bool) []string {
	keys := make([]string, 0, len(set))
	for k := range set {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// transcriptSource renders one document per meeting transcript.
type transcriptSource struct{}

func (transcriptSource) Name() string { return "transcript" }

func (transcriptSource) Changed(ctx context.Context, q Queryer, cursor string, _ time.Time) ([]string, string, bool, error) {
	keys, next, err := changedByColumn(ctx, q, cursor,
		`SELECT 'transcript:' || id, updated_at FROM meeting_transcripts WHERE updated_at >= ?`, cursor)
	return keys, next, true, err
}

func (transcriptSource) Keys(ctx context.Context, q Queryer) ([]string, error) {
	return queryStrings(ctx, q, `SELECT 'transcript:' || id FROM meeting_transcripts`)
}

type transcriptSegment struct {
	Deleted  bool    `json:"deleted"`
	StartSec float64 `json:"start_sec"`
	Speaker  string  `json:"speaker"`
	Text     string  `json:"text"`
}

func (transcriptSource) Build(ctx context.Context, q Queryer, key string) (*Doc, error) {
	id, ok := splitRef(key, "transcript:")
	if !ok {
		return nil, nil //nolint:nilerr // malformed ref: treat as missing doc, not an error
	}
	var title, createdAt, text, segmentsJSON string
	err := q.QueryRowContext(ctx, `SELECT title, created_at, transcript_text, COALESCE(segments_json, '')
		FROM meeting_transcripts WHERE id = ?`, id).Scan(&title, &createdAt, &text, &segmentsJSON)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("kb transcript %s: %w", key, err)
	}

	doc := &Doc{
		ID:     key,
		Source: "transcript",
		Title:  title,
		Time:   parseTime(createdAt),
		Anchor: map[string]string{"transcript_id": id},
	}
	if len(createdAt) >= 10 {
		doc.Title = title + " · " + createdAt[:10]
	}
	var segments []transcriptSegment
	if json.Unmarshal([]byte(segmentsJSON), &segments) != nil {
		segments = nil // invalid JSON: fall back to the flat text
	}
	for _, s := range segments {
		if s.Deleted || strings.TrimSpace(s.Text) == "" {
			continue
		}
		line := s.Text
		if s.Speaker != "" {
			line = "[" + s.Speaker + "] " + s.Text
		}
		doc.Sections = append(doc.Sections, Section{Text: line, Anchor: strconv.FormatFloat(s.StartSec, 'f', 0, 64)})
	}
	// An all-deleted segment list renders no sections on purpose (the
	// canonical transcript_text is then empty too) — the transcript stays
	// indexed by its title; only a NULL/invalid/empty list falls back to the
	// flat text.
	if len(segments) == 0 {
		for _, line := range strings.Split(text, "\n") {
			if line = strings.TrimSpace(line); line != "" {
				doc.Sections = append(doc.Sections, Section{Text: line})
			}
		}
	}
	return doc, nil
}

// recapSource renders one document per meeting recap.
type recapSource struct{}

func (recapSource) Name() string { return "recap" }

func (recapSource) Changed(ctx context.Context, q Queryer, cursor string, _ time.Time) ([]string, string, bool, error) {
	keys, next, err := changedByColumn(ctx, q, cursor,
		`SELECT 'recap:' || id, updated_at FROM meeting_recaps WHERE updated_at >= ?`, cursor)
	return keys, next, true, err
}

func (recapSource) Keys(ctx context.Context, q Queryer) ([]string, error) {
	return queryStrings(ctx, q, `SELECT 'recap:' || id FROM meeting_recaps`)
}

// Build joins the event title in at render time. Accepted v1 limit: a later
// rename of the event does not move the recap's change marker, so the indexed
// title refreshes only on the recap's next change or a `kb reindex`.
func (recapSource) Build(ctx context.Context, q Queryer, key string) (*Doc, error) {
	id, ok := splitRef(key, "recap:")
	if !ok {
		return nil, nil //nolint:nilerr // malformed ref: treat as missing doc, not an error
	}
	var recapJSON, createdAt, eventID, eventTitle string
	err := q.QueryRowContext(ctx, `SELECT r.recap_json, r.created_at, COALESCE(r.event_id,''), COALESCE(e.title,'')
		FROM meeting_recaps r LEFT JOIN calendar_events e ON e.id = r.event_id WHERE r.id = ?`, id).
		Scan(&recapJSON, &createdAt, &eventID, &eventTitle)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("kb recap %s: %w", key, err)
	}
	doc := &Doc{
		ID:     key,
		Source: "recap",
		Title:  eventTitle,
		Time:   parseTime(createdAt),
		Anchor: map[string]string{"recap_id": id},
	}
	if doc.Title == "" {
		doc.Title = "Meeting recap"
	}
	if eventID != "" {
		doc.Anchor["event_id"] = eventID
	}
	for _, s := range jsonTexts(recapJSON) {
		doc.Sections = append(doc.Sections, Section{Text: s})
	}
	return doc, nil
}

// digestSource renders one document per digest topic.
type digestSource struct{}

func (digestSource) Name() string { return "digest" }

func (digestSource) Changed(ctx context.Context, q Queryer, cursor string, _ time.Time) ([]string, string, bool, error) {
	// LEFT JOIN: a digest re-upserted with zero topics still marks its
	// previously indexed topics for rebuild.
	rows, err := q.QueryContext(ctx, `SELECT d.id, t.idx, d.created_at FROM digests d
		LEFT JOIN digest_topics t ON t.digest_id = d.id WHERE d.created_at >= ?`, cursor)
	if err != nil {
		return nil, cursor, false, err
	}
	set, parents, next := map[string]bool{}, map[string]bool{}, cursor
	scanErr := func() error {
		defer rows.Close()
		for rows.Next() {
			var id int64
			var idx sql.NullInt64
			var createdAt string
			if err := rows.Scan(&id, &idx, &createdAt); err != nil {
				return err
			}
			parent := strconv.FormatInt(id, 10)
			parents[parent] = true
			if idx.Valid {
				set["digest:"+parent+":"+strconv.FormatInt(idx.Int64, 10)] = true
			}
			next = maxString(next, createdAt)
		}
		return rows.Err()
	}()
	if scanErr != nil {
		return nil, cursor, false, scanErr
	}
	if err := addIndexedChildren(ctx, q, "digest:", parents, set); err != nil {
		return nil, cursor, false, err
	}
	return sortedKeys(set), next, true, nil
}

func (digestSource) Keys(ctx context.Context, q Queryer) ([]string, error) {
	return queryStrings(ctx, q, `SELECT 'digest:' || digest_id || ':' || idx FROM digest_topics`)
}

// Build joins the channel name into meta at render time. Accepted v1 limit: a
// channel rename does not move the digest's change marker, so the indexed
// name refreshes only on the digest's next change or a `kb reindex`.
func (digestSource) Build(ctx context.Context, q Queryer, key string) (*Doc, error) {
	rest, ok := splitRef(key, "digest:")
	if !ok {
		return nil, nil //nolint:nilerr // malformed ref: treat as missing doc, not an error
	}
	digestID, idx, ok := splitIDIdx(rest)
	if !ok {
		return nil, nil //nolint:nilerr // malformed ref: treat as missing doc, not an error
	}
	var title, summary, decisions, actions, typ, channelID string
	var periodTo float64
	err := q.QueryRowContext(ctx, `SELECT t.title, t.summary, t.decisions, t.action_items, d.type, d.channel_id, d.period_to
		FROM digest_topics t JOIN digests d ON d.id = t.digest_id WHERE t.digest_id = ? AND t.idx = ?`, digestID, idx).
		Scan(&title, &summary, &decisions, &actions, &typ, &channelID, &periodTo)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("kb digest %s: %w", key, err)
	}

	var meta []string
	if channelID != "" {
		names, err := queryStrings(ctx, q, `SELECT COALESCE(name,'') FROM channels WHERE id = ?`, channelID)
		if err != nil {
			return nil, fmt.Errorf("kb digest %s channel: %w", key, err)
		}
		if len(names) > 0 && names[0] != "" {
			meta = append(meta, "#"+names[0])
		}
	}
	meta = append(meta, typ)

	doc := &Doc{
		ID:     key,
		Source: "digest",
		Title:  title,
		Meta:   strings.Join(meta, " "),
		Time:   time.Unix(int64(periodTo), 0).UTC(),
		Anchor: map[string]string{"digest_id": digestID, "idx": idx},
	}
	if channelID != "" {
		doc.Anchor["channel_id"] = channelID
	}
	if summary != "" {
		doc.Sections = append(doc.Sections, Section{Text: summary})
	}
	for _, s := range jsonTexts(decisions) {
		doc.Sections = append(doc.Sections, Section{Text: "Decision: " + s})
	}
	for _, s := range jsonTexts(actions) {
		doc.Sections = append(doc.Sections, Section{Text: "Action: " + s})
	}
	return doc, nil
}

// streamDigestSource renders one document per Gmail/Jira stream-digest topic
// (an entry of stream_digests.topics_json, keyed by its array index).
type streamDigestSource struct{}

func (streamDigestSource) Name() string { return "stream_digest" }

// topicCount is the number of entries in a topics_json array (0 when invalid).
func topicCount(raw string) int {
	var entries []json.RawMessage
	if json.Unmarshal([]byte(raw), &entries) != nil {
		return 0
	}
	return len(entries)
}

type streamDigestRow struct {
	id, topicsJSON, createdAt string
}

func loadStreamDigestRows(ctx context.Context, q Queryer, query string, args ...any) ([]streamDigestRow, error) {
	rows, err := q.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []streamDigestRow
	for rows.Next() {
		var r streamDigestRow
		var id int64
		if err := rows.Scan(&id, &r.topicsJSON, &r.createdAt); err != nil {
			return nil, err
		}
		r.id = strconv.FormatInt(id, 10)
		out = append(out, r)
	}
	return out, rows.Err()
}

func streamDigestKeys(rows []streamDigestRow, set map[string]bool) {
	for _, r := range rows {
		for i := range topicCount(r.topicsJSON) {
			set["stream_digest:"+r.id+":"+strconv.Itoa(i)] = true
		}
	}
}

func (streamDigestSource) Changed(ctx context.Context, q Queryer, cursor string, _ time.Time) ([]string, string, bool, error) {
	rows, err := loadStreamDigestRows(ctx, q, `SELECT id, topics_json, created_at FROM stream_digests WHERE created_at >= ?`, cursor)
	if err != nil {
		return nil, cursor, false, err
	}
	set, parents, next := map[string]bool{}, map[string]bool{}, cursor
	streamDigestKeys(rows, set)
	for _, r := range rows {
		parents[r.id] = true
		next = maxString(next, r.createdAt)
	}
	if err := addIndexedChildren(ctx, q, "stream_digest:", parents, set); err != nil {
		return nil, cursor, false, err
	}
	return sortedKeys(set), next, true, nil
}

func (streamDigestSource) Keys(ctx context.Context, q Queryer) ([]string, error) {
	rows, err := loadStreamDigestRows(ctx, q, `SELECT id, topics_json, created_at FROM stream_digests`)
	if err != nil {
		return nil, err
	}
	set := map[string]bool{}
	streamDigestKeys(rows, set)
	return sortedKeys(set), nil
}

func (streamDigestSource) Build(ctx context.Context, q Queryer, key string) (*Doc, error) {
	rest, ok := splitRef(key, "stream_digest:")
	if !ok {
		return nil, nil //nolint:nilerr // malformed ref: treat as missing doc, not an error
	}
	id, idxStr, ok := splitIDIdx(rest)
	if !ok {
		return nil, nil //nolint:nilerr // malformed ref: treat as missing doc, not an error
	}
	idx, err := strconv.Atoi(idxStr)
	if err != nil {
		return nil, nil //nolint:nilerr // malformed ref: treat as missing doc, not an error
	}
	var source, scope, periodTo, topicsJSON string
	err = q.QueryRowContext(ctx, `SELECT source, scope, period_to, topics_json FROM stream_digests WHERE id = ?`, id).
		Scan(&source, &scope, &periodTo, &topicsJSON)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("kb stream_digest %s: %w", key, err)
	}
	var entries []json.RawMessage
	if json.Unmarshal([]byte(topicsJSON), &entries) != nil || idx < 0 || idx >= len(entries) {
		return nil, nil //nolint:nilerr // unparsable topics or idx out of range: the topic no longer exists
	}
	entry := entries[idx]
	var head struct {
		Title string `json:"title"`
	}
	_ = json.Unmarshal(entry, &head) // a non-object entry simply has no title
	title := strings.TrimSpace(head.Title)

	doc := &Doc{
		ID:     key,
		Source: "stream_digest",
		Title:  title,
		Meta:   strings.TrimSpace(source + " " + scope),
		Time:   parseTime(periodTo),
		Anchor: map[string]string{"stream_digest_id": id, "idx": idxStr, "source": source},
	}
	if doc.Title == "" {
		doc.Title = source + " digest"
	}
	skippedTitle := title == ""
	for _, s := range jsonTexts(string(entry)) {
		if !skippedTitle && s == head.Title {
			skippedTitle = true
			continue
		}
		doc.Sections = append(doc.Sections, Section{Text: s})
	}
	return doc, nil
}

// ideaSource renders one document per registry idea/decision/note.
type ideaSource struct{}

func (ideaSource) Name() string { return "idea" }

func (ideaSource) Changed(ctx context.Context, q Queryer, cursor string, _ time.Time) ([]string, string, bool, error) {
	keys, next, err := changedByColumn(ctx, q, cursor,
		`SELECT 'idea:' || id, updated_at FROM ideas WHERE updated_at >= ?
		 UNION ALL
		 SELECT 'idea:' || idea_id, created_at FROM idea_mentions WHERE created_at >= ?`,
		cursor, cursor)
	return keys, next, true, err
}

func (ideaSource) Keys(ctx context.Context, q Queryer) ([]string, error) {
	return queryStrings(ctx, q, `SELECT 'idea:' || id FROM ideas`)
}

type ideaMention struct {
	id           int64
	author, text string
}

func loadIdeaMentions(ctx context.Context, q Queryer, ideaID string) ([]ideaMention, error) {
	rows, err := q.QueryContext(ctx, `SELECT id, author, quote FROM idea_mentions WHERE idea_id = ? ORDER BY said_at, id`, ideaID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ideaMention
	for rows.Next() {
		var m ideaMention
		if err := rows.Scan(&m.id, &m.author, &m.text); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

func (ideaSource) Build(ctx context.Context, q Queryer, key string) (*Doc, error) {
	id, ok := splitRef(key, "idea:")
	if !ok {
		return nil, nil //nolint:nilerr // malformed ref: treat as missing doc, not an error
	}
	var kind, status, title, essence, lastMention, updatedAt string
	err := q.QueryRowContext(ctx, `SELECT kind, status, title, essence, last_mention_at, updated_at FROM ideas WHERE id = ?`, id).
		Scan(&kind, &status, &title, &essence, &lastMention, &updatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("kb idea %s: %w", key, err)
	}
	mentions, err := loadIdeaMentions(ctx, q, id)
	if err != nil {
		return nil, fmt.Errorf("kb idea %s mentions: %w", key, err)
	}
	doc := &Doc{
		ID:     key,
		Source: "idea",
		Title:  title,
		Meta:   kind + " " + status,
		Time:   parseTime(lastMention),
		Anchor: map[string]string{"idea_id": id},
	}
	if doc.Time.IsZero() {
		doc.Time = parseTime(updatedAt)
	}
	if essence != "" {
		doc.Sections = append(doc.Sections, Section{Text: essence})
	}
	for _, m := range mentions {
		if strings.TrimSpace(m.text) == "" {
			continue
		}
		text := m.text
		if m.author != "" {
			text = m.author + ": " + m.text
		}
		doc.Sections = append(doc.Sections, Section{Text: text, Anchor: strconv.FormatInt(m.id, 10)})
	}
	return doc, nil
}
