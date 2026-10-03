package kb

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"

	"watchtower/internal/db"
)

// A file set is a folder's files indexed as one document each, under one
// container (a workbench). Each document is keyed
// <prefix><container>:<rel path>, split at its #–### headings, anchored by
// {<container anchor>, rel_path, unreadable?, truncated?} and linked by a
// file:// URL; its time is the file's mtime, which gates the daemon's
// re-rendering (needsRender).
// Visibility stays a per-source SQL condition (workbenchDocVisible).

// fileSetMaxBytes caps how much of one file is read; a longer file is
// indexed up to it and its anchor says so.
const fileSetMaxBytes = 2 << 20

// fileSetKind is how one file-set source keys and anchors its documents.
type fileSetKind struct {
	prefix          string // a key is <prefix><container>:<rel path>
	containerAnchor string // the anchor field holding the container id
}

var fileSetKinds = map[string]fileSetKind{
	WorkbenchDocSource: {prefix: workbenchDocPrefix, containerAnchor: "project_id"},
}

// containerPrefix is the key prefix of every document of one container.
func (k fileSetKind) containerPrefix(container int64) string {
	return k.prefix + strconv.FormatInt(container, 10) + ":"
}

// parseKey splits a key into its container and rel path.
func (k fileSetKind) parseKey(key string) (int64, string, bool) {
	rest, ok := splitRef(key, k.prefix)
	if !ok {
		return 0, "", false
	}
	idStr, rel, ok := strings.Cut(rest, ":")
	if !ok || rel == "" {
		return 0, "", false
	}
	id, err := strconv.ParseInt(idStr, 10, 64)
	return id, rel, err == nil
}

// FileSet is files of one container to index.
type FileSet struct {
	Source    string   // a file-set source: WorkbenchDocSource
	Container int64    // the container's id (a workbench id)
	Root      string   // the folder the files are in
	Files     []string // slash-separated paths relative to Root
}

// IndexFileSet indexes set's files now — an explicit trigger: every file is
// rendered, with no mtime gate (an edit in the second of the last index
// keeps its mtime), and only a changed text is written (the content hash).
// A file that is gone loses its entry; other entries of the container are
// left alone. An unreadable file is indexed by its path, never an error.
// docs is how many files the set has, changed how many index entries were
// written or removed.
func IndexFileSet(ctx context.Context, d *db.DB, set FileSet) (docs, changed int, err error) {
	return indexFileSet(ctx, d, set, false)
}

// indexFileSet is IndexFileSet; prune also removes every entry of the
// container whose file is not in the set (the set is the whole listing) —
// found by its anchor, so entries keyed another way (attached documents
// before 2026-10-03) go too.
func indexFileSet(ctx context.Context, d *db.DB, set FileSet, prune bool) (docs, changed int, err error) {
	kind, ok := fileSetKinds[set.Source]
	if !ok {
		return 0, 0, fmt.Errorf("kb: %q keeps no file set", set.Source)
	}
	if err := checkSetPaths(set.Files); err != nil {
		return 0, 0, err
	}
	var indexed []string
	if prune {
		indexed, err = queryStrings(ctx, d, `SELECT id FROM kb_documents WHERE source = ? AND json_extract(anchor_json, '$.'||?) = ?`,
			set.Source, kind.containerAnchor, strconv.FormatInt(set.Container, 10))
		if err != nil {
			return 0, 0, fmt.Errorf("kb: listing indexed %s documents: %w", set.Source, err)
		}
	}
	live, keys, rendered := renderFileSet(kind, set) // before the write tx opens
	prepared := prepareBatch(rendered)
	err = withTx(ctx, d, func(tx *sql.Tx) error {
		written, deleted, err := storeBatch(ctx, tx, keys, prepared)
		if err != nil {
			return err
		}
		changed = written + deleted
		if !prune {
			return nil
		}
		pruned, err := pruneUnlistedDocs(ctx, tx, indexed, live)
		changed += pruned
		return err
	})
	if err != nil {
		return 0, 0, err
	}
	return len(live), changed, nil
}

// checkSetPaths refuses a file set naming a path that is not inside its
// folder.
func checkSetPaths(files []string) error {
	for _, rel := range files {
		if !filepath.IsLocal(filepath.FromSlash(rel)) || rel == "." {
			return fmt.Errorf("kb: %q is not a path inside the folder", rel)
		}
	}
	return nil
}

