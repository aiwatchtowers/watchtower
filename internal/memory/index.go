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
		v:                v,
		database:         database,
		logf:             logf,
		indexed:          indexed,
		onDisk:           make(map[string]bool),
		now:              time.Now().UTC().Format(time.RFC3339),
		stats:            &stats,
		priorLinkTargets: make(map[string]bool),
		ownerMemo:        newOwnerEditedMemo(v),
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

	for _, row := range existing {
		if pass.onDisk[row.ID] {
			continue
		}
		// Capture this doomed node's OWN outgoing links before its row and
		// FTS entry vanish below — its former link targets must still be
		// delta-refined (the second vector of the same link-removal
		// asymmetry file()'s edit case closes above).
		pass.capturePriorLinks(row.ID)
		if err := database.DeleteMemoryNode(row.ID); err != nil {
			return stats, fmt.Errorf("memory: reconcile: %w", err)
		}
		stats.Deleted++
	}

	if err := pass.refineImportance(); err != nil {
		return stats, err
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

	// priorLinkTargets collects node ids a REMOVED link used to point at:
	// from an edited touched node's PRIOR body (captured in file(), read
	// from memory_fts before UpsertMemoryNode overwrites it) and from a
	// deleted node's body (captured in Reconcile's deletion loop, read
	// before DeleteMemoryNode drops it). Unioned into refineImportance's
	// delta-refine candidate set alongside the NEW-body link targets 5d-iii
	// already collects, so both a link ADDED and a link REMOVED cause the
	// affected target to be recomputed — closing the asymmetry 5d-iii left
	// open as a documented residual (second whole-branch review follow-up,
	// 2026-07-19, MEM-16 addendum).
	priorLinkTargets map[string]bool

	// ownerMemo lazily memoizes v.OwnerEditedFiles() (ownerEditedMemo,
	// vault.go) — Reconcile's own instance of the same shared per-call
	// memoization every genuine batch upsertIndexNode caller now uses
	// (second whole-branch review follow-up, 2026-07-19, MEM-16 addendum:
	// this used to be three ad hoc fields on reconcilePass alone).
	ownerMemo *ownerEditedMemo
}

func (p *reconcilePass) quarantine(rel string, reason error) {
	p.logf("memory: reconcile: quarantined %s: %v (file kept, existing index row preserved)", rel, reason)
	p.stats.Quarantined++
	p.stats.QuarantinedPaths = append(p.stats.QuarantinedPaths, rel)
}

// ownerEdited is reconcilePass's owner-touch signal, passed to
// computeNodeImportance as its ownerEdited func(rel string) (bool, error)
// parameter — a thin delegate to the shared ownerEditedMemo (vault.go),
// scoped to this one Reconcile call exactly as before this refactor.
func (p *reconcilePass) ownerEdited(rel string) (bool, error) {
	return p.ownerMemo.lookup(rel)
}

