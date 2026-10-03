// Package workbenchdocs lists the text documents of a workbench folder —
// the files the knowledge index holds for the workbench's sessions
// (PROJ-08). It only reads the folder; it never writes a file.
package workbenchdocs

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"watchtower/internal/devpack"
	"watchtower/internal/gitbin"
	"watchtower/internal/workbenchgit"
)

// MaxTextFiles caps one listing: the newest files by modification time are
// kept, and the cut is logged.
const MaxTextFiles = 2000

// gitListBudget bounds the git run of one listing.
const gitListBudget = 5 * time.Second

// hiddenNames are never listed, at any depth: the Go twin of the Desktop's
// CodeFileTree.hiddenNames (VCS and build output that would bury the
// documents).
var hiddenNames = []string{".git", ".build", "node_modules", ".DS_Store", ".swiftpm", "DerivedData", ".idea", ".worktrees"}

// hiddenDirs are skipped as a whole, at any depth: Claude Code's worktrees
// of the folder hold copies of its documents, and the skills the workbench
// install writes (internal/devpack; git-excluded in a repository) are
// Watchtower's, not the owner's.
var hiddenDirs = []string{
	".claude/worktrees",
	".claude/skills/" + devpack.WorkbenchSkillName,
	".claude/skills/" + devpack.LegacySkillName,
}

// File is one text document of the folder.
type File struct {
	RelPath string // slash-separated, relative to the folder
	ModTime time.Time
}

// Lister lists a folder's text documents. The zero value is the real one.
type Lister struct {
	// Locate finds git. nil = gitbin.Locate.
	Locate func() (string, bool)
}

// ListTextFiles lists folder's .md, .markdown and .txt files with the
// zero Lister.
func ListTextFiles(ctx context.Context, folder string) ([]File, error) {
	return Lister{}.List(ctx, folder)
}

// List lists folder's .md, .markdown and .txt files (any case), newest
// first, capped at MaxTextFiles. Inside a git repository they are the files
// git does not ignore (internal/workbenchgit, within gitListBudget);
// elsewhere, or when no git is installed, a walk. Either way only regular
// files are listed (a symlink is never followed), and the hidden names and
// directories (.claude/worktrees, the installed skills) are skipped. A
// failed git run is an error, never an empty listing: a caller pruning by
// the listing would otherwise drop every entry of the folder.
func (l Lister) List(ctx context.Context, folder string) ([]File, error) {
	rels, err := l.gitFiles(ctx, folder)
	if errors.Is(err, errNoGit) {
		rels, err = walkFiles(folder)
	}
	if err != nil {
		return nil, err
	}
	var out []File
	for _, rel := range rels {
		if !isTextDocument(rel) || isHidden(rel) {
			continue
		}
		// Lstat: a symlink is never followed, and never listed — the file
		// it points to is listed when it is a document of the folder.
		fi, err := os.Lstat(filepath.Join(folder, filepath.FromSlash(rel)))
		switch {
		case errors.Is(err, fs.ErrNotExist):
			continue // tracked, but deleted from the working tree
		case err != nil:
			out = append(out, File{RelPath: rel}) // listed: the reader says why it cannot read it
		case fi.Mode().IsRegular():
			out = append(out, File{RelPath: rel, ModTime: fi.ModTime()})
		}
	}
	slices.SortFunc(out, func(a, b File) int {
		if c := b.ModTime.Compare(a.ModTime); c != 0 {
			return c
		}
		return strings.Compare(a.RelPath, b.RelPath)
	})
	if len(out) > MaxTextFiles {
		log.Printf("workbenchdocs: %s holds %d text files; listing the %d newest", folder, len(out), MaxTextFiles)
		out = out[:MaxTextFiles]
	}
	return out, nil
}

// errNoGit: the folder is outside a repository, or no git is installed.
var errNoGit = errors.New("no git listing")

func (l Lister) gitFiles(ctx context.Context, folder string) ([]string, error) {
	if !gitbin.InsideRepository(folder) {
		return nil, errNoGit
	}
	ctx, cancel := context.WithTimeout(ctx, gitListBudget)
	defer cancel()
	rels, err := workbenchgit.ListFiles(ctx, workbenchgit.Options{Folder: folder, Locate: l.Locate})
	if errors.Is(err, gitbin.ErrUnavailable) {
		return nil, errNoGit
	}
	if err != nil {
		return nil, fmt.Errorf("listing %s with git: %w", folder, err)
	}
	return rels, nil
}

// walkFiles lists every non-directory entry below folder. fs.WalkDir never
// follows a symlink, so a linked directory is not entered. A subdirectory
// that cannot be read is skipped; only an unreadable folder fails.
func walkFiles(folder string) ([]string, error) {
	var out []string
	err := fs.WalkDir(os.DirFS(folder), ".", func(p string, e fs.DirEntry, err error) error {
		if err != nil {
			if p == "." {
				return err
			}
			if e != nil && e.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		if e.IsDir() {
			if p != "." && isHidden(p) {
				return fs.SkipDir
			}
			return nil
		}
		out = append(out, p)
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("listing %s: %w", folder, err)
	}
	return out, nil
}

func isTextDocument(rel string) bool {
	switch strings.ToLower(path.Ext(rel)) {
	case ".md", ".markdown", ".txt":
		return true
	}
	return false
}

// isHidden reports whether rel is, or lies below, a hidden name or one of
// the hidden directories.
func isHidden(rel string) bool {
	for _, dir := range hiddenDirs {
		if strings.Contains("/"+rel+"/", "/"+dir+"/") {
			return true
		}
	}
	for part := range strings.SplitSeq(rel, "/") {
		if slices.Contains(hiddenNames, part) {
			return true
		}
	}
	return false
}
