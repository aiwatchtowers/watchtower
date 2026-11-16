package sessioncleanup

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// headEntry is one entry of a worktree's HEAD log: its new sha, its time,
// and the branch names it mentions — both sides of a `checkout: moving from
// <a> to <b>`, any `refs/heads/<name>` of another move's message
// (`rebase (finish): returning to refs/heads/<name>`), and for the
// log's first entry, which `git worktree add` writes with no message, the
// branch the worktree started on (the <a> of its first checkout, else its
// current branch).
type headEntry struct {
	sha   string
	at    time.Time
	names []string
}

// headLog is a worktree's HEAD log. candidates are the §2c candidates it
// gives: the <a> and <b> of its checkout entries. bad counts the lines that
// did not parse.
type headLog struct {
	entries    []headEntry
	candidates []string
	bad        int
}

// headLogBranches is source §2c of the auto cleanup spec (2026-11-10): the
// branches created in the session's worktree wt in the same step that
// switched to it (`git worktree add -b`, `git checkout -b`, `git switch
// -c`). The candidates are the <a> and <b> of every `checkout: moving from
// <a> to <b>` entry of wt's own HEAD log (`git rev-parse --git-path
// logs/HEAD` in it) and wt's current branch. A candidate is named when its
// own ref log's first entry (`branch: Created from …`) has the same new sha
// as one entry of wt's HEAD log and lies within one second of it (git
// writes both in one command). switchedTo are the candidates that fail
// that: only checked out in wt — the default branch, the owner's branch,
// another session's, a branch made with `git branch` and switched to later
// — kept as not_this_session. A named branch that appears in another
// worktree's HEAD log at or after its creation — the main worktree's log
// included, read only for this — is moved to switchedTo as well.
//
// A prunable wt (its folder gone) has its log read from its admin dir. wt
// without a HEAD log names nothing (found false); wt's log that exists
// but cannot be read is err (the plan fails). unknown is true when the
// exclusion cannot be checked — another worktree's HEAD log missing,
// unreadable or with a line that does not parse, its admin dir unknown, or
// a candidate's ref log unreadable: the caller keeps the named candidates
// as created_unknown. The other logs are found from the repository's admin
// dirs (<common>/worktrees/<name>/logs/HEAD, the main one
// <common>/logs/HEAD) — the file `rev-parse --git-path` names, without a
// git run per worktree.
func headLogBranches(ctx context.Context, r *repoState, wt worktree) (named, switchedTo map[string]bool, found,
	unknown bool, err error) {
	named, switchedTo = map[string]bool{}, map[string]bool{}
	var path string
	if wt.Prunable {
		admin, ok := r.adminDirs[wt.Root]
		if !ok {
			return named, switchedTo, false, false, nil // no admin dir: no HEAD log
		}
		path = filepath.Join(admin, "logs", "HEAD")
	} else {
		out, err := r.git.output(ctx, wt.Root, "rev-parse", "--git-path", "logs/HEAD")
		if err != nil {
			return nil, nil, false, false, fmt.Errorf("locating the HEAD log of %s: %w", wt.Root, err)
		}
		path = absFrom(wt.Root, strings.TrimSpace(string(out)))
	}
	own, found, err := readHeadLog(path, wt.Branch)
	if err != nil || !found {
		return named, switchedTo, false, false, err
	}
	created := map[string]headEntry{}
	for _, c := range append(append([]string(nil), own.candidates...), wt.Branch) {
		if _, ok := r.branchTip(c); !ok || named[c] || created[c].sha != "" || switchedTo[c] {
			continue
		}
		birth, ok, err := branchCreation(r.commonDir, c)
		switch {
		case err != nil:
			unknown, named[c] = true, true // undecided: the caller keeps it as created_unknown
		case ok && enteredAtBirth(own.entries, birth):
			created[c] = birth
		default:
			switchedTo[c] = true
		}
	}
	if len(created) == 0 {
		return named, switchedTo, true, unknown, nil
	}
	for _, o := range r.worktrees {
		if o.Root == wt.Root || o.Bare {
			continue
		}
		var path string
		if o.Main {
			path = filepath.Join(r.commonDir, "logs", "HEAD")
		} else if admin, ok := r.adminDirs[o.Root]; ok {
			path = filepath.Join(admin, "logs", "HEAD")
		} else {
			unknown = true
			continue
		}
		log, ok, err := readHeadLog(path, o.Branch)
		if err != nil || !ok || log.bad > 0 {
			unknown = true
			continue
		}
		for c, birth := range created {
			if mentionedSince(log.entries, c, birth.at) {
				delete(created, c)
				switchedTo[c] = true
			}
		}
	}
	for c := range created {
		named[c] = true
	}
	return named, switchedTo, true, unknown, nil
}

