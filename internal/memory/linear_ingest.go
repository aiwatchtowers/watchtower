package memory

// This file is the mechanical Linear issue → episode builder (spec
// 2026-10-15-linear-integration-design §6 "memory"). Linear behaves like Jira:
// it runs behind the same memory.sources.jira switch (the existing tracker
// switches govern both trackers, spec §3.5), right after the Jira builder, with
// NO AI call — one updated linear_issues row becomes at most one episode built
// straight from the structured row.
//
// Differences from the Jira builder, all forced by Linear's model:
//   - the idempotency alias is linearissue:<account>:<issue uuid>, because a
//     Linear key moves with a team move (ENG-12 → OPS-40) — the same issue
//     keeps its one episode, retitled under the new key;
//   - the provenance ref is linear:<KEY> (current key at build time), resolved
//     by linearResolver against the current key or previous_keys (MEM-12);
//   - the watermark is linear_accounts.memory_last_extracted_ts, one per
//     workspace (the per-account Jira watermark precedent).

import (
	"fmt"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/db"
)

// linearIssueAliasPrefix marks an episode's stable per-issue identity alias.
const linearIssueAliasPrefix = "linearissue:"

func linearIssueAlias(accountID int64, issueID string) string {
	return fmt.Sprintf("%s%d:%s", linearIssueAliasPrefix, accountID, issueID)
}

// linearPriorityNames maps Linear's priority number to its name (0 = none).
var linearPriorityNames = map[int]string{1: "Urgent", 2: "High", 3: "Medium", 4: "Low"}

// runLinearIngest is the Linear twin of runJiraIngest: looped over every
// enabled linear_accounts row, each with its own watermark, one account's
// failure recorded on its own step row and the loop moving on. Returns the
// number of step rows recorded.
func (p *Pipeline) runLinearIngest(runID int64, stepOffset int, stats *RunStats) (int, error) {
	accounts, err := p.db.ListEnabledLinearAccounts()
	if err != nil {
		return 0, err
	}
	// linear: is the only scheme a Linear episode can carry (MEM-12 scheme
	// scoping); LinearIssueExists is account-unscoped like JiraIssueExists.
	linearReg := newProvenanceRegistry(linearResolver{p.db})

	recorded := 0
	for _, acct := range accounts {
		n, aerr := p.runLinearIngestAccount(runID, stepOffset+recorded, linearReg, acct.ID, stats)
		if aerr != nil {
			p.logf("memory: linear ingest account %d: %v", acct.ID, aerr)
		}
		recorded += n
	}
	return recorded, nil
}

// failLinearStep records a failed linear-ingest step row and counts it.
func (p *Pipeline) failLinearStep(runID int64, stepOffset int, stats *RunStats, err error) (int, error) {
	stats.LinearIssuesFailed++
	step := stepOffset + 1
	p.recordSemanticStep(runID, &step, "linear-ingest", "error", nil, time.Now())
	return 1, err
}

// runLinearIngestAccount runs the step for ONE workspace. The first gated run
// with rows present initializes the watermark to the newest parsed updated_at
// and builds nothing (no backfill, the Jira rule). Later runs build the issues
// above the watermark in one vault commit and advance the watermark only after
// the commit succeeded (MEM-04-adapted; frozen on any build/commit/lookup
// error).
func (p *Pipeline) runLinearIngestAccount(runID int64, stepOffset int, linearReg *provenanceRegistry, accountID int64, stats *RunStats) (int, error) {
	wm, err := p.db.MemoryLinearWatermark(accountID)
	if err != nil {
		return p.failLinearStep(runID, stepOffset, stats, err)
	}
	if wm == 0 {
		maxU, merr := p.db.MaxLinearUpdatedUnix(accountID)
		if merr != nil {
			return p.failLinearStep(runID, stepOffset, stats, merr)
		}
		if maxU == 0 {
			return 0, nil // no synced issues yet — retry initialization next run
		}
		if serr := p.db.SetMemoryLinearWatermark(accountID, float64(maxU)); serr != nil {
			return p.failLinearStep(runID, stepOffset, stats, serr)
		}
		p.logf("memory: linear source account %d initialized at %d, no backfill", accountID, maxU)
		step := stepOffset + 1
		p.recordSemanticStep(runID, &step, "linear-ingest", "done", nil, time.Now())
		return 1, nil
	}

	issues, err := p.db.ListLinearIssuesForExtract(accountID, int64(wm), orDefault(p.cfg.MaxChunkMessages, 2000))
	if err != nil {
		return p.failLinearStep(runID, stepOffset, stats, err)
	}
	if len(issues) == 0 {
		return 0, nil
	}

	start := time.Now()
	built, failed, maxUpdated, berr := p.buildLinearEpisodes(runID, linearReg, issues)
	stepErr := berr
	if berr != nil {
		stats.LinearIssuesFailed += len(issues)
		p.logf("memory: linear ingest: %v", berr)
	} else {
		stats.LinearEpisodes += built
		stats.LinearIssuesFailed += failed
		if float64(maxUpdated) > wm {
			if serr := p.db.SetMemoryLinearWatermark(accountID, float64(maxUpdated)); serr != nil {
				p.logf("memory: linear ingest: set watermark: %v", serr)
				stepErr = serr
			}
		}
	}
	step := stepOffset + 1
	p.recordSemanticStep(runID, &step, "linear-ingest", stepStatus(stepErr), nil, start)
	return 1, nil
}

