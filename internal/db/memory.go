package db

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// MemoryNodeRow mirrors one row of memory_nodes — the rebuildable SQLite index
// over the markdown memory vault (files + git are the source of truth, MEM-02).
type MemoryNodeRow struct {
	ID          string // ent_*/ep_*/sum_*/bel_*
	Type        string // entity|episode|rollup|belief
	Tier        string // short|long
	Status      string // active|closed|tombstone
	RedirectTo  string // target node ID when Status == tombstone, else empty
	Title       string
	Path        string // vault-relative file path
	ContentHash string // sha256 of file bytes at last index
	IndexedAt   string
}

// MemoryHit is one full-text search result from SearchMemoryFTS.
type MemoryHit struct {
	ID      string
	Title   string
	Type    string
	Snippet string
}

// UpsertMemoryNode writes a node row, replaces its aliases, and replaces its
// FTS row in a single transaction, so a reindex interrupted mid-node never
// leaves the index half-updated for that node.
func (db *DB) UpsertMemoryNode(row MemoryNodeRow, body string, aliases []string) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("beginning memory node tx: %w", err)
	}
	defer tx.Rollback()

	_, err = tx.Exec(`INSERT INTO memory_nodes
		(id, type, tier, status, redirect_to, title, path, content_hash, indexed_at)
		VALUES (?, ?, ?, ?, NULLIF(?, ''), ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET
			type = excluded.type,
			tier = excluded.tier,
			status = excluded.status,
			redirect_to = excluded.redirect_to,
			title = excluded.title,
			path = excluded.path,
			content_hash = excluded.content_hash,
			indexed_at = excluded.indexed_at`,
		row.ID, row.Type, row.Tier, row.Status, row.RedirectTo,
		row.Title, row.Path, row.ContentHash, row.IndexedAt)
	if err != nil {
		return fmt.Errorf("upserting memory node %s: %w", row.ID, err)
	}

	// Replace this node's aliases wholesale — the vault frontmatter is the
	// authority, so stale aliases must not survive a re-upsert.
	if _, err := tx.Exec(`DELETE FROM memory_aliases WHERE node_id = ?`, row.ID); err != nil {
		return fmt.Errorf("clearing aliases for %s: %w", row.ID, err)
	}
	for _, alias := range aliases {
		if _, err := tx.Exec(`INSERT INTO memory_aliases (alias, node_id) VALUES (?, ?)`, alias, row.ID); err != nil {
			return fmt.Errorf("inserting alias %q for %s: %w", alias, row.ID, err)
		}
	}

	// Replace the FTS row (fts5 has no upsert).
	if _, err := tx.Exec(`DELETE FROM memory_fts WHERE id = ?`, row.ID); err != nil {
		return fmt.Errorf("clearing fts row for %s: %w", row.ID, err)
	}
	if _, err := tx.Exec(`INSERT INTO memory_fts (id, title, body) VALUES (?, ?, ?)`,
		row.ID, row.Title, body); err != nil {
		return fmt.Errorf("inserting fts row for %s: %w", row.ID, err)
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("committing memory node tx for %s: %w", row.ID, err)
	}
	return nil
}

// DeleteMemoryNode removes a node and its aliases, stats, and FTS row in one
// transaction (used by reconcile when a vault file disappears).
func (db *DB) DeleteMemoryNode(id string) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("beginning memory delete tx: %w", err)
	}
	defer tx.Rollback()

	// Children first: memory_aliases and memory_node_stats reference memory_nodes.
	for _, stmt := range []string{
		`DELETE FROM memory_aliases WHERE node_id = ?`,
		`DELETE FROM memory_node_stats WHERE node_id = ?`,
		`DELETE FROM memory_fts WHERE id = ?`,
		`DELETE FROM memory_nodes WHERE id = ?`,
	} {
		if _, err := tx.Exec(stmt, id); err != nil {
			return fmt.Errorf("deleting memory node %s: %w", id, err)
		}
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("committing memory delete tx for %s: %w", id, err)
	}
	return nil
}

// LookupMemoryAlias resolves an alias (case-insensitive — the column is
// COLLATE NOCASE) to its node ID. Returns sql.ErrNoRows when unknown.
func (db *DB) LookupMemoryAlias(ref string) (string, error) {
	var nodeID string
	err := db.QueryRow(`SELECT node_id FROM memory_aliases WHERE alias = ?`, ref).Scan(&nodeID)
	if errors.Is(err, sql.ErrNoRows) {
		return "", err
	}
	if err != nil {
		return "", fmt.Errorf("looking up memory alias %q: %w", ref, err)
	}
	return nodeID, nil
}

