package watchman

import (
	"errors"
	"fmt"
	"path"
	"slices"
	"strings"

	"watchtower/internal/db"
)

// LimitOwner is a limit the owner added (watchman_extra_limits, spec §5:
// the owner can add to the table, never remove a built-in row).
const LimitOwner HardLimit = "owner"

// The kinds of an owner's limit.
const (
	ExtraLimitCommand = "command" // a shell command whose words start with the pattern's words
	ExtraLimitTool    = "tool"    // a tool by name, or an MCP tool by its name after the last "__"
)

// BuiltinLimits lists the built-in table's rows in their order; none can be
// removed.
func BuiltinLimits() []HardLimit {
	out := make([]HardLimit, 0, len(hardLimits))
	for _, row := range hardLimits {
		out = append(out, row.limit)
	}
	return out
}

// CheckLimits is the built-in table (ParkedBy) and then the owner's rows: a
// command row parks a Bash request with a command (wrappers stripped, the
// program by its base name) whose words start with the pattern's words; a
// tool row parks a tool whose name equals the pattern or ends with
// "__<pattern>".
func CheckLimits(r PermissionAsk, extra []db.WatchmanExtraLimit) (HardLimit, bool) {
	if l, ok := ParkedBy(r); ok {
		return l, true
	}
	for _, e := range extra {
		switch e.Kind {
		case ExtraLimitCommand:
			if matchOwnerCommand(r, e.Pattern) {
				return LimitOwner, true
			}
		case ExtraLimitTool:
			if e.Pattern != "" && (r.Tool == e.Pattern || strings.HasSuffix(r.Tool, "__"+e.Pattern)) {
				return LimitOwner, true
			}
		}
	}
	return "", false
}

// matchOwnerCommand reports a command of a Bash request that starts with
// pattern's words. A pattern that cannot be split matches nothing (the CLI
// refuses one, ValidateLimitPattern).
func matchOwnerCommand(r PermissionAsk, pattern string) bool {
	want, ok := splitWords(pattern)
	if !ok || len(want) == 0 {
		return false
	}
	want[0] = path.Base(want[0])
	return anyCmd(r, func(c shellCmd) bool {
		return len(c.w) >= len(want) && slices.Equal(c.w[:len(want)], want)
	})
}

// ValidateLimitPattern checks an owner's limit before it is stored: one
// line, a known kind, a command pattern with at least one word and its
// quotes closed, a tool name without blanks.
func ValidateLimitPattern(kind, pattern string) error {
	if strings.ContainsAny(pattern, "\r\n") { // the arm sidecar keeps one limit per line
		return errors.New("the pattern must be one line")
	}
	switch kind {
	case ExtraLimitCommand:
		words, ok := splitWords(pattern)
		if !ok {
			return errors.New("the command pattern has an unclosed quote")
		}
		if len(words) == 0 {
			return errors.New("the command pattern is empty")
		}
	case ExtraLimitTool:
		if pattern == "" || strings.ContainsAny(pattern, " \t\r\n") {
			return errors.New("the tool pattern must be one tool name without blanks")
		}
	default:
		return fmt.Errorf("unknown limit kind %q (command or tool)", kind)
	}
	return nil
}
