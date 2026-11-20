package watchman

import (
	"cmp"
	"encoding/json"
	"maps"
	"path"
	"regexp"
	"slices"
	"strings"
	"unicode"

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
	// Branch is the session's branch when the request was read; nil = not
	// recorded (stored rows).
	Branch *BranchInfo
	// Cwd is the directory a live tool call starts in ("" = unknown, stored
	// rows). It places a shell command's relative paths only; it is no
	// directory change (a cd or -C in the command is).
	Cwd string
	// Lenient is the guard hook's mode (it runs on every tool call of an
	// armed session): a shape this reader cannot see into (a subshell, a
	// command substitution, a loop body, a background job...) parks only
	// when the command text also names a hard-limit action (limitWords),
	// and the merge backstop reads the command without its comments. The
	// twin and the backtest are strict (false): every hidden shape parks.
	Lenient bool
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
	// chdir: a wrapper option (env -C, sudo -D) runs the command in another
	// directory (a GIT_DIR-style assignment does not).
	chdir bool
}

// gitDirVars are the environment variables that point git at another
// repository or work tree.
var gitDirVars = []string{"GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR"}

// isGitDirAssignment reports NAME=value for a gitDirVars name.
func isGitDirAssignment(w string) bool {
	name, _, ok := strings.Cut(w, "=")
	return ok && slices.Contains(gitDirVars, name)
}

// chdirOpts are each wrapper's options that run its command in another
// directory (sudo's chroot too; sudo -C is close-from, not a directory).
// doas -C names a config file; it stays here, which only parks more.
var chdirOpts = map[string]map[string]bool{
	"env":  {"-C": true, "--chdir": true},
	"sudo": {"-D": true, "--chdir": true, "-R": true, "--chroot": true},
	"doas": {"-C": true},
}

const cwdUnknown = "?"

// wrappers maps each wrapper program to the options that take an operand
// (the macOS BSD and GNU man pages together).
var wrappers = map[string]map[string]bool{
	"sudo": {"-a": true, "-c": true, "-u": true, "-g": true, "-p": true, "-r": true, "-t": true, "-C": true, "-D": true, "-R": true, "-T": true, "-U": true,
		"--auth-type": true, "--login-class": true, "--user": true, "--group": true, "--prompt": true, "--role": true, "--type": true,
		"--close-from": true, "--chdir": true, "--chroot": true, "--command-timeout": true, "--other-user": true},
	"command": {},
	"time":    {"-f": true, "-o": true, "--format": true, "--output": true},
	"nohup":   {},
	"env": {"-a": true, "-u": true, "-C": true, "-S": true, "-L": true, "-P": true, "-U": true, "--argv0": true, "--unset": true, "--chdir": true,
		"--split-string": true},
	"exec": {"-a": true},
	"nice": {"-n": true, "--adjustment": true},
	// timeout's command follows a duration as well (stripWrappers).
	"timeout":    {"-s": true, "-k": true, "--signal": true, "--kill-after": true},
	"caffeinate": {"-t": true, "-w": true},
	"doas":       {"-a": true, "-u": true, "-C": true},
	"stdbuf":     {"-i": true, "-o": true, "-e": true, "--input": true, "--output": true, "--error": true},
	"xcrun":      {"--sdk": true, "-sdk": true, "--toolchain": true, "-toolchain": true},
	"xargs": {"-a": true, "-d": true, "-E": true, "-I": true, "-J": true, "-L": true, "-n": true, "-P": true, "-R": true, "-s": true, "-S": true,
		"--max-args": true, "--max-procs": true, "--max-chars": true, "--delimiter": true, "--arg-file": true, "--process-slot-var": true},
}

// unresolved stands for a command that cannot be read (a wrapper around
// nothing readable, an unterminated quote); it parks.
const unresolved = "<unresolved>"

// hiddenMark stands for a shape whose real command this reader cannot see
// into (hiddenText, hiddenShape): it parks a strict request, and a lenient
// one only with a hard-limit word in its command text (matchUnreadable).
const hiddenMark = "<hidden>"

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
		_, ok := wrappers[path.Base(w)]
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
			if opt == "--" { // the end of the wrapper's options
				break
			}
			name, takesNext, known := wrapperOption(opt, path.Base(w))
			if !known { // an option this reader cannot place: what follows may be its operand
				return []string{unresolved}
			}
			moved := chdirOpts[path.Base(w)][name]
			c.elsewhere, c.chdir = c.elsewhere || moved, c.chdir || moved
			if takesNext && len(words) > 0 {
				words = words[1:]
			}
		}
		if path.Base(w) == "timeout" && len(words) > 0 { // the duration
			words = words[1:]
		}
	}
	if wrapped {
		return []string{unresolved}
	}
	return nil
}

