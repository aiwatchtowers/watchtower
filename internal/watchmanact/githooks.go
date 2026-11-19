package watchmanact

import (
	"bytes"
	"context"
	"crypto/sha1" // #nosec G505 -- a file name for a path, not a security use
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"text/template"

	"watchtower/internal/fsutil"
)

// Git at the ref (spec 2026-11-16-watchman-design §5 item 1, D30): an armed
// session's worktree gets core.hooksPath — at the worktree level only — set
// to HooksDir, a directory holding a script for every client-side hook
// name. pre-push refuses, while the worktree is armed, a push to
// main/master, a tag push, a deletion and a non-fast-forward push; then,
// armed or not, every script runs the worktree's previous hook of its name,
// so the repository's own hooks keep working. Unarmed is pass-through, so
// the hooks may stay until the worktree goes.
//
// Accepted gaps of this layer (the guard hook and the feature note cover
// them): `git push --no-verify`, a hooks path given on the command line
// (`-c core.hooksPath=…`, GIT_CONFIG_COUNT), `git send-pack`, and pushing
// the branch from the main checkout or another unarmed worktree of the same
// repository. A disarm racing the daemon's upkeep can leave the hooks set on
// a worktree no longer armed: they pass through, so nothing is refused.

// ClientHookNames are the client-side hook names of githooks(5) — every
// hook git runs in a working repository; the server-side ones (pre-receive,
// update, proc-receive, post-receive, post-update) are left out. Pinned
// against the installed git's `git help hooks` by
// TestClientHookNames_CoverInstalledGit.
var ClientHookNames = []string{
	"applypatch-msg", "pre-applypatch", "post-applypatch",
	"pre-commit", "pre-merge-commit", "prepare-commit-msg", "commit-msg", "post-commit",
	"pre-rebase", "post-checkout", "post-merge", "pre-push", "pre-auto-gc", "post-rewrite",
	"sendemail-validate", "post-index-change", "reference-transaction", "push-to-checkout",
	"fsmonitor-watchman",
	"p4-changelist", "p4-prepare-changelist", "p4-post-changelist", "p4-pre-submit",
}

// HooksDir is <workspace>/watchman/hooks, the hooks path of armed worktrees.
func HooksDir(workspace string) string { return filepath.Join(workspace, "watchman", "hooks") }

// hooksPrevDir holds one record per worktree: its previous hooks.
func hooksPrevDir(workspace string) string { return filepath.Join(workspace, "watchman", "hooks-prev") }

// hooksRecord is a worktree's state before Watchman set its hooks path:
// its resolved top level and git dir (the scripts find their record by the
// git dir), the hooks directory its own worktree-level config named
// ("" = none: the scripts read the other config levels when they run, so a
// later retarget of the shared or global hooks path keeps chaining), and
// the direct worktree-level core.hooksPath (nil = unset; what RestoreHooks
// puts back). On disk, `worktree `, `gitdir `, optional `hooks ` and
// optional `value ` lines.
type hooksRecord struct {
	Worktree, GitDir, Hooks string
	Value                   *string
}

func recordPath(workspace, top string) string {
	sum := sha1.Sum([]byte(top)) // #nosec G401 -- a file name, not a security use
	return filepath.Join(hooksPrevDir(workspace), hex.EncodeToString(sum[:]))
}

func (r hooksRecord) encode() ([]byte, error) {
	lines := [][2]string{{"worktree", r.Worktree}, {"gitdir", r.GitDir}}
	if r.Hooks != "" {
		lines = append(lines, [2]string{"hooks", r.Hooks})
	}
	if r.Value != nil {
		lines = append(lines, [2]string{"value", *r.Value})
	}
	var b bytes.Buffer
	for _, l := range lines {
		if strings.ContainsAny(l[1], "\r\n") {
			return nil, fmt.Errorf("the %s path %q has a line break", l[0], l[1])
		}
		fmt.Fprintf(&b, "%s %s\n", l[0], l[1])
	}
	return b.Bytes(), nil
}

// readRecord reads a record; a missing file, or one without its worktree
// and gitdir lines, is an error.
func readRecord(path string) (hooksRecord, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return hooksRecord{}, err
	}
	var r hooksRecord
	for _, line := range strings.Split(string(raw), "\n") {
		key, value, _ := strings.Cut(line, " ")
		switch key {
		case "worktree":
			r.Worktree = value
		case "gitdir":
			r.GitDir = value
		case "hooks":
			r.Hooks = value
		case "value":
			r.Value = &value
		}
	}
	if r.Worktree == "" || r.GitDir == "" {
		return hooksRecord{}, fmt.Errorf("%s is not a hooks record", path)
	}
	return r, nil
}