// GetMemoryNode returns one node row by canonical ID. Returns sql.ErrNoRows
// when the node is not indexed.
func (db *DB) GetMemoryNode(id string) (MemoryNodeRow, error) {
	var row MemoryNodeRow
	err := db.QueryRow(`SELECT id, type, tier, status, COALESCE(redirect_to, ''),
		title, path, content_hash, indexed_at
		FROM memory_nodes WHERE id = ?`, id).
		Scan(&row.ID, &row.Type, &row.Tier, &row.Status, &row.RedirectTo,
			&row.Title, &row.Path, &row.ContentHash, &row.IndexedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return MemoryNodeRow{}, err
	}
	if err != nil {
		return MemoryNodeRow{}, fmt.Errorf("getting memory node %s: %w", id, err)
	}
	return row, nil
}

// ListMemoryNodes returns all indexed nodes ordered by ID (used by reconcile
// to diff the index against the vault).
func (db *DB) ListMemoryNodes() ([]MemoryNodeRow, error) {
	rows, err := db.Query(`SELECT id, type, tier, status, COALESCE(redirect_to, ''),
		title, path, content_hash, indexed_at
		FROM memory_nodes ORDER BY id`)
	if err != nil {
		return nil, fmt.Errorf("listing memory nodes: %w", err)
	}
	defer rows.Close()

	var nodes []MemoryNodeRow
	for rows.Next() {
		var row MemoryNodeRow
		if err := rows.Scan(&row.ID, &row.Type, &row.Tier, &row.Status, &row.RedirectTo,
			&row.Title, &row.Path, &row.ContentHash, &row.IndexedAt); err != nil {
			return nil, fmt.Errorf("scanning memory node: %w", err)
		}
		nodes = append(nodes, row)
	}
	return nodes, rows.Err()
}

// SearchMemoryFTS runs a full-text search over node titles and bodies,
// excluding tombstones. The query is sanitized the same way as message search
// (each term double-quoted) so user input cannot inject FTS5 operators.
func (db *DB) SearchMemoryFTS(query string, limit int) ([]MemoryHit, error) {
	sanitized := sanitizeFTS5Query(query)
	if sanitized == "" {
		return nil, nil
	}
	if limit <= 0 {
		limit = 20
	}

	rows, err := db.Query(`SELECT n.id, n.title, n.type,
			snippet(memory_fts, -1, '', '', '…', 12)
		FROM memory_fts fts
		JOIN memory_nodes n ON n.id = fts.id
		WHERE memory_fts MATCH ? AND n.status != 'tombstone'
		ORDER BY rank
		LIMIT ?`, sanitized, limit)
	if err != nil {
		return nil, fmt.Errorf("searching memory fts: %w", err)
	}
	defer rows.Close()

	var hits []MemoryHit
	for rows.Next() {
		var h MemoryHit
		if err := rows.Scan(&h.ID, &h.Title, &h.Type, &h.Snippet); err != nil {
			return nil, fmt.Errorf("scanning memory hit: %w", err)
		}
		hits = append(hits, h)
	}
	return hits, rows.Err()
}

// BumpMemoryAccess increments a node's access counter and stamps the access
// time (powers recency/usage stats for the memory_open MCP tool).
func (db *DB) BumpMemoryAccess(id string) error {
	_, err := db.Exec(`INSERT INTO memory_node_stats (node_id, access_count, last_accessed_at)
		VALUES (?, 1, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
		ON CONFLICT(node_id) DO UPDATE SET
			access_count = access_count + 1,
			last_accessed_at = excluded.last_accessed_at`, id)
	if err != nil {
		return fmt.Errorf("bumping memory access for %s: %w", id, err)
	}
	return nil
}

// MessageExists reports whether a live (non-deleted) message row exists for
// (channelID, ts) — the MEM-01 write-time check that no unvalidated
// provenance ref ever reaches the memory vault. Tombstoned messages
// (is_deleted = 1) do not count: a ref to a deleted message would 404 for the
// owner just like a hallucinated one.
func (db *DB) MessageExists(channelID, ts string) (bool, error) {
	var one int
	err := db.QueryRow(`SELECT 1 FROM messages WHERE channel_id = ? AND ts = ? AND is_deleted = 0`, channelID, ts).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("checking message %s/%s: %w", channelID, ts, err)
	}
	return true, nil
}

// MemoryWatermark returns the unix ts of the last raw message fully processed
// by the episode extractor (MEM-04 freeze discipline, same shape as the inbox
// watermark accessors). A fresh workspace without its singleton row yet reads
// as 0 — nothing extracted — rather than an error.
func (db *DB) MemoryWatermark() (float64, error) {
	var ts float64
	err := db.QueryRow(`SELECT COALESCE(memory_last_extracted_ts, 0) FROM workspace LIMIT 1`).Scan(&ts)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("getting memory watermark: %w", err)
	}
	return ts, nil
}

