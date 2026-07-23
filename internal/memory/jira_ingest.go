package memory

// This file is the mechanical Jira issue → episode builder (behind
// memory.sources.jira, owner scope-B: all issues, watermark-bounded). Like the
// calendar source it makes NO AI call: one updated jira_issues row becomes at
// most one episode built straight from the structured row. It runs as
// mechanical Run step 3d, after operational mirrors (3c) and before Slack
// extraction.
//
// Idempotency is alias-keyed (jiraissue:<KEY>, the calevent:/gmailthread:
// precedent): an issue update re-lists the row (updated_at > watermark) and
// UPDATEs the episode in place; a content-equality check keeps an unchanged
// re-scan a no-op. Its own watermark: memory_jira_last_extracted_ts (the FIFTH
// extraction watermark, parsed updated_at unix). No bounded lookback (unlike
// calendar): jira_issues rows are permanent and every change lifts updated_at
// above the watermark by itself. No backfill: the first gated run initializes
// the watermark to the newest synced updated_at and builds nothing.

import (
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/db"
)

// jiraIssueAliasPrefix marks an episode's stable per-issue identity alias
// ("jiraissue:<KEY>") — the idempotency key.
const jiraIssueAliasPrefix = "jiraissue:"

func jiraIssueAlias(key string) string { return jiraIssueAliasPrefix + key }

// jiraDescriptionCapBytes bounds the description snippet folded into the Story
// (Jira descriptions can be pages long; the episode is a gist, not a mirror).
const jiraDescriptionCapBytes = 1500

// runJiraIngest is Run step 3d (behind memory.sources.jira): the mechanical,
// no-AI fold of updated Jira issues into episode nodes. First gated run with
// rows present initializes the watermark to the newest parsed updated_at and
// builds nothing (no backfill, owner decision). Subsequent runs load issues
// above the watermark, build episodes in one vault commit, and advance the
// watermark only after the commit succeeded (MEM-04-adapted; frozen on any
// build/commit/lookup error). Returns the number of step rows recorded.
func (p *Pipeline) runJiraIngest(runID int64, stepOffset int, stats *RunStats) (int, error) {
	wm, err := p.db.MemoryJiraWatermark()
	if err != nil {
		stats.JiraIssuesFailed++
		step := stepOffset + 1
		p.recordSemanticStep(runID, &step, "jira-ingest", "error", nil, time.Now())
		return 1, err
	}

	if wm == 0 {
		maxU, merr := p.db.MaxJiraUpdatedUnix()
		if merr != nil {
			stats.JiraIssuesFailed++
			step := stepOffset + 1
			p.recordSemanticStep(runID, &step, "jira-ingest", "error", nil, time.Now())
			return 1, merr
		}
		if maxU == 0 {
			return 0, nil // no synced issues yet — retry initialization next run
		}
		if serr := p.db.SetMemoryJiraWatermark(float64(maxU)); serr != nil {
			stats.JiraIssuesFailed++
			step := stepOffset + 1
			p.recordSemanticStep(runID, &step, "jira-ingest", "error", nil, time.Now())
			return 1, serr
		}
		p.logf("memory: jira source initialized at %d, no backfill", maxU)
		step := stepOffset + 1
		p.recordSemanticStep(runID, &step, "jira-ingest", "done", nil, time.Now())
		return 1, nil
	}

	issues, err := p.db.ListJiraIssuesForExtract(int64(wm), orDefault(p.cfg.MaxChunkMessages, 2000))
	if err != nil {
		stats.JiraIssuesFailed++
		step := stepOffset + 1
		p.recordSemanticStep(runID, &step, "jira-ingest", "error", nil, time.Now())
		return 1, err
	}
	if len(issues) == 0 {
		return 0, nil
	}

	// jira: is the only scheme a Jira episode can carry (MEM-12 scheme scoping).
	jiraReg := newProvenanceRegistry(jiraResolver{p.db})

	start := time.Now()
	built, failed, maxUpdated, berr := p.buildJiraEpisodes(runID, jiraReg, issues)
	if berr != nil {
		// A commit/lookup failure freezes the whole step: the watermark stays
		// and every pending issue re-scans next run (MEM-04-adapted).
		stats.JiraIssuesFailed += len(issues)
		p.logf("memory: jira ingest: %v", berr)
	} else {
		stats.JiraEpisodes += built
		stats.JiraIssuesFailed += failed
		if float64(maxUpdated) > wm {
			if serr := p.db.SetMemoryJiraWatermark(float64(maxUpdated)); serr != nil {
				p.logf("memory: jira ingest: set watermark: %v", serr)
			}
		}
	}
	step := stepOffset + 1
	p.recordSemanticStep(runID, &step, "jira-ingest", stepStatus(berr), nil, start)
	return 1, nil
}