// lockHooks serialises EnsureHooks and RestoreHooks across processes (the
// `watchman arm|disarm` CLI and the daemon's upkeep).
func lockHooks(ctx context.Context, workspace string) (func(), error) {
	dir := filepath.Join(workspace, "watchman")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("creating %s: %w", dir, err)
	}
	unlock, err := fsutil.LockFile(ctx, filepath.Join(dir, "hooks.lock"))
	if err != nil {
		return nil, fmt.Errorf("locking the watchman hooks: %w", err)
	}
	return unlock, nil
}

// GuardUnsupportedError means the repository's shared config holds core.worktree
// or core.bare = true, which extensions.worktreeConfig would make wrong for
// its other worktrees, so Watchman installs no git guard there.
type GuardUnsupportedError struct{ Repo string }

func (e *GuardUnsupportedError) Error() string {
	return "Watchman's git guard cannot be installed in " + e.Repo + ": shared core.worktree/core.bare — the other layers still apply"
}

// CheckGuardLayout reads, without writing, whether the git guard can be
// installed in folder's repository: a *GuardUnsupportedError when the
// shared config has core.worktree or core.bare = true.
func CheckGuardLayout(ctx context.Context, folder string) error {
	top, err := WorktreeRoot(ctx, folder)
	if err != nil {
		return err
	}
	return checkLayout(ctx, top)
}

func checkLayout(ctx context.Context, top string) error {
	_, worktreeSet, err := gitConfigGet(ctx, top, "--local", "core.worktree")
	if err != nil {
		return err
	}
	bare, _, err := gitConfigGet(ctx, top, "--local", "--type=bool", "core.bare")
	if err != nil {
		return err
	}
	if !worktreeSet && bare != "true" {
		return nil
	}
	common, err := runGit(ctx, top, "rev-parse", "--path-format=absolute", "--git-common-dir")
	if err != nil {
		return fmt.Errorf("reading the git common dir: %w", err)
	}
	repo := filepath.Clean(strings.TrimSpace(string(common)))
	if filepath.Base(repo) == ".git" {
		repo = filepath.Dir(repo)
	}
	return &GuardUnsupportedError{Repo: repo}
}

// EnsureHooks makes the worktree run Watchman's hooks. It refuses a
// repository whose shared layout the worktree config would break
// (*GuardUnsupportedError), (re)writes the hook scripts whose content
// differs, enables extensions.worktreeConfig, and — unless the worktree's
// own core.hooksPath is HooksDir already — records the worktree's previous
// hooks and sets core.hooksPath with `git config --worktree` (never the
// shared config). Calling it again changes nothing. An owner's later
// change of the worktree value while armed is taken as the new previous
// value and the hooks path is set again (the layer holds while armed);
// RestoreHooks gives the owner's value back at disarm.
func EnsureHooks(ctx context.Context, worktree, workspace string) error {
	unlock, err := lockHooks(ctx, workspace)
	if err != nil {
		return err
	}
	defer unlock()
	top, err := WorktreeRoot(ctx, worktree)
	if err != nil {
		return err
	}
	if err := checkLayout(ctx, top); err != nil {
		return err
	}
	if err := writeHookScripts(workspace); err != nil {
		return err
	}
	if err := enableWorktreeConfig(ctx, top); err != nil {
		return err
	}
	gitDir, err := absGitDir(ctx, top)
	if err != nil {
		return err
	}
	own := HooksDir(workspace)
	cur, set, err := gitConfigGet(ctx, top, "--worktree", "core.hooksPath")
	if err != nil {
		return err
	}
	rec := recordPath(workspace, top)
	if set && filepath.Clean(cur) == own {
		if _, err := readRecord(rec); err == nil {
			return nil
		}
		// The record went missing: the scripts fall back to the other
		// config levels, as for a worktree that had no value of its own.
		return writeRecord(rec, hooksRecord{Worktree: top, GitDir: gitDir})
	}
	r := hooksRecord{Worktree: top, GitDir: gitDir}
	if set {
		v := cur
		r.Value = &v
	}
	// The worktree level's effective value, includes followed.
	eff, effSet, err := gitConfigGet(ctx, top, "--worktree", "--includes", "--type=path", "core.hooksPath")
	if err != nil {
		return err
	}
	if abs := absHooks(top, eff); effSet && abs != own {
		r.Hooks = abs
	}
	if err := writeRecord(rec, r); err != nil {
		return err
	}
	if _, err := runGit(ctx, top, "config", "--worktree", "core.hooksPath", own); err != nil {
		return fmt.Errorf("setting the worktree's core.hooksPath: %w", err)
	}
	return nil
}

