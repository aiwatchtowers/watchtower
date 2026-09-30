package projectdocs

import (
	"fmt"
	"strings"

	"watchtower/internal/db"
)

// Report is the outcome of one import. Every slice is non-nil so its JSON
// form is always an array.
type Report struct {
	Imported        []string `json:"imported"`         // attached now (or, in a dry run, would be)
	AlreadyAttached []string `json:"already_attached"` // found, left untouched
	SkippedOverCap  []string `json:"skipped_over_cap"` // new, but past MaxImport this run: not attached
	DryRun          bool     `json:"dry_run"`
}

// Import scans the project folder and attaches every candidate the project
// does not have yet as an origin 'import' document. It is additive and
// idempotent: an attached rel_path is never touched, so running it again
// (e.g. a re-run of setup) only adds what is new. A dry run writes nothing.
func Import(d *db.DB, p *db.Project, dryRun bool) (Report, error) {
	found, err := Scan(p.FolderPath)
	if err != nil {
		return Report{}, err
	}
	attached, err := attachedPaths(d, p.ID)
	if err != nil {
		return Report{}, err
	}
	rep := Report{Imported: []string{}, AlreadyAttached: []string{}, SkippedOverCap: []string{}, DryRun: dryRun}
	var todo []db.ProjectDocument
	for _, c := range found {
		switch {
		case attached[strings.ToLower(c.RelPath)]:
			rep.AlreadyAttached = append(rep.AlreadyAttached, c.RelPath)
		case len(todo) >= MaxImport:
			rep.SkippedOverCap = append(rep.SkippedOverCap, c.RelPath)
		default:
			todo = append(todo, db.ProjectDocument{ProjectID: p.ID, RelPath: c.RelPath, Kind: c.Kind, Title: c.Title})
		}
	}
	if dryRun {
		for _, t := range todo {
			rep.Imported = append(rep.Imported, t.RelPath)
		}
		return rep, nil
	}
	inserted, err := d.ImportProjectDocuments(p.ID, todo)
	if err != nil {
		return Report{}, fmt.Errorf("importing documents into project %d: %w", p.ID, err)
	}
	rep.Imported = append(rep.Imported, inserted...)
	return rep, nil
}

// attachedPaths is the project's attached rel_paths, lowercased (APFS is
// case-insensitive).
func attachedPaths(d *db.DB, projectID int64) (map[string]bool, error) {
	docs, err := d.ListProjectDocuments(projectID)
	if err != nil {
		return nil, fmt.Errorf("listing documents of project %d: %w", projectID, err)
	}
	out := make(map[string]bool, len(docs))
	for _, doc := range docs {
		out[strings.ToLower(doc.RelPath)] = true
	}
	return out, nil
}
