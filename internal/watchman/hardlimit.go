package watchman

import (
	"cmp"
	"encoding/json"
	"path"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"watchtower/internal/db"
)

// HardLimit names one row of the §5 hard-limit table: a class of action
// Watchman never takes on his own, whatever the precedents say.
type HardLimit string

const (
	LimitUnreadable    HardLimit = "unreadable"     // a command that cannot be read (an unterminated quote, a wrapper around nothing)
	LimitSendPack      HardLimit = "send_pack"      // the plumbing push git send-pack, in any form (no pre-push hook sees it)
	LimitMainRef       HardLimit = "main_ref"       // push to, or PR merge into, the default branch
	LimitTag           HardLimit = "tag"            // creating, deleting or pushing a tag
	LimitRelease       HardLimit = "release"        // a GitHub release
	LimitTestFlight    HardLimit = "testflight"     // an App Store Connect / TestFlight upload
	LimitForcePush     HardLimit = "force_push"     // a forced push
	LimitResetShared   HardLimit = "reset_shared"   // a forced move of a shared branch (reset --hard onto a remote ref or on a shared branch, branch -f, update-ref)
	LimitDeleteOutside HardLimit = "delete_outside" // rm outside the session's worktrees
	LimitOutward       HardLimit = "outward"        // a message or comment other people see
	LimitStandingGrant HardLimit = "standing_grant" // an edit of the agent's own settings
	LimitOutsideFolder HardLimit = "outside_folder" // a file edit outside the workbench folder and worktrees
)

// PermissionAsk is one permission request as the hard-limit table reads it.
// An empty WorkbenchFolder with no Worktrees is an unknown placement, and
// every path-dependent row then parks.
type PermissionAsk struct {
	Tool, Summary, WorkbenchFolder string
	// SummaryClipped says the stored summary was cut short: its hidden tail
	// may be what a hard limit covers, so the request parks.
	SummaryClipped bool
	Worktrees      []string
	// PRBase reports the base branch of a pull request; known=false when
	// the base is not recorded. Nil means never known.
	PRBase func(pr int) (base string, known bool)
	// Branch is the session's branch when the request was read; nil = not
	// recorded (stored rows).
	Branch *BranchInfo
	// Cwd is the directory a live tool call starts in ("" = unknown, stored
	// rows). It places a shell command's relative paths only; it is no
	// directory change (a cd or -C in the command is).
	Cwd string
}

// BranchInfo is the branch a session works on and the branches it shares
// with others. Current == "" is a live read that failed.
type BranchInfo struct {
	Current string
	// Shared holds the default branches and the session's PR base/umbrella
	// branch; nil = not known (a read failed, or the caller does not read
	// it), and then every destructive ref move parks (matchResetShared).
	Shared []string
}

var hardLimits = []struct {
	limit HardLimit
	match func(PermissionAsk) bool
}{
	{LimitUnreadable, matchUnreadable},
	{LimitSendPack, matchSendPack},
	{LimitMainRef, matchMainRef},
	{LimitTag, matchTag},
	{LimitRelease, matchRelease},
	{LimitTestFlight, matchTestFlight},
	{LimitForcePush, matchForcePush},
	{LimitResetShared, matchResetShared},
	{LimitDeleteOutside, matchDeleteOutside},
	{LimitOutward, matchOutward},
	{LimitStandingGrant, matchStandingGrant},
	{LimitOutsideFolder, matchOutsideFolder},
}

// ParkedBy returns the first hard limit the request hits.
func ParkedBy(r PermissionAsk) (HardLimit, bool) {
	for _, row := range hardLimits {
		if row.match(r) {
			return row.limit, true
		}
	}
	return "", false
}

// permissionFlags marks a permission request as a decision, parked when a
// hard limit covers it or its summary was clipped (the hidden tail cannot be
// judged). The caller fills ID.
func permissionFlags(r PermissionAsk) db.WatchmanPrecedentFlags {
	_, parked := ParkedBy(r)
	parked = parked || r.SummaryClipped
	yes := true
	return db.WatchmanPrecedentFlags{IsDecision: &yes, Parked: &parked}
}

