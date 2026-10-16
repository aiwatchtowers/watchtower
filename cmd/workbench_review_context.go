package cmd

import (
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/db"
	"watchtower/internal/reviewdiff"
)

type reviewContextItem struct {
	TargetID int    `json:"target_id"`
	Text     string `json:"text"`
	Intent   string `json:"intent"`
	PlanPath string `json:"plan_path,omitempty"`
	PlanTask int    `json:"plan_task,omitempty"`
	PlanText string `json:"plan_text,omitempty"`
	SpecPath string `json:"spec_path,omitempty"`
	Missing  string `json:"missing,omitempty"` // "plan" | "task"
}

var (
	planTaskIntent = regexp.MustCompile(`^(\S+\.md) — Task (\d+)`)
	planSpecLine   = regexp.MustCompile("\\*\\*Spec:\\*\\* `([^`]+)`")
)

const maxPlanBytes = 1 << 20

func runWorkbenchReviewContext(cmd *cobra.Command, _ []string) error {
	database, p, err := reviewTarget(cmd)
	if err != nil {
		return err
	}
	if err := checkSessionOnWorkbench(database, p, reviewFlagSession); err != nil {
		return failReview(cmd, err)
	}
	ids, err := database.SessionLinkedTargets(reviewFlagSession)
	if err != nil {
		return failReview(cmd, err)
	}
	items := []reviewContextItem{}
	for _, id := range ids {
		t, err := database.GetTargetByID(int(id))
		if err != nil || t == nil || !t.WorkbenchID.Valid || t.WorkbenchID.Int64 != p.ID {
			continue
		}
		items = append(items, contextItem(p.FolderPath, t))
	}
	lenses, notes := reviewdiff.LoadLenses(p.FolderPath)
	return writeReview(cmd, reviewEnvelope{OK: true, Items: items, Lenses: lenses, LensNotes: notes})
}

func contextItem(folder string, t *db.Target) reviewContextItem {
	it := reviewContextItem{TargetID: t.ID, Text: t.Text, Intent: t.Intent}
	m := planTaskIntent.FindStringSubmatch(t.Intent)
	if m == nil {
		return it
	}
	it.PlanPath = m[1]
	it.PlanTask, _ = strconv.Atoi(m[2])
	body, ok := readPlainFile(folder, filepath.Join(folder, filepath.Clean("/"+m[1])))
	if !ok {
		it.Missing = "plan"
		return it
	}
	if s := planSpecLine.FindStringSubmatch(body); s != nil {
		it.SpecPath = s[1]
	}
	it.PlanText = taskSection(body, it.PlanTask)
	if it.PlanText == "" {
		it.Missing = "task"
	}
	return it
}

// readPlainFile: a regular file of at most maxPlanBytes whose symlink-resolved
// path stays inside the symlink-resolved folder.
func readPlainFile(folder, path string) (string, bool) {
	realFolder, err := filepath.EvalSymlinks(folder)
	if err != nil {
		return "", false
	}
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return "", false
	}
	rel, err := filepath.Rel(realFolder, resolved)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", false
	}
	fi, err := os.Lstat(resolved)
	if err != nil || !fi.Mode().IsRegular() {
		return "", false
	}
	f, err := os.Open(resolved)
	if err != nil {
		return "", false
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, maxPlanBytes+1))
	if err != nil || len(b) > maxPlanBytes {
		return "", false
	}
	return string(b), true
}

// taskSection: from "### Task N:" to the next "### " heading.
func taskSection(body string, n int) string {
	head := "### Task " + strconv.Itoa(n) + ":"
	start := strings.Index(body, head)
	if start < 0 {
		return ""
	}
	rest := body[start+len(head):]
	if end := strings.Index(rest, "\n### "); end >= 0 {
		rest = rest[:end]
	}
	return strings.TrimSpace(head + rest)
}
