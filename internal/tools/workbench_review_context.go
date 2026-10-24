package tools

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"watchtower/internal/db"
	"watchtower/internal/reviewai"
)

// ReviewContextItem is one thing the owner asked a session for: a target it
// is linked to, with its plan task when the intent names one.
type ReviewContextItem struct {
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

// ReviewContextItems lists the session's linked targets that belong to workbench p,
// each with its plan task when the intent names one.
func ReviewContextItems(_ context.Context, database *db.DB, p *db.Workbench, sessionID int64) ([]ReviewContextItem, error) {
	ids, err := database.SessionLinkedTargets(sessionID)
	if err != nil {
		return nil, err
	}
	items := []ReviewContextItem{}
	for _, id := range ids {
		t, err := database.GetTargetByID(int(id))
		if errors.Is(err, sql.ErrNoRows) {
			continue // deleted between the two reads
		}
		if err != nil {
			return nil, fmt.Errorf("reading linked target %d: %w", id, err)
		}
		if t == nil || !t.WorkbenchID.Valid || t.WorkbenchID.Int64 != p.ID {
			continue
		}
		items = append(items, contextItem(p.FolderPath, t))
	}
	return items, nil
}

func contextItem(folder string, t *db.Target) ReviewContextItem {
	it := ReviewContextItem{TargetID: t.ID, Text: t.Text, Intent: t.Intent}
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
	_, after, ok := strings.Cut(body, head)
	if !ok {
		return ""
	}
	rest := after
	if end := strings.Index(rest, "\n### "); end >= 0 {
		rest = rest[:end]
	}
	return strings.TrimSpace(head + rest)
}

// ReviewOverviewInput gathers a session's context items and its notes: the
// intent an AI overview is made for and cached under (reviewai.IntentHash).
func ReviewOverviewInput(ctx context.Context, d *db.DB, p *db.Workbench, sessionID int64) (reviewai.Input, error) {
	var in reviewai.Input
	items, err := ReviewContextItems(ctx, d, p, sessionID)
	if err != nil {
		return in, err
	}
	for _, it := range items {
		in.Intent = append(in.Intent, reviewai.IntentItem{Text: it.Text, Intent: it.Intent, Task: it.PlanText})
	}
	if in.Notes, err = d.ReviewNotes(p.ID, sessionID); err != nil {
		return in, err
	}
	return in, nil
}