// shellCmd is one simple command of a shell line: its words with quotes
// removed, wrappers (env assignments, sudo, xargs...) stripped and the
// program reduced to its base name, plus the directory a preceding cd
// moved to.
type shellCmd struct {
	w     []string
	cwd   string // "" = never cd'd; cwdUnknown = a cd that cannot be resolved
	xargs bool   // the arguments come from stdin as well
	// elsewhere: an env assignment (GIT_DIR, GIT_WORK_TREE...) or a wrapper
	// option (env -C, sudo -D) points the command at another repository
	// or directory.
	elsewhere bool
}

// gitDirVars are the environment variables that point git at another
// repository or work tree.
var gitDirVars = []string{"GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR"}

// isGitDirAssignment reports NAME=value for a gitDirVars name.
func isGitDirAssignment(w string) bool {
	name, _, ok := strings.Cut(w, "=")
	return ok && slices.Contains(gitDirVars, name)
}

// chdirOpts are the wrapper options that change the directory.
var chdirOpts = map[string]bool{"-C": true, "--chdir": true, "-D": true}

const cwdUnknown = "?"

// wrappers maps each wrapper program to the options that take an operand.
var wrappers = map[string]map[string]bool{
	"sudo":    {"-u": true, "-g": true, "-h": true, "-p": true, "-C": true, "-D": true, "-R": true, "-T": true, "-U": true, "--user": true, "--group": true, "--host": true, "--prompt": true, "--chdir": true, "--chroot": true},
	"command": {},
	"time":    {"-f": true, "-o": true, "--format": true, "--output": true},
	"nohup":   {},
	"env":     {"-u": true, "-C": true, "-S": true, "--unset": true, "--chdir": true, "--split-string": true},
	"exec":    {"-a": true},
	"nice":    {"-n": true, "--adjustment": true},
	"xcrun":   {"--sdk": true, "-sdk": true, "--toolchain": true, "-toolchain": true},
	"xargs":   {"-n": true, "-L": true, "-I": true, "-P": true, "-s": true, "-d": true, "-E": true, "-a": true, "--max-args": true, "--max-lines": true, "--max-procs": true, "--max-chars": true, "--delimiter": true, "--arg-file": true, "--replace": true, "--eof": true},
}

// unresolved stands for a command that cannot be read (a wrapper around
// nothing readable, an unterminated quote); it parks.
const unresolved = "<unresolved>"

// commandPart is one simple command of a line and the separator before it.
type commandPart struct{ text, sep string }

// splitCommands splits a command line on ; && || | and newlines outside
// quotes. A comment (a # at the start of a word, outside quotes) is dropped
// up to its newline first, so a quote or separator inside it counts for
// nothing. Quotes and backslashes are kept for splitWords.
func splitCommands(line string) []commandPart {
	var out []commandPart
	var cur strings.Builder
	sep := ""
	var quote byte
	wordStart := true // the previous byte ended a word, outside quotes
	for i := 0; i < len(line); i++ {
		ch := line[i]
		if quote == 0 && ch == '#' && wordStart {
			nl := strings.IndexByte(line[i:], '\n')
			if nl < 0 {
				break
			}
			i += nl // the comment's newline
			ch = '\n'
		}
		// A backslash-newline outside quotes is a line continuation: it
		// leaves wordStart as it was.
		if quote == 0 && ch == '\\' && i+1 < len(line) && line[i+1] == '\n' {
			cur.WriteString("\\\n")
			i++
			continue
		}
		wordStart = quote == 0 && strings.IndexByte(" \t\r\n;&|()", ch) >= 0
		switch {
		case quote == '\'':
			if ch == '\'' {
				quote = 0
			}
		case ch == '\\' && i+1 < len(line):
			cur.WriteByte(ch)
			i++
			ch = line[i]
		case quote == '"':
			if ch == '"' {
				quote = 0
			}
		case ch == '\'' || ch == '"':
			quote = ch
		default:
			next := ""
			switch {
			case strings.HasPrefix(line[i:], "&&"):
				next = "&&"
			case strings.HasPrefix(line[i:], "||"):
				next = "||"
			case ch == ';' || ch == '|' || ch == '\n':
				next = line[i : i+1]
			}
			if next != "" {
				out = append(out, commandPart{cur.String(), sep})
				cur.Reset()
				sep = next
				i += len(next) - 1
				continue
			}
		}
		cur.WriteByte(ch)
	}
	return append(out, commandPart{cur.String(), sep})
}

