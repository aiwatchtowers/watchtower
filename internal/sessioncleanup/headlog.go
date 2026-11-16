package sessioncleanup

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// headSwitch is one move of a worktree's HEAD onto a branch, read from its
// HEAD log: a `checkout: moving from <a> to <b>` entry (onto b), or the
// log's first entry, which `git worktree add` writes with no message (onto
// the branch the worktree started on: the <a> of its first checkout, else
// its current branch).
type headSwitch struct {
	branch, sha string
	at          time.Time
}

// headLog is a worktree's HEAD log as switches, plus every name its
// checkout entries mention (the from and to sides).
type headLog struct {
	switches []headSwitch
	names    []string
}

// headLogBranches is source §2c of the auto cleanup spec (2026-11-10): the
// branches created in the session's worktree wt in the same step that
// switched to them (`git worktree add -b`, `git checkout -b`, `git switch
// -c`). The candidates are the names wt's own HEAD log (`git rev-parse
// --git-path logs/HEAD` in it) moves from or to and wt's current branch; a
// candidate is named when its own ref log's first entry (`branch: Created
// from …`) has the new sha of a switch onto it in wt's log within one
// second (git writes both in one command). switchedTo are the candidates
// that fail that: only switched to in wt (the default branch, the owner's
// branch, another session's), kept as not_this_session. A named branch that
// another worktree's HEAD log — the main worktree's included, read only
// for this — switched onto at or after its creation is moved to
// switchedTo as well.
//
// wt without a HEAD log names nothing; wt's log that exists but cannot be
// read is err (the plan fails). Another worktree's unreadable log makes
// unknown true: the caller keeps every named candidate of the repository
// as created_unknown. Those logs are found from the repository's admin
// dirs (<common>/worktrees/<name>/logs/HEAD, the main one
// <common>/logs/HEAD) — the file `rev-parse --git-path` names, without a
// git run per worktree.
func headLogBranches(ctx context.Context, r *repoState, wt worktree) (named, switchedTo map[string]bool, unknown bool,
	err error) {
	named, switchedTo = map[string]bool{}, map[string]bool{}
	out, err := r.git.output(ctx, wt.Root, "rev-parse", "--git-path", "logs/HEAD")
	if err != nil {
		return nil, nil, false, fmt.Errorf("locating the HEAD log of %s: %w", wt.Root, err)
	}
	own, found, err := readHeadLog(absFrom(wt.Root, strings.TrimSpace(string(out))), wt.Branch)
	if err != nil {
		return nil, nil, false, err
	}
	if !found {
		return named, switchedTo, false, nil
	}
	candidates := append(append([]string(nil), own.names...), wt.Branch)
	created := map[string]headSwitch{}
	for _, c := range candidates {
		if _, ok := r.branchTip(c); !ok || created[c].sha != "" || switchedTo[c] {
			continue
		}
		birth, ok := branchCreation(r.commonDir, c)
		if ok && switchedOnAtBirth(own.switches, c, birth) {
			created[c] = birth
		} else {
			switchedTo[c] = true
		}
	}
	if len(created) == 0 {
		return named, switchedTo, false, nil
	}
	for _, o := range r.worktrees {
		if o.Root == wt.Root || o.Bare {
			continue
		}
		path := filepath.Join(r.commonDir, "logs", "HEAD")
		if !o.Main {
			admin, ok := r.adminDirs[o.Root]
			if !ok {
				unknown = true
				continue
			}
			path = filepath.Join(admin, "logs", "HEAD")
		}
		log, _, err := readHeadLog(path, o.Branch)
		if err != nil {
			unknown = true
			continue
		}
		for c, birth := range created {
			if switchedOnSince(log.switches, c, birth.at) {
				delete(created, c)
				switchedTo[c] = true
			}
		}
	}
	for c := range created {
		named[c] = true
	}
	return named, switchedTo, unknown, nil
}

// switchedOnAtBirth: a switch of switches onto c has the new sha of c's
// creation and lies within one second of it.
func switchedOnAtBirth(switches []headSwitch, c string, birth headSwitch) bool {
	for _, s := range switches {
		d := s.at.Sub(birth.at)
		if s.branch == c && s.sha == birth.sha && d <= time.Second && d >= -time.Second {
			return true
		}
	}
	return false
}

// switchedOnSince: a switch of switches onto c at or after since.
func switchedOnSince(switches []headSwitch, c string, since time.Time) bool {
	for _, s := range switches {
		if s.branch == c && !s.at.Before(since) {
			return true
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
	var first *headSwitch
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 1<<20)
	for n := 0; sc.Scan(); n++ {
		old, sha, at, msg, ok := parseReflogLine(sc.Text())
		if !ok {
			continue
		}
		if n == 0 && strings.Trim(old, "0") == "" {
			first = &headSwitch{sha: sha, at: at}
			continue
		}
		rest, ok := strings.CutPrefix(msg, "checkout: moving from ")
		if !ok {
			continue
		}
		from, to, ok := strings.Cut(rest, " to ")
		if !ok || strings.ContainsRune(from, ' ') || strings.ContainsRune(to, ' ') {
			continue
		}
		if first != nil && first.branch == "" {
			first.branch = from
		}
		log.names = append(log.names, from, to)
		log.switches = append(log.switches, headSwitch{branch: to, sha: sha, at: at})
	}
	if err := sc.Err(); err != nil {
		return headLog{}, false, fmt.Errorf("reading the HEAD log %s: %w", path, err)
	}
	if first != nil {
		if first.branch == "" {
			first.branch = current
		}
		log.switches = append(log.switches, *first)
	}
	return log, true, nil
}

// branchCreation is the first entry of branch name's ref log when it is
// the branch's creation (`branch: Created from …`).
func branchCreation(commonDir, name string) (headSwitch, bool) {
	f, err := os.Open(filepath.Join(commonDir, "logs", "refs", "heads", filepath.FromSlash(name)))
	if err != nil {
		return headSwitch{}, false
	}
	defer f.Close()
	line, err := bufio.NewReader(f).ReadString('\n')
	if err != nil && line == "" {
		return headSwitch{}, false
	}
	_, sha, at, msg, ok := parseReflogLine(line)
	if !ok || !strings.HasPrefix(msg, "branch: Created from ") {
		return headSwitch{}, false
	}
	return headSwitch{branch: name, sha: sha, at: at}, true
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
