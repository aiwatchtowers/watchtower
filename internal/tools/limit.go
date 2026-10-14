package tools

// List-tool result caps: a read tool with no explicit limit returns
// DefaultListLimit rows, and an oversized request is clamped to MaxListLimit,
// so a single call can never dump an entire table into an LLM context window.
// The one copy of these values: internal/automations' limits refer here.
const (
	DefaultListLimit = 50
	MaxListLimit     = 200
)

// listLimit applies DefaultListLimit when the caller passed 0 (or a negative)
// and clamps anything above MaxListLimit. Mirrors the internal/mcp helper the
// read tools migrated from.
func listLimit(n int) int {
	switch {
	case n <= 0:
		return DefaultListLimit
	case n > MaxListLimit:
		return MaxListLimit
	}
	return n
}