// renderFileSet renders each distinct file of set once, returning the keys
// it covers (live), in listing order (keys) with their renders (rendered).
func renderFileSet(kind fileSetKind, set FileSet) (live map[string]bool, keys []string, rendered []*Doc) {
	live = make(map[string]bool, len(set.Files))
	for _, rel := range set.Files {
		key := kind.containerPrefix(set.Container) + rel
		if live[key] {
			continue
		}
		live[key] = true
		keys = append(keys, key)
		rendered = append(rendered, renderFile(set.Source, kind, set.Container, set.Root, rel))
	}
	return live, keys, rendered
}

// pruneUnlistedDocs deletes every indexed document not in live, returning
// how many were removed.
func pruneUnlistedDocs(ctx context.Context, tx *sql.Tx, indexed []string, live map[string]bool) (int, error) {
	n := 0
	for _, id := range indexed {
		if live[id] {
			continue
		}
		removed, err := deleteDoc(ctx, tx, id)
		if err != nil {
			return n, err
		}
		if removed {
			n++
		}
	}
	return n, nil
}

// docTimesWithPrefix maps every indexed document whose id starts with
// prefix to its indexed time.
func docTimesWithPrefix(ctx context.Context, q Queryer, prefix string) (map[string]float64, error) {
	upper, _ := prefixUpperBound(prefix) // a non-empty ASCII prefix always has one
	rows, err := q.QueryContext(ctx, `SELECT id, COALESCE(doc_time_unix, -1) FROM kb_documents WHERE id >= ? AND id < ?`, prefix, upper)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]float64{}
	for rows.Next() {
		var id string
		var at float64
		if err := rows.Scan(&id, &at); err != nil {
			return nil, err
		}
		out[id] = at
	}
	return out, rows.Err()
}

// needsRender reports whether root/rel must be rendered against its indexed
// time (-1 = not indexed). There is no cursor: a file changes on disk with
// nothing else changing, and an edit can carry an older mtime (cp -p, a
// sync client) — so any difference counts. A file that is gone or now leads
// out of the folder is rendered (the render drops or refuses it); one whose
// stat fails otherwise keeps its indexed text.
func needsRender(root, rel string, indexed float64) bool {
	fi, err := statInside(root, rel)
	switch {
	case errors.Is(err, fs.ErrNotExist), errors.Is(err, errDocOutside):
		return true
	case err != nil:
		return indexed < 0
	}
	return float64(fi.ModTime().Unix()) != indexed
}

// renderFile renders root/rel, or nil when the file is gone. A file that
// cannot be read is indexed by its path; the anchor says why the text is
// missing, so an open does not read as an empty file.
func renderFile(source string, kind fileSetKind, container int64, root, rel string) *Doc {
	doc := &Doc{
		ID:     kind.containerPrefix(container) + rel,
		Source: source,
		Title:  rel,
		Link:   (&url.URL{Scheme: "file", Path: filepath.Join(root, filepath.FromSlash(rel))}).String(),
		Anchor: map[string]string{kind.containerAnchor: strconv.FormatInt(container, 10), "rel_path": rel},
	}
	f, err := readSetFile(root, rel)
	if errors.Is(err, errDocMissing) {
		return nil
	}
	if err != nil {
		doc.Anchor["unreadable"] = err.Error()
		if fi, serr := statInside(root, rel); serr == nil {
			doc.Time = fi.ModTime().UTC() // gates the next pass like a readable file's
		}
		return doc
	}
	doc.Time = f.modTime
	doc.Sections = markdownSections(f.text)
	if f.truncated {
		doc.Anchor["truncated"] = "indexed up to 2 MiB"
	}
	return doc
}

// statInside stats folder/rel after resolveInside.
func statInside(folder, rel string) (fs.FileInfo, error) {
	realFolder, err := filepath.EvalSymlinks(folder)
	if err != nil {
		return nil, err
	}
	path, err := resolveInside(realFolder, rel)
	if err != nil {
		return nil, err
	}
	return os.Stat(path)
}