// wrapperFlags are the wrappers' options that take no operand — short
// ones, and long ones (xcrun's single-dash too); with the valued ones of
// wrappers and the optional ones of wrapperOptional they are every option
// this reader knows. Any other option cannot be placed and parks
// (wrapperOption).
var wrapperFlags = map[string][]string{
	"sudo": {"-A", "-B", "-b", "-E", "-e", "-H", "-i", "-K", "-k", "-l", "-N", "-n", "-P", "-S", "-s", "-V", "-v",
		"--preserve-env", "--non-interactive", "--login", "--shell", "--reset-timestamp", "--remove-timestamp", "--background",
		"--stdin", "--set-home", "--validate", "--list", "--edit", "--askpass", "--bell", "--preserve-groups", "--no-update"},
	"command": {"-p", "-V", "-v"},
	"env": {"-0", "-i", "-v", "--ignore-environment", "--null", "--debug", "--default-signal", "--ignore-signal", "--block-signal",
		"--list-signal-handling"},
	"exec":       {"-c", "-l"},
	"time":       {"-a", "-h", "-l", "-p", "-q", "-v", "-V", "--verbose", "--portability", "--append", "--quiet"},
	"timeout":    {"-f", "-p", "-v", "--preserve-status", "--foreground", "--verbose"},
	"caffeinate": {"-d", "-i", "-m", "-s", "-u"},
	"doas":       {"-L", "-n", "-s"},
	"xargs": {"-0", "-o", "-p", "-r", "-t", "-x", "--null", "--no-run-if-empty", "--verbose", "--interactive", "--exit", "--open-tty",
		"--show-limits"},
	"xcrun": {"-f", "-h", "-k", "-l", "-n", "-r", "-v", "-find", "-kill-cache", "-log", "-no-cache", "-run", "-verbose",
		"--find", "--run", "--verbose", "--no-cache", "--kill-cache", "--log", "--show-sdk-path", "--show-sdk-version",
		"--show-sdk-build-version", "--show-sdk-platform-path", "--show-sdk-platform-version"},
}

// wrapperOptional are the wrappers' options whose operand is optional: it
// is only ever attached (xargs -i{} or --replace={}), never the next word.
// A sudo -h or --host with nothing attached parks instead: sudo 1.8 takes
// the next word as the host, 1.9 shows its help.
var wrapperOptional = map[string][]string{
	"sudo":  {"-h", "--host"},
	"xargs": {"-e", "-i", "-l", "--eof", "--replace", "--max-lines"},
}

// niceAdjustment is nice's legacy numeric option: one word, no cluster.
var niceAdjustment = regexp.MustCompile(`^-(\+|-)?[0-9]+$`)

// wrapperOption reads one option word of wrapper prog: name is the option
// with an operand it sets ("" for a flag) and takesNext reports that its
// operand is the next word. An operand can be attached (-C/tmp,
// --chdir=/tmp) and a short valued or optional option can end a cluster of
// flags (env -iC/tmp, sudo -iu x, xargs -ti{}). A long option may be
// abbreviated to an unambiguous prefix, as getopt_long takes it (--chd is
// --chdir). known is false for an option that is none of prog's own — a
// long one neither known nor such a prefix, or a short letter in a cluster
// that is not one of its flags: its operand, if any, could be the next word.
func wrapperOption(opt, prog string) (name string, takesNext, known bool) {
	valued, flags, optional := wrappers[prog], wrapperFlags[prog], wrapperOptional[prog]
	if valued[opt] {
		return opt, true, true
	}
	if prog == "nice" && niceAdjustment.MatchString(opt) { // the legacy -N, -+N, --N
		return "", false, true
	}
	if strings.HasPrefix(opt, "--") {
		long, _, attached := strings.Cut(opt, "=")
		var hits []string
		for _, cand := range slices.Concat(slices.Collect(maps.Keys(valued)), flags, optional) {
			if cand == long {
				hits = []string{cand}
				break
			}
			if strings.HasPrefix(cand, "--") && strings.HasPrefix(cand, long) {
				hits = append(hits, cand)
			}
		}
		if len(hits) != 1 { // unknown, or an ambiguous prefix
			return "", false, false
		}
		match := hits[0]
		switch {
		case valued[match]:
			return match, !attached, true
		case slices.Contains(optional, match):
			return match, false, !(prog == "sudo" && !attached)
		}
		return "", false, true
	}
	if slices.Contains(flags, opt) { // a single-dash long flag (xcrun -run)
		return "", false, true
	}
	for i := 1; i < len(opt); i++ {
		short := "-" + opt[i:i+1]
		switch {
		case valued[short]:
			return short, i == len(opt)-1, true
		case slices.Contains(optional, short): // the rest of the word is its operand
			return short, false, !(prog == "sudo" && i == len(opt)-1)
		case !slices.Contains(flags, short):
			return "", false, false
		}
	}
	return "", false, true
}

// commands splits a Bash summary into its commands. The request's
// description follows as `# ` comment lines (cmd.permissionSummary), which
// splitCommands drops with every other comment. Only a cd joined to the
// next command by && carries its directory on; after any other separator
// the directory is unknown.
//
// A shell that runs a string (bash/sh/zsh/dash/ksh -c, eval) is a wrapper:
// its one literal inner string is parsed as commands in its place (an eval
// carries a cd on); anything else — more words, a $ or a backtick in the
// string, a source or . of a file, nesting past maxShellDepth — cannot be
// read and parks.
func commands(summary string) []shellCmd {
	out, _ := commandsIn(summary, "", 0)
	return out
}

