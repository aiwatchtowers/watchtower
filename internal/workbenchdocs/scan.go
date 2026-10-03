package workbenchdocs

// Scan finds the specs, plans and README a project folder already holds, so
// project setup can attach them to Documents without an AI call (board item
// #79).

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
// hidden directories and node_modules are not walked. A path below the
// folder or docs/ that cannot be read is skipped and returned as
// "<rel_path>: <reason>" in the second result; only an unreadable folder or
// docs/ itself fails the scan.
func Scan(folder string) ([]Candidate, []string, error) {
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
		c, err := candidate(e, e.Name(), "doc")
		if err != nil {
			return nil, []string{unreadableEntry(e.Name(), err)}, nil
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
			unreadable = append(unreadable, unreadableEntry(p, err))
			if e != nil && e.IsDir() {
				return fs.SkipDir // not even the entries listed before the failure
			}
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
		c, err := candidate(e, p, kind)
		if err != nil {
			unreadable = append(unreadable, unreadableEntry(p, err))
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

func candidate(e fs.DirEntry, rel, kind string) (Candidate, error) {
	info, err := e.Info()
	if err != nil {
		return Candidate{}, err
	}
	base := path.Base(rel)
	return Candidate{RelPath: rel, Kind: kind, Title: strings.TrimSuffix(base, path.Ext(base)), modTime: info.ModTime()}, nil
}

// unreadableEntry is "<rel>: <reason>", the reason without the path an
// fs.PathError repeats ("permission denied", "no such file or directory").
func unreadableEntry(rel string, err error) string {
	var pe *fs.PathError
	if errors.As(err, &pe) {
		err = pe.Err
	}
	return rel + ": " + err.Error()
}

func sortNewestFirst(cs []Candidate) {
	slices.SortStableFunc(cs, func(a, b Candidate) int {
		if c := b.modTime.Compare(a.modTime); c != 0 {
			return c
		}
		return strings.Compare(a.RelPath, b.RelPath)
	})
}