// ErrHooksRecordUnreadable means RestoreHooks found Watchman's hooks path but
// not the record of what was there before, so it left the hooks in place
// (they pass through while the worktree is not armed).
var ErrHooksRecordUnreadable = errors.New("the record of the worktree's previous hooks cannot be read; the Watchman hooks stay (they pass through while not armed)")

// RestoreHooks puts back the worktree's previous core.hooksPath (or unsets
// it) only while the worktree's value is still HooksDir, so an owner's later
// change is never overwritten, and drops the record. A record that cannot
// be read leaves the hooks and returns ErrHooksRecordUnreadable for the
// caller to log.
func RestoreHooks(ctx context.Context, worktree, workspace string) error {
	unlock, err := lockHooks(ctx, workspace)
	if err != nil {
		return err
	}
	defer unlock()
	top, err := WorktreeRoot(ctx, worktree)
	if err != nil {
		return err
	}
	rec := recordPath(workspace, top)
	// Without the extension `--worktree` would reach the shared config,
	// and Watchman never set anything there.
	on, _, err := gitConfigGet(ctx, top, "--type=bool", "extensions.worktreeConfig")
	if err != nil {
		return err
	}
	if on != "true" {
		return removeRecord(rec)
	}
	cur, set, err := gitConfigGet(ctx, top, "--worktree", "core.hooksPath")
	if err != nil {
		return err
	}
	if !set || filepath.Clean(cur) != HooksDir(workspace) {
		return removeRecord(rec)
	}
	r, err := readRecord(rec)
	if err != nil {
		return fmt.Errorf("%s: %w (%v)", top, ErrHooksRecordUnreadable, err)
	}
	if r.Value != nil {
		_, err = runGit(ctx, top, "config", "--worktree", "core.hooksPath", *r.Value)
	} else {
		_, err = runGit(ctx, top, "config", "--worktree", "--unset", "core.hooksPath")
	}
	if err != nil {
		return fmt.Errorf("restoring the worktree's core.hooksPath: %w", err)
	}
	return removeRecord(rec)
}

func writeRecord(path string, r hooksRecord) error {
	data, err := r.encode()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("creating %s: %w", filepath.Dir(path), err)
	}
	if err := fsutil.WriteFileAtomic(path, data, 0o644); err != nil {
		return fmt.Errorf("writing the hooks record: %w", err)
	}
	return nil
}

func removeRecord(path string) error {
	if err := os.Remove(path); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("removing the hooks record: %w", err)
	}
	return nil
}

// WorktreeRoot is the canonical top level of the git worktree holding
// folder (symlinks resolved): the key the hooks are installed and restored
// under, so two paths to one worktree are one worktree.
func WorktreeRoot(ctx context.Context, folder string) (string, error) {
	out, err := runGit(ctx, folder, "rev-parse", "--show-toplevel")
	if err != nil {
		return "", fmt.Errorf("%s is not a git worktree: %w", folder, err)
	}
	top, err := filepath.EvalSymlinks(strings.TrimSpace(string(out)))
	if err != nil {
		return "", fmt.Errorf("resolving the worktree %s: %w", folder, err)
	}
	return top, nil
}

// absGitDir is the worktree's git dir, absolute with symlinks resolved —
// what the scripts compute with `git rev-parse --absolute-git-dir` and
// `pwd -P`.
func absGitDir(ctx context.Context, top string) (string, error) {
	out, err := runGit(ctx, top, "rev-parse", "--absolute-git-dir")
	if err != nil {
		return "", fmt.Errorf("reading the git dir of %s: %w", top, err)
	}
	dir, err := filepath.EvalSymlinks(strings.TrimSpace(string(out)))
	if err != nil {
		return "", fmt.Errorf("resolving the git dir of %s: %w", top, err)
	}
	return dir, nil
}

// enableWorktreeConfig turns extensions.worktreeConfig on (repository-wide;
// harmless on git ≥ 2.20) unless it already is.
func enableWorktreeConfig(ctx context.Context, top string) error {
	on, _, err := gitConfigGet(ctx, top, "--type=bool", "extensions.worktreeConfig")
	if err != nil || on == "true" {
		return err
	}
	if _, err := runGit(ctx, top, "config", "extensions.worktreeConfig", "true"); err != nil {
		return fmt.Errorf("enabling extensions.worktreeConfig: %w", err)
	}
	return nil
}

