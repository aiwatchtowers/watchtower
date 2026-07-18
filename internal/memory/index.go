package memory

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"

	"watchtower/internal/db"
)

// Stats counts the index mutations performed by one Reconcile pass.
type Stats struct {
	Added   int
	Updated int
	Deleted int
	// Quarantined counts node files skipped because they could not be parsed
	// or indexed (Obsidian CRLF/BOM damage, unknown frontmatter key, filename
	// mismatch, duplicate alias). The file stays on disk and its existing
	// index row (if any) is preserved — quarantine never deletes anything.
	Quarantined      int
	QuarantinedPaths []string
}

// touchedNode records one successfully-indexed file from the current
// Reconcile pass so its importance can be refined in phase B, once the
// whole vaultSubdirs walk completes — see refineImportance. A link from a
// later-scanned directory to an earlier one is otherwise invisible to
// CountMemoryLinksIn during phase A's processing of the earlier node
// (Slice A follow-up, added 2026-07-18, MEM-16).
type touchedNode struct {
	n   Node
	rel string
}

// Reconcile diffs the vault working tree against the SQLite index: node files
// whose sha256 content hash differs from memory_nodes.content_hash (or that
// are missing from the index) are re-parsed and upserted (row + aliases +
// FTS); index rows whose file no longer exists are deleted. Non-node files —
// anything in the four subdirectories not named <matching-prefix-id>.md — are
// skipped, as is map.md at the vault root.
//
// A per-file failure (parse error, id/filename mismatch, index upsert error
// such as a duplicate alias) quarantines that file: it is skipped and counted
// (Stats.Quarantined + path list), a warning is logged with the exact path,
// and — because the file still exists on disk — its previously indexed row is
// NOT deleted by the removal loop. One malformed owner edit must never brick
// the whole consolidation phase. Reconcile itself errors only on IO/DB-wide
// failures (listing the index, reading a directory or file, deleting a row).
func Reconcile(v *Vault, database *db.DB, logf func(string, ...any)) (Stats, error) {
	if logf == nil {
		logf = func(string, ...any) {}
	}
	var stats Stats

	existing, err := database.ListMemoryNodes()
	if err != nil {
		return stats, fmt.Errorf("memory: reconcile: %w", err)
	}
	indexed := make(map[string]db.MemoryNodeRow, len(existing))
	for _, row := range existing {
		indexed[row.ID] = row
	}

	pass := &reconcilePass{
		v:        v,
		database: database,
		logf:     logf,
		indexed:  indexed,
		onDisk:   make(map[string]bool),
		now:      time.Now().UTC().Format(time.RFC3339),
		stats:    &stats,
	}
	for _, sub := range vaultSubdirs {
		entries, err := os.ReadDir(filepath.Join(v.path, sub))
		if err != nil {
			return stats, fmt.Errorf("memory: reconcile: read %s: %w", sub, err)
		}
		for _, entry := range entries {
			if err := pass.file(sub, entry); err != nil {
				return stats, err
			}
		}
	}

	if err := pass.refineImportance(); err != nil {
		return stats, err
	}

	for _, row := range existing {
		if pass.onDisk[row.ID] {
			continue
		}
		if err := database.DeleteMemoryNode(row.ID); err != nil {
			return stats, fmt.Errorf("memory: reconcile: %w", err)
		}
		stats.Deleted++
	}

	return stats, nil
}

// reconcilePass carries the shared state of one Reconcile sweep so the
// per-file work can live in its own function.
type reconcilePass struct {
	v        *Vault
	database *db.DB
	logf     func(string, ...any)
	indexed  map[string]db.MemoryNodeRow
	onDisk   map[string]bool
	now      string
	stats    *Stats
	touched  []touchedNode
}

func (p *reconcilePass) quarantine(rel string, reason error) {
	p.logf("memory: reconcile: quarantined %s: %v (file kept, existing index row preserved)", rel, reason)
	p.stats.Quarantined++
	p.stats.QuarantinedPaths = append(p.stats.QuarantinedPaths, rel)
}

