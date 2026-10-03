package briefing

import (
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
)

// noWorkbenchActivity is the WORKBENCHES placeholder when no workbench has
// anything to report; the template tells the model to ignore workbenches
// entirely then, and it keeps the Sprintf argument count fixed. The text,
// like the block's "[project_id=N]" lines, keeps its pre-rename wording: a
// customized v8 template (which names both) is rendered with this same data
// (spec 2026-10-02 A8), and v9 names them as they are.
const noWorkbenchActivity = "(no project activity)"

// maxBriefingWorkbenches and maxWorkbenchItems keep the block short: the briefing
// points at the board, it does not reproduce it.
const (
	maxBriefingWorkbenches = 5
	maxWorkbenchItems      = 5
)

// workbenchActivity is one project's slice of the briefing. Mechanical, no AI.
type workbenchActivity struct {
	inProgress, inReview, blocked, doneSince []string
	// openAsks are the titles of the agent's asks still waiting on the owner.
	openAsks    []string
	unreadAgent int
}

func (a workbenchActivity) empty() bool {
	return len(a.inProgress) == 0 && len(a.inReview) == 0 && len(a.blocked) == 0 && len(a.doneSince) == 0 &&
		len(a.openAsks) == 0 && a.unreadAgent == 0
}

// gatherWorkbenches renders the WORKBENCHES block: per project with activity — in
// progress, blocked, done since `since` (the previous briefing), open owner
// asks and unread agent comments. A project that fails to load is logged and skipped; the rest still render.
func (p *Pipeline) gatherWorkbenches(since time.Time) (string, bool) {
	projects, err := p.db.ListWorkbenches()
	if err != nil {
		p.logger.Printf("briefing: error loading workbenches: %v", err)
		return noWorkbenchActivity, false
	}
	sinceTS := since.UTC().Format("2006-01-02T15:04:05Z")
	var sb strings.Builder
	shown := 0
	for i := range projects {
		if shown >= maxBriefingWorkbenches {
			break
		}
		a, err := p.workbenchActivity(projects[i].ID, sinceTS)
		if err != nil {
			p.logger.Printf("briefing: workbench %d: %v", projects[i].ID, err)
			continue
		}
		if a.empty() {
			continue
		}
		p.shown.addWorkbench(projects[i].ID)
		sb.WriteString(renderWorkbenchActivity(projects[i], a))
		shown++
	}
	if shown == 0 {
		return noWorkbenchActivity, false
	}
	return sb.String(), true
}

func (p *Pipeline) workbenchActivity(projectID int64, sinceTS string) (workbenchActivity, error) {
	var a workbenchActivity
	board, err := p.db.GetWorkbenchBoard(projectID)
	if err != nil {
		return a, fmt.Errorf("board: %w", err)
	}
	comments, err := p.db.ListWorkbenchComments(db.WorkbenchCommentFilter{WorkbenchID: projectID})
	if err != nil {
		return a, fmt.Errorf("comments: %w", err)
	}
	open, err := p.db.ListOwnerAsks(projectID, db.OwnerAskFilter{Statuses: []string{"open"}})
	if err != nil {
		return a, fmt.Errorf("asks: %w", err)
	}
	a.addTargets(board, sinceTS)
	a.addComments(comments)
	for _, ask := range open {
		a.openAsks = append(a.openAsks, firstLine(ask.Title))
	}
	return a, nil
}

func (a *workbenchActivity) addTargets(nodes []db.BoardNode, sinceTS string) {
	for _, n := range nodes {
		title := firstLine(n.Target.Text)
		switch {
		case n.Target.Status == "in_progress":
			a.inProgress = append(a.inProgress, title)
		case n.Target.Status == "in_review":
			a.inReview = append(a.inReview, title)
		case n.Target.Status == "blocked":
			a.blocked = append(a.blocked, title)
		case n.Target.Status == "done" && n.Target.UpdatedAt >= sinceTS:
			a.doneSince = append(a.doneSince, title)
		}
		a.addTargets(n.Children, sinceTS)
	}
}

func (a *workbenchActivity) addComments(comments []db.WorkbenchComment) {
	for _, c := range comments {
		if c.Author == "agent" && c.ReadAt == "" {
			a.unreadAgent++
		}
	}
}

func renderWorkbenchActivity(pr db.Workbench, a workbenchActivity) string {
	var sb strings.Builder
	fmt.Fprintf(&sb, "--- [project_id=%d] %s (%s) ---\n", pr.ID, pr.Name, pr.FolderPath)
	writeWorkbenchLine(&sb, "In progress", a.inProgress)
	writeWorkbenchLine(&sb, "In review", a.inReview)
	writeWorkbenchLine(&sb, "Blocked", a.blocked)
	writeWorkbenchLine(&sb, "Done since the last briefing", a.doneSince)
	writeWorkbenchLine(&sb, "Open asks waiting for the owner", a.openAsks)
	if a.unreadAgent > 0 {
		fmt.Fprintf(&sb, "Unread agent comments: %d\n", a.unreadAgent)
	}
	return sb.String()
}

func writeWorkbenchLine(sb *strings.Builder, label string, items []string) {
	if len(items) == 0 {
		return
	}
	shown := items
	more := ""
	if len(items) > maxWorkbenchItems {
		shown = items[:maxWorkbenchItems]
		more = fmt.Sprintf(" (+%d more)", len(items)-maxWorkbenchItems)
	}
	fmt.Fprintf(sb, "%s (%d): %s%s\n", label, len(items), strings.Join(shown, "; "), more)
}

func firstLine(s string) string {
	line, _, _ := strings.Cut(s, "\n")
	return strings.TrimSpace(line)
}
