package watchman

import (
	"context"
	"fmt"
	"net/url"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/db"
)

// GitRunner runs git with args in dir and returns its stdout.
type GitRunner func(ctx context.Context, dir string, args ...string) ([]byte, error)

// ExecGit is the production GitRunner: git -C dir args…, no shell.
func ExecGit(ctx context.Context, dir string, args ...string) ([]byte, error) {
	return exec.CommandContext(ctx, "git", append([]string{"-C", dir}, args...)...).Output() // #nosec G204 -- fixed binary, explicit args
}

const (
	// gitRewriteWindow is how far back an agent commit counts as the work an
	// owner commit rewrote.
	gitRewriteWindow = 7 * 24 * time.Hour
	gitTextLimit     = 2048
)

// GitSource reads the owner's own commits in the workbench folder that
// rewrite paths an agent commit changed in the 7 days before (choice
// "rewrote"), and the workbench's merged PRs (category finish, choice
// "merged"). A folder that is not a git repository yields nothing and is done.
func GitSource(git GitRunner) Source { return gitSource{git: git} }

type gitSource struct{ git GitRunner }

func (gitSource) Name() string { return "git" }

type gitCommit struct {
	hash    string
	at      time.Time
	subject string
	agent   bool
	paths   []string
}

type gitItem struct {
	at  time.Time
	key string
	p   db.WatchmanPrecedent
}

type gitPos struct {
	at  time.Time
	key string
}

func (a gitPos) less(b gitPos) bool {
	return a.at.Before(b.at) || a.at.Equal(b.at) && a.key < b.key
}

// Next returns items newer than the cursor's hi mark first (oldest of them
// first), then items older than its lo mark, newest first. The cursor is
// "<unix nanos>,<escaped key>|<unix nanos>,<escaped key>".
func (s gitSource) Next(ctx context.Context, d *db.DB, workbenchID int64, cursor string, limit int) ([]db.WatchmanPrecedent, string, bool, error) {
	hi, lo, has, err := parseGitCursor(cursor)
	if err != nil {
		return nil, "", false, err
	}
	if limit <= 0 {
		return nil, cursor, false, nil
	}
	wb, err := d.GetWorkbench(workbenchID)
	if err != nil {
		return nil, "", false, fmt.Errorf("watchman git source: %w", err)
	}
	if wb.FolderPath == "" {
		return nil, cursor, true, nil
	}
	if out, err := s.git(ctx, wb.FolderPath, "rev-parse", "--is-inside-work-tree"); err != nil || strings.TrimSpace(string(out)) != "true" {
		if cerr := ctx.Err(); cerr != nil {
			return nil, "", false, cerr
		}
		return nil, cursor, true, nil // not a git repository: nothing to learn here
	}
	commits, err := s.commits(ctx, wb.FolderPath)
	if err != nil {
		return nil, "", false, err
	}
	items := gitRewrites(workbenchID, commits)
	merges, err := gitMerges(d, workbenchID)
	if err != nil {
		return nil, "", false, err
	}
	items = append(items, merges...)
	sort.Slice(items, func(i, j int) bool {
		return gitPos{items[i].at, items[i].key}.less(gitPos{items[j].at, items[j].key})
	})

	var out []db.WatchmanPrecedent
	next := func() string { return encodeGitPos(hi) + "|" + encodeGitPos(lo) }
	if has {
		for _, it := range items {
			pos := gitPos{it.at, it.key}
			if !hi.less(pos) {
				continue
			}
			out, hi = append(out, it.p), pos
			if len(out) == limit {
				return out, next(), false, nil
			}
		}
	}
	for i := len(items) - 1; i >= 0; i-- {
		pos := gitPos{items[i].at, items[i].key}
		if has && !pos.less(lo) {
			continue
		}
		if !has {
			hi, has = pos, true
		}
		out, lo = append(out, items[i].p), pos
		if len(out) == limit {
			return out, next(), false, nil
		}
	}
	if !has {
		return out, "", true, nil
	}
	return out, next(), true, nil
}

// commits lists every non-merge commit with its changed paths. A repository
// with no commit yet has none.
func (s gitSource) commits(ctx context.Context, dir string) ([]gitCommit, error) {
	out, err := s.git(ctx, dir, "-c", "core.quotePath=false", "log", "--no-merges",
		"--format=%x1e%H%x1f%aI%x1f%B%x1d", "--name-only")
	if err != nil {
		if _, herr := s.git(ctx, dir, "rev-parse", "--verify", "-q", "HEAD"); herr != nil {
			return nil, nil //nolint:nilerr // no commit yet
		}
		return nil, fmt.Errorf("watchman git log: %w", err)
	}
	var commits []gitCommit
	for _, rec := range strings.Split(string(out), "\x1e") {
		if strings.TrimSpace(rec) == "" {
			continue
		}
		f := strings.SplitN(rec, "\x1f", 3)
		if len(f) != 3 {
			continue
		}
		at, err := time.Parse(time.RFC3339, strings.TrimSpace(f[1]))
		if err != nil {
			continue
		}
		body, names, _ := strings.Cut(f[2], "\x1d")
		c := gitCommit{hash: strings.TrimSpace(f[0]), at: at, agent: isAgentCommit(body)}
		c.subject, _, _ = strings.Cut(strings.TrimSpace(body), "\n")
		for _, n := range strings.Split(names, "\n") {
			if n = strings.TrimSpace(n); n != "" {
				c.paths = append(c.paths, n)
			}
		}
		commits = append(commits, c)
	}
	return commits, nil
}