// absHooks makes a hooks path absolute: a relative core.hooksPath is
// relative to where hooks run, the worktree's top level.
func absHooks(top, p string) string {
	if filepath.IsAbs(p) {
		return filepath.Clean(p)
	}
	return filepath.Join(top, p)
}

// gitConfigGet reads one value; set is false when the key is not set
// (git config's exit code 1).
func gitConfigGet(ctx context.Context, dir string, args ...string) (value string, set bool, err error) {
	out, err := runGit(ctx, dir, append([]string{"config", "--get"}, args...)...)
	if isExit(err, 1) {
		return "", false, nil
	}
	if err != nil {
		return "", false, fmt.Errorf("git config --get %s: %w", strings.Join(args, " "), err)
	}
	return strings.TrimRight(string(out), "\n"), true, nil
}

func isExit(err error, code int) bool {
	var ee *exec.ExitError
	return errors.As(err, &ee) && ee.ExitCode() == code
}

// runGit runs git -C dir args… and returns its stdout; a failure carries
// git's stderr.
func runGit(ctx context.Context, dir string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, "git", append([]string{"-C", dir}, args...)...) // #nosec G204 -- fixed binary, explicit args
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		if msg := strings.TrimSpace(stderr.String()); msg != "" {
			return out, fmt.Errorf("%w: %s", err, msg)
		}
		return out, err
	}
	return out, nil
}

// writeHookScripts writes every ClientHookNames script into HooksDir,
// rewriting only those whose content differs.
func writeHookScripts(workspace string) error {
	dir := HooksDir(workspace)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("creating %s: %w", dir, err)
	}
	for _, name := range ClientHookNames {
		script, err := hookScript(workspace, name)
		if err != nil {
			return err
		}
		path := filepath.Join(dir, name)
		if old, err := os.ReadFile(path); err == nil && bytes.Equal(old, script) {
			if st, err := os.Stat(path); err == nil && st.Mode().Perm()&0o111 == 0o111 {
				continue
			}
		}
		if err := fsutil.WriteFileAtomic(path, script, 0o755); err != nil {
			return fmt.Errorf("writing the %s hook: %w", name, err)
		}
	}
	return nil
}

// shQuote single-quotes s for POSIX sh.
func shQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

func hookScript(workspace, name string) ([]byte, error) {
	var b bytes.Buffer
	err := hookTemplate.Execute(&b, map[string]string{
		"Name":    name,
		"Records": shQuote(hooksPrevDir(workspace)),
		"Self":    shQuote(HooksDir(workspace)),
		"Sidecar": shQuote(SidecarPath(workspace)),
	})
	if err != nil {
		return nil, fmt.Errorf("rendering the %s hook: %w", name, err)
	}
	return b.Bytes(), nil
}