// splitWords splits a command on blanks the way a POSIX shell does: quotes
// are removed, outside quotes \x is a literal x, inside double quotes \
// escapes only " \ $ and backtick, inside single quotes nothing escapes.
// ok is false for an unterminated quote: the command cannot be read.
func splitWords(text string) (words []string, ok bool) {
	var cur strings.Builder
	var quote byte
	has := false
	flush := func() {
		if has || cur.Len() > 0 {
			words = append(words, cur.String())
		}
		cur.Reset()
		has = false
	}
	for i := 0; i < len(text); i++ {
		ch := text[i]
		switch {
		case quote == '\'':
			if ch == '\'' {
				quote = 0
			} else {
				cur.WriteByte(ch)
			}
		case ch == '\\' && i+1 < len(text) && (quote == 0 || strings.IndexByte("\"\\$`\n", text[i+1]) >= 0):
			i++
			if text[i] != '\n' { // backslash-newline is a line continuation
				cur.WriteByte(text[i])
				has = true
			}
		case quote == '"':
			if ch == '"' {
				quote = 0
			} else {
				cur.WriteByte(ch)
			}
		case ch == '"' || ch == '\'':
			quote, has = ch, true
		case ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n':
			flush()
		default:
			cur.WriteByte(ch)
		}
	}
	if quote != 0 {
		return nil, false
	}
	flush()
	return words, true
}

// stripWrappers removes leading env assignments and wrappers, with their
// options and the options' operands.
func stripWrappers(words []string, c *shellCmd) []string {
	wrapped := false
	for len(words) > 0 {
		w := words[0]
		if i := strings.Index(w, "="); i > 0 && !strings.ContainsAny(w[:i], "/-") {
			c.elsewhere = c.elsewhere || isGitDirAssignment(w)
			words = words[1:]
			continue
		}
		valued, ok := wrappers[path.Base(w)]
		if !ok {
			return words
		}
		wrapped = true
		if path.Base(w) == "xargs" {
			c.xargs = true
		}
		words = words[1:]
		for len(words) > 0 && strings.HasPrefix(words[0], "-") {
			opt := words[0]
			words = words[1:]
			name, _, _ := strings.Cut(opt, "=")
			c.elsewhere = c.elsewhere || (valued[name] && chdirOpts[name])
			if valued[opt] && len(words) > 0 {
				words = words[1:]
			}
		}
	}
	if wrapped {
		return []string{unresolved}
	}
	return nil
}

// commands splits a Bash summary into its commands. The request's
// description follows as `# ` comment lines (cmd.permissionSummary), which
// splitCommands drops with every other comment. Only a cd joined to the
// next command by && carries its directory on; after any other separator
// the directory is unknown.
func commands(summary string) []shellCmd {
	var out []shellCmd
	cwd := ""
	for _, part := range splitCommands(summary) {
		if part.sep != "&&" && part.sep != "" && cwd != "" {
			cwd = cwdUnknown
		}
		words, ok := splitWords(part.text)
		if !ok { // an unterminated quote: unreadable, so it parks
			out = append(out, shellCmd{w: []string{unresolved}, cwd: cwd})
			continue
		}
		c := shellCmd{cwd: cwd}
		words = stripWrappers(words, &c)
		if len(words) == 0 {
			continue
		}
		words[0] = path.Base(words[0])
		c.w = words
		if words[0] == "cd" {
			switch {
			case len(words) != 2:
				cwd = cwdUnknown
			case path.IsAbs(words[1]):
				cwd = path.Clean(words[1])
			case cwd != "" && cwd != cwdUnknown && !strings.HasPrefix(words[1], "~") && !strings.Contains(words[1], "$") && words[1] != "-":
				cwd = path.Join(cwd, words[1])
			default:
				cwd = cwdUnknown
			}
			continue
		}
		out = append(out, c)
	}
	return out
}

// gitValuedGlobals are git's global options that take an operand, attached
// with = or as the next word. --exec-path takes one only attached (alone it
// prints the path and exits).
var gitValuedGlobals = map[string]bool{"-c": true, "-C": true, "--git-dir": true, "--work-tree": true, "--namespace": true, "--config-env": true, "--super-prefix": true}

// gitGlobals skips the global options of w (a git command line, or any
// program's), with their operands. sub is the index of the subcommand;
// elsewhere reports -C, --git-dir or --work-tree, which point git at
// another repository or work tree.
func gitGlobals(w []string) (sub int, elsewhere bool) {
	i := 1
	for i < len(w) && strings.HasPrefix(w[i], "-") {
		name, _, attached := strings.Cut(w[i], "=")
		switch name {
		case "-C", "--git-dir", "--work-tree":
			elsewhere = true
		}
		if strings.HasPrefix(name, "-C") && len(name) > 2 { // -C<path>
			elsewhere = true
		}
		if !attached && gitValuedGlobals[name] {
			i++
		}
		i++
	}
	return i, elsewhere
}

