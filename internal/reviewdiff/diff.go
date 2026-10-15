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
	Hunks           []Hunk `json:"hunks"`
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

// Diff lists from → to: paths and statuses from `diff-tree -z --name-status`
// (NUL-separated, so any path is exact), hunks from `diff-tree -p` matched
// to the files in the same order git emits both. The patch call keeps the
// subcommand first so gitbin blanks the folder's filter drivers; its quoted
// "diff --git" headers are only used to cut sections.
func (r *Repo) Diff(ctx context.Context, from, to string) (Diff, error) {
	names, err := r.git(ctx, nil, "diff-tree", "-r", "-M", "-z", "--name-status", "--no-commit-id", from, to)
	if err != nil {
		return Diff{}, err
	}
	files := parseNameStatus(names)
	patch, err := r.git(ctx, nil, "diff-tree", "-r", "-M", "-p",
		"--no-commit-id", "--no-color", "--no-ext-diff", "--no-textconv", "--full-index", from, to)
	if err != nil {
		return Diff{}, err
	}
	sections := splitSections(patch)
	if len(sections) != len(files) {
		return Diff{}, fmt.Errorf("diff-tree: %d files but %d patch sections", len(files), len(sections))
	}
	d := Diff{Files: files}
	total := 0
	for i := range d.Files {
		f := &d.Files[i]
		f.CollapsedReason = collapsedReason(f.Path)
		parseSection(f, sections[i])
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

func parseNameStatus(b []byte) []File {
	fields := strings.Split(strings.TrimSuffix(string(b), "\x00"), "\x00")
	var files []File
	for i := 0; i < len(fields); {
		st := fields[i]
		if st == "" {
			break
		}
		switch st[0] {
		case 'R', 'C':
			if i+2 >= len(fields) {
				return files
			}
			files = append(files, File{Status: "renamed", OldPath: fields[i+1], Path: fields[i+2]})
			i += 3
			continue
		}
		if i+1 >= len(fields) {
			return files
		}
		switch st[0] {
		case 'A':
			files = append(files, File{Status: "added", Path: fields[i+1]})
		case 'D':
			files = append(files, File{Status: "deleted", Path: fields[i+1]})
		default: // M, T
			files = append(files, File{Status: "modified", Path: fields[i+1]})
		}
		i += 2
	}
	return files
}

// splitSections cuts the patch at each "diff --git " line.
func splitSections(patch []byte) [][]string {
	var out [][]string
	sc := bufio.NewScanner(bytes.NewReader(patch))
	sc.Buffer(make([]byte, 1<<20), 64<<20)
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, "diff --git ") {
			out = append(out, nil)
		}
		if len(out) > 0 {
			out[len(out)-1] = append(out[len(out)-1], line)
		}
	}
	return out
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
		case cur != nil && (strings.HasPrefix(l, "+") || strings.HasPrefix(l, "-") || strings.HasPrefix(l, " ")):
			cur.Lines = append(cur.Lines, l)
			if l[0] == '+' {
				f.Additions++
			} else if l[0] == '-' {
				f.Deletions++
			}
		case cur != nil && strings.HasPrefix(l, `\ `):
			cur.Lines = append(cur.Lines, l) // "\ No newline at end of file"
		}
	}
	flush()
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
