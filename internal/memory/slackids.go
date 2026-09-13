package memory

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"watchtower/internal/db"
	"watchtower/internal/slack"
)

// This file is the one-off backfill migration 00048 could not do: the vault is
// markdown files, not SQL, so when Slack ids became account-namespaced
// ("<accountID>:<rawID>") every alias and provenance ref already written in the
// bare form stayed bare — invisible to every namespaced lookup. It rewrites
// them in place, once, under the same lock and commit discipline as any other
// vault write.

// bareSlackIDRe matches a Slack id in its raw, un-namespaced form: a user (U/W),
// channel (C/G), or DM (D) id. A namespaced id carries a colon and therefore
// never matches, which is what makes the migration idempotent.
var bareSlackIDRe = regexp.MustCompile(`^[UWCGD][A-Z0-9]{8,}$`)

// slackIDSampleCap bounds the preview's sample of rewrites.
const slackIDSampleCap = 10

// SlackIDMigration is what one MigrateSlackIDs pass did (or, in dry-run mode,
// would do).
type SlackIDMigration struct {
	AccountID          int64 // the single connected Slack account the ids are namespaced with
	NodesChanged       int
	ByType             map[string]int // node type -> nodes changed
	AliasRewrites      int
	ProvenanceRewrites int
	// Conflicts counts bare aliases left alone because the namespaced form
	// already belongs to a different page (rewriting would collide on the
	// UNIQUE alias constraint); Unreadable counts node files that could not be
	// parsed and were skipped.
	Conflicts  int
	Unreadable int
	Samples    []string
	Committed  bool
}

// MigrateSlackIDs rewrites every bare Slack id the vault still carries — in
// node aliases and in the ""-scheme (Slack message) refs of each node's
// ## Provenance section — into the namespaced form of the single connected
// Slack account, then commits the changed nodes once and rebuilds the index
// (the provenance index is derived from those very lines, so it must follow).
//
// It refuses unless exactly one slack_accounts row exists, counting disabled
// and removed ones: with two connected organizations a bare id could belong to
// either, and guessing would attach one workspace's history to the other.
//
// Idempotent by construction: a namespaced id no longer matches
// bareSlackIDRe, so a second run finds nothing to change and makes no commit.
// dryRun computes the same plan and writes nothing.
//
// logf may be nil (logging is dropped).
func MigrateSlackIDs(v *Vault, database *db.DB, dryRun bool, logf func(string, ...any)) (SlackIDMigration, error) {
	if logf == nil {
		logf = func(string, ...any) {}
	}
	stats := SlackIDMigration{ByType: make(map[string]int)}

	accountID, err := singleSlackAccountID(database)
	if err != nil {
		return stats, err
	}
	stats.AccountID = accountID

	nodes, unreadable, err := readAllNodes(v, logf)
	if err != nil {
		return stats, err
	}
	stats.Unreadable = unreadable

	jiraKeys, err := jiraProjectKeys(database)
	if err != nil {
		return stats, err
	}

	plan := &slackIDPlan{accountID: accountID, jiraKeys: jiraKeys, owners: aliasOwners(nodes), stats: &stats, logf: logf}
	var write []Node
	for _, n := range nodes {
		rewritten, ok := plan.node(n)
		if !ok {
			continue
		}
		write = append(write, rewritten)
		stats.NodesChanged++
		stats.ByType[n.Type]++
	}
	if dryRun || len(write) == 0 {
		return stats, nil
	}

	ids := make([]string, len(write))
	for i, n := range write {
		ids[i] = n.ID
	}
	msg := CommitMsg{
		Op:      "migrate",
		Summary: fmt.Sprintf("slack ids → namespaced (%d nodes)", len(write)),
		Cause:   "migrate",
		NodeIDs: ids,
	}
	if _, err := v.WriteNodes(write, msg); err != nil {
		return stats, err
	}
	stats.Committed = true

	if _, err := Rebuild(v, database, logf); err != nil {
		return stats, fmt.Errorf("%w (the vault is migrated but the index is stale; run `watchtower memory reindex`)", err)
	}
	return stats, nil
}