// sub returns the arguments after `<prog> <subcommand>` of c, skipping
// git's global options; ok is false when c is not that command.
func (c shellCmd) sub(prog, subcommand string) (args []string, ok bool) {
	if c.w[0] != prog {
		return nil, false
	}
	i, _ := gitGlobals(c.w)
	if i >= len(c.w) || c.w[i] != subcommand {
		return nil, false
	}
	return c.w[i+1:], true
}

func isBash(r PermissionAsk) bool { return r.Tool == "Bash" }

// anyCmd reports whether f holds for any command of a Bash request.
func anyCmd(r PermissionAsk, f func(shellCmd) bool) bool {
	if !isBash(r) {
		return false
	}
	for _, c := range commands(r.Summary) {
		if f(c) {
			return true
		}
	}
	return false
}

func isDefaultBranch(s string) bool { return s == "main" || s == "master" }

// pushArgs splits git push arguments into flags and positional words.
func pushArgs(c shellCmd) (flags, pos []string, ok bool) {
	args, ok := c.sub("git", "push")
	if !ok {
		return nil, nil, false
	}
	for _, a := range args {
		if strings.HasPrefix(a, "-") {
			flags = append(flags, a)
		} else {
			pos = append(pos, a)
		}
	}
	return flags, pos, true
}

// refDest is the destination branch of a push refspec.
func refDest(spec string) string {
	spec = strings.TrimPrefix(spec, "+")
	if i := strings.LastIndex(spec, ":"); i >= 0 {
		spec = spec[i+1:]
	}
	return strings.TrimPrefix(spec, "refs/heads/")
}

// matchSendPack: git send-pack or git-send-pack, whatever it pushes. An
// agent never needs the plumbing, and it bypasses the pre-push hook, so it
// parks unconditionally.
func matchSendPack(r PermissionAsk) bool {
	return anyCmd(r, func(c shellCmd) bool {
		_, ok := c.sub("git", "send-pack")
		return ok || c.w[0] == "git-send-pack"
	})
}

// stripRemote reduces origin/main, refs/heads/main and main to main.
func stripRemote(ref string) string {
	ref = strings.TrimPrefix(ref, "refs/heads/")
	for _, r := range []string{"origin/", "upstream/"} {
		ref = strings.TrimPrefix(ref, r)
	}
	return ref
}

// rebaseOnDefault reports a git rebase whose upstream (or --onto) is the
// default branch.
func rebaseOnDefault(args []string) bool {
	valued := map[string]bool{"-s": true, "-X": true, "-x": true, "-C": true, "--exec": true, "--strategy": true, "--strategy-option": true}
	var pos []string
	for i := 0; i < len(args); i++ {
		switch a := args[i]; {
		case valued[a]:
			i++
		case a == "--onto" && i+1 < len(args):
			return isDefaultBranch(stripRemote(args[i+1]))
		case strings.HasPrefix(a, "--onto="):
			return isDefaultBranch(stripRemote(strings.TrimPrefix(a, "--onto=")))
		case strings.HasPrefix(a, "-"):
		default:
			pos = append(pos, a)
		}
	}
	return len(pos) > 0 && isDefaultBranch(stripRemote(pos[0]))
}

// prMergeNumber is the PR number of `gh pr merge` arguments; ok is false
// when the PR is named by URL or branch, or not at all.
func prMergeNumber(args []string) (int, bool) {
	valued := map[string]bool{"--body": true, "-b": true, "--body-file": true, "-F": true, "--subject": true, "-t": true, "--match-head-commit": true, "--author-email": true, "-A": true, "--repo": true, "-R": true}
	for i := 0; i < len(args); i++ {
		switch a := args[i]; {
		case valued[a]:
			i++
		case strings.HasPrefix(a, "-"):
		default:
			n, err := strconv.Atoi(a)
			return n, err == nil
		}
	}
	return 0, false
}

// ghRepoEnv names gh's environment variables that point it at another
// repository or host.
var ghRepoEnv = regexp.MustCompile(`\bGH_(REPO|HOST)\b`)

