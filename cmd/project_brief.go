package cmd

import (
	"errors"
	"fmt"
	"math"
	"os"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/spf13/cobra"

	"watchtower/internal/db"
)

const (
	// briefMaxChars caps the SessionStart hook body (runes): Claude Code adds
	// it to every session's context, whatever the board holds.
	briefMaxChars  = 4000
	briefLineChars = 240
)

var briefRules = []string{
	"Board rules: set a target in_progress (update_target) before you work on it and done after; ask the owner with add_comment instead of stopping.",
	"Before revising an attached document call list_comments(document_id); resolve each comment you addressed (resolve_comment), then attach_document again.",
}

var projectBriefCmd = &cobra.Command{
	Use:   "brief",
	Short: "Print a project's brief for Claude Code (the SessionStart hook body)",
	Long: "Prints at most 4000 characters: target counts, the open part of the board with\n" +
		"ids, status and priority (board order, done omitted), comments waiting for the agent, and the\n" +
		"board rules. Always exits 0 — a hook must never break a session start, so any\n" +
		"failure (project gone, folder moved, database unreadable) is one line.",
	// No root schema/config pre-run: a broken config would otherwise fail the
	// hook before RunE could turn it into the one-line brief (the
	// extract-pdf-text precedent). loadProjectBrief loads config itself.
	PersistentPreRunE: func(*cobra.Command, []string) error { return nil },
	// ArbitraryArgs + UnknownFlags: a hook invocation carrying an extra
	// positional arg or a flag this version doesn't know must still exit 0
	// with the one-line brief, never fail in cobra's own flag parser.
	Args:               cobra.ArbitraryArgs,
	FParseErrWhitelist: cobra.FParseErrWhitelist{UnknownFlags: true},
	RunE:               runProjectBrief,
}

// projectBriefFlagProject is a string, not an int64: an Int64Var flag makes
// cobra's flag parser itself reject a non-numeric --project value before
// RunE (or PersistentPreRunE) ever runs, exiting non-zero — exactly what this
// command must never do. loadProjectBriefFlag turns it into an id (0 for
// empty/invalid) so every bad value becomes the one-line brief instead.
var projectBriefFlagProject string

func init() {
	projectBriefCmd.Flags().StringVar(&projectBriefFlagProject, "project", "", "project id")
	projectCmd.AddCommand(projectBriefCmd)
}

func runProjectBrief(cmd *cobra.Command, _ []string) error {
	fmt.Fprintln(cmd.OutOrStdout(), loadProjectBriefFlag(projectBriefFlagProject))
	return nil
}

// loadProjectBriefFlag parses the raw --project flag value. Empty (missing,
// or explicitly "") reads as "no --project id given" via loadProjectBrief's
// own id<=0 branch; a non-empty value that isn't a positive integer gets its
// own one-line reason so it isn't misreported as missing.
func loadProjectBriefFlag(raw string) string {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return loadProjectBrief(0)
	}
	id, err := strconv.ParseInt(trimmed, 10, 64)
	if err != nil || id <= 0 {
		return briefUnavailable(0, fmt.Sprintf("is unavailable: invalid --project value %q", raw))
	}
	return loadProjectBrief(id)
}

func loadProjectBrief(id int64) string {
	if id <= 0 {
		return briefUnavailable(id, "is unavailable: no --project id given")
	}
	_, database, err := openJiraCmdDB()
	if err != nil {
		return briefUnavailable(id, "is unavailable: "+err.Error())
	}
	defer database.Close()
	p, err := database.GetProject(id)
	if errors.Is(err, db.ErrProjectNotFound) {
		return briefUnavailable(id, "no longer exists")
	}
	if err != nil {
		return briefUnavailable(id, "is unavailable: "+err.Error())
	}
	if _, err := os.Stat(p.FolderPath); err != nil {
		return briefUnavailable(id, fmt.Sprintf("folder %s is missing (moved or deleted?)", p.FolderPath))
	}
	return briefFromDB(database, p)
}

func briefFromDB(database *db.DB, p *db.Project) string {
	board, err := database.GetProjectBoard(p.ID)
	if err != nil {
		return briefUnavailable(p.ID, "is unavailable: "+err.Error())
	}
	comments, err := database.ListProjectComments(db.ProjectCommentFilter{ProjectID: p.ID, NewForAgent: true})
	if err != nil {
		return briefUnavailable(p.ID, "is unavailable: "+err.Error())
	}
	docs, err := database.ListProjectDocuments(p.ID)
	if err != nil {
		return briefUnavailable(p.ID, "is unavailable: "+err.Error())
	}
	byID := make(map[int64]db.ProjectDocument, len(docs))
	for _, d := range docs {
		byID[d.ID] = d
	}
	return renderProjectBrief(board, p, comments, byID)
}

// briefUnavailable is the one-line brief for every failure.
func briefUnavailable(id int64, reason string) string {
	return briefClip(fmt.Sprintf("Watchtower: project %d %s.", id, reason), briefLineChars)
}

// renderProjectBrief is the hook body: header, the open tree, the comments new
// for the agent, the rules — at most briefMaxChars runes. Pure.
func renderProjectBrief(board []db.BoardNode, p *db.Project, comments []db.ProjectComment, docs map[int64]db.ProjectDocument) string {
	head := briefHeader(p, board, len(comments))
	rules := strings.Join(briefRules, "\n")
	budget := briefMaxChars - utf8.RuneCountInString(head) - utf8.RuneCountInString(rules) - 3 // three joining newlines
	commentLines := briefCommentLines(comments, docs, boardTitles(board))
	treeBudget := budget
	if len(commentLines) > 0 {
		treeBudget = budget / 2
	}
	tree := fitBriefSection("Open targets:", briefTargetLines(board), treeBudget, "targets (project_board)")
	section := fitBriefSection("New comments for you:", commentLines, budget-utf8.RuneCountInString(tree), "comments (list_comments)")
	return strings.Join([]string{head, tree, section, rules}, "\n")
}

