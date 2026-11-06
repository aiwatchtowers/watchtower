package providers

import "watchtower/internal/providers/caps"

// Capabilities is what a provider's transport offers (spec §3.3); the
// table is internal/providers/caps. Consumers read it, never a name.
type Capabilities = caps.Capabilities

// CapsFor is provider id's capabilities; false for an unknown id.
func CapsFor(id string) (Capabilities, bool) { return caps.For(id) }

// Pairs reports whether preferred and reserve form a fallback pair.
func Pairs(preferred, reserve string) bool { return caps.Pairs(preferred, reserve) }

// Satisfies reports whether c offers what profile needs: a batch call
// anything, an image call image input, a read-only review folder reading,
// a tool preflight the watchtower tools. An unknown profile is refused.
// (A method on the caps type would need the profile type in the leaf.)
func Satisfies(c Capabilities, profile InvocationProfile) bool {
	switch profile {
	case BatchText:
		return true
	case Image:
		return c.Images
	case ReviewReadonly:
		return c.ReadsFolder()
	case ToolPreflight:
		return c.HasTools()
	}
	return false
}