// prMergeElsewhere reports a gh pr merge whose repository may not be the
// session folder's, so a base read there says nothing about it: a --repo/-R
// option in any form, a cd or a wrapper's directory change before it, or a
// GH_REPO/GH_HOST assignment or export anywhere in the request. (A PR URL is
// no number, so prMergeNumber already fails it.)
func prMergeElsewhere(r PermissionAsk, c shellCmd, args []string) bool {
	if c.cwd != "" || c.elsewhere || ghRepoEnv.MatchString(r.Summary) {
		return true
	}
	return slices.ContainsFunc(args, func(a string) bool {
		return a == "--repo" || strings.HasPrefix(a, "--repo=") ||
			(strings.HasPrefix(a, "-") && !strings.HasPrefix(a, "--") && strings.Contains(a, "R"))
	})
}

// matchUnreadable: a command that cannot be read, so cannot be judged.
func matchUnreadable(r PermissionAsk) bool {
	return anyCmd(r, func(c shellCmd) bool { return c.w[0] == unresolved })
}

// matchMainRef: a push to, a rebase onto, or a PR merge into the default
// branch. A plain `git push` with no refspec is not matched: its
// destination is unknown here, and parking every plain push would drop
// most push decisions (the live pre-push hook covers it).
func matchMainRef(r PermissionAsk) bool {
	return anyCmd(r, func(c shellCmd) bool {
		if _, pos, ok := pushArgs(c); ok {
			for _, spec := range pos[min(1, len(pos)):] { // pos[0] is the remote
				if isDefaultBranch(refDest(spec)) {
					return true
				}
			}
			return false
		}
		if args, ok := c.sub("git", "rebase"); ok {
			return rebaseOnDefault(args)
		}
		if args, ok := c.sub("gh", "pr"); ok && len(args) > 0 && args[0] == "merge" {
			pr, ok := prMergeNumber(args[1:])
			if !ok || r.PRBase == nil || prMergeElsewhere(r, c, args[1:]) {
				return true
			}
			base, known := r.PRBase(pr)
			return !known || isDefaultBranch(base)
		}
		return false
	})
}

func matchTag(r PermissionAsk) bool {
	return anyCmd(r, func(c shellCmd) bool {
		if flags, pos, ok := pushArgs(c); ok {
			for _, f := range flags {
				if f == "--tags" || f == "--follow-tags" {
					return true
				}
			}
			for _, spec := range pos[min(1, len(pos)):] {
				if strings.HasPrefix(strings.TrimPrefix(spec, "+"), "refs/tags/") || spec == "tag" {
					return true
				}
			}
			return false
		}
		args, ok := c.sub("git", "tag")
		if !ok {
			return false
		}
		for _, a := range args {
			switch a {
			case "-l", "--list", "-v", "--verify", "--contains", "--points-at", "--merged", "--no-merged":
				return false
			}
		}
		return len(args) > 0
	})
}

func matchRelease(r PermissionAsk) bool {
	return anyCmd(r, func(c shellCmd) bool {
		args, ok := c.sub("gh", "release")
		return ok && len(args) > 0 && args[0] != "list" && args[0] != "view" && args[0] != "download"
	})
}

// matchTestFlight matches the commands that upload a build only.
func matchTestFlight(r PermissionAsk) bool {
	return anyCmd(r, func(c shellCmd) bool {
		switch prog := c.w[0]; prog {
		case "altool":
			return slices.ContainsFunc(c.w[1:], func(a string) bool { return strings.HasPrefix(a, "--upload") })
		case "iTMSTransporter":
			return true
		case "fastlane":
			return len(c.w) > 1 && (c.w[1] == "pilot" || c.w[1] == "upload_to_testflight")
		case "make":
			return slices.ContainsFunc(c.w[1:], func(a string) bool { return strings.Contains(strings.ToLower(a), "testflight") })
		}
		return false
	})
}

func matchForcePush(r PermissionAsk) bool {
	return anyCmd(r, func(c shellCmd) bool {
		flags, pos, ok := pushArgs(c)
		if !ok {
			return false
		}
		for _, f := range flags {
			if f == "--force" || f == "--force-with-lease" || f == "--force-if-includes" || strings.HasPrefix(f, "--force-with-lease=") {
				return true
			}
			if !strings.HasPrefix(f, "--") && strings.Contains(f, "f") { // -f, -fu
				return true
			}
		}
		for _, spec := range pos[min(1, len(pos)):] {
			if strings.HasPrefix(spec, "+") {
				return true
			}
		}
		return false
	})
}

