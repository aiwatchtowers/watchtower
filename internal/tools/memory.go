package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"watchtower/internal/db"
	"watchtower/internal/memory"
)

// defaultRecallLimit applies when memory_recall's caller left limit unset.
const defaultRecallLimit = 10

// memoryNotInitializedMsg is the graceful-degradation answer for all memory_
// tools when the vault is unavailable: memory disabled (no vault configured)
// or the vault directory not created yet.
const memoryNotInitializedMsg = "memory not initialized: the memory vault does not exist yet " +
	"(memory may be disabled in config, or consolidation has not run)"

type memoryMapArgs struct{}

type memoryOpenArgs struct {
	Ref string `json:"ref" jsonschema:"memory node id (ent_*/ep_*/sum_*/bel_*), any alias, or a tombstoned old id"`
}

type memoryRecallArgs struct {
	Query string `json:"query" jsonschema:"full-text query over memory titles and bodies; an exact alias match ranks first"`
	Limit int    `json:"limit,omitempty" jsonschema:"max results, 0 = default (10), capped at 200"`
}

// memoryTypeTierCount is one node-count bucket in the memory_map payload.
type memoryTypeTierCount struct {
	Type  string `json:"type"`
	Tier  string `json:"tier"`
	Count int    `json:"count"`
}

type memoryMapResult struct {
	Map    string                `json:"map"`
	Counts []memoryTypeTierCount `json:"counts"`
}

type memoryLinkResult struct {
	ID    string `json:"id"`
	Label string `json:"label,omitempty"`
}

// memoryNodeResult is the memory_open payload. ID is always the final
// canonical id (tombstone redirects already chased), so callers holding a
// stale id can self-heal.
type memoryNodeResult struct {
	ID      string             `json:"id"`
	Type    string             `json:"type"`
	Tier    string             `json:"tier"`
	Status  string             `json:"status"`
	Title   string             `json:"title,omitempty"`
	Aliases []string           `json:"aliases,omitempty"`
	Links   []memoryLinkResult `json:"links,omitempty"`
	Body    string             `json:"body"`
}

// memoryHitResult is one memory_recall search hit.
type memoryHitResult struct {
	ID      string `json:"id"`
	Title   string `json:"title"`
	Type    string `json:"type"`
	Snippet string `json:"snippet"`
}

// memoryUnavailable returns the not-initialized error when the vault is
// unusable, nil when it exists. It checks for the vault's .git directory
// rather than opening it, so the read path never git-inits a vault — creating
// one is the consolidation pipeline's job.
func memoryUnavailable(vaultPath string) error {
	if vaultPath == "" {
		return errors.New(memoryNotInitializedMsg)
	}
	if _, err := os.Stat(filepath.Join(vaultPath, ".git")); err != nil {
		return errors.New(memoryNotInitializedMsg)
	}
	return nil
}

// NewMemoryMap is the read tool returning the hot memory world map plus node
// counts by type and tier. It closes over the vault path (a filesystem read of
// map.md) and reads the SQLite index for the counts.
func NewMemoryMap(vaultPath string) *Tool {
	return &Tool{
		Name:        "memory_map",
		Description: "Read the hot memory world map (map.md — a compact at-a-glance summary; use memory_recall or memory_open for anything not shown) plus node counts by type and tier.",
		InputSchema: mustSchema[memoryMapArgs]("memory_map"),
		Access:      AccessRead,
		Execute: func(_ context.Context, d *db.DB, _ Call) (any, error) {
			if err := memoryUnavailable(vaultPath); err != nil {
				return nil, err
			}
			mapMD, err := os.ReadFile(filepath.Join(vaultPath, "map.md"))
			if err != nil {
				return nil, fmt.Errorf("reading memory map: %w", err)
			}
			rows, err := d.ListMemoryNodes()
			if err != nil {
				return nil, fmt.Errorf("counting memory nodes: %w", err)
			}
			// Tombstones are redirects, not knowledge — excluded, matching the
			// map render in the consolidation pipeline.
			byBucket := map[memoryTypeTierCount]int{}
			for _, row := range rows {
				if row.Status == "tombstone" {
					continue
				}
				byBucket[memoryTypeTierCount{Type: row.Type, Tier: row.Tier}]++
			}
			counts := make([]memoryTypeTierCount, 0, len(byBucket))
			for bucket, n := range byBucket {
				bucket.Count = n
				counts = append(counts, bucket)
			}
			sort.Slice(counts, func(a, b int) bool {
				if counts[a].Type != counts[b].Type {
					return counts[a].Type < counts[b].Type
				}
				return counts[a].Tier < counts[b].Tier
			})
			return memoryMapResult{Map: string(mapMD), Counts: counts}, nil
		},
	}
}