// SetMemoryWatermark updates the consolidation watermark.
func (db *DB) SetMemoryWatermark(ts float64) error {
	_, err := db.Exec(`UPDATE workspace SET memory_last_extracted_ts = ?`, ts)
	if err != nil {
		return fmt.Errorf("setting memory watermark: %w", err)
	}
	return nil
}

// MemoryExtractMessage is one raw message row fed to the memory episode
// extractor: human-authored (effective is_bot = 0, not muted for LLM),
// non-empty text, not deleted, strictly newer than the extraction watermark.
type MemoryExtractMessage struct {
	ChannelID   string
	ChannelName string
	TS          string
	TSUnix      float64
	Author      string
	Text        string
}

// ListMemoryExtractMessages returns the extractable messages with ts_unix
// strictly above sinceTS, oldest first (read-only; the memory pipeline groups
// them into per-channel windows). Messages authored by bots or LLM-muted
// users are excluded, but a message whose author has no users row at all
// (deleted/ex-employee, never synced) IS included, with the raw user_id as
// the author fallback — an INNER JOIN would skip such messages forever.
//
// Boundary drain: ts_unix is a GENERATED column truncated to whole seconds,
// so a LIMIT cut can land inside a same-second group. The caller's watermark
// advances to a loaded message's ts_unix and reloads with a strict >, which
// would permanently skip the unloaded rows of that second. When the limit
// cuts inside a second, this query therefore extends the result past the
// limit to include ALL rows sharing the last loaded second, so the boundary
// second is always fully loaded (the overshoot is at most one second of
// traffic).
func (db *DB) ListMemoryExtractMessages(sinceTS float64, limit int) ([]MemoryExtractMessage, error) {
	if limit <= 0 {
		limit = 2000
	}
	out, err := db.queryMemoryExtractMessages(`m.ts_unix > ?`, sinceTS, limit)
	if err != nil || len(out) < limit {
		return out, err
	}
	boundary := out[len(out)-1].TSUnix
	full, err := db.queryMemoryExtractMessages(`m.ts_unix = ?`, boundary, -1) // LIMIT -1: unbounded
	if err != nil {
		return nil, err
	}
	// Replace the (possibly cut) tail rows of the boundary second with the
	// full set; both slices share the same deterministic order.
	i := len(out)
	for i > 0 && out[i-1].TSUnix == boundary {
		i--
	}
	return append(out[:i], full...), nil
}