// maxShellDepth bounds shells nested in shells.
const maxShellDepth = 3

// shells are the programs whose -c option runs a string.
var shells = map[string]bool{"bash": true, "sh": true, "zsh": true, "dash": true, "ksh": true}

// shellValued are the shell options that take an operand.
var shellValued = map[string]bool{"-o": true, "-O": true, "+o": true, "+O": true, "--rcfile": true, "--init-file": true}

// isShellDashC reports a shell's -c option, alone or among short options.
func isShellDashC(w string) bool {
	return strings.HasPrefix(w, "-") && !strings.HasPrefix(w, "--") && strings.Contains(w, "c")
}

// shellInner returns the string words run as commands: a shell's -c
// string or eval's argument. isShell is false when words do not run a
// string; inner is "" when they do but it cannot be read (always for
// source and .). hidden marks the unreadable cases that are a hidden shape
// (a file sourced, a $ or backtick in the string) rather than a malformed
// call.
func shellInner(words []string) (inner string, isShell, hidden bool) {
	var rest []string
	switch prog := words[0]; {
	case prog == "eval":
		rest = words[1:]
	case prog == "source" || prog == ".":
		return "", true, true
	case shells[prog]:
		i, dashC := 1, false
		for ; i < len(words) && (strings.HasPrefix(words[i], "-") || strings.HasPrefix(words[i], "+")) && words[i] != "--"; i++ {
			if shellValued[words[i]] {
				i++ // the option's operand
				continue
			}
			dashC = dashC || isShellDashC(words[i])
		}
		if !dashC {
			// A -c the options above did not reach cannot be read.
			return "", slices.ContainsFunc(words[1:], isShellDashC), false
		}
		rest = words[min(i, len(words)):]
	default:
		return "", false, false
	}
	switch {
	case len(rest) != 1:
		return "", true, false
	case strings.ContainsAny(rest[0], "$`"):
		return "", true, true
	}
	return rest[0], true, false
}

// compoundStarts are the first words of shell syntax this reader does not
// follow (subshells, groups, negation, the bodies of if/for/while).
var compoundStarts = map[string]bool{"(": true, "{": true, "!": true, "then": true, "do": true, "else": true, "elif": true, "function": true}

// hiddenShape reports a command whose real command this reader cannot
// see: a shell reading its commands from a pipe (a script operand is no
// such thing), a gh alias definition, or a gh api call whose body comes
// from a file. hiddenText covers the shell syntax.
func hiddenShape(c shellCmd, sep string) bool {
	if sep == "|" && shells[c.w[0]] {
		if _, isShell, _ := shellInner(c.w); !isShell && readsStdin(c.w) {
			return true
		}
	}
	if verb, ok := c.ghCmd("alias"); ok && verb == "set" {
		return true
	}
	if args, ok := c.sub("gh", "api"); ok {
		return slices.ContainsFunc(args, func(a string) bool {
			return strings.HasPrefix(a, "@") || strings.Contains(a, "=@") || a == "--input" || strings.HasPrefix(a, "--input=")
		})
	}
	return false
}

// readsStdin reports a shell call that takes its commands from stdin: no
// script operand after its options (operands of -o, --rcfile... skipped),
// or -s, which reads stdin whatever follows.
func readsStdin(w []string) bool {
	for i := 1; i < len(w); i++ {
		a := w[i]
		switch {
		case a == "--":
			return i+1 >= len(w)
		case shellValued[a]:
			i++
		case strings.HasPrefix(a, "-") && !strings.HasPrefix(a, "--") && strings.Contains(a, "s"):
			return true
		case strings.HasPrefix(a, "-") || strings.HasPrefix(a, "+"):
		default:
			return false // a script operand
		}
	}
	return true
}

// hiddenText reports shell syntax in one command's raw text (quotes kept)
// that this reader does not follow: a compound start (a subshell, a group,
// negation, an if/for/while body) as the first word, or — outside single
// quotes, where everything is literal — a command substitution ($( or a
// backtick, also inside double quotes), a here-string <<< or a lone &
// sending a job to the background (not &&, 2>&1, &> or >&2, and not inside
// any quotes). It reads the text before the wrappers are stripped, so an
// assignment's substitution (x=$(...)) is seen too.
func hiddenText(text string) bool {
	if f := strings.Fields(text); len(f) > 0 && (compoundStarts[f[0]] || strings.HasPrefix(f[0], "(") ||
		strings.Contains(f[0], "()") || (len(f) > 1 && strings.HasPrefix(f[1], "()"))) {
		return true // a subshell, a group, a body, a function definition
	}
	var quote byte
	for i := 0; i < len(text); i++ {
		ch := text[i]
		switch {
		case quote == '\'':
			if ch == '\'' {
				quote = 0
			}
			continue
		case ch == '\\':
			i++ // escaped: literal
			continue
		case ch == '`' || (ch == '$' && i+1 < len(text) && text[i+1] == '('):
			return true
		case quote == '"':
			if ch == '"' {
				quote = 0
			}
			continue
		case ch == '\'' || ch == '"':
			quote = ch
			continue
		case strings.HasPrefix(text[i:], "<<<"):
			return true
		case ch == '&':
			switch {
			case i+1 < len(text) && text[i+1] == '&':
				i++
			case i+1 < len(text) && text[i+1] == '>', i > 0 && (text[i-1] == '>' || text[i-1] == '<'):
			default:
				return true
			}
		}
	}
	return false
}