// NewMemoryOpen is the read tool opening one node by id, alias, or stale id.
// It bumps the node's usage stats — best-effort telemetry, the one deliberate
// write on the read surface (DEV-01): on a query_only (dev) session the write
// fails silently and the open still returns the node; on the writable chat
// session it lands. The bump goes through the Execute-supplied handle, so it
// inherits whichever read-only state that connection carries.
func NewMemoryOpen(vaultPath string) *Tool {
	return &Tool{
		Name:        "memory_open",
		Description: "Open one memory node by id, alias, or a stale (tombstoned) id; returns the canonical node with body, aliases, and outgoing links.",
		InputSchema: mustSchema[memoryOpenArgs]("memory_open"),
		Access:      AccessRead,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			if err := memoryUnavailable(vaultPath); err != nil {
				return nil, err
			}
			var a memoryOpenArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			ref := strings.TrimSpace(a.Ref)
			if ref == "" {
				return nil, &ValidationError{Msg: "ref is required"}
			}
			v, err := memory.OpenExistingVault(vaultPath)
			if err != nil {
				return nil, fmt.Errorf("opening memory vault: %w", err)
			}
			n, err := memory.Resolve(v, d, ref)
			if errors.Is(err, memory.ErrNotFound) {
				return nil, fmt.Errorf("no memory node or alias matching %s", strconv.Quote(ref))
			}
			if err != nil {
				return nil, fmt.Errorf("opening memory node: %w", err)
			}
			// Open is "use", so it counts toward the node's stats — always for
			// the canonical node, even when the caller passed a stale id. The
			// bump is best-effort telemetry: on a query_only session the write
			// fails and the open must still return the node.
			_ = d.BumpMemoryAccess(n.ID)

			var links []memoryLinkResult
			for _, l := range n.Links() {
				links = append(links, memoryLinkResult{ID: l.ID, Label: l.Label})
			}
			return memoryNodeResult{
				ID:      n.ID,
				Type:    n.Type,
				Tier:    n.Tier,
				Status:  n.Status,
				Title:   n.Title,
				Aliases: n.Aliases,
				Links:   links,
				Body:    n.Body,
			}, nil
		},
	}
}

// NewMemoryRecall is the read tool searching memory full-text with alias-first
// ranking. It closes over shadowDB, the SEPARATE ordinarily-writable handle for
// the dark retrieval-compare shadow write (memory.retrieve.recall_compare); nil
// means the flag is off and recall never touches memory_retrieve_shadow. Recall
// itself never bumps node stats — browsing is not use, only memory_open counts.
func NewMemoryRecall(vaultPath string, shadowDB *db.DB) *Tool {
	return &Tool{
		Name:        "memory_recall",
		Description: "Full-text search over memory nodes; an exact alias match ranks first. Returns id, title, type, snippet per hit.",
		InputSchema: mustSchema[memoryRecallArgs]("memory_recall"),
		Access:      AccessRead,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			if err := memoryUnavailable(vaultPath); err != nil {
				return nil, err
			}
			var a memoryRecallArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			query := strings.TrimSpace(a.Query)
			if query == "" {
				return nil, &ValidationError{Msg: "query is required"}
			}
			limit := a.Limit
			switch {
			case limit <= 0:
				limit = defaultRecallLimit
			case limit > maxListLimit:
				limit = maxListLimit
			}

			// An exact alias match (case-insensitive) ranks first: aliases are
			// curated synonyms, so hitting one is a stronger signal than any FTS
			// rank.
			hits, err := recallAliasHit(d, query)
			if err != nil {
				return nil, err
			}
			ftsHits, err := d.SearchMemoryFTS(query, limit)
			if err != nil {
				return nil, fmt.Errorf("searching memory: %w", err)
			}
			hits = mergeFTSHits(hits, ftsHits, limit)
			runRecallCompare(d, shadowDB, query, hits, limit)
			if hits == nil {
				hits = []memoryHitResult{}
			}
			return hits, nil
		},
	}
}

// mergeFTSHits appends ftsHits to hits (skipping the alias hit's own id, when
// present), capped at limit.
func mergeFTSHits(hits []memoryHitResult, ftsHits []db.MemoryHit, limit int) []memoryHitResult {
	for _, h := range ftsHits {
		if len(hits) > 0 && hits[0].ID == h.ID {
			continue // already present as the alias hit
		}
		hits = append(hits, memoryHitResult{ID: h.ID, Title: h.Title, Type: h.Type, Snippet: h.Snippet})
	}
	if len(hits) > limit {
		hits = hits[:limit]
	}
	return hits
}

// runRecallCompare is the Slice B Task 8 dark retrieval-compare
// (memory.retrieve.recall_compare): runs RetrieveByQuery and shadow-diffs it
// against hits — the EXACT combined legacy result the tool is about to return.
// The comparison result is discarded; the response is unaffected regardless of
// the flag. A compare failure is skipped silently here (no logger threaded into
// this tool today) — it must never fail or alter the actual tool call. A nil
// shadowDB (the flag off) is a no-op.
func runRecallCompare(readDB, shadowDB *db.DB, query string, hits []memoryHitResult, limit int) {
	if shadowDB == nil {
		return
	}
	legacyIDs := make([]string, len(hits))
	for i, h := range hits {
		legacyIDs[i] = h.ID
	}
	_, _ = memory.CompareRecall(readDB, shadowDB, query, legacyIDs, limit)
}

// recallAliasHit returns the exact-alias hit for query as a zero-or-one-item
// slice, or an error on a genuine lookup failure. No alias match (an empty
// nodeID — LookupMemoryAlias returns "" on sql.ErrNoRows), an alias that points
// at a gone node, and a tombstoned target all mean "no hit" — not an error. The
// not-found branches key off the returned value rather than the error, the
// package idiom (see resolveEmailToUserID in experts.go).
func recallAliasHit(d *db.DB, query string) ([]memoryHitResult, error) {
	nodeID, err := d.LookupMemoryAlias(query)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("resolving alias: %w", err)
	}
	if nodeID == "" {
		return nil, nil
	}
	row, err := d.GetMemoryNode(nodeID)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("loading alias hit: %w", err)
	}
	if err == nil && row.Status != "tombstone" {
		return []memoryHitResult{{
			ID: row.ID, Title: row.Title, Type: row.Type, Snippet: "alias: " + query,
		}}, nil
	}
	return nil, nil
}
