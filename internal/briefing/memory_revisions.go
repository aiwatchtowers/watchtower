package briefing

import (
	"errors"
	"math"
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

// confidenceNotableDelta is the |confidence| move within the window that makes a
// non-status revision worth surfacing. Beliefs move in 0.1 steps, so this is two
// net steps in one direction.
const confidenceNotableDelta = 0.2

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

	var lines []string
	for _, n := range nodes {
		if n.Type != "belief" {
			continue
		}
		node, err := vault.ReadNode(n.ID)
		if err != nil {
			// Index/vault drift (a file removed since indexing): skip, don't fail.
			continue
		}
		if line, ok := notableRevision(node, since); ok {
			lines = append(lines, line)
			if len(lines) >= maxMemoryRevisions {
				break
			}
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

// notableRevision inspects one belief's ## History for entries dated on or after
// since and, when the aggregate change is notable, renders a single journal line:
//
//	<belief title> — <what changed> — because <evidence digest>
//
// Notability (code-side filter): any status transition (shake/retire) or belief
// creation always qualifies; otherwise a summed |confidence| move of >=0.2 across
// the window's confirm/weaken entries qualifies. Returns ok=false when no in-
// window entry is notable.
func notableRevision(node memory.Node, since time.Time) (string, bool) {
	entries := historyEntriesSince(node.Body, since)
	if len(entries) == 0 {
		return "", false
	}

	statusNotable := false
	confDelta := 0.0
	for _, e := range entries {
		switch e.Cause {
		case "shake", "retire", "created", "propose-new":
			statusNotable = true
		case "confirm":
			confDelta += 0.1
		case "weaken":
			confDelta -= 0.1
		}
	}

	if !statusNotable && math.Abs(confDelta) < confidenceNotableDelta {
		return "", false
	}

	tail := entries[len(entries)-1]
	title := strings.TrimSpace(node.Title)
	if title == "" {
		title = node.ID
	}
	digest := tail.Rationale
	if digest == "" {
		digest = "recent evidence"
	}
	return title + " — " + describeChange(tail.Cause, confDelta) + " — because " + digest, true
}

// historyEntriesSince returns the belief ## History bullets dated on or after
// since, in file order (oldest first). It delegates parsing to the single
// memory.ParseHistory reader (the counterpart of memory.historyLine) and only
// filters by date; date comparison is day-granular via lexical YYYY-MM-DD
// ordering.
func historyEntriesSince(body string, since time.Time) []memory.HistoryBullet {
	sinceDate := since.Format("2006-01-02")
	var entries []memory.HistoryBullet
	for _, b := range memory.ParseHistory(body) {
		if b.Date >= sinceDate {
			entries = append(entries, b)
		}
	}
	return entries
}

// describeChange renders the human "what changed" clause for a journal line.
func describeChange(cause string, confDelta float64) string {
	switch cause {
	case "shake":
		return "belief shaken — evidence now conflicts"
	case "retire":
		return "belief retired"
	case "created", "propose-new":
		return "new belief formed"
	case "confirm":
		return "confidence strengthened"
	case "weaken":
		return "confidence weakened"
	default:
		if confDelta > 0 {
			return "confidence strengthened"
		}
		if confDelta < 0 {
			return "confidence weakened"
		}
		return "belief revised"
	}
}