// slackIDPlan carries the decision inputs shared by every node of one pass.
type slackIDPlan struct {
	accountID int64
	jiraKeys  map[string]bool
	owners    map[string]string // lower(alias) -> owning node id, across the whole vault
	stats     *SlackIDMigration
	logf      func(string, ...any)
}

// node returns n with its bare Slack ids rewritten, and whether anything
// changed.
func (p *slackIDPlan) node(n Node) (Node, bool) {
	aliases, aliasesChanged := p.aliases(n)
	body, provRewrites := p.provenance(n)
	if !aliasesChanged && provRewrites == 0 {
		return Node{}, false
	}
	n.Aliases = aliases
	n.Body = body
	return n, true
}

// aliases rewrites the node's bare Slack-id aliases. The result is
// deduplicated case-insensitively (the alias grammar's COLLATE NOCASE), so a
// page the seeder stitched BOTH spellings onto keeps only the namespaced one —
// carrying the same alias twice would fail the index write.
func (p *slackIDPlan) aliases(n Node) ([]string, bool) {
	out := make([]string, 0, len(n.Aliases))
	emitted := make(map[string]bool, len(n.Aliases))
	changed := false
	for _, a := range n.Aliases {
		value := a
		if ns, ok := p.namespaced(a, n.ID); ok {
			changed = true
			p.stats.AliasRewrites++
			p.sample(n.ID, a, ns)
			value = ns
		}
		key := strings.ToLower(value)
		if emitted[key] {
			continue
		}
		emitted[key] = true
		out = append(out, value)
	}
	return out, changed
}

// namespaced decides whether alias is a bare Slack id this migration may
// rewrite, and to what. A rewrite it approves CLAIMS the namespaced form for
// nodeID, so a second page carrying the same bare alias (two duplicate pages
// from the seeder bug) is refused below rather than rewritten into a collision.
//
// Two values that look like a Slack id are left alone. A Jira project key is
// aliased bare on its own entity page (seedJiraProjects) and a long
// all-uppercase key matches the same shape, so a key the database knows about
// is never touched. And a bare id whose namespaced form already belongs to a
// DIFFERENT page cannot be rewritten at all: memory_aliases is UNIQUE, so the
// rewrite would fail the index write for both pages. Unifying those two pages
// is a merge — the semantic tier's job, never this migration's.
func (p *slackIDPlan) namespaced(alias, nodeID string) (string, bool) {
	if !bareSlackIDRe.MatchString(alias) {
		return "", false
	}
	if p.jiraKeys[alias] {
		p.logf("memory: migrate: alias %q on %s left alone (it is a Jira project key, not a Slack id)", alias, nodeID)
		return "", false
	}
	ns := slack.Namespace(p.accountID, alias)
	if owner, ok := p.owners[strings.ToLower(ns)]; ok && owner != nodeID {
		p.logf("memory: migrate: alias %q on %s left alone (%q already belongs to %s — merge them instead)", alias, nodeID, ns, owner)
		p.stats.Conflicts++
		return "", false
	}
	p.owners[strings.ToLower(ns)] = nodeID
	return ns, true
}

// provenance rewrites the bare Slack channel ids of the node's
// "- <channel_id> <ts>" provenance bullets, returning the new body and how
// many refs changed. It reads the section exactly as parseProvenance does, so
// the two can never disagree on which lines are refs; a ref of any other
// scheme (mail:, jira:, chat:, act:, cal:) carries a colon and is left alone.
func (p *slackIDPlan) provenance(n Node) (string, int) {
	lines := strings.Split(n.Body, "\n")
	inProv := false
	rewrites := 0
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "## ") {
			inProv = trimmed == "## Provenance"
			continue
		}
		if !inProv {
			continue
		}
		item := strings.TrimSpace(strings.TrimPrefix(trimmed, "-"))
		if item == trimmed { // not a "- " bullet
			continue
		}
		fields := strings.Fields(item)
		if len(fields) != 2 || !bareSlackIDRe.MatchString(fields[0]) {
			continue
		}
		ns := slack.Namespace(p.accountID, fields[0])
		lines[i] = strings.Replace(line, fields[0], ns, 1)
		rewrites++
		p.sample(n.ID, fields[0], ns)
	}
	if rewrites == 0 {
		return n.Body, 0
	}
	p.stats.ProvenanceRewrites += rewrites
	return strings.Join(lines, "\n"), rewrites
}

