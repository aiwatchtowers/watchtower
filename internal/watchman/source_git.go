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
	// gitLookback is how far behind the hi mark the incremental pass looks
	// again: a worktree branch merged late brings commits dated before hi,
	// and a PR's merge can be cached after newer ones.
	gitLookback  = 30 * 24 * time.Hour
	gitTextLimit = 2048
	// gitBackfillDone is the lo mark once the backfill has nothing older.
	gitBackfillDone = "end"
)

// GitSource reads the owner's own commits in the workbench folder that
// rewrite paths an agent commit changed in the 7 days before (choice
// "rewrote"), and the workbench's merged PRs (category finish, choice
// "merged"). A folder that is not a git repository yields nothing and is done.
//
// The incremental pass rescans gitLookback behind the hi mark and returns
// what it finds there that the learner has not handled yet — neither stored
// nor marked skipped (db.MarkWatchmanSkippedKeys) — so a late commit or
// merge is not lost and each is offered once.
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

func (it gitItem) pos() gitPos { return gitPos{it.at, it.key} }

type gitPos struct {
	at  time.Time
	key string
}

func (a gitPos) less(b gitPos) bool {
	return a.at.Before(b.at) || a.at.Equal(b.at) && a.key < b.key
}

// Next returns items newer than the cursor's hi mark first (oldest of them
// first), then items older than its lo mark, newest first. The cursor is
// "<hi>|<lo>", each "<unix nanos>,<escaped key>"; lo is "end" once the
// backfill is over.
func (s gitSource) Next(ctx context.Context, d *db.DB, workbenchID int64, cursor string, limit int) ([]db.WatchmanPrecedent, string, bool, error) {
	hi, lo, loDone, has, err := parseGitCursor(cursor)
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
	next := func() string {
		if loDone {
			return encodeGitPos(hi) + "|" + gitBackfillDone
		}
		return encodeGitPos(hi) + "|" + encodeGitPos(lo)
	}
	var out []db.WatchmanPrecedent
	n := 0
	if has {
		floor := hi.at.Add(-gitLookback)
		items, err := s.items(ctx, d, workbenchID, wb.FolderPath, floor)
		if err != nil {
			return nil, "", false, err
		}
		// isLate: at or behind hi, and not left to the backfill still to come.
		isLate := func(it gitItem) bool {
			return !hi.less(it.pos()) && (loDone || lo.less(it.pos()))
		}
		var late []string
		for _, it := range items {
			if isLate(it) {
				late = append(late, it.key)
			}
		}
		known, err := d.WatchmanKnownKeys("git", late)
		if err != nil {
			return nil, "", false, fmt.Errorf("watchman git source: %w", err)
		}
		for _, it := range items {
			if !hi.less(it.pos()) {
				if !isLate(it) || known[it.key] {
					continue
				}
				out = append(out, it.p) // a late find; hi stays
			} else {
				out, hi = append(out, it.p), it.pos()
			}
			if n++; n == limit {
				return out, next(), false, nil
			}
		}
		if loDone {
			return out, next(), true, nil
		}
	}
	items, err := s.items(ctx, d, workbenchID, wb.FolderPath, time.Time{})
	if err != nil {
		return nil, "", false, err
	}
	for i := len(items) - 1; i >= 0; i-- {
		pos := items[i].pos()
		if has && !pos.less(lo) {
			continue
		}
		if !has {
			hi, has = pos, true
		}
		out, lo = append(out, items[i].p), pos
		if n++; n == limit {
			return out, next(), false, nil
		}
	}
	if !has {
		return out, "", true, nil
	}
	loDone = true
	return out, next(), true, nil
}

// items lists the rewrites and merges decided at or after floor (zero =
// all), oldest first.
func (s gitSource) items(ctx context.Context, d *db.DB, workbenchID int64, dir string, floor time.Time) ([]gitItem, error) {
	var since []string
	if !floor.IsZero() {
		since = []string{"--since=" + floor.Add(-gitRewriteWindow).UTC().Format(time.RFC3339)}
	}
	commits, err := s.commits(ctx, dir, since...)
	if err != nil {
		return nil, err
	}
	merges, err := gitMerges(d, workbenchID)
	if err != nil {
		return nil, err
	}
	var items []gitItem
	for _, it := range append(gitRewrites(workbenchID, commits), merges...) {
		if !it.at.Before(floor) {
			items = append(items, it)
		}
	}
	sort.Slice(items, func(i, j int) bool { return items[i].pos().less(items[j].pos()) })
	return items, nil
}

// commits lists the non-merge commits (narrowed by extra log args) with
// their changed paths, oldest author date first. A repository
// with no commit yet has none.
func (s gitSource) commits(ctx context.Context, dir string, extra ...string) ([]gitCommit, error) {
	args := append([]string{"-c", "core.quotePath=false", "log", "--no-merges",
		"--format=%x1e%H%x1f%aI%x1f%B%x1d", "--name-only"}, extra...)
	out, err := s.git(ctx, dir, args...)
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
	sort.SliceStable(commits, func(i, j int) bool { return commits[i].at.Before(commits[j].at) })
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
// before it that changed one of its paths; commits are oldest first.
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
		// commits is sorted by author date: only the 7 days before o.
		from := sort.Search(len(commits), func(i int) bool { return !commits[i].at.Before(o.at.Add(-gitRewriteWindow)) })
		for j := len(commits) - 1; j >= from; j-- { // newest agent subject first
			a := commits[j]
			if !a.agent || !a.at.Before(o.at) {
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

func parseGitCursor(c string) (hi, lo gitPos, loDone, has bool, err error) {
	if c == "" {
		return hi, lo, false, false, nil
	}
	h, l, ok := strings.Cut(c, "|")
	if !ok {
		return hi, lo, false, false, fmt.Errorf("watchman git cursor %q: no lo mark", c)
	}
	if hi, err = parseGitPos(h); err != nil {
		return hi, lo, false, false, fmt.Errorf("watchman git cursor %q: %w", c, err)
	}
	if l == gitBackfillDone {
		return hi, lo, true, true, nil
	}
	if lo, err = parseGitPos(l); err != nil {
		return hi, lo, false, false, fmt.Errorf("watchman git cursor %q: %w", c, err)
	}
	return hi, lo, false, true, nil
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
