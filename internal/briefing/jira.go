package briefing

import (
	"fmt"
	"log"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/jira"
)

// trackerLabels are one tracker's briefing section headings. The Jira ones
// are the pre-Linear headings, unchanged.
type trackerLabels struct {
	myIssues, awaiting, iteration, stale, overdue string
}

var briefingLabels = map[string]trackerLabels{
	db.TrackerJira: {
		myIssues:  "=== MY JIRA ISSUES ===",
		awaiting:  "=== AWAITING MY INPUT ===",
		iteration: "=== SPRINT PROGRESS ===",
		stale:     "STALE JIRA ISSUES",
		overdue:   "OVERDUE JIRA ISSUES",
	},
	db.TrackerLinear: {
		myIssues:  "=== MY LINEAR ISSUES ===",
		awaiting:  "=== AWAITING MY INPUT (LINEAR) ===",
		iteration: "=== CYCLE PROGRESS ===",
		stale:     "STALE LINEAR ISSUES",
		overdue:   "OVERDUE LINEAR ISSUES",
	},
}

// reportedLimit caps the "reported by you" list per tracker.
const reportedLimit = 20

// gatherJiraContext collects the issue-tracker data (Jira, then Linear) for
// the briefing prompt based on enabled feature toggles. Each tracker reads
// tracker_issues and contributes only when its integration is enabled; the
// Jira feature toggles govern both (spec §3.5). Returns an empty string when
// no tracker is enabled or no relevant data exists (graceful degradation).
func (p *Pipeline) gatherJiraContext(owner db.Owner) string {
	var sections []string
	if p.cfg.Jira.Enabled {
		sections = append(sections, p.trackerSections(owner, db.TrackerJira)...)
	}
	if p.cfg.Linear.Enabled {
		sections = append(sections, p.trackerSections(owner, db.TrackerLinear)...)
	}
	return strings.Join(sections, "\n\n")
}

// trackerSections renders one tracker's briefing sections.
func (p *Pipeline) trackerSections(owner db.Owner, tracker string) []string {
	labels := briefingLabels[tracker]
	feature := func(name string) bool {
		on, _ := jira.FeatureValue(&p.cfg.Jira.Features, name)
		return on
	}

	// Load assigned issues once — reused by multiple sub-functions (C2 fix).
	assigned, err := p.db.OwnerAssignedTrackerIssues(owner, tracker)
	if err != nil {
		p.logger.Printf("briefing: error loading %s issues for user: %v", tracker, err)
		assigned = nil
	}
	assignedIssues := asJiraIssues(assigned)

	var sections []string

	// My Issues — issues assigned to user.
	if feature("my_issues") {
		if ctx := formatMyIssues(assignedIssues); ctx != "" {
			sections = append(sections, labels.myIssues+"\n"+ctx)
		}
	}

	// Awaiting My Input — issues reported by user still in progress, or blocked issues assigned to user.
	if feature("awaiting_input") {
		if ctx := p.gatherAwaitingInput(owner, tracker, assigned); ctx != "" {
			sections = append(sections, labels.awaiting+"\n"+ctx)
		}
	}

	// Sprint/Iteration Progress — Jira: active sprints on selected boards;
	// Linear: active cycles.
	if feature("iteration_progress") {
		ctx := ""
		if tracker == db.TrackerJira {
			ctx = p.gatherSprintProgress()
		} else {
			ctx = p.gatherCycleProgress()
		}
		if ctx != "" {
			sections = append(sections, labels.iteration+"\n"+ctx)
		}
	}

	// Always include stale and overdue issues when the tracker is enabled.
	if ctx := gatherStaleAndOverdueLabeled(assignedIssues, time.Now(), p.logger, labels); ctx != "" {
		sections = append(sections, ctx)
	}
	return sections
}

func asJiraIssues(issues []db.TrackerIssue) []db.JiraIssue {
	if len(issues) == 0 {
		return nil
	}
	out := make([]db.JiraIssue, len(issues))
	for i, t := range issues {
		out[i] = t.AsJiraIssue()
	}
	return out
}

// formatMyIssues returns formatted issues assigned to the user.
func formatMyIssues(issues []db.JiraIssue) string {
	if len(issues) == 0 {
		return ""
	}
	return jira.BuildIssueContext(issues)
}

// gatherAwaitingInput returns issues where the user is the reporter and
// the issue is still in todo/in_progress (they may need to follow up),
// plus blocked issues assigned to the user.
func (p *Pipeline) gatherAwaitingInput(owner db.Owner, tracker string, assigned []db.TrackerIssue) string {
	var parts []string

	// Issues reported by user that are still active (todo or in_progress).
	reported, err := p.db.OwnerReportedActiveTrackerIssues(owner, tracker, reportedLimit)
	if err != nil {
		p.logger.Printf("briefing: error querying reported %s issues: %v", tracker, err)
	}
	if len(reported) > 0 {
		parts = append(parts, "Reported by you (still open):")
		parts = append(parts, jira.BuildIssueContext(asJiraIssues(reported)))
	}

	// Blocked issues assigned to the user.
	var blocked []db.JiraIssue
	for _, issue := range assigned {
		if isBlocked(issue) {
			blocked = append(blocked, issue.AsJiraIssue())
		}
	}
	if len(blocked) > 0 {
		parts = append(parts, "Blocked (assigned to you):")
		parts = append(parts, jira.BuildIssueContext(blocked))
	}

	return strings.Join(parts, "\n")
}