// file processes one directory entry: skip non-node files, hash, parse, and
// upsert. It returns an error only for IO-wide failures; per-file problems
// quarantine the file and return nil.
func (p *reconcilePass) file(sub string, entry os.DirEntry) error {
	if entry.IsDir() {
		return nil
	}
	id, ok := strings.CutSuffix(entry.Name(), ".md")
	if !ok {
		return nil
	}
	// A node file's ID prefix must match its directory; anything else
	// (notes.md, a misplaced ent_*.md in episodes/) is not a node.
	if ownSub, err := subdirFor(id); err != nil || ownSub != sub {
		return nil //nolint:nilerr // not a node file — skipped, not an error
	}

	rel := path.Join(sub, entry.Name())
	raw, err := os.ReadFile(filepath.Join(p.v.path, sub, entry.Name()))
	if err != nil {
		return fmt.Errorf("memory: reconcile: read %s: %w", rel, err)
	}
	p.onDisk[id] = true

	sum := sha256.Sum256(raw)
	hash := hex.EncodeToString(sum[:])
	prev, wasIndexed := p.indexed[id]
	if wasIndexed && prev.ContentHash == hash {
		return nil
	}

	n, err := ParseNode(raw)
	if err != nil {
		p.quarantine(rel, err)
		return nil
	}
	if n.ID != id {
		p.quarantine(rel, fmt.Errorf("frontmatter id %q does not match filename", n.ID))
		return nil
	}

	importance, err := computeNodeImportance(p.database, p.v, n, rel)
	if err != nil {
		p.quarantine(rel, fmt.Errorf("computing importance: %w", err))
		return nil
	}

	row := db.MemoryNodeRow{
		ID:              n.ID,
		Type:            n.Type,
		Tier:            n.Tier,
		Status:          n.Status,
		RedirectTo:      n.RedirectTo,
		Title:           n.Title,
		Path:            rel,
		ContentHash:     hash,
		IndexedAt:       p.now,
		Subject:         n.Subject,    // file-derived (belief-only; "" otherwise), see 00019
		Confidence:      n.Confidence, // file-derived (belief-only; 0 otherwise), see 00019
		ImportanceScore: importance,   // merged override-or-computed snapshot, see 00027 (MEM-16)
	}
	if err := p.database.UpsertMemoryNode(row, n.Body, n.Aliases, provenanceRows(n, p.logf)...); err != nil {
		p.quarantine(rel, err)
		return nil
	}
	p.touched = append(p.touched, touchedNode{n: n, rel: rel})
	if wasIndexed {
		p.stats.Updated++
	} else {
		p.stats.Added++
	}
	return nil
}

// refineImportance is Reconcile's phase B: after the whole vaultSubdirs walk
// completes, recompute importance for every file this pass successfully
// indexed, now that the run's full link graph is populated — correcting
// phase A's scan-order-dependent initial value. A recompute error is logged
// and that node's phase-A value is kept (not escalated to an abort or a
// quarantine — the file's content was already successfully indexed in phase
// A; only its importance may be transiently stale, which is an accepted
// characteristic elsewhere in this design). Slice A follow-up, added
// 2026-07-18, MEM-16.
func (p *reconcilePass) refineImportance() error {
	for _, tn := range p.touched {
		importance, err := computeNodeImportance(p.database, p.v, tn.n, tn.rel)
		if err != nil {
			p.logf("memory: reconcile: refining importance for %s failed (keeping first-pass value): %v", tn.n.ID, err)
			continue
		}
		if err := p.database.UpdateMemoryNodeImportanceScore(tn.n.ID, importance); err != nil {
			return fmt.Errorf("memory: reconcile: refining importance for %s: %w", tn.n.ID, err)
		}
	}
	return nil
}

// Rebuild drops the whole memory index and reconciles it back from the vault
// (MEM-02: the rebuilt index equals the incrementally-maintained one).
// memory_node_stats is cleared too and NOT restored — access stats are
// runtime state, not derivable from files; losing them on reindex is accepted
// v1 behavior.
func Rebuild(v *Vault, database *db.DB, logf func(string, ...any)) (Stats, error) {
	if err := database.DropMemoryIndex(); err != nil {
		return Stats{}, fmt.Errorf("memory: rebuild: %w", err)
	}
	stats, err := Reconcile(v, database, logf)
	if err != nil {
		return stats, fmt.Errorf("memory: rebuild: %w", err)
	}
	return stats, nil
}
