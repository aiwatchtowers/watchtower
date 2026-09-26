package tools

// List-tool result caps: a read tool with no explicit limit returns
// defaultListLimit rows, and an oversized request is clamped to maxListLimit,
// so a single call can never dump an entire table into an LLM context window.
const (
	defaultListLimit = 50
	maxListLimit     = 200
)

// listLimit applies defaultListLimit when the caller passed 0 (or a negative)
// and clamps anything above maxListLimit. Mirrors the internal/mcp helper the
// read tools migrated from.
func listLimit(n int) int {
	switch {
	case n <= 0:
		return defaultListLimit
	case n > maxListLimit:
		return maxListLimit
	}
	return n
}
