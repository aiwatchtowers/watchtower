package automations

import (
	"fmt"

	"watchtower/internal/db"
	"watchtower/internal/policy"
)

// The PolicyBlock kinds, also `automations show/list --json`'s policy_blocked.
const (
	PolicyBlockShell = "shell"
	PolicyBlockMCP   = "mcp"
)

// PolicyBlock is a manifest the organization's policy (#608) refuses: Kind is
// what it needs (PolicyBlockShell or PolicyBlockMCP), Err the policy refusal.
type PolicyBlock struct {
	Kind string
	Err  error
}

func (b *PolicyBlock) Error() string { return b.Err.Error() }
func (b *PolicyBlock) Unwrap() error { return b.Err }

// CheckManifestPolicy refuses a manifest the current policy forbids: a
// shell: entry while AllowAutomationShell is false, or an mcp: entry whose
// named Quick Connection exists and is outside AllowedQuickConnections (a
// missing one is mcp()'s NotAvailable, not a policy matter). connection
// looks a connection up by exact name; nil skips the mcp: entries. It runs
// at validate, save and confirm, never at indexing, so a blocked recipe
// stays listed. nil or a *PolicyBlock.
func CheckManifestPolicy(m *Manifest, connection func(name string) (kind, url, command string, ok bool)) error {
	p := policy.Current()
	for _, e := range m.entries {
		if e.Capability == kindShell && !p.ShellAllowed() {
			return &PolicyBlock{Kind: PolicyBlockShell, Err: policy.ShellError()}
		}
	}
	if connection == nil {
		return nil
	}
	for _, e := range m.entries {
		if e.Capability != kindMCP {
			continue
		}
		if kind, url, command, ok := connection(e.MCPServer); ok && !p.ConnectionAllowed(kind, url, command) {
			return &PolicyBlock{Kind: PolicyBlockMCP, Err: p.ConnectionError(e.MCPServer)}
		}
	}
	return nil
}

// ConnectionLookup is CheckManifestPolicy's lookup over every Quick
// Connection (disabled ones too: enabling one is refused anyway), read once.
func ConnectionLookup(database *db.DB) (func(name string) (kind, url, command string, ok bool), error) {
	conns, err := database.ListExternalConnections()
	if err != nil {
		return nil, fmt.Errorf("listing Quick Connections: %w", err)
	}
	return func(name string) (string, string, string, bool) {
		for _, c := range conns {
			if c.Name == name {
				return c.Kind, c.URL, c.Command, true
			}
		}
		return "", "", "", false
	}, nil
}

// CheckRecipePolicy is CheckManifestPolicy for a parsed recipe, its Quick
// Connections read from database (nil: a registry without a database, whose
// shell: entries are still checked).
func CheckRecipePolicy(database *db.DB, r *Recipe) error {
	m, err := ParseManifest(r.Permissions, r.Outputs, r.Scope)
	if err != nil {
		return err
	}
	if database == nil {
		return CheckManifestPolicy(m, nil)
	}
	lookup, err := ConnectionLookup(database)
	if err != nil {
		return err
	}
	return CheckManifestPolicy(m, lookup)
}
