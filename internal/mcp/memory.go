package mcp

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

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

// memoryUnavailable returns a not-initialized tool result when the vault is
// unusable, nil when it exists. It checks for the vault's .git directory
// rather than opening it, so the read path never git-inits a vault — creating
// one is the consolidation pipeline's job.
func memoryUnavailable(vaultPath string) *mcpsdk.CallToolResult {
	if vaultPath == "" {
		return errResult(memoryNotInitializedMsg)
	}
	if _, err := os.Stat(filepath.Join(vaultPath, ".git")); err != nil {
		return errResult(memoryNotInitializedMsg)
	}
	return nil
}

func registerMemory(s *mcpsdk.Server, database *db.DB, vaultPath string) {
	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "memory_map",
		Description: "Read the memory world map (map.md) plus node counts by type and tier.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args memoryMapArgs) (*mcpsdk.CallToolResult, any, error) {
		if res := memoryUnavailable(vaultPath); res != nil {
			return res, nil, nil
		}
		mapMD, err := os.ReadFile(filepath.Join(vaultPath, "map.md"))
		if err != nil {
			return errResult("reading memory map: " + err.Error()), nil, nil
		}
		rows, err := database.ListMemoryNodes()
		if err != nil {
			return errResult("counting memory nodes: " + err.Error()), nil, nil
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
		return jsonResult(memoryMapResult{Map: string(mapMD), Counts: counts})
	})

	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "memory_open",
		Description: "Open one memory node by id, alias, or a stale (tombstoned) id; returns the canonical node with body, aliases, and outgoing links.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args memoryOpenArgs) (*mcpsdk.CallToolResult, any, error) {
		if res := memoryUnavailable(vaultPath); res != nil {
			return res, nil, nil
		}
		ref := strings.TrimSpace(args.Ref)
		if ref == "" {
			return errResult("ref is required"), nil, nil
		}
		v, err := memory.OpenExistingVault(vaultPath)
		if err != nil {
			return errResult("opening memory vault: " + err.Error()), nil, nil
		}
		n, err := memory.Resolve(v, database, ref)
		if errors.Is(err, memory.ErrNotFound) {
			return errResult("no memory node or alias matching " + strconv.Quote(ref)), nil, nil
		}
		if err != nil {
			return errResult("opening memory node: " + err.Error()), nil, nil
		}
		// Open is "use", so it counts toward the node's stats — always for
		// the canonical node, even when the caller passed a stale id. The
		// bump is best-effort telemetry: on a query_only session the write
		// fails and the open must still return the node.
		_ = database.BumpMemoryAccess(n.ID)

		var links []memoryLinkResult
		for _, l := range n.Links() {
			links = append(links, memoryLinkResult{ID: l.ID, Label: l.Label})
		}
		return jsonResult(memoryNodeResult{
			ID:      n.ID,
			Type:    n.Type,
			Tier:    n.Tier,
			Status:  n.Status,
			Title:   n.Title,
			Aliases: n.Aliases,
			Links:   links,
			Body:    n.Body,
		})
	})

	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "memory_recall",
		Description: "Full-text search over memory nodes; an exact alias match ranks first. Returns id, title, type, snippet per hit.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args memoryRecallArgs) (*mcpsdk.CallToolResult, any, error) {
		if res := memoryUnavailable(vaultPath); res != nil {
			return res, nil, nil
		}
		query := strings.TrimSpace(args.Query)
		if query == "" {
			return errResult("query is required"), nil, nil
		}
		limit := args.Limit
		switch {
		case limit <= 0:
			limit = defaultRecallLimit
		case limit > maxListLimit:
			limit = maxListLimit
		}

		// An exact alias match (case-insensitive) ranks first: aliases are
		// curated synonyms, so hitting one is a stronger signal than any FTS
		// rank. Recall never bumps stats — browsing is not use; only
		// memory_open counts.
		var hits []memoryHitResult
		nodeID, aliasErr := database.LookupMemoryAlias(query)
		if aliasErr != nil && !errors.Is(aliasErr, sql.ErrNoRows) {
			return errResult("resolving alias: " + aliasErr.Error()), nil, nil
		}
		if aliasErr == nil {
			row, err := database.GetMemoryNode(nodeID)
			if err != nil && !errors.Is(err, sql.ErrNoRows) {
				return errResult("loading alias hit: " + err.Error()), nil, nil
			}
			if err == nil && row.Status != "tombstone" {
				hits = append(hits, memoryHitResult{
					ID: row.ID, Title: row.Title, Type: row.Type, Snippet: "alias: " + query,
				})
			}
		}

		ftsHits, err := database.SearchMemoryFTS(query, limit)
		if err != nil {
			return errResult("searching memory: " + err.Error()), nil, nil
		}
		for _, h := range ftsHits {
			if len(hits) > 0 && hits[0].ID == h.ID {
				continue // already present as the alias hit
			}
			hits = append(hits, memoryHitResult{ID: h.ID, Title: h.Title, Type: h.Type, Snippet: h.Snippet})
		}
		if len(hits) > limit {
			hits = hits[:limit]
		}
		return jsonListResult(hits)
	})
}