// isShared reports a branch others build on: a default branch, or one the
// request's BranchInfo lists as shared.
func (r PermissionAsk) isShared(branch string) bool {
	branch = strings.TrimPrefix(branch, "refs/heads/")
	return isDefaultBranch(branch) || (r.Branch != nil && slices.Contains(r.Branch.Shared, branch))
}

// expandFlags splits combined short flags (-fD into -f -D); long flags and
// positionals pass through.
func expandFlags(args []string) []string {
	var out []string
	for _, a := range args {
		if len(a) > 2 && a[0] == '-' && a[1] != '-' {
			for _, f := range a[1:] {
				out = append(out, "-"+string(f))
			}
			continue
		}
		out = append(out, a)
	}
	return out
}

// splitFlags splits expanded arguments into a set of flags and the
// positional words; every word after -- is positional.
func splitFlags(args []string) (flags map[string]bool, pos []string) {
	flags = map[string]bool{}
	expanded := expandFlags(args)
	for i, a := range expanded {
		if a == "--" {
			return flags, append(pos, expanded[i+1:]...)
		}
		if strings.HasPrefix(a, "-") && a != "-" {
			flags[a] = true
		} else {
			pos = append(pos, a)
		}
	}
	return flags, pos
}

// movesContext reports a command after which the branch or repository a
// later git command works on is no longer the recorded one: any git
// checkout, switch, rebase or worktree, gh pr checkout, pushd/popd, an
// export of a gitDirVars name. A cd shows as the command's cwd, git
// -C/--git-dir/--work-tree and GIT_DIR=... via gitElsewhere.
func movesContext(c shellCmd) bool {
	for _, sub := range []string{"checkout", "switch", "rebase", "worktree"} {
		if _, ok := c.sub("git", sub); ok {
			return true
		}
	}
	if c.w[0] == "export" && slices.ContainsFunc(c.w[1:], isGitDirAssignment) {
		return true
	}
	if args, ok := c.sub("gh", "pr"); ok && len(args) > 0 && args[0] == "checkout" {
		return true
	}
	return c.w[0] == "pushd" || c.w[0] == "popd"
}

// gitElsewhere reports a command pointed at another repository or work
// tree: by a git global option, a GIT_DIR-style assignment or a wrapper's
// directory option.
func gitElsewhere(c shellCmd) bool {
	if c.elsewhere {
		return true
	}
	if c.w[0] != "git" {
		return false
	}
	_, elsewhere := gitGlobals(c.w)
	return elsewhere
}

// forceCreateTarget is the branch a git checkout/switch -B, -C or
// --force-create (re)creates, its operand attached (-Bmain,
// --force-create=main) or the next word; ok is false for any other
// checkout. Words after -- are paths.
func forceCreateTarget(args []string) (branch string, ok bool) {
	next := func(i int) (string, bool) {
		if i+1 < len(args) {
			return args[i+1], true
		}
		return "", false
	}
	for i, a := range args {
		switch {
		case a == "--":
			return "", false
		case a == "--force-create":
			return next(i)
		case strings.HasPrefix(a, "--force-create="):
			return strings.TrimPrefix(a, "--force-create="), true
		case strings.HasPrefix(a, "--"):
		case len(a) > 1 && a[0] == '-':
			// A short-flag cluster: -B/-C take the rest as their operand,
			// or the next word; -b/-c (create without force) end it too.
			for j := 1; j < len(a); j++ {
				switch a[j] {
				case 'B', 'C':
					if j+1 < len(a) {
						return a[j+1:], true
					}
					return next(i)
				case 'b', 'c':
					j = len(a)
				}
			}
		}
	}
	return "", false
}