// queryMemoryExtractMessages runs the extract-message select with the given
// ts_unix condition. The ORDER BY ends in (channel_id, ts) — the messages
// primary key — so the ordering is fully deterministic within a same-second
// group, which the boundary-drain logic above relies on.
func (db *DB) queryMemoryExtractMessages(tsCond string, tsArg float64, limit int) ([]MemoryExtractMessage, error) {
	rows, err := db.Query(`
		SELECT m.channel_id, c.name, m.ts, m.ts_unix,
		       COALESCE(NULLIF(u.display_name, ''), NULLIF(u.real_name, ''), NULLIF(u.name, ''), m.user_id),
		       m.text
		FROM messages m
		JOIN channels c ON c.id = m.channel_id
		LEFT JOIN users u ON u.id = m.user_id
		WHERE m.text != '' AND m.is_deleted = 0
		  AND ((u.id IS NULL AND m.user_id != '') OR (COALESCE(u.is_bot_override, u.is_bot) = 0 AND u.is_muted_for_llm = 0))
		  AND `+tsCond+`
		ORDER BY m.ts_unix, m.channel_id, m.ts
		LIMIT ?`, tsArg, limit)
	if err != nil {
		return nil, fmt.Errorf("listing memory extract messages: %w", err)
	}
	defer rows.Close()

	var out []MemoryExtractMessage
	for rows.Next() {
		var m MemoryExtractMessage
		if err := rows.Scan(&m.ChannelID, &m.ChannelName, &m.TS, &m.TSUnix, &m.Author, &m.Text); err != nil {
			return nil, fmt.Errorf("scanning memory extract message: %w", err)
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// EntityHint is one (hint, episode) observation to persist: an unresolved
// extractor entity hint together with the episode node that emitted it.
type EntityHint struct {
	Hint      string // normalized (lowercased, trimmed) hint text
	EpisodeID string // the ep_* node that emitted it
}

// PromotableHint is one recurring hint eligible for concept-entity promotion:
// the hint text and the distinct episode IDs that emitted it (unpromoted only).
type PromotableHint struct {
	Hint       string
	EpisodeIDs []string
}

// RecordEntityHints persists unresolved extractor hints for concept-entity
// promotion. Each (hint, episode_id) pair is INSERT OR IGNORE'd (the table's
// PRIMARY KEY), so re-extracting the same episode never double-counts a hint —
// distinct-episode recurrence is COUNT(*) per hint. first_seen is stamped on
// first insert only. Empty hint or episode_id pairs are skipped. This is
// runtime accumulation (like memory_node_stats), NOT derivable from files, so
// it is excluded from MEM-02 and deliberately survives DropMemoryIndex.
func (db *DB) RecordEntityHints(hints []EntityHint) error {
	if len(hints) == 0 {
		return nil
	}
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("beginning entity-hint tx: %w", err)
	}
	defer tx.Rollback()

	now := time.Now().UTC().Format(time.RFC3339)
	for _, h := range hints {
		if h.Hint == "" || h.EpisodeID == "" {
			continue
		}
		if _, err := tx.Exec(`INSERT OR IGNORE INTO memory_entity_hints
			(hint, episode_id, first_seen) VALUES (?, ?, ?)`,
			h.Hint, h.EpisodeID, now); err != nil {
			return fmt.Errorf("recording entity hint %q/%s: %w", h.Hint, h.EpisodeID, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("committing entity-hint tx: %w", err)
	}
	return nil
}

// ListPromotableHints returns hints that have recurred across at least
// minEpisodes distinct episodes and have not yet been promoted, each with its
// contributing (unpromoted) episode IDs. Ordered by hint, then episode id, so
// promotion is deterministic across runs.
func (db *DB) ListPromotableHints(minEpisodes int) ([]PromotableHint, error) {
	if minEpisodes < 1 {
		minEpisodes = 1
	}
	rows, err := db.Query(`
		SELECT hint, episode_id FROM memory_entity_hints
		WHERE promoted_to = ''
		  AND hint IN (
			SELECT hint FROM memory_entity_hints
			WHERE promoted_to = ''
			GROUP BY hint HAVING COUNT(*) >= ?)
		ORDER BY hint, episode_id`, minEpisodes)
	if err != nil {
		return nil, fmt.Errorf("listing promotable hints: %w", err)
	}
	defer rows.Close()

	var out []PromotableHint
	for rows.Next() {
		var hint, episodeID string
		if err := rows.Scan(&hint, &episodeID); err != nil {
			return nil, fmt.Errorf("scanning promotable hint: %w", err)
		}
		if len(out) == 0 || out[len(out)-1].Hint != hint {
			out = append(out, PromotableHint{Hint: hint})
		}
		last := &out[len(out)-1]
		last.EpisodeIDs = append(last.EpisodeIDs, episodeID)
	}
	return out, rows.Err()
}

// MarkHintPromoted stamps every unpromoted row of a hint with the concept
// entity id it was promoted into, so a later run never re-promotes it.
func (db *DB) MarkHintPromoted(hint, nodeID string) error {
	if _, err := db.Exec(`UPDATE memory_entity_hints SET promoted_to = ?
		WHERE hint = ? AND promoted_to = ''`, nodeID, hint); err != nil {
		return fmt.Errorf("marking hint %q promoted to %s: %w", hint, nodeID, err)
	}
	return nil
}

// CountMemoryLinksIn counts the live (non-tombstone) nodes whose body contains
// a [[<id>...]] wiki-link to the given node — the "links-in" importance input
// to the retention score. Self-links and tombstones (whose only link is their
// own redirect stub) are excluded. Uses instr for an exact substring match so
// the underscore in an id prefix cannot act as a LIKE wildcard.
func (db *DB) CountMemoryLinksIn(id string) (int, error) {
	var n int
	err := db.QueryRow(`
		SELECT COUNT(*) FROM memory_fts f
		JOIN memory_nodes m ON m.id = f.id
		WHERE m.status != 'tombstone' AND m.id != ?
		  AND instr(f.body, '[[' || ?) > 0`, id, id).Scan(&n)
	if err != nil {
		return 0, fmt.Errorf("counting links-in for %s: %w", id, err)
	}
	return n, nil
}

// DropMemoryIndex empties all four memory index tables in one transaction so
// a full reindex can rebuild them from the vault (MEM-02).
func (db *DB) DropMemoryIndex() error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("beginning memory drop tx: %w", err)
	}
	defer tx.Rollback()

	// Children first: aliases and stats reference memory_nodes.
	for _, stmt := range []string{
		`DELETE FROM memory_aliases`,
		`DELETE FROM memory_node_stats`,
		`DELETE FROM memory_fts`,
		`DELETE FROM memory_nodes`,
	} {
		if _, err := tx.Exec(stmt); err != nil {
			return fmt.Errorf("dropping memory index: %w", err)
		}
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("committing memory drop tx: %w", err)
	}
	return nil
}