// resolveInside resolves rel inside realFolder, following symlinks one
// path component at a time and refusing — before touching it — any step
// that would leave the folder. Unlike filepath.EvalSymlinks it never
// stats a path outside the folder, so a link into a location macOS guards
// cannot make the indexer touch it.
func resolveInside(realFolder, rel string) (string, error) {
	parts := strings.Split(filepath.ToSlash(rel), "/")
	cur, hops := realFolder, 0
	for len(parts) > 0 {
		part := parts[0]
		parts = parts[1:]
		if part == "" || part == "." {
			continue
		}
		next := filepath.Join(cur, part)
		if !strictlyInside(realFolder, next) {
			return "", errDocOutside
		}
		fi, err := os.Lstat(next)
		if err != nil {
			return "", err
		}
		if fi.Mode()&fs.ModeSymlink == 0 {
			cur = next
			continue
		}
		if hops++; hops > 40 {
			return "", errors.New("too many symbolic links")
		}
		target, err := os.Readlink(next)
		if err != nil {
			return "", err
		}
		if !filepath.IsAbs(target) {
			target = filepath.Join(cur, target)
		}
		if target = filepath.Clean(target); !strictlyInside(realFolder, target) {
			return "", errDocOutside
		}
		// Resolve the target's own components from the folder again: one of
		// them may be a link too.
		relTarget, err := filepath.Rel(realFolder, target)
		if err != nil {
			return "", errDocOutside
		}
		parts = append(strings.Split(filepath.ToSlash(relTarget), "/"), parts...)
		cur = realFolder
	}
	if cur == realFolder {
		return "", errDocNotRegular
	}
	return cur, nil
}

func strictlyInside(root, path string) bool {
	return strings.HasPrefix(path, root+string(filepath.Separator))
}

type setFile struct {
	text      string
	modTime   time.Time
	truncated bool
}

var (
	errDocMissing    = errors.New("file is missing")
	errDocNotRegular = errors.New("not a regular file")
	errDocOutside    = errors.New("no longer inside the workbench folder")
)

// readSetFile reads a regular file that still resolves (symlinks followed,
// resolveInside) inside folder, capped at fileSetMaxBytes and cut to valid
// UTF-8. The type is checked before the open, and the open never blocks,
// so a named pipe put in a file's place cannot stall the indexer.
func readSetFile(folder, rel string) (setFile, error) {
	realFolder, err := filepath.EvalSymlinks(folder)
	if err != nil {
		return setFile{}, fmt.Errorf("workbench folder: %w", err)
	}
	realPath, err := resolveInside(realFolder, rel)
	if errors.Is(err, fs.ErrNotExist) {
		return setFile{}, errDocMissing
	}
	if err != nil {
		return setFile{}, err
	}
	if fi, err := os.Stat(realPath); err != nil || !fi.Mode().IsRegular() {
		return setFile{}, errDocNotRegular
	}
	f, err := os.OpenFile(realPath, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return setFile{}, err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil || !fi.Mode().IsRegular() {
		return setFile{}, errDocNotRegular
	}
	b, err := io.ReadAll(io.LimitReader(f, fileSetMaxBytes+1))
	if err != nil {
		return setFile{}, err
	}
	out := setFile{modTime: fi.ModTime().UTC(), truncated: len(b) > fileSetMaxBytes}
	if out.truncated {
		b = b[:fileSetMaxBytes]
	}
	for len(b) > 0 && !utf8.Valid(b) {
		b = b[:len(b)-1] // a cap can split a multi-byte rune
	}
	out.text = string(b)
	return out, nil
}

// markdownSections splits text at its #, ## and ### headings (outside fenced
// code); each section's anchor is its heading text, so a hit's chunk_anchor
// names the part of the document it matched. Text before the first heading
// is a section without an anchor.
func markdownSections(text string) []Section {
	var out []Section
	var cur strings.Builder
	anchor, fenced := "", false
	flush := func() {
		if strings.TrimSpace(cur.String()) != "" {
			out = append(out, Section{Text: cur.String(), Anchor: anchor})
		}
		cur.Reset()
	}
	for _, line := range strings.Split(text, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "```") || strings.HasPrefix(trimmed, "~~~") {
			fenced = !fenced
		}
		if h, isHeading := markdownHeading(trimmed); isHeading && !fenced {
			flush()
			anchor = h
		}
		cur.WriteString(line)
		cur.WriteString("\n")
	}
	flush()
	return out
}

// markdownHeading returns the text of a level 1–3 ATX heading line.
func markdownHeading(line string) (string, bool) {
	level := len(line) - len(strings.TrimLeft(line, "#"))
	if level < 1 || level > 3 || len(line) == level || line[level] != ' ' {
		return "", false
	}
	return strings.TrimSpace(line[level:]), true
}
