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
//   - `-h`/`--help` in `worktree add`, `checkout` or `switch` records nothing
//     (git prints usage). `worktree add` has no dry-run option (git 2.50).
//   - Directory: a `cd` applies to the rest of its own &&-chain. When the
//     chain ends (`;`, newline, end) the new directory is kept only if the cd
//     was the chain's first command; otherwise it becomes unknown. A cd
//     followed by `||` or reached after one, a negated cd (`! cd`), and a cd
//     inside if/while/until/for/select make the directory unknown. A cd in a
//     pipeline element (`|`, `|&`) or a backgrounded chain (`&`) runs in a
//     subshell and changes nothing after it; so does a `( … )` subshell.
//     `pushd`/`popd` make the directory unknown. A function definition or a
//     `case` makes it unknown for the rest of the command.
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
	w := &walker{}
	w.dir = path.Clean(cwd)
	w.chainStart = w.dir
	var seg []token
	prevOp := ""
	for i, t := range toks {
		if t.kind == tokWord {
			seg = append(seg, t)
			continue
		}
		w.segment(seg, prevOp, t.text)
		seg = nil
		fnDef := t.text == "(" && i+1 < len(toks) && toks[i+1].kind == tokOp && toks[i+1].text == ")"
		w.operator(t.text, fnDef)
		prevOp = t.text
	}
	w.segment(seg, prevOp, "")
	return w.out
}

// frame is the directory state of one shell level; a ( … ) subshell pushes a
// new one. dir == "" means unknown.
type frame struct {
	dir        string
	chainStart string // dir when the current &&/|| chain began
	commands   int    // commands seen so far in the chain
	sawCD      bool   // a cd changed dir in this chain
	cdLater    bool   // a cd changed dir past the chain's first command
	sawOr      bool   // the chain has passed a ||
	depth      int    // open if/while/until/for/select
}

// walker carries the effective directory across the segments of a command.
type walker struct {
	frame
	stack []frame
	lost  bool // a function or case was seen: dir is unknown for good
	out   []Created
}

func (w *walker) operator(op string, fnDef bool) {
	switch op {
	case "&&", "|", "|&":
	case "||":
		w.sawOr = true
		if w.sawCD {
			w.dir = "" // the cd may or may not have happened
		}
	case "&":
		// The chain ran in a background subshell: its cd stays there.
		w.endChain(w.chainStart)
	case "(":
		if fnDef {
			w.lose()
			return
		}
		w.stack = append(w.stack, w.frame)
		w.frame = frame{dir: w.dir, chainStart: w.dir}
	case ")":
		if w.lost || len(w.stack) == 0 {
			w.lose()
			return
		}
		w.frame = w.stack[len(w.stack)-1]
		w.stack = w.stack[:len(w.stack)-1]
		w.commands++
	default: // ";", ";;", newline
		next := w.dir
		if w.cdLater || (w.sawOr && w.sawCD) {
			next = "" // a conditional cd: unknown whether it ran
		}
		w.endChain(next)
	}
}

func (w *walker) endChain(dir string) {
	if w.lost {
		dir = ""
	}
	depth := w.depth
	w.frame = frame{dir: dir, chainStart: dir, depth: depth}
}

func (w *walker) lose() {
	w.lost = true
	w.dir = ""
}

// leadingWords may precede a command without changing what it runs.
var leadingWords = map[string]bool{
	"!": true, "{": true, "if": true, "then": true, "else": true, "elif": true,
	"do": true, "while": true, "until": true, "time": true, "command": true,
}

func (w *walker) segment(words []token, prevOp, nextOp string) {
	if len(words) == 0 {
		return
	}
	first := w.commands == 0
	w.commands++
	negated := false
	for len(words) > 0 {
		t := words[0]
		if leadingWords[t.text] {
			switch t.text {
			case "if", "while", "until":
				w.depth++
			case "!":
				negated = true
			}
			words = words[1:]
			continue
		}
		if isAssignment(t.text) {
			if strings.HasPrefix(t.text, "GIT_") {
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
	piped := prevOp == "|" || prevOp == "|&" || nextOp == "|" || nextOp == "|&"
	cmd, args := words[0].text, words[1:]
	// Builtins and keywords match by exact text (/usr/bin/cd is a child
	// process and changes nothing); only git is recognised by base name.
	switch {
	case cmd == "case" || cmd == "function":
		w.lose()
	case cmd == "for" || cmd == "select":
		w.depth++
	case cmd == "fi" || cmd == "done":
		if w.depth > 0 {
			w.depth--
		}
	case cmd == "cd":
		switch {
		case w.lost || piped:
			// A pipeline element runs in a subshell.
		case w.depth > 0 || w.sawOr || negated:
			w.dir = "" // inside a condition or branch: may not have run
		default:
			w.dir = cdTarget(args, w.dir)
			w.sawCD = true
			w.cdLater = w.cdLater || !first
		}
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

// isAssignment reports whether word is NAME=value.
func isAssignment(word string) bool {
	name, _, found := strings.Cut(word, "=")
	if !found || name == "" {
		return false
	}
	for i := 0; i < len(name); i++ {
		c := name[i]
		letter := c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
		if !letter && (i == 0 || c < '0' || c > '9') {
			return false
		}
	}
	return true
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
	if !ok || asksHelp(opts) || len(pos) < 1 || len(pos) > 2 || pos[0] == "" {
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
	if !ok || asksHelp(opts) || len(pos) > 1 {
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

// asksHelp reports a -h/--help, with which git prints usage and creates nothing.
func asksHelp(opts []option) bool {
	for _, o := range opts {
		if o.name == "-h" || o.name == "--help" {
			return true
		}
	}
	return false
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
				name := "-" + string(a[j]) // option letters are ASCII bytes
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