// buildLinearEpisodes turns updated issues into episode nodes (plus entity
// back-links: the team entity seeded by its bare key, assignee/creator people
// by Slack id) committed as ONE vault commit. Returns built, failed (dropped
// for an unresolved linear: ref — MEM-01 drop-and-count), the newest processed
// updated_at unix, and an error that freezes the whole step.
func (p *Pipeline) buildLinearEpisodes(runID int64, linearReg *provenanceRegistry, issues []db.LinearExtractIssue) (built, failed int, maxUpdated int64, err error) {
	byID := map[string]*Node{}
	var order []string
	dirty := map[string]bool{}

	for _, is := range issues {
		// maxUpdated lifts before validation on purpose (the Jira rule): an
		// unresolvable row was deleted between load and validate and can never
		// be built later.
		if is.UpdatedUnix > maxUpdated {
			maxUpdated = is.UpdatedUnix
		}
		ref := episodeRef{ChannelID: linearRefPrefix + is.Key, TS: strconv.FormatInt(is.UpdatedUnix, 10)}
		ok, registered, verr := linearReg.Validate(ref)
		if verr != nil {
			return 0, 0, 0, fmt.Errorf("memory: linear ingest: validate %s: %w", ref.ChannelID, verr)
		}
		if !registered || !ok {
			failed++
			p.logf("memory: linear ingest: issue %s ref unresolved — episode discarded (MEM-01)", is.Key)
			continue
		}

		title := fmt.Sprintf("%s: %s", is.Key, firstNonEmpty(strings.Join(strings.Fields(is.Title), " "), "(untitled issue)"))
		body := jiraEpisodeBody(title, linearStory(is), linearOutcome(is), ref)
		status, tier := "active", "short"
		if linearResolvedAt(is) != "" {
			status, tier = "closed", "long"
		}

		epNode, changed, berr := p.issueEpisodeNode("linear", linearIssueAlias(is.AccountID, is.ID), title, body, status, tier)
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

		link := "- [[" + epNode.ID + "|" + linkLabel(title) + "]]\n"
		for _, entRef := range []string{is.TeamKey, strings.TrimSpace(is.AssigneeSlackID), strings.TrimSpace(is.CreatorSlackID)} {
			if entRef == "" {
				continue
			}
			if lerr := linkEntity(p, byID, &order, dirty, entRef, link); lerr != nil {
				return 0, 0, 0, lerr
			}
		}
	}

	if lerr := p.commitSourceNodes(runID, "linear", byID, order, dirty); lerr != nil {
		return 0, 0, 0, lerr
	}
	return built, failed, maxUpdated, nil
}

// linearResolvedAt is when a done issue was completed or canceled, "" when it
// is not done.
func linearResolvedAt(is db.LinearExtractIssue) string {
	if is.StatusCategory != "done" {
		return ""
	}
	if v := strings.TrimSpace(is.CompletedAt); v != "" {
		return v
	}
	return strings.TrimSpace(is.CanceledAt)
}

// linearStory renders the mechanical Story: a metadata block (state, priority,
// people, cycle/project/due/estimate — each only when set) plus the capped
// description snippet (the jiraStory shape).
func linearStory(is db.LinearExtractIssue) string {
	var b strings.Builder
	fmt.Fprintf(&b, "Status: %s (%s).", is.StateName, is.StatusCategory)
	if v := linearPriorityNames[is.Priority]; v != "" {
		fmt.Fprintf(&b, " Priority: %s.", v)
	}
	if v := strings.TrimSpace(is.AssigneeDisplayName); v != "" {
		fmt.Fprintf(&b, " Assignee: %s.", v)
	}
	if v := strings.TrimSpace(is.CreatorDisplayName); v != "" {
		fmt.Fprintf(&b, " Creator: %s.", v)
	}
	if v := strings.TrimSpace(is.CycleName); v != "" {
		fmt.Fprintf(&b, " Cycle: %s.", v)
	}
	if v := strings.TrimSpace(is.ProjectName); v != "" {
		fmt.Fprintf(&b, " Project: %s.", v)
	}
	if v := strings.TrimSpace(is.DueDate); v != "" {
		fmt.Fprintf(&b, " Due: %s.", v)
	}
	if is.Estimate.Valid {
		fmt.Fprintf(&b, " Estimate: %g.", is.Estimate.Float64)
	}
	if desc := capBytes(oneLine(is.DescriptionText), jiraDescriptionCapBytes); desc != "" {
		b.WriteString("\n" + desc)
	}
	return b.String()
}

// linearOutcome renders the deterministic Outcome: the resolution when done,
// else the current state.
func linearOutcome(is db.LinearExtractIssue) string {
	if at := linearResolvedAt(is); at != "" {
		return fmt.Sprintf("Resolved (%s) at %s", is.StateName, at)
	}
	return fmt.Sprintf("Current status: %s", is.StateName)
}
