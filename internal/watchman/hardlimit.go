package watchman

import (
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

// shellCmd is one simple command of a shell line: its words, quotes removed.
type shellCmd []string

// commands splits a Bash summary on ; && || | and newlines.
func commands(summary string) []shellCmd {
	line := strings.NewReplacer("&&", "\n", "||", "\n", ";", "\n", "|", "\n").Replace(summary)
	var out []shellCmd
	for _, part := range strings.Split(line, "\n") {
		var c shellCmd
		for _, w := range strings.Fields(part) {
			if w = strings.Trim(w, `"'`); w != "" {
				c = append(c, w)
			}
		}
		if len(c) > 0 {
			out = append(out, c)
		}
	}
	return out
}

// sub returns the arguments after `<prog> <subcommand>` of c, skipping
// git's global options; ok is false when c is not that command.
func (c shellCmd) sub(prog, subcommand string) (args []string, ok bool) {
	if c[0] != prog {
		return nil, false
	}
	i := 1
	for i < len(c) && strings.HasPrefix(c[i], "-") {
		if c[i] == "-C" || c[i] == "-c" {
			i++
		}
		i++
	}
	if i >= len(c) || c[i] != subcommand {
		return nil, false
	}
	return c[i+1:], true
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
		if args, ok := c.sub("gh", "pr"); ok && len(args) > 0 && args[0] == "merge" {
			pr := 0
			for _, a := range args[1:] {
				if n, err := strconv.Atoi(a); err == nil {
					pr = n
					break
				}
			}
			if pr == 0 || r.PRBase == nil {
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

func matchTestFlight(r PermissionAsk) bool {
	return anyCmd(r, func(c shellCmd) bool {
		for _, w := range c {
			switch {
			case w == "altool" || w == "iTMSTransporter" || w == "testflight" || w == "upload-app" || w == "upload-to-testflight":
				return true
			case w == "fastlane" && len(c) > 1 && (c[1] == "pilot" || c[1] == "deliver" || c[1] == "beta"):
				return true
			}
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
		if c[0] != "rm" {
			return false
		}
		for _, a := range c[1:] {
			if strings.HasPrefix(a, "-") {
				continue
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

func matchOutward(r PermissionAsk) bool {
	for _, t := range outwardTools {
		if strings.HasSuffix(r.Tool, t) {
			return true
		}
	}
	return anyCmd(r, func(c shellCmd) bool {
		for _, prog := range []string{"pr", "issue"} {
			if args, ok := c.sub("gh", prog); ok && len(args) > 0 {
				switch args[0] {
				case "comment", "create", "review", "close", "reopen", "edit":
					return true
				}
			}
		}
		return false
	})
}

var fileTools = map[string]bool{"Edit": true, "Write": true, "MultiEdit": true, "NotebookEdit": true}

// filePath is the first path-looking word of a file tool's summary.
func filePath(r PermissionAsk) (string, bool) {
	if !fileTools[r.Tool] {
		return "", false
	}
	for _, w := range strings.Fields(r.Summary) {
		w = strings.Trim(w, `"'`)
		if strings.ContainsAny(w, "/") || strings.HasPrefix(w, "~") {
			return w, true
		}
	}
	return "", false
}

func matchStandingGrant(r PermissionAsk) bool {
	p, ok := filePath(r)
	if !ok {
		return false
	}
	return strings.Contains(p, ".claude/settings")
}

func matchOutsideFolder(r PermissionAsk) bool {
	p, ok := filePath(r)
	return ok && !r.inside(p, true)
}