// sample records one rewrite for the preview, up to slackIDSampleCap.
func (p *slackIDPlan) sample(nodeID, from, to string) {
	if len(p.stats.Samples) >= slackIDSampleCap {
		return
	}
	p.stats.Samples = append(p.stats.Samples, fmt.Sprintf("%s: %s → %s", nodeID, from, to))
}

// aliasOwners maps every alias in the vault to the node carrying it, so a
// rewrite can see a collision before it writes one.
func aliasOwners(nodes []Node) map[string]string {
	owners := make(map[string]string)
	for _, n := range nodes {
		for _, a := range n.Aliases {
			owners[strings.ToLower(a)] = n.ID
		}
	}
	return owners
}

// singleSlackAccountID returns the id of the one connected Slack account, or
// an error naming why the migration cannot pick one. Removed and disabled
// accounts count: their historical ids are just as present in the vault as an
// enabled account's.
func singleSlackAccountID(database *db.DB) (int64, error) {
	accounts, err := database.ListSlackAccounts()
	if err != nil {
		return 0, fmt.Errorf("memory: migrate: listing slack accounts: %w", err)
	}
	switch len(accounts) {
	case 0:
		return 0, fmt.Errorf("memory: migrate: no Slack account is connected — there is no account id to namespace bare ids with")
	case 1:
		return accounts[0].ID, nil
	default:
		return 0, fmt.Errorf("memory: migrate: %d Slack accounts are connected (counting disabled and removed ones) — "+
			"which account a bare id belongs to is not guessable, so nothing is rewritten", len(accounts))
	}
}

// jiraProjectKeys returns the distinct Jira project keys the database knows,
// upper-cased as they are stored — the exclusion set for alias rewrites.
func jiraProjectKeys(database *db.DB) (map[string]bool, error) {
	rows, err := database.Query(`SELECT DISTINCT project_key FROM jira_issues`)
	if err != nil {
		return nil, fmt.Errorf("memory: migrate: listing jira project keys: %w", err)
	}
	defer rows.Close()

	keys := make(map[string]bool)
	for rows.Next() {
		var key string
		if err := rows.Scan(&key); err != nil {
			return nil, fmt.Errorf("memory: migrate: scanning jira project key: %w", err)
		}
		keys[key] = true
	}
	return keys, rows.Err()
}

// readAllNodes reads every node file in the vault worktree, in directory
// order. A file that is not a node (wrong prefix for its directory, no .md
// suffix) is skipped silently, as in Reconcile; one that cannot be parsed is
// skipped, logged, and counted rather than failing the pass — the same
// quarantine discipline, since one damaged file must not block the migration
// of the rest.
func readAllNodes(v *Vault, logf func(string, ...any)) ([]Node, int, error) {
	var out []Node
	skipped := 0
	for _, sub := range vaultSubdirs {
		entries, err := os.ReadDir(filepath.Join(v.path, sub))
		if err != nil {
			return nil, 0, fmt.Errorf("memory: migrate: read %s: %w", sub, err)
		}
		for _, entry := range entries {
			if entry.IsDir() {
				continue
			}
			id, ok := strings.CutSuffix(entry.Name(), ".md")
			if !ok {
				continue
			}
			if own, err := subdirFor(id); err != nil || own != sub {
				continue
			}
			n, err := v.ReadNode(id)
			if err != nil {
				logf("memory: migrate: skipped %s/%s: %v", sub, entry.Name(), err)
				skipped++
				continue
			}
			if n.ID != id {
				logf("memory: migrate: skipped %s/%s: frontmatter id %q does not match filename", sub, entry.Name(), n.ID)
				skipped++
				continue
			}
			out = append(out, n)
		}
	}
	return out, skipped, nil
}
