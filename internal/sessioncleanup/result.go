package sessioncleanup

import (
	"fmt"
	"strings"
)

// Kind is an item's kind.
type Kind string

const (
	KindWorktree Kind = "worktree"
	KindBranch   Kind = "branch"
	KindProcess  Kind = "process"
	KindLsreg    Kind = "lsreg"
)

// Item actions.
const (
	ActionRemove = "remove"
	ActionKeep   = "keep"
)

// Item is one thing the plan would remove or keeps, with why (spec §4.1).
type Item struct {
	Key        string     `json:"key"`
	Kind       Kind       `json:"kind"`
	Name       string     `json:"name"`
	Branch     string     `json:"branch"`
	Bytes      int64      `json:"bytes"`
	BytesKnown bool       `json:"bytes_known"`
	Action     string     `json:"action"`
	Reason     string     `json:"reason"`
	Detail     string     `json:"detail"`
	Done       bool       `json:"done"`
	Error      string     `json:"error"`
	Owner      *OwnerHint `json:"owner,omitempty"` // sweep only
}

// OwnerHint is the sweep's guess at whose an item is: the session that
// recorded it, or Unknown (a pre-feature or deleted session).
type OwnerHint struct {
	SessionID  int64  `json:"session_id,omitempty"`
	Title      string `json:"title,omitempty"`
	LastActive string `json:"last_active,omitempty"` // RFC 3339
	Unknown    bool   `json:"unknown,omitempty"`
}

// Plan is what an evaluation found. Items is never nil.
type Plan struct {
	Items         []Item `json:"items"`
	DefaultBranch string `json:"default_branch"`
}

// reasonPhrases are the summary's words for the reason codes; a code
// without one reads as itself with spaces.
var reasonPhrases = map[string]string{
	ReasonMainFolder:           "the main folder",
	ReasonWorkbenchFolder:      "a workbench folder",
	ReasonLocked:               "locked",
	ReasonUncommittedChanges:   "uncommitted changes",
	ReasonProcessRunning:       "a process is running in it",
	ReasonProcessUnknown:       "a process could not be checked",
	ReasonSessionInIt:          "another session works in it",
	ReasonYouAreInIt:           "you are in it",
	ReasonUnpushedCommits:      "unpushed commits",
	ReasonOperationInProgress:  "an operation in progress",
	ReasonDefaultBranch:        "the default branch",
	ReasonDefaultBranchUnknown: "default branch unknown",
	ReasonCheckedOut:           "checked out",
	ReasonClaudeHome:           "under ~/.claude",
	ReasonNotAWorktree:         "not a worktree",
	ReasonNotABranch:           "not a branch",
	ReasonSessionRecent:        "its session was active recently",
	ReasonCheckFailed:          "could not be checked",
	ReasonContainsWorktree:     "another worktree is inside",
	ReasonNotThisSession:       "not this session's",
	ReasonExistedBeforeSession: "existed before the session",
	ReasonCreatedUnknown:       "creation time unknown",
	ReasonGitRefused:           "git refused",
	ReasonMoved:                "moved since the check",
	ReasonNotSelected:          "not selected",
	ReasonNotInPlan:            "not in the plan",
	ReasonNotAttempted:         "not attempted after a failure",
	ReasonBundleUnreadable:     "its bundle could not be checked",
}

// Summarize is one English line for the finish summary and the session
// report: what was removed (done items), what is still to remove (a plan),
// what was kept and why, and how many items failed. Only worktrees and
// branches are counted as kept; sizes are "~" (APFS clones share blocks).
func Summarize(items []Item) string {
	var parts []string
	if s := countPart(items, func(it Item) bool { return it.Done }); s != "" {
		parts = append(parts, s+" removed"+sizePart(items, func(it Item) bool { return it.Done }))
	}
	pending := func(it Item) bool { return it.Action == ActionRemove && !it.Done && it.Error == "" }
	if s := countPart(items, pending); s != "" {
		parts = append(parts, s+" to remove"+sizePart(items, pending))
	}
	if s := keptPart(items); s != "" {
		parts = append(parts, s)
	}
	if n := countWhere(items, func(it Item) bool { return it.Error != "" }); n > 0 {
		parts = append(parts, plural(n, "error", "errors"))
	}
	if len(parts) == 0 {
		return "nothing to clean up"
	}
	return strings.Join(parts, "; ")
}

var kindNouns = []struct {
	kind        Kind
	one, plural string
}{
	{KindWorktree, "worktree", "worktrees"},
	{KindBranch, "branch", "branches"},
	{KindProcess, "process", "processes"},
	{KindLsreg, "LaunchServices entry", "LaunchServices entries"},
}

// countPart is "2 worktrees, 4 branches" over the items match takes.
func countPart(items []Item, match func(Item) bool) string {
	var parts []string
	for _, k := range kindNouns {
		n := countWhere(items, func(it Item) bool { return it.Kind == k.kind && match(it) })
		if n > 0 {
			parts = append(parts, plural(n, k.one, k.plural))
		}
	}
	return strings.Join(parts, ", ")
}

func countWhere(items []Item, match func(Item) bool) int {
	n := 0
	for _, it := range items {
		if match(it) {
			n++
		}
	}
	return n
}

func plural(n int, one, many string) string {
	if n == 1 {
		return "1 " + one
	}
	return fmt.Sprintf("%d %s", n, many)
}

// sizePart is " (~14 GB)" over the matched worktrees; "" when they hold
// no known bytes and none is unknown.
func sizePart(items []Item, match func(Item) bool) string {
	var total int64
	unknown := false
	for _, it := range items {
		if it.Kind != KindWorktree || !match(it) {
			continue
		}
		total += it.Bytes
		unknown = unknown || !it.BytesKnown
	}
	switch {
	case unknown && total == 0:
		return " (size unknown)"
	case unknown:
		return " (~" + SizeText(total) + ", some sizes unknown)"
	case total == 0:
		return ""
	}
	return " (~" + SizeText(total) + ")"
}

// SizeText is bytes in decimal units, as Finder shows them.
func SizeText(n int64) string {
	units := []string{"B", "KB", "MB", "GB", "TB"}
	v, i := float64(n), 0
	for v >= 1000 && i < len(units)-1 {
		v, i = v/1000, i+1
	}
	if i == 0 || v >= 10 {
		return fmt.Sprintf("%.0f %s", v, units[i])
	}
	return fmt.Sprintf("%.1f %s", v, units[i])
}

// keptPart is "kept 1 worktree, 2 branches — uncommitted changes, checked
// out" (reasons in first-seen order).
func keptPart(items []Item) string {
	kept := func(it Item) bool {
		return it.Action == ActionKeep && (it.Kind == KindWorktree || it.Kind == KindBranch)
	}
	counts := countPart(items, kept)
	if counts == "" {
		return ""
	}
	var reasons []string
	seen := map[string]bool{}
	for _, it := range items {
		if kept(it) && !seen[it.Reason] {
			seen[it.Reason] = true
			reasons = append(reasons, ReasonPhrase(it.Reason))
		}
	}
	return "kept " + counts + " — " + strings.Join(reasons, ", ")
}

// ReasonPhrase is a reason code in the summary's words; a code without
// a phrase reads as itself with spaces.
func ReasonPhrase(code string) string {
	if p, ok := reasonPhrases[code]; ok {
		return p
	}
	return strings.ReplaceAll(code, "_", " ")
}
