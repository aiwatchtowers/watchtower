// Package gitcmdparse reads a shell command an agent ran and names the git
// worktrees and branches it asked git to create. It is pure string work: no
// git, no file system, no environment.
//
// Words are split the way sh would (quotes, backslashes, comments, here-docs),
// but nothing is expanded: a word holding `$` or a backtick, a leading
// unquoted `~` or an unquoted glob character is "tainted", and a git command
// with a tainted word records nothing. A `cd` to a tainted, relative-to-home
// or unknown place makes the directory unknown, and commands in an unknown
// directory record nothing until a `cd` to an absolute path.
//
// Edge-case rules:
//   - `git worktree add [opts] <path> [<commit-ish>]` records the worktree,
//     with the -b/-B branch when given. Without -b/-B Branch is "" (git's
//     basename-of-path convenience branch is not guessed).
//   - `git branch <name> [<start>]` records <name>. `-c/-C/--copy [<old>] <new>`
//     creates a branch and records <new>. `-f/--force` without a copy moves
//     an existing branch and records nothing; so do every list, delete,
//     rename and upstream mode.
//   - `git checkout -b/-B/--orphan <name>` and `git switch -c/-C/--create/
//     --force-create/--orphan <name>` record <name>. A remote-tracking DWIM
//     checkout (`git checkout -t origin/x`, `git switch x`) records nothing.
//   - `git --git-dir/--work-tree` and a `GIT_*=` assignment before git record
//     nothing: the repository is not the directory.
//   - `pushd`/`popd` make the directory unknown; a `( … )` subshell restores
//     the directory it started in.
//   - Text that does not lex (an unterminated quote, substitution or
//     here-doc, a redirection without a target) records nothing at all.
package gitcmdparse

import (
	"path"
	"strings"
)

// Kinds of Created.
const (
	KindWorktree = "worktree"
	KindBranch   = "branch"
)

// Created is one worktree or branch a command asked git to create.
type Created struct {
	Kind   string // KindWorktree or KindBranch
	Path   string // worktree only: absolute, cleaned, resolved against Dir
	Branch string // may be "" for a worktree without -b/-B
	Dir    string // the effective directory the git command ran in (absolute)
}

// Parse returns what command, run in the absolute directory cwd, asked git to
// create. It returns nil for a relative cwd or a command it cannot read.
func Parse(command, cwd string) []Created {
	if !path.IsAbs(cwd) {
		return nil
	}
	toks, ok := lex(command)
	if !ok {
		return nil
	}
	p := &walker{dir: path.Clean(cwd)}
	var seg []token
	for _, t := range toks {
		if t.kind == tokWord {
			seg = append(seg, t)
			continue
		}
		p.segment(seg)
		seg = nil
		switch t.text {
		case "(":
			p.stack = append(p.stack, p.dir)
		case ")":
			if n := len(p.stack); n > 0 {
				p.dir = p.stack[n-1]
				p.stack = p.stack[:n-1]
			}
		}
	}
	p.segment(seg)
	return p.out
}

// walker carries the effective directory across the segments of a command.
// dir == "" means unknown.
type walker struct {
	dir   string
	stack []string
	out   []Created
}

// leadingWords may precede a command without changing what it runs.
var leadingWords = map[string]bool{
	"!": true, "{": true, "if": true, "then": true, "else": true, "elif": true,
	"do": true, "while": true, "until": true, "time": true, "command": true,
}

func (w *walker) segment(words []token) {
	for len(words) > 0 {
		t := words[0]
		if leadingWords[t.text] {
			words = words[1:]
			continue
		}
		if name, ok := assignmentName(t.text); ok {
			if strings.HasPrefix(name, "GIT_") {
				return
			}
			words = words[1:]
			continue
		}
		break
	}
	if len(words) == 0 || words[0].tainted {
		return
	}
	cmd, args := words[0].text, words[1:]
	switch {
	case cmd == "cd":
		w.dir = cdTarget(args, w.dir)
	case cmd == "pushd" || cmd == "popd":
		w.dir = ""
	case path.Base(cmd) == "git":
		plain := make([]string, len(args))
		for i, a := range args {
			if a.tainted {
				return
			}
			plain[i] = a.text
		}
		w.out = append(w.out, parseGit(plain, w.dir)...)
	}
}

// assignmentName reports whether word is NAME=value and returns NAME.
func assignmentName(word string) (string, bool) {
	name, _, found := strings.Cut(word, "=")
	if !found || name == "" {
		return "", false
	}
	for i := 0; i < len(name); i++ {
		c := name[i]
		letter := c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
		if !letter && (i == 0 || c < '0' || c > '9') {
			return "", false
		}
	}
	return name, true
}

func cdTarget(args []token, dir string) string {
	for len(args) > 0 && !args[0].tainted && len(args[0].text) > 1 && args[0].text[0] == '-' {
		done := args[0].text == "--"
		args = args[1:]
		if done {
			break
		}
	}
	if len(args) != 1 || args[0].tainted || args[0].text == "" || args[0].text == "-" {
		return ""
	}
	return resolve(dir, args[0].text)
}

// resolve returns p against dir, cleaned; "" when p is relative and dir unknown.
func resolve(dir, p string) string {
	if path.IsAbs(p) {
		return path.Clean(p)
	}
	if dir == "" {
		return ""
	}
	return path.Join(dir, p)
}