// matchResetShared: a forced move of a branch others build on.
//
// Named branches park by name: git checkout|switch -B/-C/--force-create of
// a shared branch, a
// forced git branch (-f, -D, -M, -C, or -m/-c with -f) naming a shared
// branch, git update-ref of refs/heads/<shared> or from stdin.
//
// Commands that move the current branch (reset --hard, update-ref HEAD, a
// forced git branch rename with one name) park when the current branch is
// shared or unknown: the recorded Branch says it is shared or its read
// failed, or the request has a movesContext command or a cd before it, or
// the command itself is gitElsewhere, so the recorded branch no longer
// tells. A stored row
// (Branch nil) with none of those parks only a reset --hard onto a remote
// ref.
//
// A live request whose shared branches are not known (Branch.Shared nil)
// fails closed: any forced branch move (checkout/switch -B, branch -f/-D/
// -M/-C, update-ref) parks, and so does a reset --hard to an explicit
// target other than HEAD; a reset --hard with no target (or HEAD) only
// drops the working tree's changes and stays private.
func matchResetShared(r PermissionAsk) bool {
	recordedShared := r.Branch != nil && (r.Branch.Current == "" || r.isShared(r.Branch.Current))
	sharedUnknown := r.Branch != nil && r.Branch.Shared == nil
	moved := false
	return anyCmd(r, func(c shellCmd) bool {
		if movesContext(c) {
			moved = true
		}
		currentShared := recordedShared || moved || c.cwd != "" || gitElsewhere(c)
		for _, sub := range []string{"checkout", "switch"} {
			if args, ok := c.sub("git", sub); ok {
				branch, forced := forceCreateTarget(args)
				return forced && (sharedUnknown || r.isShared(branch))
			}
		}
		if args, ok := c.sub("git", "branch"); ok {
			flags, pos := splitFlags(args)
			force := flags["-f"] || flags["--force"]
			rename := flags["-M"] || ((flags["-m"] || flags["--move"]) && force)
			forced := force || rename || flags["-D"] || flags["-C"]
			if !forced {
				return false
			}
			return sharedUnknown || slices.ContainsFunc(pos, r.isShared) || (rename && len(pos) == 1 && currentShared)
		}
		if args, ok := c.sub("git", "update-ref"); ok {
			return sharedUnknown || updateRefShared(r, args, currentShared)
		}
		args, ok := c.sub("git", "reset")
		if !ok || !slices.Contains(args, "--hard") {
			return false
		}
		if _, pos := splitFlags(args); sharedUnknown && slices.ContainsFunc(pos, func(a string) bool { return a != "HEAD" && a != "@" }) {
			return true
		}
		return currentShared || slices.ContainsFunc(args, func(a string) bool {
			return strings.HasPrefix(a, "origin/") || strings.HasPrefix(a, "upstream/") || a == "@{u}" || a == "@{upstream}" || a == "FETCH_HEAD"
		})
	})
}

// updateRefShared reports a git update-ref of a shared branch, of HEAD
// while the current branch is shared or unknown, or from stdin (refs
// unknown).
func updateRefShared(r PermissionAsk, args []string, currentShared bool) bool {
	for i := 0; i < len(args); i++ {
		switch a := args[i]; {
		case a == "--stdin":
			return true
		case a == "-m":
			i++
		case strings.HasPrefix(a, "-"):
		default:
			return (a == "HEAD" && currentShared) || (strings.HasPrefix(a, "refs/heads/") && r.isShared(a))
		}
	}
	return false
}

// roots are the folders the session may touch: its worktrees (the session
// folder included) and, for edits, the workbench folder.
func (r PermissionAsk) roots(withWorkbench bool) []string {
	list := r.Worktrees
	if withWorkbench {
		list = append([]string{r.WorkbenchFolder}, list...)
	}
	var out []string
	for _, w := range list {
		if w != "" {
			out = append(out, path.Clean(w))
		}
	}
	return out
}

// inside reports whether p lies in a known root. A relative path counts as
// inside only when a root is known and, cleaned, it does not climb out with
// ".." (subdir/.. is inside, subdir/../.. is not).
func (r PermissionAsk) inside(p string, withWorkbench bool) bool {
	roots := r.roots(withWorkbench)
	if len(roots) == 0 {
		return false
	}
	if strings.HasPrefix(p, "~") || strings.Contains(p, "$") {
		return false
	}
	p = path.Clean(p)
	if !path.IsAbs(p) {
		return p != ".." && !strings.HasPrefix(p, "../")
	}
	for _, root := range roots {
		if p == root || strings.HasPrefix(p, strings.TrimSuffix(root, "/")+"/") {
			return true
		}
	}
	return false
}