// buildJiraEpisodes turns updated issues into episode nodes (plus entity
// back-links) committed as ONE vault commit, keyed by their jiraissue:<KEY>
// alias. Returns built (created-or-refreshed), failed (dropped for an
// unresolved jira: ref — the row was deleted between load and validate,
// MEM-01 drop-and-count), the newest processed updated_at unix (the watermark
// bound), and an error that freezes the whole step.
func (p *Pipeline) buildJiraEpisodes(runID int64, jiraReg *provenanceRegistry, issues []db.JiraExtractIssue) (built, failed int, maxUpdated int64, err error) {
	byID := map[string]*Node{}
	var order []string
	dirty := map[string]bool{}

	for _, is := range issues {
		// maxUpdated lifts BEFORE ref validation on purpose: an issue whose
		// jira: ref fails to resolve was hard-deleted between load and
		// validate; the row is gone and can never be built later.
		if is.UpdatedUnix > maxUpdated {
			maxUpdated = is.UpdatedUnix
		}
		ref := episodeRef{ChannelID: jiraRefPrefix + is.Key, TS: strconv.FormatInt(is.UpdatedUnix, 10)}

		ok, registered, verr := jiraReg.Validate(ref)
		if verr != nil {
			return 0, 0, 0, fmt.Errorf("memory: jira ingest: validate %s: %w", ref.ChannelID, verr)
		}
		if !registered || !ok {
			failed++
			p.logf("memory: jira ingest: issue %s ref unresolved — episode discarded (MEM-01)", is.Key)
			continue
		}

		title := fmt.Sprintf("%s: %s", is.Key, firstNonEmpty(strings.Join(strings.Fields(is.Summary), " "), "(untitled issue)"))
		body := jiraEpisodeBody(title, jiraStory(is), jiraOutcome(is), ref)
		status, tier := "active", "short"
		if is.StatusCategory == "done" && strings.TrimSpace(is.ResolvedAt) != "" {
			status, tier = "closed", "long"
		}

		epNode, changed, berr := p.jiraEpisodeNode(jiraIssueAlias(is.Key), title, body, status, tier)
		if berr != nil {
			return 0, 0, 0, berr
		}
		if _, seen := byID[epNode.ID]; !seen {
			byID[epNode.ID] = &epNode
			order = append(order, epNode.ID)
		}
		if changed {
			dirty[epNode.ID] = true
			built++
		}

		// Entity back-links: the project entity (seeded by seedJiraProjects,
		// aliased by its bare key) + assignee/reporter person entities via
		// their Slack ids — structural, no model judgment.
		link := "- [[" + epNode.ID + "|" + linkLabel(title) + "]]\n"
		refs := []string{is.ProjectKey}
		if sid := strings.TrimSpace(is.AssigneeSlackID); sid != "" {
			refs = append(refs, sid)
		}
		if sid := strings.TrimSpace(is.ReporterSlackID); sid != "" {
			refs = append(refs, sid)
		}
		for _, entRef := range refs {
			if entRef == "" {
				continue
			}
			if lerr := linkEntity(p, byID, &order, dirty, entRef, link); lerr != nil {
				return 0, 0, 0, lerr
			}
		}
	}

	if lerr := p.commitSourceNodes(runID, "jira", byID, order, dirty); lerr != nil {
		return 0, 0, 0, lerr
	}
	return built, failed, maxUpdated, nil
}

