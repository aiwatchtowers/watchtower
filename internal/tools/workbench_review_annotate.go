package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"unicode/utf8"

	"watchtower/internal/db"
	"watchtower/internal/reviewdiff"
)

const (
	maxAnnotateNotes    = 40
	maxAnnotateChapters = 20
	maxNoteRunes        = 800
	maxChapterTitle     = 120
	maxChapterPaths     = 200
	maxChapterWhy       = 400
)

type annotateNote struct {
	Path      string `json:"path" jsonschema:"a file of your changes, relative to the repository root"`
	StartLine int    `json:"start_line" jsonschema:"first line of the note, 1-based, in the file as it is now"`
	EndLine   int    `json:"end_line" jsonschema:"last line of the note"`
	Note      string `json:"note" jsonschema:"why this change, not what it does (1-800 characters)"`
}

type annotateChapter struct {
	Title string   `json:"title" jsonschema:"a short chapter title"`
	Paths []string `json:"paths" jsonschema:"the files of the chapter, in reading order"`
	Core  bool     `json:"core" jsonschema:"true for the heart of the change"`
	Why   string   `json:"why,omitempty" jsonschema:"why the chapter exists (at most 400 characters)"`
}

type annotateChangesArgs struct {
	Notes    []annotateNote    `json:"notes,omitempty" jsonschema:"line notes on the non-obvious changes (at most 40)"`
	Chapters []annotateChapter `json:"chapters,omitempty" jsonschema:"reading order of a big change (at most 20)"`
	Reason   string            `json:"reason" jsonschema:"one sentence: why you annotate"`
}

var errNoAnnotateSession = &ValidationError{Msg: "annotate_changes needs a Watchtower terminal session"}

// NewAnnotateChanges is annotate_changes: the agent's own notes and reading
// order for the owner's diff reviewer. Each call replaces the session's
// earlier notes; applied immediately and audited.
func NewAnnotateChanges(sessionEnv func() string) *Tool {
	return &Tool{
		Name: "annotate_changes",
		Description: "Before you hand work back: leave the owner notes in the diff reviewer — a note on each " +
			"non-obvious change (why, not what) and, for a big change, chapters in reading order. Each call " +
			"replaces your earlier notes for this session. Lines refer to the files as they are now. Applied immediately.",
		InputSchema: mustSchema[annotateChangesArgs]("annotate_changes"),
		Access:      AccessWrite,
		Surfaces:    workbenchSurfaces,
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a annotateChangesArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			_, err := cleanAnnotation(a)
			return err
		},
		Scope: func(ctx context.Context, d *db.DB, raw json.RawMessage, b Binding) error {
			var a annotateChangesArgs
			if err := json.Unmarshal(raw, &a); err != nil {
				return &ValidationError{Msg: "invalid arguments"}
			}
			_, err := prepareAnnotation(ctx, d, b, a, sessionEnv)
			return err
		},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a annotateChangesArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding annotate_changes args: %w", err)
			}
			plan, err := prepareAnnotation(ctx, d, call.Binding, a, sessionEnv)
			if err != nil {
				return nil, err
			}
			if err := d.ReplaceReviewNotes(plan.project, plan.session, plan.tree, plan.rows); err != nil {
				return nil, err
			}
			chapters := 0
			for _, n := range plan.rows {
				if n.Kind == "chapter" {
					chapters++
				}
			}
			stored, tree := len(plan.rows)-chapters, plan.tree
			return map[string]any{"tree_sha": tree, "notes": stored, "chapters": chapters,
				"text": fmt.Sprintf("Stored %d notes and %d chapters for the current changes (tree %s). "+
					"They replace this session's earlier notes; the owner sees them in Review Changes.", stored, chapters, tree[:7])}, nil
		},
	}
}