func matchDeleteOutside(r PermissionAsk) bool {
	return anyCmd(r, func(c shellCmd) bool {
		if c.w[0] != "rm" {
			return false
		}
		if c.xargs { // xargs appends paths from stdin
			return true
		}
		for _, a := range c.w[1:] {
			if strings.HasPrefix(a, "-") {
				continue
			}
			base := cmp.Or(c.cwd, r.Cwd)
			if !path.IsAbs(a) && base != "" {
				if base == cwdUnknown {
					return true
				}
				a = path.Join(base, a)
			}
			if !r.inside(a, false) {
				return true
			}
		}
		return false
	})
}

// outwardTools are the MCP tools whose effect other people see.
var outwardTools = []string{"send_slack_message", "slack_send_message", "slack_send_message_draft", "slack_schedule_message", "slack_add_reaction"}

// mailTools are fragments of MCP mail-sending tool names.
var mailTools = []string{"send_email", "send_mail", "email_send", "mail_send", "send_draft", "draft_send"}

func matchOutward(r PermissionAsk) bool {
	for _, t := range outwardTools {
		if strings.HasSuffix(r.Tool, t) {
			return true
		}
	}
	name := strings.ToLower(r.Tool[strings.LastIndex(r.Tool, "__")+1:])
	if slices.ContainsFunc(mailTools, func(f string) bool { return strings.Contains(name, f) }) ||
		(strings.Contains(strings.ToLower(r.Tool), "gmail") && strings.Contains(name, "send")) {
		return true
	}
	return anyCmd(r, func(c shellCmd) bool {
		switch c.w[0] {
		case "mail", "mailx", "sendmail", "mutt":
			return true
		}
		if args, ok := c.sub("gh", "pr"); ok && len(args) > 0 && (args[0] == "comment" || args[0] == "review") {
			return true
		}
		args, ok := c.sub("gh", "issue")
		return ok && len(args) > 0 && args[0] == "comment"
	})
}

// plainPathTools show the file path alone as their summary; jsonPathTools
// show the tool input as compact JSON (cmd.permissionSummary).
var (
	plainPathTools = map[string]bool{"Edit": true, "Write": true, "NotebookEdit": true}
	jsonPathTools  = map[string]bool{"Read": true, "MultiEdit": true, "Glob": true, "Grep": true}
)

// filePath is the path a file tool touches. isFileTool is false for any
// other tool; placed is false when a file tool names no usable path.
func filePath(r PermissionAsk) (p string, isFileTool, placed bool) {
	switch {
	case plainPathTools[r.Tool]:
		p, _, _ = strings.Cut(r.Summary, "\n")
		p = strings.TrimSpace(p)
		// The JSON fallback summary (the tool input, an object) is not a
		// path; a file named 123, null or [1] is.
		var obj map[string]json.RawMessage
		isObject := strings.HasPrefix(p, "{") && json.Unmarshal([]byte(p), &obj) == nil
		return p, true, p != "" && !isObject
	case jsonPathTools[r.Tool]:
		var in map[string]json.RawMessage
		if json.Unmarshal([]byte(r.Summary), &in) != nil {
			return "", true, false
		}
		// Each field is decoded on its own: a non-string value leaves that
		// field empty without unplacing the others.
		str := func(key string) string {
			var s string
			_ = json.Unmarshal(in[key], &s)
			return s
		}
		p = cmp.Or(str("file_path"), str("notebook_path"), str("path"))
		return p, true, p != ""
	}
	return "", false, false
}

// writeTools are the file tools that change a file. Bash writes stay out of
// the standing-grant row (a read-mostly shell line would over-park).
var writeTools = map[string]bool{"Write": true, "Edit": true, "MultiEdit": true, "NotebookEdit": true}

// matchStandingGrant: a file write to the agent's own settings, Claude's
// .claude/settings*.json or Codex's .codex/config.toml. A read is not one.
func matchStandingGrant(r PermissionAsk) bool {
	if !writeTools[r.Tool] {
		return false
	}
	p, _, placed := filePath(r)
	if !placed {
		return false
	}
	p = path.Clean(p)
	dir, base := path.Base(path.Dir(p)), path.Base(p)
	settings, _ := path.Match("settings*.json", base)
	return (dir == ".claude" && settings) || (dir == ".codex" && base == "config.toml")
}

// matchOutsideFolder: a file tool whose path is outside the workbench
// folder and worktrees, or cannot be placed. Bash is judged by the delete
// row only: absolute paths in ordinary reads would over-park.
func matchOutsideFolder(r PermissionAsk) bool {
	p, isFileTool, placed := filePath(r)
	return isFileTool && (!placed || !r.inside(p, true))
}
