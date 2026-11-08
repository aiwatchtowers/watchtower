package reviewdiff

import (
	"bytes"
	"context"
	"fmt"
	"strconv"
	"strings"
)

// commitMark starts every line git renders from our --format, so a
// subject line is never left out and a CommitFiles header never reads as a
// path.
const commitMark = "\x01"

// Commit is one commit of a first-parent walk: its id, its parents in
// order (the first parent first) and its subject line.
type Commit struct {
	SHA     string
	Parents []string
	Subject string
}

// FirstParentWalk lists tip's first-parent history, newest first, minus
// every commit reachable from exclude (`rev-list --first-parent --parents`).
// limit > 0 caps the number of commits. Read-only (REVIEW-01/05).
func (r *Repo) FirstParentWalk(ctx context.Context, tip string, exclude []string, limit int) ([]Commit, error) {
	revs, err := walkRevs(tip, exclude)
	if err != nil {
		return nil, err
	}
	args := []string{"rev-list", "--first-parent", "--parents", "--format=" + commitMark + "%s"}
	if limit > 0 {
		args = append(args, "--max-count="+strconv.Itoa(limit))
	}
	out, err := r.git(ctx, nil, append(args, revs...)...)
	if ctxErr := ctx.Err(); ctxErr != nil {
		return nil, ctxErr
	}
	if err != nil {
		return nil, err
	}
	return parseWalk(out)
}

// parseWalk reads rev-list's `commit <sha> <parents…>` header followed by
// one subject line; the line starts with commitMark because git leaves out
// a format line that renders empty (%s never holds a newline).
func parseWalk(out []byte) ([]Commit, error) {
	lines := strings.Split(strings.TrimSuffix(string(out), "\n"), "\n")
	if len(lines) == 1 && lines[0] == "" {
		return nil, nil
	}
	if len(lines)%2 != 0 {
		return nil, fmt.Errorf("rev-list: %d lines, want header and subject pairs", len(lines))
	}
	commits := make([]Commit, 0, len(lines)/2)
	for i := 0; i < len(lines); i += 2 {
		fields := strings.Fields(lines[i])
		if len(fields) < 2 || fields[0] != "commit" {
			return nil, fmt.Errorf("rev-list: line %d is not a commit header", i+1)
		}
		subject, ok := strings.CutPrefix(lines[i+1], commitMark)
		if !ok {
			return nil, fmt.Errorf("rev-list: line %d is not a subject", i+2)
		}
		c := Commit{SHA: fields[1], Subject: subject}
		if len(fields) > 2 {
			c.Parents = fields[2:]
		}
		commits = append(commits, c)
	}
	return commits, nil
}

// CommitFiles maps each non-merge commit of tip's first-parent history,
// minus exclude's, to the paths it changes (`log --first-parent --no-merges
// --no-renames --name-only -z`, one call for the whole walk). Paths come
// NUL-separated, so spaces, quotes and non-ASCII letters arrive as they
// are. limit > 0 caps the number of commits. A commit that changes no file
// maps to nil.
func (r *Repo) CommitFiles(ctx context.Context, tip string, exclude []string, limit int) (map[string][]string, error) {
	revs, err := walkRevs(tip, exclude)
	if err != nil {
		return nil, err
	}
	args := []string{"log", "--first-parent", "--no-merges", "--no-renames", "--name-only", "-z",
		"--format=" + commitMark + "%H"}
	if limit > 0 {
		args = append(args, "--max-count="+strconv.Itoa(limit))
	}
	out, err := r.git(ctx, nil, append(args, revs...)...)
	if ctxErr := ctx.Err(); ctxErr != nil {
		return nil, ctxErr
	}
	if err != nil {
		return nil, err
	}
	return parseCommitFiles(out)
}

// parseCommitFiles reads `\x01<sha>\0` headers, each followed by its paths
// as NUL-terminated tokens, the first one prefixed with a newline.
func parseCommitFiles(out []byte) (map[string][]string, error) {
	files := map[string][]string{}
	current := ""
	first := false
	for tok := range bytes.SplitSeq(out, []byte{0}) {
		s := string(tok)
		if sha, ok := strings.CutPrefix(s, commitMark); ok && isHex(sha) {
			current, first = sha, true
			files[current] = nil
			continue
		}
		if first {
			s, first = strings.TrimPrefix(s, "\n"), false
		}
		if s == "" {
			continue
		}
		if current == "" {
			return nil, fmt.Errorf("log: a path before any commit header")
		}
		files[current] = append(files[current], s)
	}
	return files, nil
}

// IsAncestor reports whether commit a is an ancestor of (or equal to) b
// (`merge-base --is-ancestor`: exit 0 yes, exit 1 no). An unknown commit
// or a done context is an error.
func (r *Repo) IsAncestor(ctx context.Context, a, b string) (bool, error) {
	if !isRevision(a) || !isRevision(b) {
		return false, fmt.Errorf("is-ancestor: invalid revision")
	}
	_, err := r.git(ctx, nil, "merge-base", "--is-ancestor", a, b)
	if ctxErr := ctx.Err(); ctxErr != nil {
		return false, ctxErr
	}
	if saidNo(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, nil
}

// walkRevs is tip and ^exclude as revision arguments; a revision that is
// empty or reads as an option is refused.
func walkRevs(tip string, exclude []string) ([]string, error) {
	if !isRevision(tip) {
		return nil, fmt.Errorf("walk: invalid tip revision")
	}
	revs := []string{tip}
	for _, e := range exclude {
		if !isRevision(e) {
			return nil, fmt.Errorf("walk: invalid excluded revision")
		}
		revs = append(revs, "^"+e)
	}
	return revs, nil
}

func isRevision(s string) bool {
	return s != "" && !strings.HasPrefix(s, "-")
}

func isHex(s string) bool {
	if len(s) != 40 && len(s) != 64 {
		return false
	}
	for _, c := range s {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}