// jiraEpisodeNode returns the episode node for one issue: fresh when the
// jiraissue:<KEY> alias has none, else the existing node with Title/Body and
// the deterministic status/tier refreshed (a done+resolved issue is closed/
// long; a reopened issue flips back to active/short). changed reports whether
// anything differs from disk. A LookupMemoryAlias error (not a clean miss)
// fails the step — the alias is the idempotency key. If the alias has been
// re-aliased onto a non-episode node (a rollup after eviction, or any future
// re-alias), the builder never rewrites it — an evicted rollup is a deliberate
// compaction the mechanical builder must not resurrect into an episode body;
// the existing node is returned untouched with changed=false.
func (p *Pipeline) jiraEpisodeNode(alias, title, body, status, tier string) (n Node, changed bool, err error) {
	existingID, lerr := p.db.LookupMemoryAlias(alias)
	switch {
	case lerr == nil:
		existing, rerr := p.vault.ReadNode(existingID)
		if rerr != nil {
			return Node{}, false, fmt.Errorf("memory: jira ingest: read %s for %q: %w", existingID, alias, rerr)
		}
		if existing.Type != "episode" {
			p.logf("memory: jira ingest: alias %q resolves to %s (%s), skipping update (archived)", alias, existingID, existing.Type)
			return existing, false, nil
		}
		if existing.Title == title && existing.Body == body && existing.Status == status && existing.Tier == tier {
			return existing, false, nil // unchanged — no commit
		}
		existing.Title = title
		existing.Body = body
		existing.Status = status
		existing.Tier = tier
		existing.Aliases = ensureAlias(existing.Aliases, alias)
		return existing, true, nil
	case errors.Is(lerr, sql.ErrNoRows):
		return Node{
			ID:      NewID("episode"),
			Type:    "episode",
			Tier:    tier,
			Status:  status,
			Title:   title,
			Aliases: []string{alias},
			Body:    body,
		}, true, nil
	default:
		return Node{}, false, fmt.Errorf("memory: jira ingest: alias lookup %q: %w", alias, lerr)
	}
}

// jiraStory renders the mechanical Story: a metadata sentence block (type,
// status, priority, people, sprint/epic/due/points — each only when set) plus
// the capped description snippet.
func jiraStory(is db.JiraExtractIssue) string {
	var b strings.Builder
	if v := strings.TrimSpace(is.IssueType); v != "" {
		fmt.Fprintf(&b, "Type: %s. ", v)
	}
	fmt.Fprintf(&b, "Status: %s (%s).", is.Status, is.StatusCategory)
	if v := strings.TrimSpace(is.Priority); v != "" {
		fmt.Fprintf(&b, " Priority: %s.", v)
	}
	if v := strings.TrimSpace(is.AssigneeDisplayName); v != "" {
		fmt.Fprintf(&b, " Assignee: %s.", v)
	}
	if v := strings.TrimSpace(is.ReporterDisplayName); v != "" {
		fmt.Fprintf(&b, " Reporter: %s.", v)
	}
	if v := strings.TrimSpace(is.SprintName); v != "" {
		fmt.Fprintf(&b, " Sprint: %s.", v)
	}
	if v := strings.TrimSpace(is.EpicKey); v != "" {
		fmt.Fprintf(&b, " Epic: %s.", v)
	}
	if v := strings.TrimSpace(is.DueDate); v != "" {
		fmt.Fprintf(&b, " Due: %s.", v)
	}
	if is.StoryPoints.Valid {
		fmt.Fprintf(&b, " Story points: %g.", is.StoryPoints.Float64)
	}
	if desc := capRunes(oneLine(is.DescriptionText), jiraDescriptionCapBytes); desc != "" {
		b.WriteString("\n" + desc)
	}
	return b.String()
}

// capRunes truncates s to at most capBytes bytes on a rune boundary, appending
// "…" when truncated.
func capRunes(s string, capBytes int) string {
	if len(s) <= capBytes {
		return s
	}
	cut := capBytes
	for cut > 0 && !isRuneStart(s[cut]) {
		cut--
	}
	return s[:cut] + "…"
}

func isRuneStart(b byte) bool { return b&0xC0 != 0x80 }

// jiraOutcome renders the deterministic Outcome: resolution when done, else
// the current status.
func jiraOutcome(is db.JiraExtractIssue) string {
	if is.StatusCategory == "done" && strings.TrimSpace(is.ResolvedAt) != "" {
		return fmt.Sprintf("Resolved (%s) at %s", is.Status, is.ResolvedAt)
	}
	return fmt.Sprintf("Current status: %s", is.Status)
}

// jiraEpisodeBody renders the deterministic episode body (H1, Story, Outcome,
// single jira: Provenance ref) — deterministic so the content-equality check
// can detect an unchanged re-scan.
func jiraEpisodeBody(title, story, outcome string, ref episodeRef) string {
	var b strings.Builder
	fmt.Fprintf(&b, "# %s\n\n## Story\n", title)
	if story != "" {
		b.WriteString(story + "\n")
	}
	b.WriteString("\n## Outcome\n")
	if outcome != "" {
		b.WriteString(outcome + "\n")
	}
	b.WriteString("\n## Provenance\n")
	fmt.Fprintf(&b, "- %s %s\n", ref.ChannelID, ref.TS)
	return b.String()
}
