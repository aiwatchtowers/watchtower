package db

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
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
	Subject     string  // belief subject entity id, "" for non-beliefs; file-derived (Node.Subject, see 00019)
	Confidence  float64 // belief confidence 0..1, 0 for non-beliefs; file-derived (Node.Confidence, see 00019)
	// ImportanceScore is the merged (owner-override-or-computed) importance
	// snapshot Reconcile/Rebuild refresh per node — override when the node's
	// frontmatter carries one, else ComputeImportance(...)'s live signal read
	// (internal/memory/index.go). A periodic snapshot for future retrieval
	// ranking, distinct from evict.go's always-live RetentionScore (Slice A of
	// the memory-importance-score redesign, MEM-16; migration 00037).
	ImportanceScore float64
	// DisputePending mirrors presence in the memory_dispute_flags SIDE TABLE
	// (see 00019) — runtime state, never written by UpsertMemoryNode. Read-only
	// here; set via SetDisputePending and cleared by the inbox watchtower
	// detector's same-transaction DELETE when it mints a dispute item
	// (mintDisputeItem) — the only clear path, so a dispute surfaces exactly once.
	DisputePending bool
}

// MemoryHit is one full-text search result from SearchMemoryFTS.
type MemoryHit struct {
	ID      string
	Title   string
	Type    string
	Snippet string
}

// ProvenanceRow is one derived memory_provenance index row: a single
// `## Provenance` ref of a node (episode/rollup), classified by scheme and with
// its ts decoded to a unix float for windowed lookup. The memory package owns
// the ref grammar (parsing the markdown + classifying the scheme + decoding the
// ts); the db layer is a dumb store that just writes what it is handed —
// mirroring how aliases are parsed in memory and written here (one parse site
// in memory, one write site in db, one transaction).
type ProvenanceRow struct {
	NodeID    string
	Scheme    string // "" (Slack), "mail", "cal", "chat", "act", "jira"
	ChannelID string // the raw ref channel_id, e.g. "C0AAA" or "mail:<id>"
	TSRaw     string // the ref ts verbatim as rendered in ## Provenance
	TSUnix    float64
	// SenderID is the per-message sender (Slack messages.user_id, Gmail
	// gmail_messages.from_email), populated only for those two schemes —
	// "" for cal:/chat:/act: refs (Slice B, migration 00038). The recency-
	// ordered "what recently happened involving X" query
	// (ListShortTierEpisodesForAliases) filters on this.
	SenderID string
}

