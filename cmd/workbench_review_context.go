package cmd

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/db"
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
	ids, err := database.SessionLinkedTargets(reviewFlagSession)
	if err != nil {
		return failReview(cmd, err)
	}
	items := []reviewContextItem{}
	for _, id := range ids {
		t, err := database.GetTargetByID(int(id))
		if err != nil || t == nil {
			continue
		}
		items = append(items, contextItem(p.FolderPath, t))
	}
	return writeReview(cmd, reviewEnvelope{OK: true, Items: items})
}

func contextItem(folder string, t *db.Target) reviewContextItem {
	it := reviewContextItem{TargetID: t.ID, Text: t.Text, Intent: t.Intent}
	m := planTaskIntent.FindStringSubmatch(t.Intent)
	if m == nil {
		return it
	}
	it.PlanPath = m[1]
	it.PlanTask, _ = strconv.Atoi(m[2])
	body, ok := readPlainFile(filepath.Join(folder, filepath.Clean("/"+m[1])))
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

// readPlainFile: a regular, non-symlink file of at most maxPlanBytes.
func readPlainFile(path string) (string, bool) {
	fi, err := os.Lstat(path)
	if err != nil || !fi.Mode().IsRegular() || fi.Size() > maxPlanBytes {
		return "", false
	}
	b, err := os.ReadFile(path)
	return string(b), err == nil
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