// enteredAtBirth: an entry of entries has the new sha of the branch's
// creation and lies within one second of it.
func enteredAtBirth(entries []headEntry, birth headEntry) bool {
	for _, e := range entries {
		d := e.at.Sub(birth.at)
		if e.sha == birth.sha && d <= time.Second && d >= -time.Second {
			return true
		}
	}
	return false
}

// mentionedSince: an entry of entries at or after since names c.
func mentionedSince(entries []headEntry, c string, since time.Time) bool {
	for _, e := range entries {
		if e.at.Before(since) {
			continue
		}
		for _, n := range e.names {
			if n == c {
				return true
			}
		}
	}
	return false
}

// readHeadLog reads the HEAD log at path of a worktree whose current
// branch is current; found is false when there is none.
func readHeadLog(path, current string) (log headLog, found bool, err error) {
	f, err := os.Open(path)
	if errors.Is(err, fs.ErrNotExist) {
		return log, false, nil
	}
	if err != nil {
		return log, false, fmt.Errorf("reading the HEAD log %s: %w", path, err)
	}
	defer f.Close()
	first := -1 // index of the creation entry, while its branch is open
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 1<<20)
	for n := 0; sc.Scan(); n++ {
		old, sha, at, msg, ok := parseReflogLine(sc.Text())
		if !ok {
			log.bad++
			continue
		}
		e := headEntry{sha: sha, at: at}
		if n == 0 && strings.Trim(old, "0") == "" {
			first = len(log.entries)
		}
		if rest, ok := strings.CutPrefix(msg, "checkout: moving from "); ok {
			if from, to, ok := strings.Cut(rest, " to "); ok && !strings.ContainsRune(from, ' ') &&
				!strings.ContainsRune(to, ' ') {
				e.names = []string{from, to}
				log.candidates = append(log.candidates, from, to)
				if first >= 0 {
					log.entries[first].names = []string{from}
					first = -1
				}
			}
		} else {
			e.names = refNames(msg)
		}
		log.entries = append(log.entries, e)
	}
	if err := sc.Err(); err != nil {
		return headLog{}, false, fmt.Errorf("reading the HEAD log %s: %w", path, err)
	}
	if first >= 0 {
		log.entries[first].names = append(log.entries[first].names, current)
	}
	return log, true, nil
}

// refNames are the branches a reflog message names by full ref
// (`rebase (finish): returning to refs/heads/<name>`): that worktree had the
// branch checked out. A bare word is not counted: `merge feat/x` in the
// main worktree merges a session's branch, it does not use it there.
func refNames(msg string) []string {
	var out []string
	for _, w := range strings.Fields(msg) {
		if name, ok := strings.CutPrefix(strings.TrimRight(w, ":,;"), "refs/heads/"); ok && name != "" {
			out = append(out, name)
		}
	}
	return out
}

// branchCreation is the first entry of branch name's ref log when it is
// the branch's creation (`branch: Created from …`); ok false when the ref
// log is missing or its first entry is no creation. err is a ref log that
// exists but cannot be read.
func branchCreation(commonDir, name string) (headEntry, bool, error) {
	f, err := os.Open(filepath.Join(commonDir, "logs", "refs", "heads", filepath.FromSlash(name)))
	if errors.Is(err, fs.ErrNotExist) {
		return headEntry{}, false, nil
	}
	if err != nil {
		return headEntry{}, false, fmt.Errorf("reading the ref log of %s: %w", name, err)
	}
	defer f.Close()
	line, err := bufio.NewReader(f).ReadString('\n')
	if err != nil && line == "" {
		if errors.Is(err, io.EOF) {
			return headEntry{}, false, nil
		}
		return headEntry{}, false, fmt.Errorf("reading the ref log of %s: %w", name, err)
	}
	_, sha, at, msg, ok := parseReflogLine(line)
	if !ok || !strings.HasPrefix(msg, "branch: Created from ") {
		return headEntry{}, false, nil
	}
	return headEntry{sha: sha, at: at}, true, nil
}

// parseReflogLine reads "<old> <new> <name> <email> <unix> <tz>\t<msg>".
func parseReflogLine(line string) (old, sha string, at time.Time, msg string, ok bool) {
	head, msg, _ := strings.Cut(strings.TrimRight(line, "\n"), "\t")
	f := strings.Fields(head)
	if len(f) < 4 {
		return "", "", time.Time{}, "", false
	}
	sec, err := strconv.ParseInt(f[len(f)-2], 10, 64)
	if err != nil {
		return "", "", time.Time{}, "", false
	}
	return f[0], f[1], time.Unix(sec, 0), msg, true
}