// isAgentCommit reports whether a commit body has a Co-Authored-By trailer
// (any case) naming Claude, Codex, Anthropic's noreply address or OpenAI.
func isAgentCommit(body string) bool {
	for _, l := range strings.Split(body, "\n") {
		l = strings.ToLower(strings.TrimSpace(l))
		if !strings.HasPrefix(l, "co-authored-by:") {
			continue
		}
		for _, w := range []string{"claude", "codex", "noreply@anthropic.com", "openai"} {
			if strings.Contains(l, w) {
				return true
			}
		}
	}
	return false
}

// gitRewrites pairs each owner commit with the agent commits of the 7 days
// before it that changed one of its paths.
func gitRewrites(workbenchID int64, commits []gitCommit) []gitItem {
	var items []gitItem
	for _, o := range commits {
		if o.agent {
			continue
		}
		own := map[string]bool{}
		for _, p := range o.paths {
			own[p] = true
		}
		var subjects []string
		seenSubject := map[string]bool{}
		shared := map[string]bool{}
		for _, a := range commits { // newest first, as git log lists them
			if !a.agent || !a.at.Before(o.at) || o.at.Sub(a.at) > gitRewriteWindow {
				continue
			}
			hit := false
			for _, p := range a.paths {
				if own[p] {
					shared[p], hit = true, true
				}
			}
			if hit && !seenSubject[a.subject] {
				seenSubject[a.subject] = true
				subjects = append(subjects, a.subject)
			}
		}
		if len(shared) == 0 {
			continue
		}
		paths := make([]string, 0, len(shared))
		for p := range shared {
			paths = append(paths, p)
		}
		sort.Strings(paths)
		category := "tests"
		for _, p := range paths {
			if !isTestPath(p) {
				category = ""
				break
			}
		}
		var b strings.Builder
		b.WriteString("Agent commits:\n")
		for _, sj := range subjects {
			b.WriteString("- " + sj + "\n")
		}
		b.WriteString("Paths:\n")
		for _, p := range paths {
			b.WriteString("- " + p + "\n")
		}
		key := "commit:" + o.hash
		items = append(items, gitItem{at: o.at, key: key, p: db.WatchmanPrecedent{
			WorkbenchID: workbenchID,
			Source:      "git",
			SourceKey:   key,
			Category:    category,
			Situation:   Clip(Redact(strings.TrimSpace(b.String())), gitTextLimit),
			Choice:      "rewrote",
			OwnerWords:  Clip(Redact(o.subject), gitTextLimit),
			DecidedAt:   o.at,
			Weight:      1,
		}})
	}
	return items
}

func isTestPath(p string) bool {
	return strings.HasSuffix(p, "_test.go") || strings.Contains("/"+p, "/Tests/")
}

// gitMerges turns the workbench's cached merged PRs into finish precedents;
// a branch ref whose PR is also cached under its number counts once.
func gitMerges(d *db.DB, workbenchID int64) ([]gitItem, error) {
	states, err := d.PRStates(workbenchID)
	if err != nil {
		return nil, fmt.Errorf("watchman git source: %w", err)
	}
	seen := map[string]bool{}
	var items []gitItem
	for ref, st := range states {
		if st.MergedAt == "" {
			continue
		}
		at, err := time.Parse(time.RFC3339, st.MergedAt)
		if err != nil {
			continue
		}
		key := "merge:" + ref
		situation := st.Title
		if st.PRNumber.Valid {
			key = "merge:pr:" + strconv.FormatInt(st.PRNumber.Int64, 10)
			situation = fmt.Sprintf("PR #%d: %s", st.PRNumber.Int64, st.Title)
		}
		if seen[key] {
			continue
		}
		seen[key] = true
		items = append(items, gitItem{at: at, key: key, p: db.WatchmanPrecedent{
			WorkbenchID: workbenchID,
			Source:      "git",
			SourceKey:   key,
			Category:    "finish",
			Situation:   Clip(Redact(situation), gitTextLimit),
			Choice:      "merged",
			DecidedAt:   at,
			Weight:      1,
		}})
	}
	return items, nil
}

func encodeGitPos(p gitPos) string {
	return strconv.FormatInt(p.at.UnixNano(), 10) + "," + url.QueryEscape(p.key)
}

func parseGitCursor(c string) (hi, lo gitPos, has bool, err error) {
	if c == "" {
		return hi, lo, false, nil
	}
	h, l, ok := strings.Cut(c, "|")
	if !ok {
		return hi, lo, false, fmt.Errorf("watchman git cursor %q: no lo mark", c)
	}
	if hi, err = parseGitPos(h); err != nil {
		return hi, lo, false, fmt.Errorf("watchman git cursor %q: %w", c, err)
	}
	if lo, err = parseGitPos(l); err != nil {
		return hi, lo, false, fmt.Errorf("watchman git cursor %q: %w", c, err)
	}
	return hi, lo, true, nil
}

func parseGitPos(s string) (gitPos, error) {
	a, b, ok := strings.Cut(s, ",")
	if !ok {
		return gitPos{}, fmt.Errorf("mark %q is not <nanos>,<key>", s)
	}
	n, err := strconv.ParseInt(a, 10, 64)
	if err != nil {
		return gitPos{}, fmt.Errorf("mark %q: %w", s, err)
	}
	key, err := url.QueryUnescape(b)
	if err != nil {
		return gitPos{}, fmt.Errorf("mark %q: %w", s, err)
	}
	return gitPos{at: time.Unix(0, n), key: key}, nil
}
