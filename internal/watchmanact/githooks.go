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
// the worktree's resolved top level, the hooks directory git used (what the
// scripts proxy to) and the worktree-level core.hooksPath (nil = unset;
// what RestoreHooks puts back). On disk, one `worktree `, `hooks ` and
// optional `value ` line each.
type hooksRecord struct {
	Worktree, Hooks string
	Value           *string
}

func recordPath(workspace, top string) string {
	sum := sha1.Sum([]byte(top)) // #nosec G401 -- a file name, not a security use
	return filepath.Join(hooksPrevDir(workspace), hex.EncodeToString(sum[:]))
}

func (r hooksRecord) encode() ([]byte, error) {
	var b bytes.Buffer
	for _, l := range [][2]string{{"worktree", r.Worktree}, {"hooks", r.Hooks}} {
		if strings.ContainsAny(l[1], "\r\n") {
			return nil, fmt.Errorf("the %s path %q has a line break", l[0], l[1])
		}
		fmt.Fprintf(&b, "%s %s\n", l[0], l[1])
	}
	if r.Value != nil {
		if strings.ContainsAny(*r.Value, "\r\n") {
			return nil, fmt.Errorf("the hooks path %q has a line break", *r.Value)
		}
		fmt.Fprintf(&b, "value %s\n", *r.Value)
	}
	return b.Bytes(), nil
}

