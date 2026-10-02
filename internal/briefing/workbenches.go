package briefing

import (
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
)

// noProjectActivity is the PROJECTS placeholder when no project has anything
// to report; the template tells the model to ignore projects entirely then,
// and it keeps the Sprintf argument count fixed.
const noProjectActivity = "(no project activity)"

// maxBriefingProjects and maxProjectItems keep the block short: the briefing
// points at the board, it does not reproduce it.
const (
	maxBriefingProjects = 5
	maxProjectItems     = 5
)

// projectActivity is one project's slice of the briefing. Mechanical, no AI.
type projectActivity struct {
	inProgress, inReview, blocked, doneSince []string
	unreadAgent                              int
	docsAwaiting                             []string
}

func (a projectActivity) empty() bool {
	return len(a.inProgress) == 0 && len(a.inReview) == 0 && len(a.blocked) == 0 && len(a.doneSince) == 0 &&
		a.unreadAgent == 0 && len(a.docsAwaiting) == 0
}

// gatherProjects renders the PROJECTS block: per project with activity — in
// progress, blocked, done since `since` (the previous briefing), unread agent
// comments, and documents whose owner comments still wait for the agent. A
// project that fails to load is logged and skipped; the rest still render.
func (p *Pipeline) gatherProjects(since time.Time) (string, bool) {
	projects, err := p.db.ListProjects()
	if err != nil {
		p.logger.Printf("briefing: error loading projects: %v", err)
		return noProjectActivity, false
	}
	sinceTS := since.UTC().Format("2006-01-02T15:04:05Z")
	var sb strings.Builder
	shown := 0
	for i := range projects {
		if shown >= maxBriefingProjects {
			break
		}
		a, err := p.projectActivity(projects[i].ID, sinceTS)
		if err != nil {
			p.logger.Printf("briefing: project %d: %v", projects[i].ID, err)
			continue
		}
		if a.empty() {
			continue
		}
		p.shown.addProject(projects[i].ID)
		sb.WriteString(renderProjectActivity(projects[i], a))
		shown++
	}
	if shown == 0 {
		return noProjectActivity, false
	}
	return sb.String(), true
}

func (p *Pipeline) projectActivity(projectID int64, sinceTS string) (projectActivity, error) {
	var a projectActivity
	board, err := p.db.GetProjectBoard(projectID)
	if err != nil {
		return a, fmt.Errorf("board: %w", err)
	}
	comments, err := p.db.ListProjectComments(db.ProjectCommentFilter{ProjectID: projectID})
	if err != nil {
		return a, fmt.Errorf("comments: %w", err)
	}
	docs, err := p.db.ListProjectDocuments(projectID)
	if err != nil {
		return a, fmt.Errorf("documents: %w", err)
	}
	a.addTargets(board, sinceTS)
	a.addComments(comments, docs)
	return a, nil
}

func (a *projectActivity) addTargets(nodes []db.BoardNode, sinceTS string) {
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

func (a *projectActivity) addComments(comments []db.ProjectComment, docs []db.ProjectDocument) {
	awaiting := map[int64]bool{}
	for _, c := range comments {
		if c.Author == "agent" && c.ReadAt == "" {
			a.unreadAgent++
		}
		if c.Author == "owner" && c.Status == "open" && !c.ParentID.Valid && c.DocumentID.Valid {
			awaiting[c.DocumentID.Int64] = true
		}
	}
	for _, d := range docs {
		if awaiting[d.ID] {
			a.docsAwaiting = append(a.docsAwaiting, documentTitle(d))
		}
	}
}

func renderProjectActivity(pr db.Project, a projectActivity) string {
	var sb strings.Builder
	fmt.Fprintf(&sb, "--- [project_id=%d] %s (%s) ---\n", pr.ID, pr.Name, pr.FolderPath)
	writeProjectLine(&sb, "In progress", a.inProgress)
	writeProjectLine(&sb, "In review", a.inReview)
	writeProjectLine(&sb, "Blocked", a.blocked)
	writeProjectLine(&sb, "Done since the last briefing", a.doneSince)
	if a.unreadAgent > 0 {
		fmt.Fprintf(&sb, "Unread agent comments: %d\n", a.unreadAgent)
	}
	writeProjectLine(&sb, "Documents with open owner comments", a.docsAwaiting)
	return sb.String()
}

func writeProjectLine(sb *strings.Builder, label string, items []string) {
	if len(items) == 0 {
		return
	}
	shown := items
	more := ""
	if len(items) > maxProjectItems {
		shown = items[:maxProjectItems]
		more = fmt.Sprintf(" (+%d more)", len(items)-maxProjectItems)
	}
	fmt.Fprintf(sb, "%s (%d): %s%s\n", label, len(items), strings.Join(shown, "; "), more)
}

func documentTitle(d db.ProjectDocument) string {
	if d.Title != "" {
		return d.Title
	}
	return d.RelPath
}

func firstLine(s string) string {
	line, _, _ := strings.Cut(s, "\n")
	return strings.TrimSpace(line)
}