// isBlocked is Jira's status-name rule (unchanged) or, for Linear, the view's
// is_blocked: an incoming blocks relation from an issue that is not done.
func isBlocked(issue db.TrackerIssue) bool {
	if issue.Tracker == db.TrackerLinear {
		return issue.IsBlocked
	}
	return strings.EqualFold(issue.Status, "blocked") ||
		strings.Contains(strings.ToLower(issue.Status), "block")
}

// gatherCycleProgress returns the progress of every active Linear cycle.
func (p *Pipeline) gatherCycleProgress() string {
	stats, err := p.db.ActiveTrackerIterationStats(db.TrackerLinear)
	if err != nil {
		p.logger.Printf("briefing: error loading Linear cycle stats: %v", err)
		return ""
	}
	lines := make([]string, 0, len(stats))
	for _, s := range stats {
		daysLabel := "days left"
		if s.DaysLeft == 1 {
			daysLabel = "day left"
		}
		lines = append(lines, fmt.Sprintf("[%s] %q: %d total (%d done, %d in progress, %d todo), %d %s",
			s.ProjectKey, s.SprintName, s.Total, s.Done, s.InProgress, s.Todo, s.DaysLeft, daysLabel))
	}
	return strings.Join(lines, "\n")
}

// gatherSprintProgress returns sprint stats for all selected boards across
// every connected Jira account.
func (p *Pipeline) gatherSprintProgress() string {
	boards, err := p.db.ListSelectedJiraBoards()
	if err != nil {
		p.logger.Printf("briefing: error loading selected Jira boards: %v", err)
		return ""
	}
	if len(boards) == 0 {
		return ""
	}

	var lines []string
	for _, board := range boards {
		stats, err := p.db.GetJiraActiveSprintStats(board.AccountID, board.ID)
		if err != nil {
			p.logger.Printf("briefing: error loading sprint stats for board %d: %v", board.ID, err)
			continue
		}
		if stats == nil {
			continue
		}
		line := jira.BuildSprintContext(*stats)
		if line != "" {
			lines = append(lines, fmt.Sprintf("[%s] %s", board.Name, line))
		}
	}

	if len(lines) == 0 {
		return ""
	}
	return strings.Join(lines, "\n")
}

// gatherStaleAndOverdueAt returns the Jira issues that are stale (in_progress
// for >7 days without status change) or overdue (past due date, not done) —
// accepts explicit "now" for deterministic tests.
func gatherStaleAndOverdueAt(issues []db.JiraIssue, now time.Time, logger *log.Logger) string {
	return gatherStaleAndOverdueLabeled(issues, now, logger, briefingLabels[db.TrackerJira])
}

// gatherStaleAndOverdueLabeled is the core, headed with one tracker's labels.
func gatherStaleAndOverdueLabeled(issues []db.JiraIssue, now time.Time, logger *log.Logger, labels trackerLabels) string {
	todayStart := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	staleCutoff := now.AddDate(0, 0, -7)

	var stale, overdue []db.JiraIssue

	for _, issue := range issues {
		// Overdue: parsed due_date before today AND not done.
		if issue.DueDate != "" && !strings.EqualFold(issue.StatusCategory, "done") {
			if due, err := parseFlexibleTime(issue.DueDate); err == nil {
				if due.Before(todayStart) {
					overdue = append(overdue, issue)
				}
			} else if logger != nil {
				logger.Printf("briefing: cannot parse due_date %q for %s: %v", issue.DueDate, issue.Key, err)
			}
		}

		// Stale: in_progress and status unchanged for >7 days.
		if strings.EqualFold(issue.StatusCategory, "in_progress") && issue.StatusCategoryChangedAt != "" {
			changedAt, err := parseFlexibleTime(issue.StatusCategoryChangedAt)
			if err == nil && changedAt.Before(staleCutoff) {
				stale = append(stale, issue)
			}
		}
	}

	var parts []string
	if len(stale) > 0 {
		parts = append(parts, "=== "+labels.stale+" (in_progress >7 days) ===\n"+jira.BuildIssueContext(stale))
	}
	if len(overdue) > 0 {
		parts = append(parts, "=== "+labels.overdue+" ===\n"+jira.BuildIssueContext(overdue))
	}

	return strings.Join(parts, "\n\n")
}

// parseFlexibleTime tries multiple time formats.
func parseFlexibleTime(s string) (time.Time, error) {
	for _, layout := range []string{
		time.RFC3339,
		"2006-01-02T15:04:05.000Z",
		"2006-01-02T15:04:05.000-0700",
		"2006-01-02",
	} {
		if t, err := time.Parse(layout, s); err == nil {
			return t, nil
		}
	}
	return time.Time{}, fmt.Errorf("cannot parse time: %s", s)
}