// hookTemplate is every hook script. The prelude finds the previous hooks
// directory: the worktree level's own value from its record (matched by
// the git dir), else what the other config levels say now — a relative
// path against the work tree's root (push-to-checkout runs in $GIT_DIR with
// GIT_WORK_TREE set) — else <common dir>/hooks; never its own directory.
var hookTemplate = template.Must(template.New("hook").Parse(`#!/bin/sh
# Watchman's {{.Name}} hook, written by watchtower (spec 2026-11-16-watchman-design §5).
# It runs this worktree's previous {{.Name}} hook{{if eq .Name "pre-push"}} after refusing, while the
# session is handed to Watchman, a push to main/master, a tag push, a deletion and a
# non-fast-forward push{{end}}. Do not edit: it is rewritten.
wm_records={{.Records}}
wm_self={{.Self}}
{{- if eq .Name "push-to-checkout"}}
wm_top=$(cd "${GIT_WORK_TREE:-.}" 2>/dev/null && pwd -P)
{{- else}}
wm_top=$(pwd -P)
{{- end}}
wm_gitdir=$(git rev-parse --absolute-git-dir 2>/dev/null) && wm_gitdir=$(cd "$wm_gitdir" 2>/dev/null && pwd -P) || wm_gitdir=
wm_prev=
for wm_f in "$wm_records"/*; do
	[ -n "$wm_gitdir" ] && [ -f "$wm_f" ] || continue
	wm_gd= wm_h=
	while IFS= read -r wm_l || [ -n "$wm_l" ]; do
		case $wm_l in
		"gitdir "*) wm_gd=${wm_l#gitdir } ;;
		"hooks "*) wm_h=${wm_l#hooks } ;;
		esac
	done < "$wm_f"
	if [ "$wm_gd" = "$wm_gitdir" ]; then
		wm_prev=$wm_h
		break
	fi
done
if [ -z "$wm_prev" ]; then
	wm_tab=$(printf '\t')
	wm_prev=$(git config --show-scope --type=path --get-all core.hooksPath 2>/dev/null |
		while IFS="$wm_tab" read -r wm_s wm_v; do
			[ "$wm_s" = worktree ] || printf '%s\n' "$wm_v"
		done | tail -n 1)
	case $wm_prev in
	"") wm_c=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && wm_prev=$wm_c/hooks ;;
	/*) ;;
	*) wm_prev=$wm_top/$wm_prev ;;
	esac
fi
if [ -n "$wm_prev" ] && [ "$(cd "$wm_prev" 2>/dev/null && pwd -P)" = "$(cd "$wm_self" 2>/dev/null && pwd -P)" ]; then
	wm_prev= # never back into this directory
fi
wm_hook=$wm_prev/{{.Name}}
[ -n "$wm_prev" ] && [ -f "$wm_hook" ] && [ -x "$wm_hook" ] || wm_hook=
{{- if eq .Name "pre-push"}}
wm_sidecar={{.Sidecar}}
wm_in=$(mktemp "${TMPDIR:-/tmp}/watchman-pre-push.XXXXXX") || exit 1
trap 'rm -f "$wm_in"' EXIT
cat > "$wm_in"
# Armed: a sidecar worktree has this push's git dir (whatever the cwd or
# --work-tree). Cannot tell: refuse what an armed session may not push.
wm_armed=
if [ -e "$wm_sidecar" ] && [ ! -r "$wm_sidecar" ]; then
	wm_armed=1
elif [ -e "$wm_sidecar" ]; then
	while IFS= read -r wm_l || [ -n "$wm_l" ]; do
		case $wm_l in
		"worktree "*)
			if [ -z "$wm_gitdir" ]; then
				wm_armed=1
				break
			fi
			wm_wgd=$(unset $(git rev-parse --local-env-vars); cd "${wm_l#worktree }" 2>/dev/null && git rev-parse --absolute-git-dir 2>/dev/null) || continue
			wm_wgd=$(cd "$wm_wgd" 2>/dev/null && pwd -P) || continue
			if [ "$wm_wgd" = "$wm_gitdir" ]; then
				wm_armed=1
				break
			fi
			;;
		esac
	done < "$wm_sidecar"
fi
if [ -n "$wm_armed" ]; then
	while read -r wm_lref wm_lsha wm_rref wm_rsha; do
		[ -n "$wm_rref" ] || continue
		wm_why=
		case $wm_rref in
		refs/heads/main | refs/heads/master) wm_why="a push to ${wm_rref#refs/heads/}" ;;
		refs/tags/*) wm_why="a tag push ($wm_rref)" ;;
		esac
		if [ -z "$wm_why" ]; then
			case $wm_lsha in
			*[!0]*) ;;
			*) wm_why="deleting $wm_rref" ;;
			esac
		fi
		if [ -z "$wm_why" ]; then
			case $wm_rsha in
			*[!0]*) git merge-base --is-ancestor "$wm_rsha" "$wm_lsha" 2>/dev/null || wm_why="a non-fast-forward push to $wm_rref" ;;
			esac
		fi
		if [ -n "$wm_why" ]; then
			echo "Parked for the owner: $wm_why. This session is handed to Watchman; continue with other work." >&2
			exit 1
		fi
	done < "$wm_in"
fi
[ -n "$wm_hook" ] || exit 0
"$wm_hook" "$@" < "$wm_in"
exit $?
{{- else if eq .Name "push-to-checkout"}}
[ -z "$wm_hook" ] || exec "$wm_hook" "$@"
# No previous hook: what git does without one — refuse a dirty worktree,
# else check the pushed commit out (from the empty tree on an unborn HEAD).
if git rev-parse -q --verify HEAD > /dev/null; then
	wm_head=HEAD
else
	wm_head=$(git hash-object -t tree /dev/null) || exit 1
fi
git update-index -q --ignore-submodules --refresh
git diff-files --quiet --ignore-submodules -- || { echo "Working directory has unstaged changes" >&2; exit 1; }
git diff-index --quiet --cached --ignore-submodules "$wm_head" -- || { echo "Working directory has staged changes" >&2; exit 1; }
exec git read-tree -u -m "$wm_head" "$1"
{{- else}}
[ -z "$wm_hook" ] || exec "$wm_hook" "$@"
exit 0
{{- end}}
`))
