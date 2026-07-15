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
	quarantine := func(rel string, reason error) {
		logf("memory: reconcile: quarantined %s: %v (file kept, existing index row preserved)", rel, reason)
		stats.Quarantined++
		stats.QuarantinedPaths = append(stats.QuarantinedPaths, rel)
	}

	existing, err := database.ListMemoryNodes()
	if err != nil {
		return stats, fmt.Errorf("memory: reconcile: %w", err)
	}
	indexed := make(map[string]db.MemoryNodeRow, len(existing))
	for _, row := range existing {
		indexed[row.ID] = row
	}

	now := time.Now().UTC().Format(time.RFC3339)
	onDisk := make(map[string]bool)
	for _, sub := range vaultSubdirs {
		entries, err := os.ReadDir(filepath.Join(v.path, sub))
		if err != nil {
			return stats, fmt.Errorf("memory: reconcile: read %s: %w", sub, err)
		}
		for _, entry := range entries {
			if entry.IsDir() {
				continue
			}
			id, ok := strings.CutSuffix(entry.Name(), ".md")
			if !ok {
				continue
			}
			// A node file's ID prefix must match its directory; anything else
			// (notes.md, a misplaced ent_*.md in episodes/) is not a node.
			if ownSub, err := subdirFor(id); err != nil || ownSub != sub {
				continue
			}

			rel := path.Join(sub, entry.Name())
			raw, err := os.ReadFile(filepath.Join(v.path, sub, entry.Name()))
			if err != nil {
				return stats, fmt.Errorf("memory: reconcile: read %s: %w", rel, err)
			}
			onDisk[id] = true

			sum := sha256.Sum256(raw)
			hash := hex.EncodeToString(sum[:])
			prev, wasIndexed := indexed[id]
			if wasIndexed && prev.ContentHash == hash {
				continue
			}

			n, err := ParseNode(raw)
			if err != nil {
				quarantine(rel, err)
				continue
			}
			if n.ID != id {
				quarantine(rel, fmt.Errorf("frontmatter id %q does not match filename", n.ID))
				continue
			}

			row := db.MemoryNodeRow{
				ID:          n.ID,
				Type:        n.Type,
				Tier:        n.Tier,
				Status:      n.Status,
				RedirectTo:  n.RedirectTo,
				Title:       n.Title,
				Path:        rel,
				ContentHash: hash,
				IndexedAt:   now,
			}
			if err := database.UpsertMemoryNode(row, n.Body, n.Aliases); err != nil {
				quarantine(rel, err)
				continue
			}
			if wasIndexed {
				stats.Updated++
			} else {
				stats.Added++
			}
		}
	}

	for _, row := range existing {
		if onDisk[row.ID] {
			continue
		}
		if err := database.DeleteMemoryNode(row.ID); err != nil {
			return stats, fmt.Errorf("memory: reconcile: %w", err)
		}
		stats.Deleted++
	}

	return stats, nil
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
