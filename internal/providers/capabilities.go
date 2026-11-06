package providers

import "watchtower/internal/providers/caps"

// Capabilities is what a provider's transport offers (spec §3.3); the
// table is internal/providers/caps. Consumers read it, never a name.
type Capabilities = caps.Capabilities

// CapsFor is provider id's capabilities; false for an unknown id.
func CapsFor(id string) (Capabilities, bool) { return caps.For(id) }

// CapsOf is the capabilities of a provider id as a config holds it: "" is
// the default provider (claude, as ByID), an unknown id the zero row (it
// takes nothing). The one lookup for a site that does not check ok.
func CapsOf(id string) Capabilities {
	if id == "" {
		id = registry[0].ID
	}
	c, _ := caps.For(id)
	return c
}

// RunsChild reports whether provider id's transport is a CLI child (the
// routed tool path and the automation agent() runner build only those).
func RunsChild(id string) bool {
	for _, p := range registry {
		if p.ID == id {
			return p.Kind == "cli"
		}
	}
	return false
}

// Pairs reports whether preferred and reserve form a fallback pair; ""
// is the default provider.
func Pairs(preferred, reserve string) bool {
	if preferred == "" {
		preferred = registry[0].ID
	}
	return caps.Pairs(preferred, reserve)
}

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
