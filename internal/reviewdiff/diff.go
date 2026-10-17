package reviewdiff

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strconv"
	"strings"
)

type Diff struct {
	Files     []File `json:"files"`
	Truncated bool   `json:"truncated"`
}

type File struct {
	Path            string `json:"path"`
	OldPath         string `json:"old_path,omitempty"`
	Status          string `json:"status"` // added|modified|deleted|renamed
	Additions       int    `json:"additions"`
	Deletions       int    `json:"deletions"`
	Binary          bool   `json:"binary"`
	CollapsedReason string `json:"collapsed_reason,omitempty"` // lockfile|generated|too_large
	NewBlob         string `json:"new_blob"`                   // the new side's blob id; "" for a deleted file
	NewMode         string `json:"new_mode"`                   // the new side's mode; "" for a deleted file
	OldMode         string `json:"old_mode,omitempty"`         // the old side's mode; "" for an added file
	Hunks           []Hunk `json:"hunks"`

	typeChange bool // name-status T: the patch holds a deletion and a creation section
}

type Hunk struct {
	ID       string   `json:"hunk_id"`
	Header   string   `json:"header"`
	OldStart int      `json:"old_start"`
	OldLines int      `json:"old_lines"`
	NewStart int      `json:"new_start"`
	NewLines int      `json:"new_lines"`
	Lines    []string `json:"lines"` // each with its ' ', '+' or '-' prefix
}

// Diff lists from → to: paths, statuses, new-side blobs and modes from
// `diff-tree -z --raw` (NUL-separated, so any path is exact), hunks from `diff-tree -p` matched
// to the files in the same order git emits both. The patch call keeps the
// subcommand first so gitbin blanks the folder's filter drivers; its quoted
// "diff --git" headers are only used to cut sections.
func (r *Repo) Diff(ctx context.Context, from, to string) (Diff, error) {
	raw, err := r.git(ctx, nil, "diff-tree", "-r", "-M", "-z", "--raw", "--no-abbrev", "--no-commit-id", from, to)
	if err != nil {
		return Diff{}, err
	}
	files := parseRaw(raw)
	patch, err := r.git(ctx, nil, "diff-tree", "-r", "-M", "-p",
		"--no-commit-id", "--no-color", "--no-ext-diff", "--no-textconv", "--full-index", from, to)
	if err != nil {
		return Diff{}, err
	}
	sections, err := splitSections(patch, maxPatchLine)
	if err != nil {
		return Diff{}, fmt.Errorf("diff-tree patch: %w", err)
	}
	want := 0
	for _, f := range files {
		want++
		if f.typeChange {
			want++
		}
	}
	if len(sections) != want {
		return Diff{}, fmt.Errorf("diff-tree: %d patch sections for %d files, want %d", len(sections), len(files), want)
	}
	d := Diff{Files: files}
	total, next := 0, 0
	for i := range d.Files {
		f := &d.Files[i]
		f.CollapsedReason = collapsedReason(f.Path)
		parseSection(f, sections[next])
		next++
		if f.typeChange { // a file turned symlink (or back): git patches it as delete + create
			parseSection(f, sections[next])
			next++
		}
		changed := f.Additions + f.Deletions
		switch {
		case changed > MaxFileChangedLines:
			f.CollapsedReason, f.Hunks = "too_large", nil
		case total+changed > MaxTotalLines:
			d.Truncated, f.Hunks = true, nil
		}
		total += changed
	}
	return d, nil
}

