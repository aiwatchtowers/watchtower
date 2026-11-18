package watchman

import (
	"cmp"
	"encoding/json"
	"path"
	"slices"
	"strconv"
	"strings"

	"watchtower/internal/db"
)

// HardLimit names one row of the §5 hard-limit table: a class of action
// Watchman never takes on his own, whatever the precedents say.
type HardLimit string

const (
	LimitMainRef       HardLimit = "main_ref"       // push to, or PR merge into, the default branch
	LimitTag           HardLimit = "tag"            // creating, deleting or pushing a tag
	LimitRelease       HardLimit = "release"        // a GitHub release
	LimitTestFlight    HardLimit = "testflight"     // an App Store Connect / TestFlight upload
	LimitForcePush     HardLimit = "force_push"     // a forced push
	LimitResetShared   HardLimit = "reset_shared"   // reset --hard onto a remote ref
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
	Worktrees                      []string
	// PRBase reports the base branch of a pull request; known=false when
	// the base is not recorded. Nil means never known.
	PRBase func(pr int) (base string, known bool)
}

var hardLimits = []struct {
	limit HardLimit
	match func(PermissionAsk) bool
}{
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
// hard limit covers it. The caller fills ID.
func permissionFlags(r PermissionAsk) db.WatchmanPrecedentFlags {
	_, parked := ParkedBy(r)
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
}

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

// unresolved stands for a wrapper that wraps nothing readable; it parks.
const unresolved = "<unresolved>"

// commandPart is one simple command of a line and the separator before it.
type commandPart struct{ text, sep string }

// splitCommands splits a command line on ; && || | and newlines.
func splitCommands(line string) []commandPart {
	var out []commandPart
	start, sep := 0, ""
	for i := 0; i < len(line); {
		var next string
		switch {
		case strings.HasPrefix(line[i:], "&&"):
			next = "&&"
		case strings.HasPrefix(line[i:], "||"):
			next = "||"
		case line[i] == ';' || line[i] == '|' || line[i] == '\n':
			next = line[i : i+1]
		}
		if next == "" {
			i++
			continue
		}
		out = append(out, commandPart{line[start:i], sep})
		i += len(next)
		start, sep = i, next
	}
	return append(out, commandPart{line[start:], sep})
}

// splitWords splits a command on blanks, keeping a quoted string as one
// word with its quotes removed.
func splitWords(text string) []string {
	var words []string
	var cur strings.Builder
	var quote rune
	has := false
	for _, ch := range text {
		switch {
		case quote != 0:
			if ch == quote {
				quote = 0
			} else {
				cur.WriteRune(ch)
			}
		case ch == '"' || ch == '\'':
			quote, has = ch, true
		case ch == ' ' || ch == '\t' || ch == '\r':
			if has || cur.Len() > 0 {
				words = append(words, cur.String())
			}
			cur.Reset()
			has = false
		default:
			cur.WriteRune(ch)
		}
	}
	if has || cur.Len() > 0 {
		words = append(words, cur.String())
	}
	return words
}

// stripWrappers removes leading env assignments and wrappers, with their
// options and the options' operands.
func stripWrappers(words []string, c *shellCmd) []string {
	wrapped := false
	for len(words) > 0 {
		w := words[0]
		if i := strings.Index(w, "="); i > 0 && !strings.ContainsAny(w[:i], "/-") {
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

// commands splits a Bash summary into its commands. The `# ` line that
// carries the request's description is cut off first. Only a cd joined to
// the next command by && carries its directory on; after any other
// separator the directory is unknown.
func commands(summary string) []shellCmd {
	// permissionSummary appends the description as a last `# ` line; an
	// inner comment line is skipped below, never a cut.
	if i := strings.LastIndex(summary, "\n"); i >= 0 && strings.HasPrefix(summary[i+1:], "# ") {
		summary = summary[:i]
	}
	var out []shellCmd
	cwd := ""
	for _, part := range splitCommands(summary) {
		if part.sep != "&&" && part.sep != "" && cwd != "" {
			cwd = cwdUnknown
		}
		if strings.HasPrefix(strings.TrimSpace(part.text), "#") {
			continue
		}
		words := splitWords(part.text)
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

// sub returns the arguments after `<prog> <subcommand>` of c, skipping
// git's global options; ok is false when c is not that command.
func (c shellCmd) sub(prog, subcommand string) (args []string, ok bool) {
	if c.w[0] != prog {
		return nil, false
	}
	i := 1
	for i < len(c.w) && strings.HasPrefix(c.w[i], "-") {
		if c.w[i] == "-C" || c.w[i] == "-c" {
			i++
		}
		i++
	}
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

// matchMainRef: a push to, a rebase onto, or a PR merge into the default
// branch. A plain `git push` with no refspec is not matched: its
// destination is unknown here, and parking every plain push would drop
// most push decisions (the live pre-push hook covers it).
func matchMainRef(r PermissionAsk) bool {
	return anyCmd(r, func(c shellCmd) bool {
		if c.w[0] == unresolved { // a wrapper around nothing readable: cannot be judged
			return true
		}
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
			if !ok || r.PRBase == nil {
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

func matchResetShared(r PermissionAsk) bool {
	return anyCmd(r, func(c shellCmd) bool {
		args, ok := c.sub("git", "reset")
		if !ok {
			return false
		}
		if !slices.Contains(args, "--hard") {
			return false
		}
		return slices.ContainsFunc(args, func(a string) bool {
			return strings.HasPrefix(a, "origin/") || strings.HasPrefix(a, "upstream/") || a == "@{u}" || a == "@{upstream}" || a == "FETCH_HEAD"
		})
	})
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
// inside only when a root is known and it does not climb out with "..".
func (r PermissionAsk) inside(p string, withWorkbench bool) bool {
	roots := r.roots(withWorkbench)
	if len(roots) == 0 {
		return false
	}
	if strings.HasPrefix(p, "~") || strings.Contains(p, "$") {
		return false
	}
	if !path.IsAbs(p) {
		return p != ".." && !strings.HasPrefix(p, "../") && !strings.Contains(p, "/../")
	}
	p = path.Clean(p)
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
			if !path.IsAbs(a) && c.cwd != "" {
				if c.cwd == cwdUnknown {
					return true
				}
				a = path.Join(c.cwd, a)
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
		// A JSON fallback summary is not a path.
		return p, true, p != "" && !json.Valid([]byte(p))
	case jsonPathTools[r.Tool]:
		var in struct {
			FilePath     string `json:"file_path"`
			NotebookPath string `json:"notebook_path"`
			Path         string `json:"path"`
		}
		if json.Unmarshal([]byte(r.Summary), &in) != nil {
			return "", true, false
		}
		p = cmp.Or(in.FilePath, in.NotebookPath, in.Path)
		return p, true, p != ""
	}
	return "", false, false
}

func matchStandingGrant(r PermissionAsk) bool {
	p, _, placed := filePath(r)
	return placed && strings.Contains(p, ".claude/settings")
}

// matchOutsideFolder: a file tool whose path is outside the workbench
// folder and worktrees, or cannot be placed. Bash is judged by the delete
// row only: absolute paths in ordinary reads would over-park.
func matchOutsideFolder(r PermissionAsk) bool {
	p, isFileTool, placed := filePath(r)
	return isFileTool && (!placed || !r.inside(p, true))
}