// commandsIn is commands for a string run from directory cwd at shell
// nesting depth; it also returns the directory it ends in.
func commandsIn(summary, cwd string, depth int) ([]shellCmd, string) {
	var out []shellCmd
	for _, part := range splitCommands(summary) {
		if part.sep != "&&" && part.sep != "" && cwd != "" {
			cwd = cwdUnknown
		}
		words, ok := splitWords(part.text)
		if !ok { // an unterminated quote: unreadable, so it parks
			out = append(out, shellCmd{w: []string{unresolved}, cwd: cwd})
			continue
		}
		// A hidden shape is marked and the command still read as it stands.
		if hiddenText(part.text) {
			out = append(out, shellCmd{w: []string{hiddenMark}, cwd: cwd})
		}
		c := shellCmd{cwd: cwd}
		words = stripWrappers(words, &c)
		if len(words) == 0 {
			continue
		}
		if c.chdir { // env -C, sudo -D...: the command runs elsewhere
			c.cwd = cwdUnknown
		}
		if strings.HasPrefix(words[0], "$") { // the program is a variable's value
			out = append(out, shellCmd{w: []string{hiddenMark}, cwd: cwd})
		}
		words[0] = path.Base(words[0])
		c.w = words
		if hiddenShape(c, part.sep) {
			out = append(out, shellCmd{w: []string{hiddenMark}, cwd: cwd})
		}
		if inner, isShell, hidden := shellInner(words); isShell {
			if inner == "" || c.xargs || depth >= maxShellDepth {
				mark := unresolved
				if hidden && !c.xargs {
					mark = hiddenMark
				}
				out = append(out, shellCmd{w: []string{mark}, cwd: cwd})
				continue
			}
			sub, subCwd := commandsIn(inner, c.cwd, depth+1)
			for _, ic := range sub {
				ic.elsewhere = ic.elsewhere || c.elsewhere
				out = append(out, ic)
			}
			if words[0] == "eval" { // eval runs in this shell: its cd stays
				cwd = subCwd
			}
			continue
		}
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
	return out, cwd
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

// ghValued are gh's options that take an operand when not attached; any
// option may precede the command (cobra accepts inherited flags there).
var ghValued = map[string]bool{"-R": true, "--repo": true, "--hostname": true}

// ghGlobals skips the options before gh's command, with their operands, so
// a flag's value is never read as the command; it returns the command's
// index (1 when no option precedes it).
func ghGlobals(w []string) int { return 1 + skipGhOptions(w[1:]) }

// skipGhOptions returns the index of the first word of args that is no
// gh option nor an option's operand.
func skipGhOptions(args []string) int {
	i := 0
	for i < len(args) && strings.HasPrefix(args[i], "-") {
		name, _, attached := strings.Cut(args[i], "=")
		if !attached && ghValued[name] {
			i++
		}
		i++
	}
	return i
}

// ghCmd returns the verb of `gh [options] <group> [options] <verb> ...`;
// ok is false when c is not such a command.
func (c shellCmd) ghCmd(group string) (verb string, ok bool) {
	rest, ok := c.sub("gh", group)
	if !ok {
		return "", false
	}
	i := skipGhOptions(rest)
	if i >= len(rest) {
		return "", false
	}
	return rest[i], true
}

// sub returns the arguments after `<prog> <subcommand>` of c, skipping
// the program's global options (git's, or gh's); ok is false when c is not
// that command.
func (c shellCmd) sub(prog, subcommand string) (args []string, ok bool) {
	if c.w[0] != prog {
		return nil, false
	}
	i, _ := gitGlobals(c.w)
	if prog == "gh" {
		i = ghGlobals(c.w)
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

// matchUnreadable: a command that cannot be read, so cannot be judged.
// A hidden shape parks a strict request, and a lenient one (the guard) only
// when its command text names a hard-limit action.
func matchUnreadable(r PermissionAsk) bool {
	return anyCmd(r, func(c shellCmd) bool {
		return c.w[0] == unresolved || (c.w[0] == hiddenMark && (!r.Lenient || lenientLimitHit(r.Summary)))
	})
}

// lenientLimitHit reports a hard-limit word in the guard's scan text, or
// an rm of an outside path read with its quotes and escapes removed.
func lenientLimitHit(summary string) bool {
	text := lenientScanText(summary)
	return limitWords.MatchString(text) || rmOutside(text)
}

// limitWords are the words of the actions the hard-limit table covers (a
// merge, push, tag, release, send-pack, reset, forced branch move,
// update-ref, rm -r/-f, an upload, a message, comment, issue, gh api call
// or Slack post others see): a hidden shape in the guard's mode parks only with one
// of them in sight.
var limitWords = regexp.MustCompile(`(?i)(^|[^a-z0-9_])(merges?|mergepullrequest|automerge|push|tags?|release|send-pack|reset|rebase|update-ref|altool|testflight|itmstransporter|pilot|upload_to_testflight|mail|mailx|sendmail|mutt|comment|review)([^a-z0-9_]|$)|hooks\.slack\.com|slack\.com/api/chat\.|gh\s+api|issue\s+create|(issue|pr)\s+close|rm\s+-[a-z]*[rf]|(^|[^a-z0-9_])rm(\s+-\S+)*\s+['"]?(/|\.\.([/\s'";|&)]|$)|~)|(branch|checkout|switch)\s+-[a-z]*[fdmcb]`)

// lenientScanText is what the guard's mode scans for limitWords and its
// merge backstop: the command text (comments and description lines
// dropped by splitCommands) with each commit-message idiom blanked — a
// "$(cat <<'D' … D)" argument (quoted delimiter, so its body is literal
// text) of a message-taking command (heredocArgsBlanked) — but only when
// every part of the request is on the plain allowlist (plainPart), so
// nothing in it can run the body. Otherwise the text unblanked.
func lenientScanText(summary string) string {
	parts := splitCommands(summary)
	blanked := make([]string, len(parts))
	found := false
	for i, p := range parts {
		var ok bool
		blanked[i], ok = heredocArgsBlanked(p)
		found = found || ok
	}
	useBlanked := found
	for i := 0; useBlanked && i < len(parts); i++ {
		useBlanked = plainPart(blanked[i])
	}
	var out strings.Builder
	for i, p := range parts {
		if i > 0 {
			out.WriteByte('\n')
		}
		if useBlanked {
			out.WriteString(blanked[i])
		} else {
			out.WriteString(p.text)
		}
	}
	return out.String()
}

// plainPart reports one part (its heredoc bodies blanked) that cannot run
// a blanked body: no hidden shape, no output redirect, no ( outside quotes
// (a zsh glob qualifier *(e:…:) or (+fn) runs code), and the command —
// written as is, no wrapper, assignment or path in front — is a plain
// message taker (plainMessageTaker) or on the allowlist (plainCommand).
func plainPart(text string) bool {
	if strings.TrimSpace(text) == "" {
		return true
	}
	if hiddenText(text) || unquotedAny(text, ">(") {
		return false
	}
	words, ok := splitWords(text)
	if !ok || len(words) == 0 {
		return ok
	}
	return plainMessageTaker(words) || plainCommand(words)
}

// unquotedAny reports any byte of chars outside quotes (not escaped): a >
// is an output redirect, a ( a glob qualifier or subshell.
func unquotedAny(text, chars string) bool {
	var quote byte
	for i := 0; i < len(text); i++ {
		ch := text[i]
		switch {
		case quote == '\'':
			if ch == '\'' {
				quote = 0
			}
		case ch == '\\':
			i++
		case quote == '"':
			if ch == '"' {
				quote = 0
			}
		case ch == '\'' || ch == '"':
			quote = ch
		case strings.IndexByte(chars, ch) >= 0:
			return true
		}
	}
	return false
}

// plainMessageTaker: git commit or an annotated git tag with no git global
// option and no -c/-C/--exec-style option, or gh pr|issue|release
// create|edit, each written directly.
func plainMessageTaker(w []string) bool {
	if len(w) < 2 {
		return false
	}
	runsThings := func(a string) bool {
		return a == "-c" || a == "-C" || strings.HasPrefix(a, "--exec") || strings.HasPrefix(a, "--template")
	}
	switch {
	case w[0] == "git" && (w[1] == "commit" || w[1] == "tag"):
		return !slices.ContainsFunc(w[2:], runsThings)
	case w[0] == "gh" && len(w) > 2 && (w[1] == "pr" || w[1] == "issue" || w[1] == "release"):
		return w[2] == "create" || w[2] == "edit"
	}
	return false
}

// plainCommand is the allowlist of commands that may stand beside a
// blanked message: cd <dir>; git add|status|diff|log|show without
// --output, --ext-diff, --textconv or -c; go test|build|vet without
// -exec, -toolexec or -o; gofmt -l; make with targets only; swift
// build|test; ls, pwd, true, echo. Each written directly.
func plainCommand(w []string) bool {
	args := w[1:]
	noneOf := func(bad ...string) bool {
		return !slices.ContainsFunc(args, func(a string) bool {
			for _, b := range bad {
				if a == b || strings.HasPrefix(a, b+"=") {
					return true
				}
			}
			return false
		})
	}
	switch w[0] {
	case "cd":
		return len(args) == 1
	case "ls", "pwd", "true", "echo":
		return true
	case "git":
		return len(args) > 0 && slices.Contains([]string{"add", "status", "diff", "log", "show"}, args[0]) &&
			noneOf("--output", "--ext-diff", "--textconv", "-c")
	case "go":
		for i, a := range args { // go takes --flag as -flag
			if strings.HasPrefix(a, "--") {
				args[i] = a[1:]
			}
		}
		return len(args) > 0 && slices.Contains([]string{"test", "build", "vet"}, args[0]) &&
			noneOf("-exec", "-toolexec", "-o", "-vettool")
	case "gofmt":
		return slices.Contains(args, "-l") && noneOf("-w")
	case "make":
		return !slices.ContainsFunc(args, func(a string) bool { return strings.HasPrefix(a, "-") || strings.Contains(a, "=") })
	case "swift":
		return len(args) > 0 && (args[0] == "build" || args[0] == "test")
	}
	return false
}

// rmOutside reports an rm anywhere in a part's words — at command
// position or not (a then-body, a group, behind a background &, even an
// echo's argument: that false park is accepted, it fails closed) — whose
// following operand, quotes and escapes removed, is an absolute, home or
// parent path (.. as a whole segment: ..cache is local). A & glued inside
// a word (sleep 1&rm) splits it.
func rmOutside(text string) bool {
	for _, p := range splitCommands(text) {
		raw, ok := splitWords(p.text)
		if !ok {
			continue
		}
		var words []string
		for _, w := range raw {
			for i, piece := range strings.Split(w, "&") {
				if i > 0 {
					words = append(words, "&")
				}
				if piece != "" {
					words = append(words, piece)
				}
			}
		}
		for i, w := range words {
			if path.Base(w) != "rm" {
				continue
			}
			for _, a := range words[i+1:] {
				if a == "&" || a == ";" || a == "|" {
					break
				}
				if strings.HasPrefix(a, "/") || strings.HasPrefix(a, "~") || a == ".." || strings.HasPrefix(a, "../") {
					return true
				}
			}
		}
	}
	return false
}

// messageTaker reports a command whose heredoc argument is a message: git
// commit, an annotated git tag (-a/-m), gh pr|issue create|edit, gh release
// create|edit. Their own rows (a tag, a release) still run on the command.
func messageTaker(c shellCmd) bool {
	if _, ok := c.sub("git", "commit"); ok {
		return true
	}
	if args, ok := c.sub("git", "tag"); ok {
		flags, _ := splitFlags(args)
		return flags["-a"] || flags["-m"] || flags["--annotate"] || flags["--message"]
	}
	for _, group := range []string{"pr", "issue", "release"} {
		if verb, ok := c.ghCmd(group); ok && (verb == "create" || verb == "edit") {
			return true
		}
	}
	return false
}

// heredocArgsBlanked returns part's text with every quoted-heredoc
// argument of a message-taking command blanked to "" (ok true): the
// argument is a whole double-quoted word that is not the first. Otherwise
// the text as it is.
func heredocArgsBlanked(part commandPart) (string, bool) {
	words, ok := splitWords(part.text)
	if !ok {
		return part.text, false
	}
	var c shellCmd
	words = stripWrappers(words, &c)
	if len(words) < 2 || c.xargs || strings.HasPrefix(words[0], "$") {
		return part.text, false
	}
	c.w = append([]string{path.Base(words[0])}, words[1:]...)
	if !messageTaker(c) {
		return part.text, false
	}
	text, blanked := part.text, false
	for _, w := range words[1:] {
		if !isQuotedHeredocCat(w) {
			continue
		}
		quoted := `"` + w + `"`
		if !strings.Contains(text, quoted) {
			return part.text, false
		}
		text, blanked = strings.Replace(text, quoted, `""`, 1), true
	}
	if !blanked || hiddenText(text) || hiddenShape(c, part.sep) {
		return part.text, false
	}
	return text, true
}

// heredocDelim is a heredoc delimiter word.
var heredocDelim = regexp.MustCompile(`^[A-Za-z0-9_]+$`)

// isQuotedHeredocCat reports a word that is exactly $(cat <<'D'\n…\nD\n)
// with a quoted delimiter ('D', "D" or \D): its body is literal text.
func isQuotedHeredocCat(w string) bool {
	rest, ok := strings.CutPrefix(w, "$(cat <<")
	if !ok {
		return false
	}
	rest = strings.TrimLeft(rest, " ")
	var delim string
	switch {
	case strings.HasPrefix(rest, "'") || strings.HasPrefix(rest, `"`):
		end := strings.IndexByte(rest[1:], rest[0])
		if end < 0 {
			return false
		}
		delim, rest = rest[1:1+end], rest[2+end:]
	case strings.HasPrefix(rest, `\`):
		nl := strings.IndexByte(rest, '\n')
		if nl < 0 {
			return false
		}
		delim, rest = rest[1:nl], rest[nl:]
	default:
		return false
	}
	if !heredocDelim.MatchString(delim) || !strings.HasPrefix(rest, "\n") {
		return false
	}
	lines := strings.Split(rest[1:], "\n")
	for i, l := range lines {
		if l == delim {
			return strings.Join(lines[i+1:], "\n") == ")"
		}
	}
	return false
}

// mergeWords and mergeTools are the backstop's two halves: a merge word
// (merge, merges, mergePullRequest, an auto-merge) and a tool that can
// merge a pull request.
var (
	mergeWords = regexp.MustCompile(`(?i)(^|[^a-z])merges?([^a-z]|$)|mergepullrequest|automerge`)
	mergeTools = regexp.MustCompile(`(?i)(^|[^a-z])(gh|hub|api|graphql|pulls|curl)([^a-z]|$)`)
)

// mergeBackstop is the coarse check after the parser (fail closed): a
// shell request whose text has a merge word and a tool that can merge a
// pull request parks, however the command is shaped. A strict request is
// read whole, comments included; a lenient one (the guard) as its word
// scan reads it (lenientScanText: no comments, a plain heredoc argument
// blanked).
func mergeBackstop(r PermissionAsk) bool {
	if !isBash(r) {
		return false
	}
	text := r.Summary
	if r.Lenient { // comments dropped, the plain heredoc idiom blanked
		text = lenientScanText(text)
	}
	return mergeWords.MatchString(text) && mergeTools.MatchString(text)
}

// prMergePath is a GitHub REST path that merges a pull request.
var prMergePath = regexp.MustCompile(`(?i)/pulls/[^/\s]+/merge\b`)

// isPRMerge reports a command that merges a pull request, in any form:
// gh pr merge (options anywhere), hub merge, a call on a .../pulls/<n>/merge
// path (gh api, curl...) or the GraphQL mergePullRequest mutation.
func isPRMerge(c shellCmd) bool {
	if verb, ok := c.ghCmd("pr"); ok && verb == "merge" {
		return true
	}
	if _, ok := c.sub("hub", "merge"); ok {
		return true
	}
	return slices.ContainsFunc(c.w, func(w string) bool {
		return prMergePath.MatchString(w) || strings.Contains(w, "mergePullRequest")
	})
}

// matchMainRef: a push to, a rebase onto the default branch, or any PR
// merge — in phase 2 merging is the owner's whatever the base: a base read
// can be pointed at another repository too many ways (-R, GH_REPO, a cd,
// aliases) to be trusted. A plain `git push` with no refspec is not
// matched: its destination is unknown here, and parking every plain push
// would drop most push decisions (the live pre-push hook covers it).
func matchMainRef(r PermissionAsk) bool {
	if mergeBackstop(r) {
		return true
	}
	return anyCmd(r, func(c shellCmd) bool {
		if isPRMerge(c) {
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
		verb, ok := c.ghCmd("release")
		return ok && verb != "list" && verb != "view" && verb != "download"
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

// branchVerbs are the git commands whose hard-limit rows read the
// session's branch or its shared branches.
var branchVerbs = []string{"reset", "branch", "update-ref", "checkout", "switch", "push", "rebase"}

// BranchDependent reports a shell request that can hit a row reading the
// live branch, the shared branches or a PR's base (a ref-moving git
// command or a push): only such a request needs those reads.
func BranchDependent(r PermissionAsk) bool {
	return anyCmd(r, func(c shellCmd) bool {
		for _, v := range branchVerbs {
			if _, ok := c.sub("git", v); ok {
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
	if verb, ok := c.ghCmd("pr"); ok && verb == "checkout" {
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

// outwardTools are the MCP tools whose effect other people see, matched by
// suffix whatever the server is called (claude.ai connectors, a local
// server): Slack messages, reactions and canvases, Jira issues and
// comments, Confluence pages and comments.
var outwardTools = []string{
	"send_slack_message", "slack_send_message", "slack_send_message_draft", "slack_schedule_message", "slack_add_reaction",
	"slack_create_canvas", "slack_update_canvas",
	"addCommentToJiraIssue", "createJiraIssue", "editJiraIssue", "transitionJiraIssue",
	"createConfluencePage", "updateConfluencePage", "createConfluenceFooterComment", "createConfluenceInlineComment",
}

// trackerServers are fragments of MCP server names for shared trackers and
// wikis: a tool of theirs whose name holds a write verb (trackerWriteVerbs)
// and does not start with a read verb changes what others see. The
// workbench's own server (add_comment stays inside it) is none of them.
var (
	trackerServers    = []string{"atlassian", "jira", "confluence", "linear", "github"}
	trackerWriteVerbs = []string{"create", "update", "add", "edit", "transition", "save", "post", "submit", "write", "delete", "merge", "push", "comment", "reply", "publish"}
	trackerReadVerbs  = []string{"get", "list", "search", "fetch", "read", "lookup"}
)

// mailTools are fragments of MCP mail-sending tool names.
var mailTools = []string{"send_email", "send_mail", "email_send", "mail_send", "send_draft", "draft_send"}

// slackPost: a curl or wget argument that posts to Slack — an incoming
// webhook, a chat.* write method, or a variable named like a webhook URL.
var slackPost = regexp.MustCompile(`(?i)hooks\.slack\.com|slack\.com/api/chat\.(postmessage|update|schedulemessage|postephemeral|memessage|delete)|\$\{?[a-z0-9_]*webhook`)

func matchOutward(r PermissionAsk) bool {
	for _, t := range outwardTools {
		if strings.HasSuffix(r.Tool, t) {
			return true
		}
	}
	if trackerWrite(r.Tool) {
		return true
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
		case "curl", "wget":
			return slices.ContainsFunc(c.w[1:], slackPost.MatchString)
		}
		if verb, ok := c.ghCmd("pr"); ok && (verb == "comment" || verb == "review" || closeComment(c, verb)) {
			return true
		}
		if verb, ok := c.ghCmd("issue"); ok && (verb == "comment" || verb == "create" || closeComment(c, verb)) {
			return true
		}
		args, ok := c.sub("gh", "api")
		return ok && ghAPIWrite(args)
	})
}

// trackerWrite: an MCP tool of a trackerServers server whose name words
// (snake_case or camelCase) hold a write verb, unless the first is a read
// verb (getConfluenceCommentChildren reads).
func trackerWrite(tool string) bool {
	rest, ok := strings.CutPrefix(tool, "mcp__")
	i := strings.LastIndex(rest, "__")
	if !ok || i < 0 {
		return false
	}
	server, name := strings.ToLower(rest[:i]), rest[i+2:]
	if !slices.ContainsFunc(trackerServers, func(f string) bool { return strings.Contains(server, f) }) {
		return false
	}
	words := nameWords(name)
	if len(words) == 0 || slices.Contains(trackerReadVerbs, words[0]) {
		return false
	}
	return slices.ContainsFunc(words, func(w string) bool { return slices.Contains(trackerWriteVerbs, w) })
}

// nameWords splits a tool name at _, - and lower-to-upper case changes,
// lower-cased: addCommentToJiraIssue → add comment to jira issue.
func nameWords(name string) []string {
	var words []string
	var cur []rune
	flush := func() {
		if len(cur) > 0 {
			words = append(words, strings.ToLower(string(cur)))
			cur = cur[:0]
		}
	}
	prevLower := false
	for _, ch := range name {
		switch {
		case ch == '_' || ch == '-' || ch == '.':
			flush()
			prevLower = false
			continue
		case unicode.IsUpper(ch) && prevLower:
			flush()
		}
		cur = append(cur, ch)
		prevLower = unicode.IsLower(ch) || unicode.IsDigit(ch)
	}
	flush()
	return words
}

// closeComment: gh pr|issue close|reopen with a comment (-c, --comment, or
// c in a short-option cluster such as -dc).
func closeComment(c shellCmd, verb string) bool {
	if verb != "close" && verb != "reopen" {
		return false
	}
	return slices.ContainsFunc(c.w, func(a string) bool {
		if a == "--comment" || strings.HasPrefix(a, "--comment=") {
			return true
		}
		return strings.HasPrefix(a, "-") && !strings.HasPrefix(a, "--") && strings.Contains(a[1:], "c")
	})
}

// ghAPIValued are gh api's options that take a value; -f/-F/--field/
// --raw-field/--input send one (gh then POSTs) and -X/--method set the
// method. ghAPIShortValued are their one-letter forms.
var (
	ghAPIValued      = map[string]bool{"--method": true, "--field": true, "--raw-field": true, "--input": true, "--header": true, "--jq": true, "--template": true, "--hostname": true, "--cache": true, "--preview": true}
	ghAPIShortValued = "XfFHpqt"
)

// ghAPIWrite: a gh api call that is no read — a method other than GET, or
// any field or input (gh POSTs them). The graphql endpoint always POSTs;
// it writes only with a mutation in the call.
func ghAPIWrite(args []string) bool {
	var method, endpoint string
	fields := false
	set := func(opt, val string) {
		switch opt {
		case "--method", "X":
			method = val
		case "--field", "--raw-field", "--input", "f", "F":
			fields = true
		}
	}
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--":
			if endpoint == "" && i+1 < len(args) {
				endpoint = args[i+1]
			}
			i = len(args)
		case strings.HasPrefix(a, "--"):
			name, val, attached := strings.Cut(a, "=")
			if !attached && ghAPIValued[name] && i+1 < len(args) {
				i++
				val = args[i]
			}
			set(name, val)
		case strings.HasPrefix(a, "-") && len(a) > 1:
			for j := 1; j < len(a); j++ {
				opt := string(a[j])
				if !strings.Contains(ghAPIShortValued, opt) {
					continue
				}
				val := a[j+1:]
				if val == "" && i+1 < len(args) {
					i++
					val = args[i]
				}
				set(opt, val)
				break
			}
		case endpoint == "":
			endpoint = a
		}
	}
	if strings.TrimPrefix(endpoint, "/") == "graphql" {
		return slices.ContainsFunc(args, func(a string) bool { return strings.Contains(strings.ToLower(a), "mutation") })
	}
	return fields || (method != "" && !strings.EqualFold(method, "GET"))
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