// parseRaw reads `diff-tree -z --raw` records: ":<old mode> <new mode>
// <old sha> <new sha> <status>" NUL path NUL (a rename or copy: old path NUL
// new path NUL).
func parseRaw(b []byte) []File {
	fields := strings.Split(strings.TrimSuffix(string(b), "\x00"), "\x00")
	var files []File
	for i := 0; i < len(fields); {
		meta := strings.Fields(strings.TrimPrefix(fields[i], ":"))
		if len(meta) != 5 || meta[4] == "" {
			break
		}
		f := File{}
		if mode, blob := meta[1], meta[3]; strings.Trim(blob, "0") != "" {
			f.NewMode, f.NewBlob = mode, blob
		}
		if strings.Trim(meta[2], "0") != "" {
			f.OldMode = meta[0]
		}
		st := meta[4][0]
		if st == 'R' || st == 'C' {
			if i+2 >= len(fields) {
				return files
			}
			f.Status, f.OldPath, f.Path = "renamed", fields[i+1], fields[i+2]
			files = append(files, f)
			i += 3
			continue
		}
		if i+1 >= len(fields) {
			return files
		}
		f.Path = fields[i+1]
		switch st {
		case 'A':
			f.Status = "added"
		case 'D':
			f.Status = "deleted"
		default: // M, T
			f.Status, f.typeChange = "modified", st == 'T'
		}
		files = append(files, f)
		i += 2
	}
	return files
}

// maxPatchLine is the longest patch line splitSections accepts.
const maxPatchLine = 64 << 20

// splitSections cuts the patch at each "diff --git " line.
func splitSections(patch []byte, maxLine int) ([][]string, error) {
	var out [][]string
	sc := bufio.NewScanner(bytes.NewReader(patch))
	sc.Buffer(make([]byte, 0, min(64<<10, maxLine)), maxLine)
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, "diff --git ") {
			out = append(out, nil)
		}
		if len(out) > 0 {
			out[len(out)-1] = append(out[len(out)-1], line)
		}
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	return out, nil
}

func parseSection(f *File, lines []string) {
	var cur *Hunk
	flush := func() {
		if cur != nil {
			cur.ID = hunkID(f.Path, *cur)
			f.Hunks = append(f.Hunks, *cur)
			cur = nil
		}
	}
	for _, l := range lines {
		switch {
		case strings.HasPrefix(l, "Binary files ") || strings.HasPrefix(l, "GIT binary patch"):
			f.Binary = true
		case strings.HasPrefix(l, "@@ "):
			flush()
			h := Hunk{Header: l}
			h.OldStart, h.OldLines, h.NewStart, h.NewLines = parseRange(l)
			cur = &h
		case cur != nil:
			addHunkLine(f, cur, l)
		}
	}
	flush()
}

// addHunkLine appends one body line to the open hunk and counts it.
func addHunkLine(f *File, cur *Hunk, l string) {
	switch {
	case l == "":
		cur.Lines = append(cur.Lines, " ") // diff.suppressBlankEmpty prints a blank context line bare
	case strings.HasPrefix(l, "+") || strings.HasPrefix(l, "-") || strings.HasPrefix(l, " "):
		cur.Lines = append(cur.Lines, l)
		if l[0] == '+' {
			f.Additions++
		} else if l[0] == '-' {
			f.Deletions++
		}
	case strings.HasPrefix(l, `\ `):
		cur.Lines = append(cur.Lines, l) // "\ No newline at end of file"
	}
}

// parseRange reads "@@ -a,b +c,d @@" (",b"/",d" default to 1).
func parseRange(h string) (os, ol, ns, nl int) {
	parts := strings.Fields(h)
	if len(parts) < 3 {
		return
	}
	os, ol = span(strings.TrimPrefix(parts[1], "-"))
	ns, nl = span(strings.TrimPrefix(parts[2], "+"))
	return
}

func span(s string) (start, n int) {
	a, b, ok := strings.Cut(s, ",")
	start, _ = strconv.Atoi(a)
	n = 1
	if ok {
		n, _ = strconv.Atoi(b)
	}
	return
}

func hunkID(path string, h Hunk) string {
	sum := sha256.New()
	fmt.Fprintf(sum, "%s\n%s\n%s", path, h.Header, strings.Join(h.Lines, "\n"))
	return hex.EncodeToString(sum.Sum(nil))[:16]
}