// UpsertMemoryNode writes a node row, replaces its aliases, replaces its FTS
// row, and replaces its provenance index rows in a single transaction, so a
// reindex interrupted mid-node never leaves the index half-updated for that
// node. provenance carries the node's `## Provenance` refs (nil for node types
// that carry none); like aliases, they are parsed in the memory layer and
// replaced wholesale here (delete-then-insert keyed on node_id) so a re-upsert
// with an edited body never leaves stale window rows behind.
func (db *DB) UpsertMemoryNode(row MemoryNodeRow, body string, aliases []string, provenance ...ProvenanceRow) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("beginning memory node tx: %w", err)
	}
	defer tx.Rollback()

	_, err = tx.Exec(`INSERT INTO memory_nodes
		(id, type, tier, status, redirect_to, title, path, content_hash, indexed_at, subject, confidence, importance_score)
		VALUES (?, ?, ?, ?, NULLIF(?, ''), ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET
			type = excluded.type,
			tier = excluded.tier,
			status = excluded.status,
			redirect_to = excluded.redirect_to,
			title = excluded.title,
			path = excluded.path,
			content_hash = excluded.content_hash,
			indexed_at = excluded.indexed_at,
			subject = excluded.subject,
			confidence = excluded.confidence,
			importance_score = excluded.importance_score`,
		row.ID, row.Type, row.Tier, row.Status, row.RedirectTo,
		row.Title, row.Path, row.ContentHash, row.IndexedAt, row.Subject, row.Confidence, row.ImportanceScore)
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

	// Replace this node's provenance index rows wholesale (the alias/FTS
	// precedent) — memory_provenance is derived from the body's ## Provenance
	// section, so a re-upsert with an edited body must not leave stale window
	// rows. The memory layer dedupes by (channel_id, ts_raw) before handing them
	// over, so a plain INSERT cannot hit the (node_id, channel_id, ts_raw) PK.
	if _, err := tx.Exec(`DELETE FROM memory_provenance WHERE node_id = ?`, row.ID); err != nil {
		return fmt.Errorf("clearing provenance for %s: %w", row.ID, err)
	}
	for _, p := range provenance {
		if _, err := tx.Exec(`INSERT INTO memory_provenance
			(node_id, scheme, channel_id, ts_raw, ts_unix, sender_id) VALUES (?, ?, ?, ?, ?, ?)`,
			row.ID, p.Scheme, p.ChannelID, p.TSRaw, p.TSUnix, p.SenderID); err != nil {
			return fmt.Errorf("inserting provenance %s/%s for %s: %w", p.ChannelID, p.TSRaw, row.ID, err)
		}
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

	// Children first: memory_aliases, memory_node_stats, and memory_provenance
	// reference memory_nodes.
	for _, stmt := range []string{
		`DELETE FROM memory_aliases WHERE node_id = ?`,
		`DELETE FROM memory_node_stats WHERE node_id = ?`,
		`DELETE FROM memory_provenance WHERE node_id = ?`,
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

// ListEpisodesForChannelWindow returns the distinct non-tombstone node ids
// whose per-channel provenance SPAN [MIN(ts_unix), MAX(ts_unix)] overlaps the
// window (fromUnix, toUnix] on channelID, sorted by node id. Span overlap —
// not ref-in-window — because episodes cite only sparse key messages while a
// story runs for days: a window falling between two cited refs still belongs
// to the story (the 2026-07-20 compare-instrument fix; see
// docs/superpowers/specs/2026-07-20-digest-compare-span-fix-design.md).
// Because provenance rows keep the raw scheme-prefixed ref in channel_id,
// passing a bare Slack channel_id naturally excludes the prefixed-scheme
// refs. The bound is exclusive-low / inclusive-high so adjacent windows tile
// without double-counting the boundary second: overlap means
// MIN(ts_unix) <= to AND MAX(ts_unix) > from. The span endpoints are floored
// to whole seconds in SQL exactly as loadRenderEpisodes floors the Go-side
// spans (messages.ts_unix is second-truncated but provenance refs carry
// microsecond suffixes) — without the floor here, an episode whose earliest
// cited ref is N.x fails MIN(ts_unix) <= N for a window ending at whole
// second N, so selection and coverage agree at boundary seconds.
func (db *DB) ListEpisodesForChannelWindow(channelID string, fromUnix, toUnix float64) ([]string, error) {
	rows, err := db.Query(`SELECT p.node_id
		FROM memory_provenance p
		JOIN memory_nodes n ON n.id = p.node_id
		WHERE p.channel_id = ? AND n.status != 'tombstone'
		GROUP BY p.node_id
		HAVING CAST(MIN(p.ts_unix) AS INTEGER) <= ? AND CAST(MAX(p.ts_unix) AS INTEGER) > ?
		ORDER BY p.node_id`, channelID, toUnix, fromUnix)
	if err != nil {
		return nil, fmt.Errorf("listing episodes for channel %s window (%v,%v]: %w", channelID, fromUnix, toUnix, err)
	}
	defer rows.Close()

	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scanning episode window row: %w", err)
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

// ListShortTierEpisodesForAliases returns short-tier, non-tombstone episode
// rows whose memory_provenance.sender_id matches one of aliases, ordered by
// each node's MOST RECENT matching ref (recency, not importance — a
// short-tier episode's value here is "what recently happened," see Slice B
// design spec §3). A node with multiple matching provenance rows (e.g. two
// refs from the same Slack user) appears once via the per-node MAX(ts_unix)
// derived table, mirroring ListDisputePendingBeliefs's unaliased
// memoryNodeSelectCols-against-bare-memory_nodes shape. Empty aliases is a
// clean empty read (nil, nil) — no query runs.
func (db *DB) ListShortTierEpisodesForAliases(aliases []string, limit int) ([]MemoryNodeRow, error) {
	if len(aliases) == 0 {
		return nil, nil
	}
	if limit <= 0 {
		limit = -1 // SQLite: LIMIT -1 is unbounded (ListDisputePendingBeliefs precedent)
	}
	placeholders, args := inClause(aliases)
	args = append(args, limit)
	rows, err := db.Query(`SELECT `+memoryNodeSelectCols+`
		FROM memory_nodes
		JOIN (
			SELECT node_id, MAX(ts_unix) AS max_ts
			FROM memory_provenance
			WHERE sender_id IN (`+placeholders+`)
			GROUP BY node_id
		) latest ON latest.node_id = memory_nodes.id
		WHERE memory_nodes.tier = 'short' AND memory_nodes.status != 'tombstone'
		ORDER BY latest.max_ts DESC
		LIMIT ?`, args...)
	if err != nil {
		return nil, fmt.Errorf("listing short-tier episodes for aliases: %w", err)
	}
	defer rows.Close()

	var out []MemoryNodeRow
	for rows.Next() {
		row, err := scanMemoryNodeRow(rows.Scan)
		if err != nil {
			return nil, fmt.Errorf("scanning short-tier episode for aliases: %w", err)
		}
		out = append(out, row)
	}
	return out, rows.Err()
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

// MirrorAliasNodeIDs returns the operational-mirror alias set as an alias→node_id
// map: every memory_aliases row aliased target:<n>/track:<n> with a NUMERIC id (the
// alias scheme the Phase-5 slice-4 mirror step owns). LIKE keeps the alias-index
// prefix search (the column is NOCASE, so LIKE alone would admit case variants);
// the case-sensitive GLOB prefix pins the exact lowercase scheme, and the NOT GLOB
// term anchors the WHOLE id as digits (GLOB '[0-9]*' alone anchors only the first
// character) — so a model-minted alias like target:foo, target:1abc, or Target:foo
// can never land in the mirror set. One SELECT, loaded once per
// run. Two callers read it: the mirror step (does a target:<id>/track:<id> mirror
// already exist, so a terminal row still refreshes vs. is skipped) and the entity
// rewrite tier (which node ids are mirrors, so they are excluded from the
// strong-tier rewrite — mirrors are maintained mechanically). READ-ONLY.
func (db *DB) MirrorAliasNodeIDs() (map[string]string, error) {
	rows, err := db.Query(`SELECT alias, node_id FROM memory_aliases
		WHERE (alias LIKE 'target:%' AND alias GLOB 'target:*' AND alias != 'target:' AND alias NOT GLOB 'target:*[^0-9]*')
		   OR (alias LIKE 'track:%' AND alias GLOB 'track:*' AND alias != 'track:' AND alias NOT GLOB 'track:*[^0-9]*')`)
	if err != nil {
		return nil, fmt.Errorf("listing mirror aliases: %w", err)
	}
	defer rows.Close()

	out := map[string]string{}
	for rows.Next() {
		var alias, nodeID string
		if err := rows.Scan(&alias, &nodeID); err != nil {
			return nil, fmt.Errorf("scanning mirror alias: %w", err)
		}
		out[alias] = nodeID
	}
	return out, rows.Err()
}

// SituationMirrorNodeIDs returns the set of node ids carrying a numeric
// `situation:<id>` alias — the situation episode-mirrors. The episode-dedupe
// pass excludes them entirely (M2, 2026-07-18): two situations can share an
// inbox signal, so their mirrors share a provenance ref, but they are distinct
// stories whose identity is the alias — merging them makes the ingest refresh
// ping-pong the merged node every run. Same numeric anchoring discipline as
// MirrorAliasNodeIDs (LIKE keeps the alias-index prefix search; the
// case-sensitive GLOB pair rejects case-variant and non-numeric aliases).
func (db *DB) SituationMirrorNodeIDs() (map[string]bool, error) {
	rows, err := db.Query(`SELECT node_id FROM memory_aliases
		WHERE alias LIKE 'situation:%' AND alias GLOB 'situation:*'
		  AND alias != 'situation:' AND alias NOT GLOB 'situation:*[^0-9]*'`)
	if err != nil {
		return nil, fmt.Errorf("listing situation mirror aliases: %w", err)
	}
	defer rows.Close()

	out := map[string]bool{}
	for rows.Next() {
		var nodeID string
		if err := rows.Scan(&nodeID); err != nil {
			return nil, fmt.Errorf("scanning situation mirror alias: %w", err)
		}
		out[nodeID] = true
	}
	return out, rows.Err()
}

// memoryNodeSelectCols is the shared column list for GetMemoryNode/
// ListMemoryNodes/ListDisputePendingBeliefs: the base memory_nodes columns
// plus DisputePending, derived via EXISTS over the memory_dispute_flags side
// table (see 00019) rather than stored on memory_nodes itself.
const memoryNodeSelectCols = `id, type, tier, status, COALESCE(redirect_to, ''),
		title, path, content_hash, indexed_at, subject, confidence, importance_score,
		EXISTS(SELECT 1 FROM memory_dispute_flags f WHERE f.node_id = memory_nodes.id)`

func scanMemoryNodeRow(scan func(...any) error) (MemoryNodeRow, error) {
	var row MemoryNodeRow
	err := scan(&row.ID, &row.Type, &row.Tier, &row.Status, &row.RedirectTo,
		&row.Title, &row.Path, &row.ContentHash, &row.IndexedAt,
		&row.Subject, &row.Confidence, &row.ImportanceScore, &row.DisputePending)
	return row, err
}

// GetMemoryNode returns one node row by canonical ID. Returns sql.ErrNoRows
// when the node is not indexed.
func (db *DB) GetMemoryNode(id string) (MemoryNodeRow, error) {
	row, err := scanMemoryNodeRow(db.QueryRow(`SELECT `+memoryNodeSelectCols+`
		FROM memory_nodes WHERE id = ?`, id).Scan)
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
	rows, err := db.Query(`SELECT ` + memoryNodeSelectCols + `
		FROM memory_nodes ORDER BY id`)
	if err != nil {
		return nil, fmt.Errorf("listing memory nodes: %w", err)
	}
	defer rows.Close()

	var nodes []MemoryNodeRow
	for rows.Next() {
		row, err := scanMemoryNodeRow(rows.Scan)
		if err != nil {
			return nil, fmt.Errorf("scanning memory node: %w", err)
		}
		nodes = append(nodes, row)
	}
	return nodes, rows.Err()
}

// ListDisputePendingBeliefs returns belief nodes currently flagged in
// memory_dispute_flags, oldest flag first (ties broken by node id), capped to
// limit. A non-positive limit means NO limit (SQLite LIMIT -1) — the per-cycle
// cap policy lives solely at the inbox watchtower detector (memoryDisputeCap),
// never here. Used by the detector to mint dispute trigger items; every
// returned row has DisputePending == true.
func (db *DB) ListDisputePendingBeliefs(limit int) ([]MemoryNodeRow, error) {
	if limit <= 0 {
		limit = -1 // SQLite: LIMIT -1 is unbounded
	}
	rows, err := db.Query(`SELECT `+memoryNodeSelectCols+`
		FROM memory_nodes
		JOIN memory_dispute_flags f ON f.node_id = memory_nodes.id
		WHERE memory_nodes.type = 'belief'
		ORDER BY f.flagged_at, memory_nodes.id
		LIMIT ?`, limit)
	if err != nil {
		return nil, fmt.Errorf("listing dispute-pending beliefs: %w", err)
	}
	defer rows.Close()

	var nodes []MemoryNodeRow
	for rows.Next() {
		row, err := scanMemoryNodeRow(rows.Scan)
		if err != nil {
			return nil, fmt.Errorf("scanning dispute-pending belief: %w", err)
		}
		nodes = append(nodes, row)
	}
	return nodes, rows.Err()
}

// ListBeliefsForSubjects returns belief nodes whose subject is one of
// subjects and whose status is 'active' or 'shaken' — a retired or
// tombstoned belief is not live evidence. This is RetrieveBySubject's
// long-term candidate set (Slice B), replacing meeting-prep's ad hoc
// encounter-order filter (beliefLinesFor); ordering here is arbitrary (by
// id) since RankByImportance imposes the real order. Empty subjects is a
// clean empty read (nil, nil) — no query runs.
func (db *DB) ListBeliefsForSubjects(subjects []string) ([]MemoryNodeRow, error) {
	if len(subjects) == 0 {
		return nil, nil
	}
	placeholders, args := inClause(subjects)
	rows, err := db.Query(`SELECT `+memoryNodeSelectCols+`
		FROM memory_nodes
		WHERE memory_nodes.type = 'belief' AND memory_nodes.subject IN (`+placeholders+`)
		  AND memory_nodes.status IN ('active','shaken')
		ORDER BY memory_nodes.id`, args...)
	if err != nil {
		return nil, fmt.Errorf("listing beliefs for subjects: %w", err)
	}
	defer rows.Close()

	var out []MemoryNodeRow
	for rows.Next() {
		row, err := scanMemoryNodeRow(rows.Scan)
		if err != nil {
			return nil, fmt.Errorf("scanning belief for subject: %w", err)
		}
		out = append(out, row)
	}
	return out, rows.Err()
}

// SetDisputePending flags a belief as disputed: the belief pass or weekly
// reflection (internal/memory) believes the node's evidence conflicts and the
// inbox watchtower detector (internal/inbox) should surface it as a dashboard
// situation. Upserts into the memory_dispute_flags side table (MEM-02-exempt
// runtime state, memory_node_stats precedent) — a re-flag of an
// already-pending node just refreshes flagged_at/reason.
func (db *DB) SetDisputePending(id, reason string) error {
	_, err := db.Exec(`INSERT INTO memory_dispute_flags (node_id, flagged_at, reason)
		VALUES (?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), ?)
		ON CONFLICT(node_id) DO UPDATE SET
			flagged_at = excluded.flagged_at,
			reason = excluded.reason`,
		id, reason)
	if err != nil {
		return fmt.Errorf("setting dispute pending for %s: %w", id, err)
	}
	return nil
}

// UpdateMemoryNodeImportanceScore narrows-updates just the importance_score
// column for an already-indexed node, without touching its content hash,
// body/FTS, aliases, or provenance rows. Used by Reconcile's phase-B
// refinement pass (internal/memory/index.go, MEM-16) to correct a node's
// importance_score once the whole vaultSubdirs walk has completed, so a
// link from a later-scanned directory (e.g. rollups) to an earlier-scanned
// one (e.g. entities) is reflected even within a single Reconcile/Rebuild
// call.
func (db *DB) UpdateMemoryNodeImportanceScore(id string, score float64) error {
	_, err := db.Exec(`UPDATE memory_nodes SET importance_score = ? WHERE id = ?`, score, id)
	if err != nil {
		return fmt.Errorf("updating importance_score for %s: %w", id, err)
	}
	return nil
}

// GetMemoryNodeBody returns the raw body last indexed for id from
// memory_fts — the pre-edit body a caller must read BEFORE overwriting it via
// UpsertMemoryNode, e.g. to diff a node's OLD outgoing links against its NEW
// ones (internal/memory/index.go's Reconcile, MEM-16: closing the
// link-removal asymmetry). Returns sql.ErrNoRows when the node has no FTS row
// (never indexed, or already deleted) — the LookupMemoryAlias convention.
func (db *DB) GetMemoryNodeBody(id string) (string, error) {
	var body string
	err := db.QueryRow(`SELECT body FROM memory_fts WHERE id = ?`, id).Scan(&body)
	if errors.Is(err, sql.ErrNoRows) {
		return "", err
	}
	if err != nil {
		return "", fmt.Errorf("getting memory fts body for %s: %w", id, err)
	}
	return body, nil
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

// MemoryFTSCandidate is one full-text search candidate carrying its full
// indexed row (importance_score included) plus the raw FTS5 rank — the
// wider candidate window RetrieveByQuery (Slice B) re-ranks through
// RankByImportance. Sibling of MemoryHit, which stays the shape
// SearchMemoryFTS/memory_recall use unchanged.
type MemoryFTSCandidate struct {
	Row  MemoryNodeRow
	Rank float64
}

// SearchMemoryFTSCandidates runs the same sanitized FTS5 MATCH as
// SearchMemoryFTS but returns full MemoryNodeRows plus the raw rank,
// best-match-first (ORDER BY rank ascending — SQLite FTS5's bm25-style rank
// is more negative for a better match, the same convention SearchMemoryFTS
// already relies on). SearchMemoryFTS itself is UNCHANGED — this is a new
// sibling, not a modification, so memory_recall's legacy path is untouched
// in this half (Slice B, RetrieveByQuery).
func (db *DB) SearchMemoryFTSCandidates(query string, limit int) ([]MemoryFTSCandidate, error) {
	sanitized := sanitizeFTS5Query(query)
	if sanitized == "" {
		return nil, nil
	}
	if limit <= 0 {
		limit = 20
	}

	// memory_fts and memory_nodes both have an "id" column, so
	// memoryNodeSelectCols's bare "id" would be ambiguous if joined directly
	// against memory_fts; scoping the MATCH in a subquery that renames its id
	// keeps only memory_nodes.id in the outer scope.
	//nolint:sqlclosecheck // rows IS closed by the defer below; the scan closure hides it from the linter
	rows, err := db.Query(`SELECT `+memoryNodeSelectCols+`, cand.rank
		FROM memory_nodes
		JOIN (SELECT id AS cand_id, rank FROM memory_fts WHERE memory_fts MATCH ?) cand
			ON cand.cand_id = memory_nodes.id
		WHERE memory_nodes.status != 'tombstone'
		ORDER BY cand.rank
		LIMIT ?`, sanitized, limit)
	if err != nil {
		return nil, fmt.Errorf("searching memory fts candidates: %w", err)
	}
	defer rows.Close()

	var out []MemoryFTSCandidate
	for rows.Next() {
		var rank float64
		row, err := scanMemoryNodeRow(func(dest ...any) error {
			return rows.Scan(append(dest, &rank)...)
		})
		if err != nil {
			return nil, fmt.Errorf("scanning memory fts candidate: %w", err)
		}
		out = append(out, MemoryFTSCandidate{Row: row, Rank: rank})
	}
	return out, rows.Err()
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

// MessageSender returns messages.user_id for (channelID, ts) — the Slack
// half of memory_provenance.sender_id population (Slice B). Returns
// sql.ErrNoRows when no such message exists (e.g. deleted since extraction);
// the memory package logs and leaves SenderID empty rather than failing the
// whole provenance row — this is index-population plumbing that runs after
// MessageExists (MEM-01) already validated the ref at write time, not a
// second validation gate.
func (db *DB) MessageSender(channelID, ts string) (string, error) {
	var userID string
	err := db.QueryRow(`SELECT user_id FROM messages WHERE channel_id = ? AND ts = ?`, channelID, ts).Scan(&userID)
	if errors.Is(err, sql.ErrNoRows) {
		return "", err
	}
	if err != nil {
		return "", fmt.Errorf("getting message sender %s/%s: %w", channelID, ts, err)
	}
	return userID, nil
}

// GmailMessageSender returns gmail_messages.from_email for id — the Gmail
// half of memory_provenance.sender_id population (Slice B). Returns
// sql.ErrNoRows when no such message exists, mirroring MessageSender.
func (db *DB) GmailMessageSender(id string) (string, error) {
	var fromEmail string
	err := db.QueryRow(`SELECT from_email FROM gmail_messages WHERE id = ?`, id).Scan(&fromEmail)
	if errors.Is(err, sql.ErrNoRows) {
		return "", err
	}
	if err != nil {
		return "", fmt.Errorf("getting gmail message sender %s: %w", id, err)
	}
	return fromEmail, nil
}

// GmailMessageExists reports whether a synced gmail_messages row with the given
// Gmail message id exists — the write-time existence check behind the mail:
// provenance scheme (resolved ambiguity #5: mail's identity is the message id,
// not channel+ts). gmail_messages is a migration-guaranteed base table (00016,
// always present after db.Open), so a query failure is a genuine lookup error
// that propagates (freezing the extract batch, MEM-01/MEM-04) rather than being
// masked as a clean miss — unlike the Swift-owned chat tables, which are
// created lazily and legitimately absent on a headless daemon.
func (db *DB) GmailMessageExists(id string) (bool, error) {
	var one int
	err := db.QueryRow(`SELECT 1 FROM gmail_messages WHERE id = ?`, id).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("checking gmail message %s: %w", id, err)
	}
	return true, nil
}

// CalendarEventExists reports whether a synced calendar_events row with the
// given Google event id exists — the write-time existence check behind the cal:
// provenance scheme (resolved ambiguity #2: cal's identity is the event id, not
// the start time). calendar_events is a migration-guaranteed base table (always
// present after db.Open), so a query failure is a genuine lookup error that
// propagates (freezing the calendar build, MEM-01/MEM-04) rather than being
// masked as a clean miss — unlike the Swift-owned chat tables, which are created
// lazily and legitimately absent on a headless daemon.
func (db *DB) CalendarEventExists(id string) (bool, error) {
	var one int
	err := db.QueryRow(`SELECT 1 FROM calendar_events WHERE id = ?`, id).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("checking calendar event %s: %w", id, err)
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

// MemoryIngestFloor returns the ingest floor: the highest situation id whose
// terminal (done|stale|converted) scan has already been folded into the vault.
// listIngestSituations rescans terminal situations only above it (open ones are
// always scanned). A workspace scalar like the watermark, so MEM-05 holds. A
// fresh workspace without its singleton row reads as 0.
func (db *DB) MemoryIngestFloor() (int64, error) {
	var id int64
	err := db.QueryRow(`SELECT COALESCE(memory_last_ingested_situation_id, 0) FROM workspace LIMIT 1`).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("getting memory ingest floor: %w", err)
	}
	return id, nil
}

// SetMemoryIngestFloor advances the ingest floor (see MemoryIngestFloor).
func (db *DB) SetMemoryIngestFloor(id int64) error {
	if _, err := db.Exec(`UPDATE workspace SET memory_last_ingested_situation_id = ?`, id); err != nil {
		return fmt.Errorf("setting memory ingest floor: %w", err)
	}
	return nil
}

// MemoryChatTurnFloor returns the owner-chat ingest floor: the highest
// chat_messages.id (a Swift-owned table) already folded by
// ingestChatStatements into the belief pass, so a rerun does not re-stage the
// same owner Discuss turns as evidence (Phase 4, Task 4). A workspace scalar
// like MemoryIngestFloor, so MEM-05 holds. A fresh workspace without its
// singleton row reads as 0.
func (db *DB) MemoryChatTurnFloor() (int64, error) {
	var id int64
	err := db.QueryRow(`SELECT COALESCE(memory_chat_turn_floor, 0) FROM workspace LIMIT 1`).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("getting memory chat turn floor: %w", err)
	}
	return id, nil
}

// SetMemoryChatTurnFloor advances the owner-chat ingest floor (see
// MemoryChatTurnFloor).
func (db *DB) SetMemoryChatTurnFloor(id int64) error {
	if _, err := db.Exec(`UPDATE workspace SET memory_chat_turn_floor = ?`, id); err != nil {
		return fmt.Errorf("setting memory chat turn floor: %w", err)
	}
	return nil
}

// ChatTablesPresent reports whether the Swift-owned chat_conversations and
// chat_messages tables both exist. The Desktop app creates them lazily via
// GRDB (ChatConversationQueries/ChatMessageQueries ensureTable) the first time
// the owner opens a Discuss chat, so a headless daemon sees them absent — the
// Phase-4 chat surface (ingestChatStatements + the belief pass's chat: ref
// validation) must treat their absence as an empty read, never an error
// (MEM-05/MEM-09, resolved ambiguity #1).
func (db *DB) ChatTablesPresent() (bool, error) {
	var n int
	err := db.QueryRow(`SELECT COUNT(*) FROM sqlite_master
		WHERE type = 'table' AND name IN ('chat_conversations', 'chat_messages')`).Scan(&n)
	if err != nil {
		return false, fmt.Errorf("checking chat tables presence: %w", err)
	}
	return n == 2, nil
}

// OwnerChatTurnExists reports whether an owner-authored Discuss turn (role='user')
// exists for (conversationID, ts) in a conversation whose context_type is in the
// allowed set — the MEM-09 authenticity check the belief pass runs before
// elevating a chat:<id> evidence ref to owner rank. contextTypes is {"situation"}
// when memory.sources.chats is off (byte-identical to the Phase-4 situation-only
// check) and {"situation","target","track"} when on, so the owner-rank elevation
// widens in lockstep with the source flag. The IN-clause is parameterized, never
// interpolated. Turn ts is chat_messages.created_at (a REAL unix second); the
// evidence-line ts is whole seconds, so the match is against the truncated second
// (CAST ... AS INTEGER). Assumes the chat tables exist — the caller guards with
// ChatTablesPresent, so a missing table surfaces as an error rather than being
// masked as a clean miss.
func (db *DB) OwnerChatTurnExists(conversationID, ts int64, contextTypes []string) (bool, error) {
	if len(contextTypes) == 0 {
		return false, nil
	}
	placeholders, args := inClause(contextTypes)
	args = append(args, conversationID, ts)
	var one int
	err := db.QueryRow(`SELECT 1 FROM chat_messages m
		JOIN chat_conversations c ON c.id = m.conversation_id
		WHERE c.context_type IN (`+placeholders+`)
		  AND c.id = ? AND m.role = 'user' AND CAST(m.created_at AS INTEGER) = ?
		LIMIT 1`, args...).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("checking owner chat turn %d/%d: %w", conversationID, ts, err)
	}
	return true, nil
}

// OwnerChatTurn is one owner-authored (role='user') Discuss turn, projected for
// ingestChatStatements. ContextType is the conversation's context_type
// (situation/target/track) and ContextID its context_id — together they pick the
// right subject mapper (chatSubjects).
type OwnerChatTurn struct {
	ID             int64  // chat_messages.id — the chat-turn ingest floor key
	ConversationID int64  // chat_messages.conversation_id (the chat:<id> ref target)
	ContextType    string // chat_conversations.context_type (situation|target|track)
	ContextID      string // chat_conversations.context_id (the id the chat is about)
	TurnTS         int64  // created_at truncated to whole unix seconds (the evidence-line ts)
	Text           string // verbatim owner statement
}

// ListOwnerChatTurns returns owner Discuss turns (role='user') in conversations
// whose context_type is in the allowed set, with chat_messages.id strictly above
// floor, oldest id first — the input ingestChatStatements folds into the belief
// pass. contextTypes is {"situation"} when memory.sources.chats is off (byte-
// identical to the Phase-4 situation-only read) and {"situation","target","track"}
// when on. The IN-clause is parameterized, never interpolated. The Swift-owned
// chat tables are absent on a headless daemon; that is a clean empty read (nil,
// nil), never an error (MEM-05).
func (db *DB) ListOwnerChatTurns(floor int64, contextTypes []string) ([]OwnerChatTurn, error) {
	present, err := db.ChatTablesPresent()
	if err != nil {
		return nil, err
	}
	if !present || len(contextTypes) == 0 {
		return nil, nil
	}
	placeholders, args := inClause(contextTypes)
	args = append(args, floor)
	rows, err := db.Query(`SELECT m.id, m.conversation_id, c.context_type, COALESCE(c.context_id, ''),
			CAST(m.created_at AS INTEGER), m.text
		FROM chat_messages m
		JOIN chat_conversations c ON c.id = m.conversation_id
		WHERE m.role = 'user' AND c.context_type IN (`+placeholders+`) AND m.id > ?
		ORDER BY m.id`, args...)
	if err != nil {
		return nil, fmt.Errorf("listing owner chat turns: %w", err)
	}
	defer rows.Close()

	var out []OwnerChatTurn
	for rows.Next() {
		var t OwnerChatTurn
		if err := rows.Scan(&t.ID, &t.ConversationID, &t.ContextType, &t.ContextID, &t.TurnTS, &t.Text); err != nil {
			return nil, fmt.Errorf("scanning owner chat turn: %w", err)
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// inClause builds a parameterized "?,?,..." placeholder string and the matching
// args slice for a SQL IN clause — the values are always bound, never
// interpolated (no injection).
func inClause(values []string) (placeholders string, args []any) {
	ph := make([]string, len(values))
	args = make([]any, len(values))
	for i, v := range values {
		ph[i] = "?"
		args[i] = v
	}
	return strings.Join(ph, ","), args
}

// TrackSubjectRefs returns a track's memory subject refs: its channel_ids +
// participant user ids + assignee/requester/owner user ids (raw ids the caller
// resolves to memory entities). READ-ONLY (MEM-05): tracks is read, never
// written. An unknown track id is a clean empty read; the JSON columns are
// app-written valid JSON, so a malformed value is tolerated (the field is
// skipped) rather than failing the read.
func (db *DB) TrackSubjectRefs(trackID int) ([]string, error) {
	var channelIDsJSON, participantsJSON, assignee, requester, owner string
	err := db.QueryRow(`SELECT channel_ids, participants, assignee_user_id, requester_user_id, owner_user_id
		FROM tracks WHERE id = ?`, trackID).Scan(&channelIDsJSON, &participantsJSON, &assignee, &requester, &owner)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading track %d subjects: %w", trackID, err)
	}
	var refs []string
	var channels []string
	_ = json.Unmarshal([]byte(channelIDsJSON), &channels) // tolerate malformed
	refs = append(refs, channels...)
	var participants []struct {
		UserID string `json:"user_id"`
	}
	_ = json.Unmarshal([]byte(participantsJSON), &participants)
	for _, p := range participants {
		if p.UserID != "" {
			refs = append(refs, p.UserID)
		}
	}
	for _, u := range []string{assignee, requester, owner} {
		if u != "" {
			refs = append(refs, u)
		}
	}
	return refs, nil
}

// TrackIDsForTarget returns the ids of tracks linked to the given target
// (tracks.linked_target_id), oldest first — the target→track subject mapping
// (resolved ambiguity #7: a target's memory subjects are its linked track(s)).
// READ-ONLY. A target with no linked track is a clean empty read.
func (db *DB) TrackIDsForTarget(targetID int) ([]int, error) {
	rows, err := db.Query(`SELECT id FROM tracks WHERE linked_target_id = ? ORDER BY id`, targetID)
	if err != nil {
		return nil, fmt.Errorf("listing tracks for target %d: %w", targetID, err)
	}
	defer rows.Close()

	var out []int
	for rows.Next() {
		var id int
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scanning track id for target %d: %w", targetID, err)
		}
		out = append(out, id)
	}
	return out, rows.Err()
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

// ListChannelMessagesInWindow returns one channel's extractable messages in the
// half-open window (fromUnix, toUnix], oldest first — the read-only input the
// dark digest-compare runner (Phase-5 5B) uses to compute a channel window's
// coverage (which messages an episode's provenance covers) and to feed the
// uncovered "coverage gap" messages raw into the render. It applies the SAME
// bot/muted author filter as the extractor's message load, so the coverage
// denominator is exactly the set episodes are built from. Read-only.
func (db *DB) ListChannelMessagesInWindow(channelID string, fromUnix, toUnix float64) ([]MemoryExtractMessage, error) {
	rows, err := db.Query(`
		SELECT m.channel_id, c.name, m.ts, m.ts_unix,
		       COALESCE(NULLIF(u.display_name, ''), NULLIF(u.real_name, ''), NULLIF(u.name, ''), m.user_id),
		       m.text
		FROM messages m
		JOIN channels c ON c.id = m.channel_id
		LEFT JOIN users u ON u.id = m.user_id
		WHERE m.channel_id = ? AND m.text != '' AND m.is_deleted = 0
		  AND ((u.id IS NULL AND m.user_id != '') OR (COALESCE(u.is_bot_override, u.is_bot) = 0 AND u.is_muted_for_llm = 0))
		  AND m.ts_unix > ? AND m.ts_unix <= ?
		ORDER BY m.ts_unix, m.ts`, channelID, fromUnix, toUnix)
	if err != nil {
		return nil, fmt.Errorf("listing channel %s messages in window (%v,%v]: %w", channelID, fromUnix, toUnix, err)
	}
	defer rows.Close()

	var out []MemoryExtractMessage
	for rows.Next() {
		var m MemoryExtractMessage
		if err := rows.Scan(&m.ChannelID, &m.ChannelName, &m.TS, &m.TSUnix, &m.Author, &m.Text); err != nil {
			return nil, fmt.Errorf("scanning channel window message: %w", err)
		}
		out = append(out, m)
	}
	return out, rows.Err()
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

// MemoryGmailWatermark returns the unix ts of the last gmail thread message
// fully folded into an episode by the Gmail thread->episode extractor
// (memory.sources.gmail) for accountID, mirroring MemoryWatermark. Deliberately
// a THIRD, independent watermark alongside gmail_last_internal_date (Gmail
// sync) and memory_last_extracted_ts (Slack episode extraction) — see 00042,
// resolved ambiguity #7. Moved onto google_accounts by migration 00043 (one
// per connected account); a missing account reads as 0.
func (db *DB) MemoryGmailWatermark(accountID int64) (float64, error) {
	var ts float64
	err := db.QueryRow(`SELECT memory_gmail_last_extracted_ts FROM google_accounts WHERE id = ?`, accountID).Scan(&ts)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("getting memory gmail watermark for account %d: %w", accountID, err)
	}
	return ts, nil
}

// SetMemoryGmailWatermark advances the Gmail episode-extraction watermark for
// accountID (see MemoryGmailWatermark). The Gmail extractor advances this only
// behind fully-committed thread batches (MEM-04), never past an unextracted
// thread.
func (db *DB) SetMemoryGmailWatermark(accountID int64, ts float64) error {
	res, err := db.Exec(`UPDATE google_accounts SET memory_gmail_last_extracted_ts = ? WHERE id = ?`, ts, accountID)
	if err != nil {
		return fmt.Errorf("setting memory gmail watermark for account %d: %w", accountID, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("setting memory gmail watermark: no google_accounts row %d", accountID)
	}
	return nil
}

// MemoryCalendarWatermark returns the unix ts of the last ended calendar
// event fully folded into an episode by the mechanical calendar
// past-event->episode builder (memory.sources.calendar), mirroring
// MemoryGmailWatermark. Deliberately a FOURTH, independent watermark
// alongside memory_last_extracted_ts (Slack extraction),
// memory_gmail_last_extracted_ts (Gmail extraction), and
// memory_last_interaction_id (5D interaction-ingest floor) — see 00023. A
// fresh workspace without its singleton row reads as 0.
func (db *DB) MemoryCalendarWatermark() (float64, error) {
	var ts float64
	err := db.QueryRow(`SELECT COALESCE(memory_calendar_last_extracted_ts, 0) FROM workspace LIMIT 1`).Scan(&ts)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("getting memory calendar watermark: %w", err)
	}
	return ts, nil
}

// SetMemoryCalendarWatermark advances the calendar episode-build watermark
// (see MemoryCalendarWatermark). The calendar builder advances this only
// behind fully-committed event episodes (MEM-04, adapted), never past an
// un-built event.
func (db *DB) SetMemoryCalendarWatermark(ts float64) error {
	if _, err := db.Exec(`UPDATE workspace SET memory_calendar_last_extracted_ts = ?`, ts); err != nil {
		return fmt.Errorf("setting memory calendar watermark: %w", err)
	}
	return nil
}

// CalendarExtractEvent is one ended calendar_events row projected for the
// mechanical calendar past-event→episode builder (memory.sources.calendar).
// StartUnix carries the event start time (the cal:<event_id> ref ts, for age
// math); EndUnix carries the end time (the watermark key). Attendees is the raw
// JSON array; RawJSON carries the recurringEventId for series linking.
type CalendarExtractEvent struct {
	ID             string
	Title          string
	Description    string
	Location       string
	OrganizerEmail string
	Attendees      string // JSON array
	StartUnix      int64
	EndUnix        int64
	IsRecurring    bool
	RawJSON        string
}

// ListCalendarEventsForExtract returns ENDED calendar events (end_time before
// now) whose end_time unix is above (sinceTS - lookbackDays), oldest end-time
// first, capped at limit — the raw input the mechanical calendar builder folds
// into episodes. sinceTS is memory_calendar_last_extracted_ts; the bounded
// lookback re-scan overlap (resolved ambiguity #3) means a recap or event-edit
// landing after the watermark passed a still-present event refreshes its episode
// via the calevent: alias, while the content-equality check keeps an unchanged
// re-scan a no-op. calendar_events is a migration-guaranteed base table, so a
// query failure propagates (freezing the calendar watermark) rather than being
// masked as an empty read.
func (db *DB) ListCalendarEventsForExtract(sinceTS float64, lookbackDays, limit int) ([]CalendarExtractEvent, error) {
	if limit <= 0 {
		limit = 2000
	}
	nowUnix := time.Now().Unix()
	floorUnix := int64(sinceTS) - int64(lookbackDays)*86400
	rows, err := db.Query(`
		SELECT id, title, description, location, organizer_email, attendees,
		       CAST(strftime('%s', start_time) AS INTEGER),
		       CAST(strftime('%s', end_time) AS INTEGER),
		       is_recurring, raw_json
		FROM calendar_events
		WHERE end_time != ''
		  AND CAST(strftime('%s', end_time) AS INTEGER) < ?
		  AND CAST(strftime('%s', end_time) AS INTEGER) > ?
		ORDER BY CAST(strftime('%s', end_time) AS INTEGER), id
		LIMIT ?`, nowUnix, floorUnix, limit)
	if err != nil {
		return nil, fmt.Errorf("listing calendar events for extract: %w", err)
	}
	defer rows.Close()

	var out []CalendarExtractEvent
	for rows.Next() {
		var e CalendarExtractEvent
		if err := rows.Scan(&e.ID, &e.Title, &e.Description, &e.Location, &e.OrganizerEmail,
			&e.Attendees, &e.StartUnix, &e.EndUnix, &e.IsRecurring, &e.RawJSON); err != nil {
			return nil, fmt.Errorf("scanning calendar extract event: %w", err)
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// MemoryJiraWatermark reads the Jira episode-extraction watermark — the FIFTH
// extraction watermark (see 00040), unix seconds of the newest fully-committed
// parsed jira_issues.updated_at. A fresh workspace reads 0.
func (db *DB) MemoryJiraWatermark() (float64, error) {
	var ts float64
	err := db.QueryRow(`SELECT COALESCE(memory_jira_last_extracted_ts, 0) FROM workspace LIMIT 1`).Scan(&ts)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("getting memory jira watermark: %w", err)
	}
	return ts, nil
}

// SetMemoryJiraWatermark advances the Jira extraction watermark. Callers only
// move it behind fully-committed issue episodes (MEM-04, adapted).
func (db *DB) SetMemoryJiraWatermark(ts float64) error {
	if _, err := db.Exec(`UPDATE workspace SET memory_jira_last_extracted_ts = ?`, ts); err != nil {
		return fmt.Errorf("setting memory jira watermark: %w", err)
	}
	return nil
}

// JiraIssueExists is the jira: scheme's write-time existence check (MEM-12): a
// jira:<KEY> ref resolves iff a non-deleted jira_issues row carries that key —
// a deleted issue 404s for the owner exactly like a tombstoned Slack message.
// jira_issues is migration-guaranteed, so a lookup failure is a genuine error
// (step freeze), never a clean miss (the CalendarEventExists precedent).
func (db *DB) JiraIssueExists(key string) (bool, error) {
	var one int
	err := db.QueryRow(`SELECT 1 FROM jira_issues WHERE key = ? AND is_deleted = 0`, key).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("checking jira issue %s: %w", key, err)
	}
	return true, nil
}

// jiraUpdatedLayout is Jira Cloud's updated_at format ("+0100" offset — no
// colon, so SQLite's strftime cannot parse it; all time math happens in Go).
const jiraUpdatedLayout = "2006-01-02T15:04:05.000-0700"

// ParseJiraTime parses a jira_issues timestamp, RFC3339 fallback. ok=false for
// an unparseable value — the caller skips the row (the Gmail internal_date
// defensive-skip precedent; the sync guarantees the format).
func ParseJiraTime(s string) (int64, bool) {
	if t, err := time.Parse(jiraUpdatedLayout, s); err == nil {
		return t.Unix(), true
	}
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t.Unix(), true
	}
	return 0, false
}

// JiraExtractIssue is one jira_issues row projected for the mechanical
// issue→episode builder (memory.sources.jira).
type JiraExtractIssue struct {
	Key, ProjectKey, Summary, DescriptionText   string
	IssueType, Status, StatusCategory, Priority string
	AssigneeDisplayName, AssigneeSlackID        string
	ReporterDisplayName, ReporterSlackID        string
	SprintName, EpicKey, DueDate                string
	StoryPoints                                 sql.NullFloat64
	UpdatedAtRaw                                string
	UpdatedUnix                                 int64
	ResolvedAt                                  string
}

// ListJiraIssuesForExtract returns non-deleted issues whose PARSED updated_at
// is strictly above sinceUnix, ascending by UpdatedUnix, capped at limit —
// draining the boundary second so a same-second tie is never split (the
// Slack/Gmail boundary-drain precedent). updated_at carries a "+0100"-style
// offset SQLite cannot compare reliably, so rows are filtered/sorted in Go
// after ParseJiraTime (an unparseable value skips the row). The table is
// small (low thousands), a full scan per run is fine — the whole filtered set
// is already in memory before the cap, so the drain is a plain Go slice
// extension, no second query needed (unlike the Slack/Gmail two-query drain).
func (db *DB) ListJiraIssuesForExtract(sinceUnix int64, limit int) ([]JiraExtractIssue, error) {
	rows, err := db.Query(`SELECT key, project_key, summary, description_text, issue_type,
		status, status_category, priority, assignee_display_name, assignee_slack_id,
		reporter_display_name, reporter_slack_id, sprint_name, epic_key, due_date,
		story_points, updated_at, resolved_at
		FROM jira_issues WHERE is_deleted = 0`)
	if err != nil {
		return nil, fmt.Errorf("listing jira issues for extract: %w", err)
	}
	defer rows.Close()

	var out []JiraExtractIssue
	for rows.Next() {
		var is JiraExtractIssue
		if err := rows.Scan(&is.Key, &is.ProjectKey, &is.Summary, &is.DescriptionText, &is.IssueType,
			&is.Status, &is.StatusCategory, &is.Priority, &is.AssigneeDisplayName, &is.AssigneeSlackID,
			&is.ReporterDisplayName, &is.ReporterSlackID, &is.SprintName, &is.EpicKey, &is.DueDate,
			&is.StoryPoints, &is.UpdatedAtRaw, &is.ResolvedAt); err != nil {
			return nil, fmt.Errorf("scanning jira issue for extract: %w", err)
		}
		u, ok := ParseJiraTime(is.UpdatedAtRaw)
		if !ok || u <= sinceUnix {
			continue
		}
		is.UpdatedUnix = u
		out = append(out, is)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("jira extract rows: %w", err)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].UpdatedUnix < out[j].UpdatedUnix })
	if limit > 0 && len(out) > limit {
		boundary := out[limit-1].UpdatedUnix
		end := limit
		for end < len(out) && out[end].UpdatedUnix == boundary {
			end++
		}
		out = out[:end]
	}
	return out, nil
}

// MaxJiraUpdatedUnix is the no-backfill initializer's bound: the newest parsed
// updated_at among non-deleted issues, 0 when none exist or parse.
func (db *DB) MaxJiraUpdatedUnix() (int64, error) {
	rows, err := db.Query(`SELECT updated_at FROM jira_issues WHERE is_deleted = 0`)
	if err != nil {
		return 0, fmt.Errorf("scanning jira updated_at for max: %w", err)
	}
	defer rows.Close()
	var maxU int64
	for rows.Next() {
		var raw string
		if err := rows.Scan(&raw); err != nil {
			return 0, fmt.Errorf("scanning jira updated_at: %w", err)
		}
		if u, ok := ParseJiraTime(raw); ok && u > maxU {
			maxU = u
		}
	}
	return maxU, rows.Err()
}

// GmailExtractMessage is one gmail_messages row fed to the Gmail thread→episode
// extractor. TSUnix is internal_date decoded to whole unix seconds (the Gmail
// sync stores internal_date as an RFC3339 string, NOT the raw ms-epoch API
// value, so strftime('%s', ...) yields second granularity — the boundary-drain
// tie-safety below is at that granularity).
type GmailExtractMessage struct {
	MessageID string
	ThreadID  string
	Subject   string
	FromEmail string
	FromName  string
	BodyText  string
	TSUnix    float64
}

// gmailTSUnixExpr decodes gmail_messages.internal_date (an RFC3339 string) to
// whole unix seconds. SQLite's strftime parses the 'T'/'Z' RFC3339 shape and
// normalizes any timezone offset to UTC.
const gmailTSUnixExpr = `CAST(strftime('%s', internal_date) AS INTEGER)`

// ListGmailThreadsForExtract returns accountID's gmail_messages with
// internal_date strictly above sinceTS (unix seconds), oldest first, capped at
// limit — the raw input the Gmail extractor groups into per-thread episodes.
// It mirrors ListMemoryExtractMessages: a message cap bounds work per run, and
// a boundary-drain keeps same-second ties safe. internal_date is
// second-granular (RFC3339), so a LIMIT cut can land inside a same-second
// group; the caller's watermark advances to a whole-second internal_date and
// reloads with a strict >, which would permanently skip the unloaded rows of
// that second — so when the limit cuts inside a second this query extends
// past the limit to include ALL rows sharing the last loaded second (overshoot
// at most one second of mail).
//
// gmail_messages is a migration-guaranteed base table (00016), so a query
// failure propagates as a genuine error (freezing the Gmail watermark) rather
// than being masked as an empty read.
func (db *DB) ListGmailThreadsForExtract(accountID int64, sinceTS float64, limit int) ([]GmailExtractMessage, error) {
	if limit <= 0 {
		limit = 2000
	}
	out, err := db.queryGmailExtractMessages(accountID, ">", sinceTS, limit)
	if err != nil || len(out) < limit {
		return out, err
	}
	boundary := out[len(out)-1].TSUnix
	full, err := db.queryGmailExtractMessages(accountID, "=", boundary, -1) // LIMIT -1: unbounded
	if err != nil {
		return nil, err
	}
	i := len(out)
	for i > 0 && out[i-1].TSUnix == boundary {
		i--
	}
	return append(out[:i], full...), nil
}

// queryGmailExtractMessages runs the gmail-extract select for accountID with
// the given comparison operator (">" or "="; never user input) against the
// decoded internal_date. The ORDER BY ends in id (part of the gmail_messages
// primary key) so the ordering is fully deterministic within a same-second
// group, which the boundary-drain above relies on. gmail_messages is a
// migration-guaranteed base table, so a query failure propagates rather than
// being masked.
func (db *DB) queryGmailExtractMessages(accountID int64, op string, tsArg float64, limit int) ([]GmailExtractMessage, error) {
	rows, err := db.Query(`
		SELECT id, thread_id, subject, from_email, from_name, body_text, `+gmailTSUnixExpr+`
		FROM gmail_messages
		WHERE account_id = ? AND internal_date != '' AND `+gmailTSUnixExpr+` `+op+` ?
		ORDER BY `+gmailTSUnixExpr+`, id
		LIMIT ?`, accountID, tsArg, limit)
	if err != nil {
		return nil, fmt.Errorf("listing gmail threads for extract: %w", err)
	}
	defer rows.Close()

	var out []GmailExtractMessage
	for rows.Next() {
		var m GmailExtractMessage
		if err := rows.Scan(&m.MessageID, &m.ThreadID, &m.Subject, &m.FromEmail, &m.FromName, &m.BodyText, &m.TSUnix); err != nil {
			return nil, fmt.Errorf("scanning gmail extract message: %w", err)
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// interactionTables is the whitelist of owner-interaction source tables an act:
// provenance ref may point at (resolved ambiguity #6). A table outside this set
// is a clean drop in InteractionExists, never an error — and, being a fixed set
// of literals, it is the only thing interpolated into the existence query, so no
// injection is possible.
var interactionTables = map[string]bool{
	"inbox_feedback":    true,
	"user_interactions": true,
	"decision_reads":    true,
	"situations":        true,
	"feedback":          true, // situation-level dashboard thumbs (M8, see 00036)
}

// InteractionExists reports whether row id exists in a WHITELISTED
// owner-interaction table — the write-time existence check behind the act:
// scheme (MEM-15). A non-whitelisted table is a clean (false, nil) drop, never
// an error. Existence keys on rowid: inbox_feedback and situations declare an
// INTEGER PRIMARY KEY (which aliases rowid), while user_interactions and
// decision_reads have composite/no integer PK, so rowid is the one uniform
// integer identity across all four whitelisted tables.
func (db *DB) InteractionExists(table string, id int64) (bool, error) {
	if !interactionTables[table] {
		return false, nil
	}
	var one int
	err := db.QueryRow(`SELECT 1 FROM `+table+` WHERE rowid = ?`, id).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("checking interaction %s/%d: %w", table, id, err)
	}
	return true, nil
}

// MemoryInteractionFloor returns the 5D interaction-ingest floor: the highest
// owner-interaction row id already folded into episode-mirror outcome
// annotations and memory_engagement aggregates by the mechanical
// interaction-ingest step (memory.sources.actions), mirroring
// MemoryChatTurnFloor. A fresh workspace without its singleton row reads as 0.
func (db *DB) MemoryInteractionFloor() (int64, error) {
	var id int64
	err := db.QueryRow(`SELECT COALESCE(memory_last_interaction_id, 0) FROM workspace LIMIT 1`).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("getting memory interaction floor: %w", err)
	}
	return id, nil
}

// SetMemoryInteractionFloor advances the interaction-ingest floor (see
// MemoryInteractionFloor). The ingest step advances this only after its
// vault commit and aggregate writes succeed.
func (db *DB) SetMemoryInteractionFloor(id int64) error {
	if _, err := db.Exec(`UPDATE workspace SET memory_last_interaction_id = ?`, id); err != nil {
		return fmt.Errorf("setting memory interaction floor: %w", err)
	}
	return nil
}

// MemorySituationFeedbackFloor returns the interaction-ingest floor over
// feedback(entity_type='situation') — the dashboard's situation-level thumbs
// (M8, see 00036). A sibling of MemoryInteractionFloor with the same
// discipline: read at step start, advanced only after the step's vault commit
// and aggregate writes succeed. A fresh workspace reads as 0.
func (db *DB) MemorySituationFeedbackFloor() (int64, error) {
	var id int64
	err := db.QueryRow(`SELECT COALESCE(memory_last_situation_feedback_id, 0) FROM workspace LIMIT 1`).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("getting memory situation-feedback floor: %w", err)
	}
	return id, nil
}

// SetMemorySituationFeedbackFloor advances the situation-feedback ingest floor
// (see MemorySituationFeedbackFloor).
func (db *DB) SetMemorySituationFeedbackFloor(id int64) error {
	if _, err := db.Exec(`UPDATE workspace SET memory_last_situation_feedback_id = ?`, id); err != nil {
		return fmt.Errorf("setting memory situation-feedback floor: %w", err)
	}
	return nil
}

// BumpEngagement records one owner interaction against a node's engagement
// aggregates, incrementing engaged_count when engaged is true, else
// dismissed_count, and stamping last_interaction_at — the memory_node_stats
// upsert precedent. The interaction-ingest step applies its per-run bumps
// atomically through BumpEngagements (all-or-nothing); this single-bump variant
// is the direct seam tests exercise. Runtime state: MEM-02-exempt like
// memory_entity_hints, survives DropMemoryIndex (see 00042, resolved ambiguity #3).
func (db *DB) BumpEngagement(nodeID string, engaged bool, at string) error {
	stmt := `INSERT INTO memory_engagement (node_id, dismissed_count, last_interaction_at)
		VALUES (?, 1, ?)
		ON CONFLICT(node_id) DO UPDATE SET
			dismissed_count = dismissed_count + 1,
			last_interaction_at = excluded.last_interaction_at`
	if engaged {
		stmt = `INSERT INTO memory_engagement (node_id, engaged_count, last_interaction_at)
		VALUES (?, 1, ?)
		ON CONFLICT(node_id) DO UPDATE SET
			engaged_count = engaged_count + 1,
			last_interaction_at = excluded.last_interaction_at`
	}
	if _, err := db.Exec(stmt, nodeID, at); err != nil {
		return fmt.Errorf("bumping engagement for %s: %w", nodeID, err)
	}
	return nil
}

// EngagementBump is one pending per-entity engagement update for the atomic
// batch applied by BumpEngagements.
type EngagementBump struct {
	NodeID  string
	Engaged bool
	At      string // last_interaction_at stamp (RFC3339)
}

// BumpEngagements applies a whole batch of per-entity bumps in ONE transaction:
// either every bump lands or none do (the tx rolls back on the first error).
// This is what lets the mechanical interaction-ingest hold its feedback floor on
// a transient failure without risking a double-count — a half-applied batch
// followed by a floor rewind would re-count the bumps that had already landed,
// so all-or-nothing makes the re-scan clean (the chat-ingest transient-error
// discipline). An empty batch is a no-op.
func (db *DB) BumpEngagements(bumps []EngagementBump) error {
	if len(bumps) == 0 {
		return nil
	}
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("beginning engagement bump tx: %w", err)
	}
	defer tx.Rollback()

	const dismissedStmt = `INSERT INTO memory_engagement (node_id, dismissed_count, last_interaction_at)
		VALUES (?, 1, ?)
		ON CONFLICT(node_id) DO UPDATE SET
			dismissed_count = dismissed_count + 1,
			last_interaction_at = excluded.last_interaction_at`
	const engagedStmt = `INSERT INTO memory_engagement (node_id, engaged_count, last_interaction_at)
		VALUES (?, 1, ?)
		ON CONFLICT(node_id) DO UPDATE SET
			engaged_count = engaged_count + 1,
			last_interaction_at = excluded.last_interaction_at`
	for _, b := range bumps {
		stmt := dismissedStmt
		if b.Engaged {
			stmt = engagedStmt
		}
		if _, err := tx.Exec(stmt, b.NodeID, b.At); err != nil {
			return fmt.Errorf("bumping engagement for %s: %w", b.NodeID, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("committing engagement bump tx: %w", err)
	}
	return nil
}

// GetEngagement returns a node's accumulated engagement aggregates. It is a
// TEST SEAM only: production retention scoring reads engagement through
// LinkedEntityEngagement (which sums a node's LINKING entities), never a node's
// own row directly. A node with no memory_engagement row (never interacted
// with) reads as (0, 0, nil) rather than an error.
func (db *DB) GetEngagement(nodeID string) (engaged, dismissed int, err error) {
	err = db.QueryRow(`SELECT engaged_count, dismissed_count FROM memory_engagement WHERE node_id = ?`, nodeID).
		Scan(&engaged, &dismissed)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, 0, nil
	}
	if err != nil {
		return 0, 0, fmt.Errorf("getting engagement for %s: %w", nodeID, err)
	}
	return engaged, dismissed, nil
}

// InteractionFeedback is one owner 👍/👎 (inbox_feedback) row projected for the
// mechanical interaction ingest (Phase-5 5D), joined to the situation its inbox
// item belongs to. A feedback item that belongs to no situation yields
// SituationID 0 (a LEFT JOIN, so the row is still consumed by the floor).
type InteractionFeedback struct {
	ID          int64  // inbox_feedback.id — the interaction-ingest floor key
	SituationID int    // situation the feedback item belongs to (0 = none)
	Rating      int    // -1 (dismissed) or +1 (engaged)
	Date        string // created_at as YYYY-MM-DD — the annotation bullet date
	At          string // created_at verbatim — the memory_engagement last_interaction_at stamp
	TSUnix      int64  // created_at unix seconds — the act:inbox_feedback:<id> ref ts
}

// ListInteractionFeedback returns inbox_feedback rows with id strictly above the
// interaction floor, oldest id first, each joined to the situation its inbox item
// belongs to — the append-only owner-action log the mechanical interaction ingest
// folds (memory.sources.actions). READ-ONLY: memory never writes inbox_feedback /
// situation_signals / situations (MEM-05); it only reads them here, exactly as
// IngestSituations already does. An item attached to several situations yields one
// row per situation (all sharing the feedback id, so the floor still advances once
// past it). inbox_feedback / situation_signals are core (always-migrated) tables,
// so a query failure propagates (freezing the floor) rather than being masked.
func (db *DB) ListInteractionFeedback(floor int64) ([]InteractionFeedback, error) {
	rows, err := db.Query(`
		SELECT fb.id, COALESCE(ss.situation_id, 0), fb.rating,
		       strftime('%Y-%m-%d', fb.created_at), fb.created_at,
		       CAST(strftime('%s', fb.created_at) AS INTEGER)
		FROM inbox_feedback fb
		LEFT JOIN situation_signals ss ON ss.inbox_item_id = fb.inbox_item_id
		WHERE fb.id > ?
		ORDER BY fb.id, ss.situation_id`, floor)
	if err != nil {
		return nil, fmt.Errorf("listing interaction feedback: %w", err)
	}
	defer rows.Close()

	var out []InteractionFeedback
	for rows.Next() {
		var f InteractionFeedback
		if err := rows.Scan(&f.ID, &f.SituationID, &f.Rating, &f.Date, &f.At, &f.TSUnix); err != nil {
			return nil, fmt.Errorf("scanning interaction feedback: %w", err)
		}
		out = append(out, f)
	}
	return out, rows.Err()
}

// ListSituationFeedback returns feedback(entity_type='situation') rows with id
// strictly above the situation-feedback floor, oldest id first — the dashboard's
// situation-level 👍/👎, the interaction ingest's SECOND floor-driven source
// (M8, see 00036): since bda8032 the Desktop persists the owner's primary
// rating gesture here on both the Swift fast path and the CLI path, never to
// inbox_feedback. Projected into the same InteractionFeedback shape (the
// situation id parsed from entity_id; a non-numeric entity_id yields
// SituationID 0 and is consumed by the floor like an unattached inbox_feedback
// row). READ-ONLY: memory never writes feedback (MEM-05 discipline). feedback
// is a core (always-migrated) table, so a query failure propagates (freezing
// the floor) rather than being masked.
func (db *DB) ListSituationFeedback(floor int64) ([]InteractionFeedback, error) {
	rows, err := db.Query(`
		SELECT id, COALESCE(CAST(entity_id AS INTEGER), 0), rating,
		       strftime('%Y-%m-%d', created_at), created_at,
		       CAST(strftime('%s', created_at) AS INTEGER)
		FROM feedback
		WHERE entity_type = 'situation' AND id > ?
		ORDER BY id`, floor)
	if err != nil {
		return nil, fmt.Errorf("listing situation feedback: %w", err)
	}
	defer rows.Close()

	var out []InteractionFeedback
	for rows.Next() {
		var f InteractionFeedback
		if err := rows.Scan(&f.ID, &f.SituationID, &f.Rating, &f.Date, &f.At, &f.TSUnix); err != nil {
			return nil, fmt.Errorf("scanning situation feedback: %w", err)
		}
		out = append(out, f)
	}
	return out, rows.Err()
}

// InteractionSituation is one terminal owner-action situation (converted /
// dismissed / done) projected for the mechanical interaction ingest — the
// owner's own lifecycle verdict on a story.
type InteractionSituation struct {
	ID                int
	Status            string // 'converted' | 'dismissed' | 'done'
	ConvertedTargetID int
	ConvertedTrackID  int
	Date              string // updated_at as YYYY-MM-DD — the stable annotation bullet date
	At                string // updated_at verbatim — the last_interaction_at stamp
	TSUnix            int64  // updated_at unix seconds — the act:situations:<id> ref ts
}

// ListInteractionSituations returns situations the OWNER has terminally acted on
// (converted / dismissed / done) whose updated_at is at/after sinceRFC3339,
// oldest id first — the situation-lifecycle half of the mechanical interaction
// ingest. Owner authorship is decided by resolved_reason: the Desktop's done and
// dismiss buttons stamp 'user_done'/'user_dismissed' (SituationQueries.swift),
// while conversion is owner-only by construction (only the Desktop convert flow
// sets status='converted'). The inbox pipeline's auto-resolve stamps
// 'signals_resolved' — a SYSTEM action that must never fold as an owner verdict
// (M7, 2026-07-17 final validation): it would mint false owner-engagement and,
// with memory.semantic.preferences on, preference beliefs from system behavior.
// READ-ONLY (MEM-05): situations are read exactly as IngestSituations reads
// them, never written. The re-scan has no id floor (verdicts are not
// id-monotonic; the mirror's verdict text is the novelty key), so the updated_at
// window bounds it: a situation terminal for longer than the window has already
// had every re-scan chance and is skipped, keeping the unbounded terminal
// backlog off every run. situations is a core (always-migrated) table, so a
// query failure propagates rather than being masked.
func (db *DB) ListInteractionSituations(sinceRFC3339 string) ([]InteractionSituation, error) {
	rows, err := db.Query(`
		SELECT id, status, COALESCE(converted_target_id, 0), COALESCE(converted_track_id, 0),
		       strftime('%Y-%m-%d', updated_at), updated_at, CAST(strftime('%s', updated_at) AS INTEGER)
		FROM situations
		WHERE (status = 'converted'
		       OR (status IN ('dismissed', 'done') AND resolved_reason IN ('user_dismissed', 'user_done')))
		  AND updated_at >= ?
		ORDER BY id`, sinceRFC3339)
	if err != nil {
		return nil, fmt.Errorf("listing interaction situations: %w", err)
	}
	defer rows.Close()

	var out []InteractionSituation
	for rows.Next() {
		var s InteractionSituation
		if err := rows.Scan(&s.ID, &s.Status, &s.ConvertedTargetID, &s.ConvertedTrackID,
			&s.Date, &s.At, &s.TSUnix); err != nil {
			return nil, fmt.Errorf("scanning interaction situation: %w", err)
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// MirrorTarget is the read-only projection of a targets row the mechanical
// operational-mirror step (Phase-5 slice-4, memory.sources.operational) needs to
// render a target's entity mirror body. READ-ONLY: memory never writes targets
// (MEM-14). Terminal is true when the target is in a terminal lifecycle state
// (done / dismissed) — the mirror clears its ## Open loops there.
type MirrorTarget struct {
	ID          int
	Text        string
	Intent      string
	Level       string
	CustomLabel string
	PeriodStart string
	PeriodEnd   string
	Status      string
	Priority    string
	BallOn      string
	DueDate     string
	SubItems    string // JSON: [{text, done, due_date}]
	NextStep    string // JSON: {title, ...}, "" when not generated
	Terminal    bool
}

// MirrorTrack is the read-only projection of a tracks row the operational-mirror
// step needs. READ-ONLY (MEM-14). Terminal is true when the track is dismissed
// (tracks have no separate "done" status — a dismissed_at stamp is the only
// terminal state), where the mirror clears its ## Open loops.
type MirrorTrack struct {
	ID        int
	Text      string
	Category  string
	Ownership string
	BallOn    string
	DueDate   float64 // unix seconds, 0 = none
	Priority  string
	SubItems  string // JSON: [{text, status}]
	Terminal  bool
}

// ListTargetsForMirror returns EVERY target row the operational-mirror step scans
// (no window): the step decides per row whether to build, refresh, or skip, using
// the existing-mirror alias set (MirrorAliasNodeIDs) — a terminal target keeps
// refreshing only while its mirror exists, and a terminal-before-the-source row
// with no mirror is skipped in the step, before any body work. READ-ONLY
// (MEM-14): targets are only read here, never written. targets is a core
// (always-migrated) table, so a query failure propagates.
func (db *DB) ListTargetsForMirror() ([]MirrorTarget, error) {
	rows, err := db.Query(`
		SELECT id, text, intent, level, custom_label, period_start, period_end,
		       status, priority, ball_on, due_date, sub_items, COALESCE(next_step, ''),
		       (status IN ('done', 'dismissed'))
		FROM targets
		ORDER BY id`)
	if err != nil {
		return nil, fmt.Errorf("listing targets for mirror: %w", err)
	}
	defer rows.Close()

	var out []MirrorTarget
	for rows.Next() {
		var t MirrorTarget
		if err := rows.Scan(&t.ID, &t.Text, &t.Intent, &t.Level, &t.CustomLabel,
			&t.PeriodStart, &t.PeriodEnd, &t.Status, &t.Priority, &t.BallOn,
			&t.DueDate, &t.SubItems, &t.NextStep, &t.Terminal); err != nil {
			return nil, fmt.Errorf("scanning target for mirror: %w", err)
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// ListTracksForMirror returns EVERY track row the operational-mirror step scans
// (no window; the same alias-set discipline as ListTargetsForMirror decides
// build/refresh/skip per row). READ-ONLY (MEM-14): tracks are only read here,
// never written. tracks is a core (always-migrated) table, so a query failure
// propagates.
func (db *DB) ListTracksForMirror() ([]MirrorTrack, error) {
	rows, err := db.Query(`
		SELECT id, text, category, ownership, ball_on, COALESCE(due_date, 0),
		       priority, sub_items, (dismissed_at != '')
		FROM tracks
		ORDER BY id`)
	if err != nil {
		return nil, fmt.Errorf("listing tracks for mirror: %w", err)
	}
	defer rows.Close()

	var out []MirrorTrack
	for rows.Next() {
		var t MirrorTrack
		if err := rows.Scan(&t.ID, &t.Text, &t.Category, &t.Ownership, &t.BallOn,
			&t.DueDate, &t.Priority, &t.SubItems, &t.Terminal); err != nil {
			return nil, fmt.Errorf("scanning track for mirror: %w", err)
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// ConvertedSituationIDs returns the ids of situations converted into the given
// target (converted_target_id = targetID) or track (converted_track_id =
// trackID), oldest id first — the DASH-03 conversion link the operational mirror
// resolves to a situation:<id> episode for its ## Links cross-link. A zero
// targetID/trackID matches nothing on that side (a mirror is a target OR a track,
// so the caller passes the relevant id and 0 for the other). READ-ONLY (MEM-14):
// situations are only read here, never written. situations is a core table, so a
// query failure propagates.
func (db *DB) ConvertedSituationIDs(targetID, trackID int) ([]int, error) {
	rows, err := db.Query(`
		SELECT id FROM situations
		WHERE (? != 0 AND converted_target_id = ?)
		   OR (? != 0 AND converted_track_id = ?)
		ORDER BY id`, targetID, targetID, trackID, trackID)
	if err != nil {
		return nil, fmt.Errorf("listing converted situation ids: %w", err)
	}
	defer rows.Close()

	var out []int
	for rows.Next() {
		var id int
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scanning converted situation id: %w", err)
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

// LinkedEntityEngagement sums the engagement aggregates of every live entity that
// links to the given node (its body carries a [[<id>…]] wiki-link) — the
// retention-importance input eviction reads for an episode (Task 8). It mirrors
// CountMemoryLinksIn's link test (instr(body,'[['||id), self-links and tombstones
// excluded) but joins memory_engagement to fold the linking entities' engaged /
// dismissed counts. A node no entity links to, or whose linkers have no
// engagement row, reads as (0, 0, nil).
func (db *DB) LinkedEntityEngagement(id string) (engaged, dismissed int, err error) {
	err = db.QueryRow(`
		SELECT COALESCE(SUM(e.engaged_count), 0), COALESCE(SUM(e.dismissed_count), 0)
		FROM memory_fts f
		JOIN memory_nodes m ON m.id = f.id
		JOIN memory_engagement e ON e.node_id = m.id
		WHERE m.type = 'entity' AND m.status != 'tombstone' AND m.id != ?
		  AND instr(f.body, '[[' || ?) > 0`, id, id).Scan(&engaged, &dismissed)
	if err != nil {
		return 0, 0, fmt.Errorf("summing linked-entity engagement for %s: %w", id, err)
	}
	return engaged, dismissed, nil
}

// DropMemoryIndex empties the vault-derived memory index tables (nodes,
// aliases, provenance, fts) in one transaction so a full reindex can rebuild
// them from the vault (MEM-02).
//
// memory_engagement and memory_dispute_flags carry a REFERENCES
// memory_nodes(id) FK but are deliberately NOT cleared here — they are
// runtime state that must survive a reindex (MEM-02-exempt, the
// memory_entity_hints precedent). Emptying memory_nodes while those rows
// still reference it would otherwise violate the FK the instant DELETE FROM
// memory_nodes runs, so foreign_keys is disabled for the duration of the
// drop, leaving those rows briefly orphaned; Reconcile's subsequent walk
// (Rebuild's caller) reinserts the same deterministic node ids, re-satisfying
// the reference. Toggled via PRAGMA foreign_keys — never defer_foreign_keys,
// which only postpones the check to commit and would not help here since
// nothing re-inserts the parent row within this transaction (see
// TestMigration_TableRecreationPreservesCascadeChildren) — and only outside
// an open transaction, since SQLite refuses to change it mid-BEGIN.
//
// The re-enable is not fire-and-forget: if PRAGMA foreign_keys = ON fails, the
// connection is left with FK enforcement OFF for every subsequent statement on
// it, silently voiding the integrity guarantee the whole database relies on. A
// reindex must fail LOUDLY in that case, so the re-enable error is
// surfaced as the function's error (via the named return) rather than swallowed
// — a successful drop with FKs stuck off is not a success.
func (db *DB) DropMemoryIndex() (err error) {
	if _, err := db.Exec(`PRAGMA foreign_keys = OFF`); err != nil {
		return fmt.Errorf("disabling foreign keys for memory index drop: %w", err)
	}
	defer func() {
		if _, rerr := db.Exec(`PRAGMA foreign_keys = ON`); rerr != nil {
			rerr = fmt.Errorf("re-enabling foreign keys after memory index drop: %w", rerr)
			if err == nil {
				err = rerr // reindex fails loudly rather than continuing with FKs off
			}
		}
	}()

	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("beginning memory drop tx: %w", err)
	}
	defer tx.Rollback()

	// Children first: aliases, stats, provenance, and dispute flags reference
	// memory_nodes. memory_provenance IS vault-derived (rebuilt by Reconcile
	// from each node's ## Provenance section), so — unlike
	// memory_node_stats/engagement/hints — it is cleared here and rebuilt on
	// reindex (inside MEM-02). memory_dispute_flags is cleared too — the
	// "self-healing on reindex" its doc comment promises (found live during
	// final validation: a single dispute flag from a MEM-06 downgrade broke
	// the whole reindex on FK). engagement/hints deliberately SURVIVE via the
	// FK toggle above.
	for _, stmt := range []string{
		`DELETE FROM memory_aliases`,
		`DELETE FROM memory_node_stats`,
		`DELETE FROM memory_provenance`,
		`DELETE FROM memory_dispute_flags`,
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

// DigestShadowRow mirrors one row of memory_digest_shadow (see 00034) — the
// dark digest_compare render's telemetry, keyed by (channel_id, period_from,
// period_to). Memory-owned compare telemetry, never the legacy
// digests/digest_topics tables (MEM-05/MEM-14); never read by any UI.
type DigestShadowRow struct {
	ID                 int64
	ChannelID          string
	PeriodFrom         float64
	PeriodTo           float64
	LegacyDigestID     int64
	RenderedJSON       string
	Coverage           float64
	RenderRefsRejected int
	Model              string
	CreatedAt          string
}

// UpsertDigestShadow writes a shadow row, replacing any existing row for the
// same (channel_id, period_from, period_to) — a rerun of the compare over
// the same window self-overwrites rather than accumulating duplicates.
func (db *DB) UpsertDigestShadow(row DigestShadowRow) error {
	_, err := db.Exec(`INSERT INTO memory_digest_shadow
		(channel_id, period_from, period_to, legacy_digest_id, rendered_json, coverage, render_refs_rejected, model, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(channel_id, period_from, period_to) DO UPDATE SET
			legacy_digest_id = excluded.legacy_digest_id,
			rendered_json = excluded.rendered_json,
			coverage = excluded.coverage,
			render_refs_rejected = excluded.render_refs_rejected,
			model = excluded.model,
			created_at = excluded.created_at`,
		row.ChannelID, row.PeriodFrom, row.PeriodTo, row.LegacyDigestID,
		row.RenderedJSON, row.Coverage, row.RenderRefsRejected, row.Model, row.CreatedAt)
	if err != nil {
		return fmt.Errorf("upserting digest shadow for channel %s [%v,%v]: %w", row.ChannelID, row.PeriodFrom, row.PeriodTo, err)
	}
	return nil
}

// ListDigestShadow returns shadow rows created at or after sinceISO, ordered
// by channel then window — the report's bounded-window input.
func (db *DB) ListDigestShadow(sinceISO string) ([]DigestShadowRow, error) {
	rows, err := db.Query(`SELECT id, channel_id, period_from, period_to, legacy_digest_id,
			rendered_json, coverage, render_refs_rejected, model, created_at
		FROM memory_digest_shadow
		WHERE created_at >= ?
		ORDER BY channel_id, period_from`, sinceISO)
	if err != nil {
		return nil, fmt.Errorf("listing digest shadow rows since %s: %w", sinceISO, err)
	}
	defer rows.Close()

	var result []DigestShadowRow
	for rows.Next() {
		var r DigestShadowRow
		if err := rows.Scan(&r.ID, &r.ChannelID, &r.PeriodFrom, &r.PeriodTo, &r.LegacyDigestID,
			&r.RenderedJSON, &r.Coverage, &r.RenderRefsRejected, &r.Model, &r.CreatedAt); err != nil {
			return nil, fmt.Errorf("scanning digest shadow row: %w", err)
		}
		result = append(result, r)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterating digest shadow rows: %w", err)
	}
	return result, nil
}

// HasFreshDigestShadow reports whether a shadow row already exists for the
// exact (channel, period) window with created_at at or after the legacy
// digest's created_at — i.e. the window was already rendered against this
// legacy digest and re-rendering would only re-spend an AI call for an
// identical comparison (compare runs on a 48h lookback every cycle).
func (db *DB) HasFreshDigestShadow(channelID string, periodFrom, periodTo float64, legacyCreatedAt string) (bool, error) {
	var n int
	err := db.QueryRow(`SELECT COUNT(*) FROM memory_digest_shadow
		WHERE channel_id = ? AND period_from = ? AND period_to = ? AND created_at >= ?`,
		channelID, periodFrom, periodTo, legacyCreatedAt).Scan(&n)
	if err != nil {
		return false, fmt.Errorf("checking digest shadow freshness: %w", err)
	}
	return n > 0, nil
}

// MemoryRetrieveShadowRow mirrors one row of memory_retrieve_shadow (see
// 00039) — Slice B's dark retrieval-compare telemetry, one row per live
// surface comparison (recall/briefing/meeting_prep). Append-only, no FK onto
// memory_nodes: pure telemetry that must survive the compared node's later
// eviction/deletion.
type MemoryRetrieveShadowRow struct {
	ID              int64
	Surface         string // "recall" | "briefing" | "meeting_prep"
	QueryKey        string // surface-specific: the recall query text, the briefing since-ts, the meeting-prep subject entity id
	OldResultJSON   string
	NewResultJSON   string
	DiffMetricsJSON string
	TS              string // RFC3339
}

// InsertMemoryRetrieveShadow appends one Slice-B retrieval-compare telemetry
// row (Task 7). Append-only — unlike UpsertDigestShadow, there is no natural
// dedup key (a surface is called ad hoc, not per fixed window), so repeat
// comparisons simply accumulate as an audit trail.
func (db *DB) InsertMemoryRetrieveShadow(row MemoryRetrieveShadowRow) error {
	_, err := db.Exec(`INSERT INTO memory_retrieve_shadow
		(surface, query_key, old_result_json, new_result_json, diff_metrics_json, ts)
		VALUES (?, ?, ?, ?, ?, ?)`,
		row.Surface, row.QueryKey, row.OldResultJSON, row.NewResultJSON, row.DiffMetricsJSON, row.TS)
	if err != nil {
		return fmt.Errorf("inserting memory retrieve shadow row: %w", err)
	}
	return nil
}

// ListMemoryRetrieveShadow returns surface's shadow rows created at or after
// since (zero time = all), newest first — the CLI report's read path.
func (db *DB) ListMemoryRetrieveShadow(surface string, since time.Time) ([]MemoryRetrieveShadowRow, error) {
	rows, err := db.Query(`SELECT id, surface, query_key, old_result_json, new_result_json, diff_metrics_json, ts
		FROM memory_retrieve_shadow WHERE surface = ? AND ts >= ? ORDER BY id DESC`,
		surface, since.UTC().Format(time.RFC3339))
	if err != nil {
		return nil, fmt.Errorf("listing memory retrieve shadow: %w", err)
	}
	defer rows.Close()
	var out []MemoryRetrieveShadowRow
	for rows.Next() {
		var r MemoryRetrieveShadowRow
		if err := rows.Scan(&r.ID, &r.Surface, &r.QueryKey, &r.OldResultJSON, &r.NewResultJSON, &r.DiffMetricsJSON, &r.TS); err != nil {
			return nil, fmt.Errorf("scanning memory retrieve shadow row: %w", err)
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// FocusFingerprint reads the hash of the last APPLIED focus.md directive set
// (memory focus salience; runtime state like the extraction watermarks).
func (db *DB) FocusFingerprint() (string, error) {
	var fp string
	err := db.QueryRow(`SELECT COALESCE(memory_focus_fingerprint, '') FROM workspace LIMIT 1`).Scan(&fp)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("getting focus fingerprint: %w", err)
	}
	return fp, nil
}

// SetFocusFingerprint stores the applied-focus hash. Callers set it only AFTER
// the matches rewrite and the importance sweep succeeded (freeze-on-error).
func (db *DB) SetFocusFingerprint(fp string) error {
	if _, err := db.Exec(`UPDATE workspace SET memory_focus_fingerprint = ?`, fp); err != nil {
		return fmt.Errorf("setting focus fingerprint: %w", err)
	}
	return nil
}

// ReplaceFocusMatches rewrites the matched-node set wholesale in one
// transaction — the focus counterpart of the alias/FTS replace discipline.
// now and cooled are guaranteed disjoint by the caller (memory.matchFocus
// resolves the Now/Cooled tie itself, keeping a doubly-matched node in Now
// only, before this is ever called), so both loops use a plain INSERT: a
// duplicate node_id here would mean matchFocus's tie-break broke, and should
// fail loudly (a UNIQUE constraint violation) rather than be silently
// papered over by OR REPLACE/OR IGNORE (round-1 review panel nit).
func (db *DB) ReplaceFocusMatches(now, cooled []string) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("focus matches tx: %w", err)
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`DELETE FROM memory_focus_matches`); err != nil {
		return fmt.Errorf("clearing focus matches: %w", err)
	}
	for _, id := range now {
		if _, err := tx.Exec(`INSERT INTO memory_focus_matches (node_id, state) VALUES (?, 'now')`, id); err != nil {
			return fmt.Errorf("inserting focus match %s: %w", id, err)
		}
	}
	for _, id := range cooled {
		if _, err := tx.Exec(`INSERT INTO memory_focus_matches (node_id, state) VALUES (?, 'cooled')`, id); err != nil {
			return fmt.Errorf("inserting cooled match %s: %w", id, err)
		}
	}
	return tx.Commit()
}

// FocusState reads one node's focus membership: ” (unmatched), 'now', or
// 'cooled'. The empty answer is the overwhelmingly common case and must stay
// cheap — a primary-key point read.
func (db *DB) FocusState(nodeID string) (string, error) {
	var state string
	err := db.QueryRow(`SELECT state FROM memory_focus_matches WHERE node_id = ?`, nodeID).Scan(&state)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("reading focus state for %s: %w", nodeID, err)
	}
	return state, nil
}

// MemoryNodeTitle is one non-tombstone node's id+title — the raw material
// for the focus matcher's Unicode-aware, in-process substring match
// (final-review Fix 3: SQLite's lower() folds ASCII only, silently missing
// non-Latin titles; Go's strings.ToLower folds Unicode correctly).
type MemoryNodeTitle struct {
	ID    string
	Title string
}

// ListMemoryNodeTitles returns every non-tombstone node's (id, title) pair —
// the focus matcher's title arm (internal/memory/focus.go's matchFocus)
// fetches this ONCE per call and matches all candidates against it in Go,
// rather than issuing one SQL query per candidate.
func (db *DB) ListMemoryNodeTitles() ([]MemoryNodeTitle, error) {
	rows, err := db.Query(`SELECT id, title FROM memory_nodes WHERE status != 'tombstone' ORDER BY id`)
	if err != nil {
		return nil, fmt.Errorf("listing memory node titles: %w", err)
	}
	defer rows.Close()
	var out []MemoryNodeTitle
	for rows.Next() {
		var t MemoryNodeTitle
		if err := rows.Scan(&t.ID, &t.Title); err != nil {
			return nil, fmt.Errorf("scanning memory node title: %w", err)
		}
		out = append(out, t)
	}
	return out, rows.Err()
}