// cleanAnnotation checks the argument bounds and returns the args trimmed,
// chapter paths trimmed and de-duplicated.
func cleanAnnotation(a annotateChangesArgs) (annotateChangesArgs, error) {
	if len(a.Notes) > maxAnnotateNotes {
		return a, &ValidationError{Msg: fmt.Sprintf("notes: at most %d", maxAnnotateNotes)}
	}
	if len(a.Chapters) > maxAnnotateChapters {
		return a, &ValidationError{Msg: fmt.Sprintf("chapters: at most %d", maxAnnotateChapters)}
	}
	if len(a.Notes) == 0 && len(a.Chapters) == 0 {
		return a, &ValidationError{Msg: "at least one note or chapter is required"}
	}
	if _, err := boundedText("reason", a.Reason, maxReasonRunes); err != nil {
		return a, err
	}
	out := a
	out.Notes = make([]annotateNote, len(a.Notes))
	for i, n := range a.Notes {
		note, err := boundedText(fmt.Sprintf("notes[%d].note", i), n.Note, maxNoteRunes)
		if err != nil {
			return a, err
		}
		n.Path, n.Note = strings.TrimSpace(n.Path), note
		if n.Path == "" {
			return a, &ValidationError{Msg: fmt.Sprintf("notes[%d].path: required", i)}
		}
		out.Notes[i] = n
	}
	out.Chapters = make([]annotateChapter, len(a.Chapters))
	for i, c := range a.Chapters {
		title, err := boundedText(fmt.Sprintf("chapters[%d].title", i), c.Title, maxChapterTitle)
		if err != nil {
			return a, err
		}
		c.Title = title
		c.Why = strings.TrimSpace(c.Why)
		if utf8.RuneCountInString(c.Why) > maxChapterWhy {
			return a, &ValidationError{Msg: fmt.Sprintf("chapters[%d].why: at most %d characters", i, maxChapterWhy)}
		}
		if len(c.Paths) == 0 || len(c.Paths) > maxChapterPaths {
			return a, &ValidationError{Msg: fmt.Sprintf("chapters[%d].paths: 1 to %d files", i, maxChapterPaths)}
		}
		seen := map[string]bool{}
		paths := make([]string, 0, len(c.Paths))
		for _, p := range c.Paths {
			if p = strings.TrimSpace(p); p != "" && !seen[p] {
				seen[p] = true
				paths = append(paths, p)
			}
		}
		if len(paths) == 0 {
			return a, &ValidationError{Msg: fmt.Sprintf("chapters[%d].paths: 1 to %d files", i, maxChapterPaths)}
		}
		c.Paths = paths
		out.Chapters[i] = c
	}
	return out, nil
}

// annotationPlan is what annotate_changes will store.
type annotationPlan struct {
	project, session int64
	tree             string
	rows             []db.ReviewNote
}

// prepareAnnotation resolves the calling session, snapshots its folder
// and checks every note against that snapshot (the file is there, text, and
// the lines exist), returning the rows to store. Scope runs it before any
// audit row; Execute runs it again and stores what it finds.
func prepareAnnotation(ctx context.Context, d *db.DB, b Binding, a annotateChangesArgs, sessionEnv func() string) (annotationPlan, error) {
	a, err := cleanAnnotation(a)
	if err != nil {
		return annotationPlan{}, err
	}
	p, err := workbenchOf(ctx, d, b)
	if err != nil {
		return annotationPlan{}, err
	}
	session, err := terminalSessionOf(d, p.ID, sessionEnv)
	if err != nil {
		return annotationPlan{}, err
	}
	if !session.Valid {
		return annotationPlan{}, errNoAnnotateSession
	}
	folder, err := ReviewSessionFolder(ctx, d, p, session.Int64)
	if err != nil {
		return annotationPlan{}, err
	}
	repo, err := reviewdiff.Open(folder, nil)
	if err != nil {
		return annotationPlan{}, err
	}
	tree, err := repo.Snapshot(ctx)
	if err != nil {
		return annotationPlan{}, err
	}
	var rows []db.ReviewNote
	files := map[string][]string{}
	for i, n := range a.Notes {
		lines, ok := files[n.Path]
		if !ok {
			side, err := repo.File(ctx, tree, n.Path)
			if err != nil {
				return annotationPlan{}, err
			}
			if !side.Exists || side.Binary || side.TooLarge {
				return annotationPlan{}, &ValidationError{Msg: fmt.Sprintf("notes[%d].path: %s is not a text file of the current changes", i, n.Path)}
			}
			lines = strings.Split(strings.TrimSuffix(side.Text, "\n"), "\n")
			files[n.Path] = lines
		}
		if n.StartLine < 1 || n.EndLine < n.StartLine || n.EndLine > len(lines) {
			return annotationPlan{}, &ValidationError{Msg: fmt.Sprintf("notes[%d]: %s has %d lines; lines %d-%d do not fit",
				i, n.Path, len(lines), n.StartLine, n.EndLine)}
		}
		rows = append(rows, db.ReviewNote{Kind: "note", Path: n.Path, StartLine: n.StartLine, EndLine: n.EndLine,
			Quote: strings.Join(lines[n.StartLine-1:n.EndLine], "\n"), Text: n.Note, TreeSHA: tree})
	}
	for _, c := range a.Chapters {
		rows = append(rows, db.ReviewNote{Kind: "chapter", Text: c.Title, Paths: c.Paths, Core: c.Core, Why: c.Why, TreeSHA: tree})
	}
	return annotationPlan{project: p.ID, session: session.Int64, tree: tree, rows: rows}, nil
}