// gitStops are global options after which git runs no subcommand.
var gitStops = map[string]bool{
	"--version": true, "--help": true, "--exec-path": true, "--html-path": true,
	"--man-path": true, "--info-path": true, "--git-dir": true, "--work-tree": true,
}

func parseGit(args []string, dir string) []Created {
	if dir == "" {
		return nil
	}
global:
	for len(args) > 0 {
		a := args[0]
		name, _, _ := strings.Cut(a, "=")
		switch {
		case a == "-C":
			if len(args) < 2 {
				return nil
			}
			dir = resolve(dir, args[1])
			args = args[2:]
		case a == "-c" || a == "--namespace" || a == "--config-env":
			if len(args) < 2 {
				return nil
			}
			args = args[2:]
		case gitStops[name]:
			return nil
		case strings.HasPrefix(a, "--") || a == "-p" || a == "-P":
			args = args[1:]
		case strings.HasPrefix(a, "-"):
			return nil
		default:
			break global
		}
	}
	if len(args) == 0 {
		return nil
	}
	sub, rest := args[0], args[1:]
	switch sub {
	case "worktree":
		if len(rest) > 0 && rest[0] == "add" {
			return worktreeAdd(rest[1:], dir)
		}
	case "branch":
		return branchCreate(rest, dir)
	case "checkout":
		return switchCreate(rest, dir, "-b", "-B", "--orphan")
	case "switch":
		return switchCreate(rest, dir, "-c", "-C", "--create", "--force-create", "--orphan")
	}
	return nil
}

func worktreeAdd(args []string, dir string) []Created {
	opts, pos, ok := splitArgs(args, set("-b", "-B", "--reason"))
	if !ok || len(pos) < 1 || len(pos) > 2 || pos[0] == "" {
		return nil
	}
	branch := ""
	for _, o := range opts {
		if o.name == "-b" || o.name == "-B" {
			if !validBranch(o.value) {
				return nil
			}
			branch = o.value
		}
	}
	return []Created{{Kind: KindWorktree, Path: resolve(dir, pos[0]), Branch: branch, Dir: dir}}
}

// branchCreateFlags are git branch options that keep it in create mode.
var branchCreateFlags = set("-t", "--track", "--no-track", "-q", "--quiet",
	"--recurse-submodules", "--no-recurse-submodules", "--create-reflog", "--no-create-reflog")

func branchCreate(args []string, dir string) []Created {
	opts, pos, ok := splitArgs(args, nil)
	if !ok {
		return nil
	}
	copying, force := false, false
	for _, o := range opts {
		switch {
		case o.name == "-c" || o.name == "-C" || o.name == "--copy":
			copying = true
		case o.name == "-f" || o.name == "--force":
			force = true
		case !branchCreateFlags[o.name]:
			return nil
		}
	}
	if (force && !copying) || len(pos) < 1 || len(pos) > 2 {
		return nil
	}
	name := pos[0]
	if copying {
		name = pos[len(pos)-1]
	}
	if !validBranch(name) {
		return nil
	}
	return []Created{{Kind: KindBranch, Branch: name, Dir: dir}}
}

// switchCreate reads git checkout/switch; creating names the options that
// create a branch from their value.
func switchCreate(args []string, dir string, creating ...string) []Created {
	valued := set(creating...)
	opts, pos, ok := splitArgs(args, valued)
	if !ok || len(pos) > 1 {
		return nil
	}
	name := ""
	for _, o := range opts {
		if valued[o.name] {
			name = o.value
		}
	}
	if !validBranch(name) {
		return nil
	}
	return []Created{{Kind: KindBranch, Branch: name, Dir: dir}}
}

// validBranch rejects what git check-ref-format would, as far as a name can
// be judged alone, and the names that are not branches.
func validBranch(name string) bool {
	return name != "" && name[0] != '-' && name != "HEAD" && name != "@" &&
		!strings.ContainsAny(name, " \t\n~^:?*[\\")
}

func set(items ...string) map[string]bool {
	m := make(map[string]bool, len(items))
	for _, s := range items {
		m[s] = true
	}
	return m
}

type option struct{ name, value string }

// splitArgs separates options from positionals the way git's parse-options
// does: "--" ends options, short options cluster ("-fb name", "-bname"), and a
// long option takes a value as "--name=value" or, when valued, as the next word.
func splitArgs(args []string, valued map[string]bool) (opts []option, pos []string, ok bool) {
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--":
			return opts, append(pos, args[i+1:]...), true
		case strings.HasPrefix(a, "--"):
			name, val, hasVal := strings.Cut(a, "=")
			if !hasVal && valued[name] {
				if i+1 >= len(args) {
					return nil, nil, false
				}
				i++
				val = args[i]
			}
			opts = append(opts, option{name, val})
		case len(a) > 1 && a[0] == '-':
			for j := 1; j < len(a); j++ {
				name := "-" + a[j:j+1]
				if !valued[name] {
					opts = append(opts, option{name: name})
					continue
				}
				val := a[j+1:]
				if val == "" {
					if i+1 >= len(args) {
						return nil, nil, false
					}
					i++
					val = args[i]
				}
				opts = append(opts, option{name, val})
				break
			}
		default:
			pos = append(pos, a)
		}
	}
	return opts, pos, true
}