// capturePriorLinks reads id's currently-indexed body — BEFORE the caller
// overwrites it (file(), an edited node) or removes it (Reconcile's deletion
// loop) — and adds every outgoing link target to priorLinkTargets, closing
// the link-removal asymmetry: a link REMOVED by an edit, or a linking file
// deleted outright, must still cause its old target to be delta-refined
// (refineImportance, MEM-16). A read failure only narrows this pass's
// delta-refine candidate set for id; it never blocks the caller's own write
// or deletion — the same log-and-continue-keep-prior-value policy this
// package already applies to every other signal-lookup error.
func (p *reconcilePass) capturePriorLinks(id string) {
	oldBody, err := p.database.GetMemoryNodeBody(id)
	if err != nil {
		p.logf("memory: reconcile: reading prior body for %s failed (link-removal delta-refine narrowed): %v", id, err)
		return
	}
	for _, link := range (Node{Body: oldBody}).Links() {
		p.priorLinkTargets[link.ID] = true
	}
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

	importance, err := computeNodeImportance(p.database, p.ownerEdited, n, rel)
	if err != nil {
		p.quarantine(rel, fmt.Errorf("computing importance: %w", err))
		return nil
	}

	if wasIndexed {
		// Capture the PRIOR body's outgoing links before UpsertMemoryNode
		// (below) overwrites the FTS row — a link REMOVED by this edit must
		// still cause its old target to be delta-refined.
		p.capturePriorLinks(id)
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

// refineImportance is Reconcile's phase B, run after the deletion loop (see
// 5d-i): recompute importance for every file this pass successfully indexed
// (phase A), now that the run's full link graph is populated and this run's
// deletions have already happened — correcting phase A's scan-order-
// dependent initial value. It then delta-refines every node a touched node's
// body links to that WASN'T itself touched this run: a node's own file may
// never change while its LinksIn keeps growing purely from OTHER nodes'
// new links (e.g. a person entity linked from many new Slack-extracted
// episodes over weeks) — CountMemoryLinksIn is this formula's dominant
// signal, so without this delta pass such a node's importance_score would
// stay frozen indefinitely (whole-branch review follow-up, added
// 2026-07-18, MEM-16 — the Critical bug). Also delta-refines every node a
// REMOVED link used to point at: file() captures an edited touched node's
// PRIOR body's outgoing links (read from memory_fts before UpsertMemoryNode
// overwrites it) and Reconcile's deletion loop captures a doomed node's own
// outgoing links (read before DeleteMemoryNode drops it) — both unioned into
// the same candidate set below, closing the asymmetry a prior version of
// this pass left as a documented residual (second whole-branch review
// follow-up, 2026-07-19, MEM-16 addendum). Still one hop only: a target's
// OWN further link neighbors are never chased. Any recompute error (either
// phase) is logged and that node's prior importance_score is kept — not
// escalated to an abort or a quarantine, the same policy this function
// already used for its own phase-A-value errors.
func (p *reconcilePass) refineImportance() error {
	touchedIDs := make(map[string]bool, len(p.touched))
	for _, tn := range p.touched {
		touchedIDs[tn.n.ID] = true
	}

	for _, tn := range p.touched {
		importance, err := computeNodeImportance(p.database, p.ownerEdited, tn.n, tn.rel)
		if err != nil {
			p.logf("memory: reconcile: refining importance for %s failed (keeping first-pass value): %v", tn.n.ID, err)
			continue
		}
		if err := p.database.UpdateMemoryNodeImportanceScore(tn.n.ID, importance); err != nil {
			return fmt.Errorf("memory: reconcile: refining importance for %s: %w", tn.n.ID, err)
		}
	}

	linkTargets := make(map[string]bool)
	for _, tn := range p.touched {
		for _, link := range tn.n.Links() {
			if touchedIDs[link.ID] {
				continue
			}
			linkTargets[link.ID] = true
		}
	}
	// Union in every id a REMOVED link (from an edit's prior body, or from a
	// deleted node's body) used to point at — recomputation is idempotent,
	// so a target already in linkTargets (a link that's still present) costs
	// nothing extra to add again. Closes the asymmetry a link ADDITION alone
	// left open (second whole-branch review follow-up, 2026-07-19, MEM-16
	// addendum).
	for id := range p.priorLinkTargets {
		if touchedIDs[id] {
			continue
		}
		linkTargets[id] = true
	}
	for id := range linkTargets {
		if err := p.refineLinkedNode(id); err != nil {
			return err
		}
	}
	return nil
}

// refineLinkedNode recomputes and persists the importance of id — a node
// some touched node's body links to, but which was not itself touched this
// run (so file() never computed a value for it this pass). A dangling or
// stale link (not a valid node id, or the node no longer exists on disk —
// merge.go documents that incoming [[loser]] links are never rewritten
// after a merge, so a tombstoned-but-still-present id is normal and simply
// gets its tombstone body re-read here) or a signal-lookup error is logged
// and skipped, keeping that node's prior importance_score untouched — the
// same log-and-continue-keep-prior-value policy refineImportance uses for
// its own errors above.
func (p *reconcilePass) refineLinkedNode(id string) error {
	rel, err := nodeRelPath(id)
	if err != nil {
		p.logf("memory: reconcile: refining linked node %s failed (not a node id, keeping prior value): %v", id, err)
		return nil
	}
	n, err := p.v.ReadNode(id)
	if err != nil {
		p.logf("memory: reconcile: refining linked node %s failed (keeping prior value): %v", id, err)
		return nil
	}
	importance, err := computeNodeImportance(p.database, p.ownerEdited, n, rel)
	if err != nil {
		p.logf("memory: reconcile: refining linked node %s failed (keeping prior value): %v", id, err)
		return nil
	}
	if err := p.database.UpdateMemoryNodeImportanceScore(id, importance); err != nil {
		return fmt.Errorf("memory: reconcile: refining linked node %s: %w", id, err)
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
