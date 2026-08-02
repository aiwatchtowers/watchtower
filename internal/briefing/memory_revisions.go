package briefing

import (
	"errors"
	"path/filepath"
	"strings"
	"time"

	"watchtower/internal/memory"
)

// noNotableRevisions is the sentinel rendered into the MEMORY REVISIONS
// placeholder when the gate is off or nothing notable changed. The template
// instructs the model to ignore memory entirely when it sees this text, so the
// placeholder is always safe to pass as a Sprintf arg (arg count stays fixed).
const noNotableRevisions = "(no notable revisions)"

// maxMemoryRevisions caps the journal at five lines so the briefing prompt stays
// focused on the day's most consequential belief changes.
const maxMemoryRevisions = 5

// gatherMemoryRevisions builds the "Memory revisions" journal block: belief nodes
// whose ## History changed since the previous briefing, filtered in code to the
// notable ones (status transitions or a >=0.2 confidence swing), capped at five.
// It always returns a string safe to pass as a Sprintf arg — the empty-block
// sentinel when the gate is off, no vault exists, or nothing qualifies.
//
// Vault content is framed as model-mediated memory notes (derived from
// Slack/Jira), never as the user's own words (memory.md Phase-4 framing).
func (p *Pipeline) gatherMemoryRevisions(userID, date string) string {
	if !p.cfg.Memory.Surfaces.Briefing {
		return noNotableRevisions
	}

	since := p.revisionWindowStart(userID, date)

	vault, err := memory.OpenExistingVault(filepath.Join(p.cfg.WorkspaceDir(), "memory"))
	if err != nil {
		// ErrVaultNotInitialized is the benign "headless daemon, memory never
		// run" case — degrade silently. Any OTHER open failure (a corrupt git
		// dir, unreadable path) is logged before degrading, so a real problem is
		// not swallowed as if the vault simply did not exist (P3).
		if !errors.Is(err, memory.ErrVaultNotInitialized) {
			p.logger.Printf("briefing: opening memory vault for revisions: %v", err)
		}
		return noNotableRevisions
	}

	nodes, err := p.db.ListMemoryNodes()
	if err != nil {
		p.logger.Printf("briefing: error listing memory nodes: %v", err)
		return noNotableRevisions
	}

	var lines, ids []string
	for _, n := range nodes {
		if n.Type != "belief" {
			continue
		}
		node, err := vault.ReadNode(n.ID)
		if err != nil {
			// Index/vault drift (a file removed since indexing): skip, don't fail.
			continue
		}
		if nr, ok := memory.NotableRevision(node, since); ok {
			lines = append(lines, nr.Line)
			ids = append(ids, n.ID)
			if len(lines) >= maxMemoryRevisions {
				break
			}
		}
	}

	// Slice B Task 9 dark retrieval-compare (memory.retrieve.briefing_compare):
	// runs RetrieveRevisions and shadow-diffs it against `ids` — the EXACT
	// legacy notable-revision selection above, same cap. The rendered journal
	// text below is unaffected by the flag in every case.
	if p.cfg.Memory.Retrieve.BriefingCompare {
		sinceTS := float64(since.Unix())
		if _, err := memory.CompareRevisions(p.db, p.db, vault, sinceTS, ids, maxMemoryRevisions); err != nil {
			p.logger.Printf("briefing: retrieve compare: %v", err)
		}
	}

	if len(lines) == 0 {
		return noNotableRevisions
	}
	return strings.Join(lines, "\n")
}

// revisionWindowStart returns the timestamp after which a belief ## History entry
// counts as "new" for this briefing: the previous day's briefing generation time,
// falling back to a 24h window when no prior briefing exists.
func (p *Pipeline) revisionWindowStart(userID, date string) time.Time {
	day, err := time.ParseInLocation("2006-01-02", date, time.Local)
	if err != nil {
		day = time.Now()
	}
	fallback := day.AddDate(0, 0, -1)

	prevDate := day.AddDate(0, 0, -1).Format("2006-01-02")
	prev, err := p.db.GetBriefing(userID, prevDate)
	if err != nil || prev == nil || prev.CreatedAt == "" {
		return fallback
	}
	created, err := time.Parse(time.RFC3339, prev.CreatedAt)
	if err != nil {
		return fallback
	}
	return created
}