func briefHeader(p *db.Project, board []db.BoardNode, newComments int) string {
	c := countBoardStatuses(board)
	lines := []string{
		briefClip(fmt.Sprintf("Watchtower project #%d %q — %s", p.ID, p.Name, p.FolderPath), briefLineChars),
		fmt.Sprintf("Targets: %d in progress, %d blocked, %d todo, %d done. New comments for you: %d.",
			c["in_progress"], c["blocked"], c["todo"], c["done"], newComments),
	}
	if strings.TrimSpace(p.Description) == "" {
		lines = append(lines, "Setup pending: run the watchtower-project skill's setup (project_info, update_project, first board).")
	}
	return strings.Join(lines, "\n")
}

// fitBriefSection writes title and as many lines as fit in limit runes; the
// rest becomes one "… N more <what>" line. Each written line reserved room
// for a marker at least as long as any later one, so the marker always fits.
func fitBriefSection(title string, lines []string, limit int, what string) string {
	if len(lines) == 0 {
		return title + " none."
	}
	var b strings.Builder
	b.WriteString(title)
	used := utf8.RuneCountInString(title)
	for i, line := range lines {
		more := fmt.Sprintf("\n… %d more %s", len(lines)-i, what)
		reserve := 0
		if i < len(lines)-1 {
			reserve = utf8.RuneCountInString(more)
		}
		need := 1 + utf8.RuneCountInString(line)
		if used+need+reserve > limit {
			b.WriteString(more)
			return b.String()
		}
		b.WriteString("\n")
		b.WriteString(line)
		used += need
	}
	return b.String()
}

func briefClosed(status string) bool { return status == "done" || status == "dismissed" }

// briefTargetLines lists the open targets depth-first in board order. A
// closed target is omitted; its open children stay, at its depth.
func briefTargetLines(board []db.BoardNode) []string {
	var lines []string
	var walk func([]db.BoardNode, int)
	walk = func(level []db.BoardNode, depth int) {
		for _, n := range level {
			if briefClosed(n.Target.Status) {
				walk(n.Children, depth)
				continue
			}
			lines = append(lines, briefTargetLine(n, depth))
			walk(n.Children, depth+1)
		}
	}
	walk(board, 0)
	return lines
}

func briefTargetLine(n db.BoardNode, depth int) string {
	indent := strings.Repeat("  ", min(depth, 4))
	t := n.Target
	line := fmt.Sprintf("- #%d [%s, %s, %d%%] %s", t.ID, t.Status, t.Priority, int(math.Round(t.Progress*100)), t.Text)
	if n.NewForAgent > 0 {
		line += fmt.Sprintf(" (%d new comments)", n.NewForAgent)
	}
	if len(n.Documents) > 0 {
		line += fmt.Sprintf(" (%d docs)", len(n.Documents))
	}
	return indent + briefClip(line, briefLineChars-len(indent))
}

func boardTitles(board []db.BoardNode) map[int64]string {
	titles := map[int64]string{}
	var walk func([]db.BoardNode)
	walk = func(level []db.BoardNode) {
		for _, n := range level {
			titles[int64(n.Target.ID)] = n.Target.Text
			walk(n.Children)
		}
	}
	walk(board)
	return titles
}

// briefCommentLines renders target comments first, then document comments.
func briefCommentLines(comments []db.ProjectComment, docs map[int64]db.ProjectDocument, titles map[int64]string) []string {
	ordered := append([]db.ProjectComment(nil), comments...)
	sort.SliceStable(ordered, func(i, j int) bool {
		return !ordered[i].DocumentID.Valid && ordered[j].DocumentID.Valid
	})
	lines := make([]string, 0, len(ordered))
	for _, c := range ordered {
		lines = append(lines, briefClip(briefCommentLine(c, docs, titles), briefLineChars))
	}
	return lines
}

func briefCommentLine(c db.ProjectComment, docs map[int64]db.ProjectDocument, titles map[int64]string) string {
	who := fmt.Sprintf("- comment #%d", c.ID)
	if c.ParentID.Valid {
		who += fmt.Sprintf(" (reply in thread #%d)", c.ParentID.Int64)
	}
	body := briefClip(c.Body, 160)
	if !c.DocumentID.Valid {
		return fmt.Sprintf("%s on target #%d %q: %s", who, c.TargetID.Int64, briefClip(titles[c.TargetID.Int64], 60), body)
	}
	where := docs[c.DocumentID.Int64].RelPath
	if c.AnchorHeading != "" {
		where += " § " + briefClip(c.AnchorHeading, 60)
	}
	if c.AnchorQuote != "" {
		where += fmt.Sprintf(" on %q", briefClip(c.AnchorQuote, 80))
	}
	return fmt.Sprintf("%s on document #%d %s: %s", who, c.DocumentID.Int64, where, body)
}

// briefClip collapses whitespace to single spaces and cuts s to n runes.
func briefClip(s string, n int) string {
	s = strings.Join(strings.Fields(s), " ")
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	r := []rune(s)
	return string(r[:n-1]) + "…"
}
