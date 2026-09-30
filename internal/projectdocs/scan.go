// Package projectdocs finds the specs, plans and README a project folder
// already holds, so project setup can attach them to Documents without an AI
// call (board item #79). It only reads the folder; it never writes a file.
package projectdocs

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

// MaxImport caps one import: the README first, then the newest specs/plans
// by modification time. What is past the cap is reported, never imported.
const MaxImport = 50

// Candidate is one file the scan found.
type Candidate struct {
	RelPath string // slash-separated, relative to the folder
	Kind    string // spec | plan | doc
	Title   string // file name without extension
	modTime time.Time
}

// Scan lists folder's README.md (at the root) and every .md/.txt file whose
// parent directory is named specs or plans anywhere under docs/ — the README
// first, then newest first. Symlinks — files or directories — are never
// followed or listed, so every rel_path is a regular file inside the folder;
// hidden directories and node_modules are not walked. A path it cannot read
// below the folder and docs/ themselves is skipped and returned in
// unreadable; only an unreadable folder or docs/ fails the scan.
func Scan(folder string) (found []Candidate, unreadable []string, err error) {
	readme, unreadable, err := scanReadme(folder)
	if err != nil {
		return nil, nil, err
	}
	docs, skipped, err := scanDocsDir(folder)
	if err != nil {
		return nil, nil, err
	}
	sortNewestFirst(docs)
	return slices.Concat(readme, docs), append(unreadable, skipped...), nil
}

func scanReadme(folder string) ([]Candidate, []string, error) {
	entries, err := os.ReadDir(folder)
	if err != nil {
		return nil, nil, fmt.Errorf("reading %s: %w", folder, err)
	}
	for _, e := range entries {
		if !strings.EqualFold(e.Name(), "README.md") || !e.Type().IsRegular() {
			continue
		}
		c, ok := candidate(e, e.Name(), "doc")
		if !ok {
			return nil, []string{e.Name()}, nil
		}
		return []Candidate{c}, nil, nil
	}
	return nil, nil, nil
}

// scanDocsDir walks folder/docs. A missing docs/, or a docs/ that is a
// symlink or a file, yields nothing.
func scanDocsDir(folder string) ([]Candidate, []string, error) {
	root := filepath.Join(folder, "docs")
	st, err := os.Lstat(root)
	if errors.Is(err, fs.ErrNotExist) || (err == nil && !st.IsDir()) {
		return nil, nil, nil
	}
	if err != nil {
		return nil, nil, fmt.Errorf("reading %s: %w", root, err)
	}
	var out []Candidate
	var unreadable []string
	err = fs.WalkDir(os.DirFS(folder), "docs", func(p string, e fs.DirEntry, err error) error {
		if err != nil {
			if p == "docs" {
				return err
			}
			// A directory WalkDir could not list: its contents are skipped.
			unreadable = append(unreadable, p)
			return nil
		}
		if e.IsDir() {
			if name := e.Name(); strings.HasPrefix(name, ".") || name == "node_modules" {
				return fs.SkipDir
			}
			return nil
		}
		kind := docKind(p, e)
		if kind == "" {
			return nil
		}
		c, ok := candidate(e, p, kind)
		if !ok {
			unreadable = append(unreadable, p)
			return nil
		}
		out = append(out, c)
		return nil
	})
	if err != nil {
		return nil, nil, fmt.Errorf("scanning %s: %w", root, err)
	}
	return out, unreadable, nil
}

// docKind is spec or plan for a regular .md/.txt file directly inside a
// specs or plans directory, else "".
func docKind(p string, e fs.DirEntry) string {
	if !e.Type().IsRegular() {
		return ""
	}
	if ext := strings.ToLower(path.Ext(p)); ext != ".md" && ext != ".txt" {
		return ""
	}
	switch strings.ToLower(path.Base(path.Dir(p))) {
	case "specs":
		return "spec"
	case "plans":
		return "plan"
	}
	return ""
}

// candidate is false when the file's metadata cannot be read (it vanished
// or is not readable): the caller reports rel as unreadable.
func candidate(e fs.DirEntry, rel, kind string) (Candidate, bool) {
	info, err := e.Info()
	if err != nil {
		return Candidate{}, false
	}
	base := path.Base(rel)
	return Candidate{RelPath: rel, Kind: kind, Title: strings.TrimSuffix(base, path.Ext(base)), modTime: info.ModTime()}, true
}

func sortNewestFirst(cs []Candidate) {
	slices.SortStableFunc(cs, func(a, b Candidate) int {
		if c := b.modTime.Compare(a.modTime); c != 0 {
			return c
		}
		return strings.Compare(a.RelPath, b.RelPath)
	})
}