// readRecord reads a record; a missing file, or one without its worktree
// and hooks lines, is an error.
func readRecord(path string) (hooksRecord, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return hooksRecord{}, err
	}
	var r hooksRecord
	for _, line := range strings.Split(string(raw), "\n") {
		switch {
		case strings.HasPrefix(line, "worktree "):
			r.Worktree = strings.TrimPrefix(line, "worktree ")
		case strings.HasPrefix(line, "hooks "):
			r.Hooks = strings.TrimPrefix(line, "hooks ")
		case strings.HasPrefix(line, "value "):
			v := strings.TrimPrefix(line, "value ")
			r.Value = &v
		}
	}
	if r.Worktree == "" || r.Hooks == "" {
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

// EnsureHooks makes the worktree run Watchman's hooks. It (re)writes the
// hook scripts when their content differs, enables extensions.worktreeConfig,
// and — unless the worktree's own core.hooksPath is HooksDir already —
// records the worktree's previous hooks and sets core.hooksPath with
// `git config --worktree` (never the shared config). Calling it again
// changes nothing. An owner's later change of the worktree value is
// recorded as the new previous value and the hooks path is set again: the
// layer holds while the session is armed.
func EnsureHooks(ctx context.Context, worktree, workspace string) error {
	unlock, err := lockHooks(ctx, workspace)
	if err != nil {
		return err
	}
	defer unlock()
	if err := writeHookScripts(workspace); err != nil {
		return err
	}
	top, err := toplevel(ctx, worktree)
	if err != nil {
		return err
	}
	if err := enableWorktreeConfig(ctx, top); err != nil {
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
		// The record went missing: what git used before is now what the
		// other config levels say.
		hooks, err := hooksBelowWorktree(ctx, top, own)
		if err != nil {
			return err
		}
		return writeRecord(rec, hooksRecord{Worktree: top, Hooks: hooks})
	}
	r := hooksRecord{Worktree: top}
	if set {
		v := cur
		r.Value = &v
		resolved, _, err := gitConfigGet(ctx, top, "--worktree", "--type=path", "core.hooksPath")
		if err != nil {
			return err
		}
		r.Hooks = absHooks(top, resolved)
		if filepath.Clean(r.Hooks) == own {
			if r.Hooks, err = hooksBelowWorktree(ctx, top, own); err != nil {
				return err
			}
		}
	} else if r.Hooks, err = hooksBelowWorktree(ctx, top, own); err != nil {
		return err
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
	top, err := toplevel(ctx, worktree)
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

// toplevel is the worktree's top level with symlinks resolved — what
// `pwd -P` says inside a hook, so the scripts find their record.
func toplevel(ctx context.Context, worktree string) (string, error) {
	out, err := runGit(ctx, worktree, "rev-parse", "--show-toplevel")
	if err != nil {
		return "", fmt.Errorf("%s is not a git worktree: %w", worktree, err)
	}
	top, err := filepath.EvalSymlinks(strings.TrimSpace(string(out)))
	if err != nil {
		return "", fmt.Errorf("resolving the worktree %s: %w", worktree, err)
	}
	return top, nil
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

// hooksBelowWorktree is the hooks directory git uses for the worktree when
// its worktree-level value is left out: the last core.hooksPath of the
// other config levels, else <common dir>/hooks. HooksDir itself never
// counts (the scripts must not proxy to themselves).
func hooksBelowWorktree(ctx context.Context, top, own string) (string, error) {
	out, err := runGit(ctx, top, "config", "--show-scope", "--type=path", "--get-all", "core.hooksPath")
	if err != nil && !isExit(err, 1) {
		return "", fmt.Errorf("reading core.hooksPath: %w", err)
	}
	hooks := ""
	for _, line := range strings.Split(strings.TrimRight(string(out), "\n"), "\n") {
		scope, value, ok := strings.Cut(line, "\t")
		if !ok || scope == "worktree" || value == "" {
			continue
		}
		if abs := absHooks(top, value); filepath.Clean(abs) != own {
			hooks = abs
		}
	}
	if hooks != "" {
		return hooks, nil
	}
	common, err := runGit(ctx, top, "rev-parse", "--path-format=absolute", "--git-common-dir")
	if err != nil {
		return "", fmt.Errorf("reading the git common dir: %w", err)
	}
	return filepath.Join(strings.TrimSpace(string(common)), "hooks"), nil
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

// hookTemplate is every hook script. The prelude finds the worktree's
// previous hooks directory: its record (matched by the top level — a hook
// runs there, push-to-checkout runs in $GIT_DIR with GIT_WORK_TREE set),
// else what the config levels below the worktree say, else
// <common dir>/hooks. Builtins only on the common path: reference-transaction
// and post-index-change run on most git commands.
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
wm_prev=
for wm_f in "$wm_records"/*; do
	[ -f "$wm_f" ] || continue
	wm_wt= wm_h=
	while IFS= read -r wm_l || [ -n "$wm_l" ]; do
		case $wm_l in
		"worktree "*) wm_wt=${wm_l#worktree } ;;
		"hooks "*) wm_h=${wm_l#hooks } ;;
		esac
	done < "$wm_f"
	if [ -n "$wm_top" ] && [ "$wm_wt" = "$wm_top" ]; then
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
	[ -n "$wm_prev" ] || wm_prev=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/hooks
fi
case $wm_prev in
"$wm_self" | "$wm_self"/) wm_prev= ;;
esac
wm_hook=$wm_prev/{{.Name}}
[ -n "$wm_prev" ] && [ -f "$wm_hook" ] && [ -x "$wm_hook" ] || wm_hook=
{{- if eq .Name "pre-push"}}
wm_sidecar={{.Sidecar}}
wm_in=$(mktemp "${TMPDIR:-/tmp}/watchman-pre-push.XXXXXX") || exit 1
trap 'rm -f "$wm_in"' EXIT
cat > "$wm_in"
wm_armed=
if [ -e "$wm_sidecar" ] && [ ! -r "$wm_sidecar" ]; then
	wm_armed=1 # cannot tell: refuse what an armed session may not push
elif [ -e "$wm_sidecar" ]; then
	while IFS= read -r wm_l || [ -n "$wm_l" ]; do
		case $wm_l in
		"worktree "*)
			wm_wt=$(unset $(git rev-parse --local-env-vars); cd "${wm_l#worktree }" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || continue
			wm_wt=$(cd "$wm_wt" 2>/dev/null && pwd -P) || continue
			if [ "$wm_wt" = "$wm_top" ]; then
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
# else check the pushed commit out.
git update-index -q --ignore-submodules --refresh
git diff-files --quiet --ignore-submodules -- || { echo "Working directory has unstaged changes" >&2; exit 1; }
git diff-index --quiet --cached --ignore-submodules HEAD -- || { echo "Working directory has staged changes" >&2; exit 1; }
exec git read-tree -u -m HEAD "$1"
{{- else}}
[ -z "$wm_hook" ] || exec "$wm_hook" "$@"
exit 0
{{- end}}
`))
