package memory

import (
	"fmt"
	"time"

	"watchtower/internal/db"
)

// AgeEpisodes is the mechanical episode-aging pass (spec §Retention). Raw
// extracted episodes are minted active + short and nothing else ever closes
// them — only situation-finalized episodes reach closed + long through ingest.
// Without this pass a non-situation episode would stay active/short forever and
// never become an eviction candidate. AgeEpisodes transitions an active
// short-tier NON-situation episode (no situation:<id> alias — those belong to
// ingest's lifecycle) whose newest provenance event is older than ageAfterDays
// to closed + long, in one "memory(age)" commit mirrored into the index. Only
// the aged episodes are touched: situation-aliased episodes and episodes whose
// newest event is still recent are left byte-identical. Returns the count aged.
//
// A per-node read failure is skipped-and-logged (the package quarantine
// convention) so one corrupted candidate never stops the pass. ageAfterDays
// <= 0 is treated as unbounded here (the pipeline floor-guards it to the
// default before calling); a run then ages every non-situation short episode.
func AgeEpisodes(v *Vault, database *db.DB, ageAfterDays int, now time.Time, logf func(string, ...any)) (aged int, err error) {
	rows, err := database.ListMemoryNodes()
	if err != nil {
		return 0, err
	}

	var (
		nodes []Node
		ids   []string
	)
	for _, row := range rows {
		if row.Type != "episode" || row.Tier != "short" || row.Status != "active" {
			continue
		}
		n, rerr := v.ReadNode(row.ID)
		if rerr != nil {
			logf("memory: age: read %s: %v (skipped)", row.ID, rerr)
			continue
		}
		if hasSituationAlias(n.Aliases) {
			continue // situation-finalized episodes age through ingest, not here
		}
		refs := parseProvenance(n.Body)
		lastTS, ok := lastEventTS(refs)
		if !ok {
			continue // no parseable event ts → cannot age
		}
		ageDays := now.Sub(time.Unix(int64(lastTS), 0)).Hours() / 24
		if ageDays < float64(ageAfterDays) {
			continue // still recent
		}
		n.Status = "closed"
		n.Tier = "long"
		nodes = append(nodes, n)
		ids = append(ids, n.ID)
		aged++
	}

	if aged == 0 {
		return 0, nil
	}
	msg := CommitMsg{
		Op:      "age",
		Summary: fmt.Sprintf("%d episodes to closed+long", aged),
		Cause:   "age",
		NodeIDs: ids,
	}
	if _, err := v.WriteNodes(nodes, msg); err != nil {
		return 0, err
	}
	nowStr := time.Now().UTC().Format(time.RFC3339)
	mem := newOwnerEditedMemo(v)
	for _, n := range nodes {
		if err := upsertIndexNode(database, mem.lookup, n, nowStr); err != nil {
			return aged, err
		}
	}
	return aged, nil
}
