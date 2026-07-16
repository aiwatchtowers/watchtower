package memory

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
)

// SeedConfig bounds the mechanical entity seeding pass.
type SeedConfig struct {
	MinMessages int  // people/senders need at least this many messages in the window
	WindowDays  int  // activity lookback for people and channels
	Gmail       bool // seed Gmail senders as person entities (memory.sources.gmail)
}

// machineSenderLocalParts are the local-part substrings that mark an email
// address as an automated/no-reply sender rather than a human worth a person
// entity. Matched case-insensitively against the address's local part. A code
// const (not config): the list is a definitional noise filter, not a tuning
// knob.
var machineSenderLocalParts = []string{
	"no-reply", "noreply", "do-not-reply", "donotreply",
	"notifications", "mailer-daemon", "postmaster", "bounce",
}

// isMachineSender reports whether an email's local part looks automated (any
// machineSenderLocalParts substring, case-insensitive) — dropped before seeding.
func isMachineSender(email string) bool {
	local := strings.ToLower(emailLocalPart(email))
	for _, m := range machineSenderLocalParts {
		if strings.Contains(local, m) {
			return true
		}
	}
	return false
}

// seedCandidate is one entity the seeding pass may create: a display name,
// the natural keys that become aliases (the first one is the idempotency
// key), an optional What line, and an optional people-card ref.
type seedCandidate struct {
	title      string
	aliases    []string
	what       string
	peopleCard int64
}

// SeedEntities creates skeleton entity pages for active people, channels
// with recent traffic, and Jira project keys (mechanical, no AI). An entity
// whose natural key already resolves to a node is skipped, so re-running is
// a no-op: nothing to create means no vault commit at all. Created nodes are
// committed once ("memory(seed): N entities") and mirrored into the SQLite
// index in the same call.
func SeedEntities(v *Vault, database *db.DB, cfg SeedConfig) (int, error) {
	since := float64(time.Now().AddDate(0, 0, -cfg.WindowDays).Unix())

	var candidates []seedCandidate
	for _, load := range []func(*db.DB, SeedConfig, float64) ([]seedCandidate, error){
		seedPeople, seedChannels, seedJiraProjects, seedGmailSenders,
	} {
		batch, err := load(database, cfg, since)
		if err != nil {
			return 0, err
		}
		candidates = append(candidates, batch...)
	}

	// claimed tracks the aliases already taken by nodes accepted THIS run
	// (lower-cased for the COLLATE NOCASE alias grammar). The DB idempotency
	// check (LookupMemoryAlias) only sees committed nodes — this run's new nodes
	// are not mirrored into the index until the commit loop below — so without
	// this set two candidates that share an alias (a Gmail sender whose email is
	// also a Slack person's email, seeded together on a fresh workspace's first
	// run) would both be created and collide on the UNIQUE alias constraint. The
	// set makes identity stitching hold WITHIN a run, not only across runs.
	claimed := make(map[string]bool)
	var nodes []Node
	var ids []string
	for _, c := range candidates {
		if claimed[strings.ToLower(c.aliases[0])] {
			continue // stitched to an entity already accepted this run
		}
		_, err := database.LookupMemoryAlias(c.aliases[0])
		if err == nil {
			continue // already seeded (or manually created) — idempotency
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return 0, fmt.Errorf("memory: seed lookup %q: %w", c.aliases[0], err)
		}
		n := Node{
			ID:      NewID("entity"),
			Type:    "entity",
			Tier:    "long",
			Status:  "active",
			Title:   c.title,
			Aliases: c.aliases,
			Body:    entitySkeletonBody(c.title, c.what),
		}
		n.Refs.PeopleCard = c.peopleCard
		for _, a := range c.aliases {
			claimed[strings.ToLower(a)] = true
		}
		nodes = append(nodes, n)
		ids = append(ids, n.ID)
	}
	if len(nodes) == 0 {
		return 0, nil
	}

	msg := CommitMsg{
		Op:      "seed",
		Summary: fmt.Sprintf("%d entities", len(nodes)),
		Cause:   "seed",
		NodeIDs: ids,
	}
	if _, err := v.WriteNodes(nodes, msg); err != nil {
		return 0, err
	}
	now := time.Now().UTC().Format(time.RFC3339)
	for _, n := range nodes {
		if err := upsertIndexNode(database, n, now); err != nil {
			return 0, err
		}
	}
	return len(nodes), nil
}

// entitySkeletonBody renders the v1 entity template: H1 plus the What /
// Current / Facts / Links / Open loops sections, all present even when empty.
func entitySkeletonBody(title, what string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "# %s\n\n## What\n", title)
	if what != "" {
		b.WriteString(what + "\n")
	}
	b.WriteString("\n## Current\n\n## Facts\n\n## Links\n\n## Open loops\n")
	return b.String()
}

// seedPeople returns non-bot users with at least cfg.MinMessages messages in
// the window, enriched from their latest people card when one exists (the
// card's summary becomes the What line; its ID becomes refs.people_card).
func seedPeople(database *db.DB, cfg SeedConfig, since float64) ([]seedCandidate, error) {
	rows, err := database.Query(`
		SELECT u.id, u.name, u.display_name, u.real_name, u.email,
		       COALESCE(pc.id, 0), COALESCE(pc.summary, '')
		FROM users u
		JOIN messages m ON m.user_id = u.id AND m.ts_unix >= ?
		LEFT JOIN people_cards pc ON pc.id = (
			SELECT id FROM people_cards WHERE user_id = u.id
			ORDER BY period_to DESC, id DESC LIMIT 1)
		WHERE u.is_bot = 0
		GROUP BY u.id
		HAVING COUNT(*) >= ?
		ORDER BY u.id`, since, cfg.MinMessages)
	if err != nil {
		return nil, fmt.Errorf("memory: seed people query: %w", err)
	}
	defer rows.Close()

	var out []seedCandidate
	for rows.Next() {
		var id, name, displayName, realName, email, summary string
		var cardID int64
		if err := rows.Scan(&id, &name, &displayName, &realName, &email, &cardID, &summary); err != nil {
			return nil, fmt.Errorf("memory: seed people scan: %w", err)
		}
		c := seedCandidate{
			title:      firstNonEmpty(displayName, realName, name),
			aliases:    []string{id},
			what:       summary,
			peopleCard: cardID,
		}
		if email != "" {
			c.aliases = append(c.aliases, email)
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// seedChannels returns channels with at least one non-empty-text message in
// the window. The What line comes from the channel topic, falling back to
// its purpose.
func seedChannels(database *db.DB, _ SeedConfig, since float64) ([]seedCandidate, error) {
	rows, err := database.Query(`
		SELECT c.id, c.name, c.topic, c.purpose
		FROM channels c
		WHERE EXISTS (
			SELECT 1 FROM messages m
			WHERE m.channel_id = c.id AND m.text != '' AND m.ts_unix >= ?)
		ORDER BY c.id`, since)
	if err != nil {
		return nil, fmt.Errorf("memory: seed channels query: %w", err)
	}
	defer rows.Close()

	var out []seedCandidate
	for rows.Next() {
		var id, name, topic, purpose string
		if err := rows.Scan(&id, &name, &topic, &purpose); err != nil {
			return nil, fmt.Errorf("memory: seed channels scan: %w", err)
		}
		out = append(out, seedCandidate{
			title:   "#" + name,
			aliases: []string{id},
			what:    firstNonEmpty(topic, purpose),
		})
	}
	return out, rows.Err()
}

// seedJiraProjects returns one candidate per distinct Jira project key —
// seeded even while Jira sync is dead so the aliases are ready when it
// revives. No activity window: project keys are few and stable.
func seedJiraProjects(database *db.DB, _ SeedConfig, _ float64) ([]seedCandidate, error) {
	rows, err := database.Query(`SELECT DISTINCT project_key FROM jira_issues ORDER BY project_key`)
	if err != nil {
		return nil, fmt.Errorf("memory: seed jira projects query: %w", err)
	}
	defer rows.Close()

	var out []seedCandidate
	for rows.Next() {
		var key string
		if err := rows.Scan(&key); err != nil {
			return nil, fmt.Errorf("memory: seed jira projects scan: %w", err)
		}
		out = append(out, seedCandidate{title: key, aliases: []string{key}})
	}
	return out, rows.Err()
}

// seedGmailSenders returns one candidate per distinct from_email that sent at
// least cfg.MinMessages gmail messages inside the window (internal_date unix >
// since), titled from from_name (falling back to the email's local-part),
// aliased by the lower-cased email address. It is a no-op unless cfg.Gmail
// (memory.sources.gmail) is on — the source seeds no senders when dark, so the
// "independently dark" contract is literally true.
//
// Two noise gates keep the person graph from filling with automated traffic:
//   - a min-message threshold (SeedConfig.MinMessages, the same floor people
//     use): a one-off sender is not worth a person entity (the plan's "external
//     senders are sparse" rationale was empirically wrong);
//   - a machine-sender pattern filter (isMachineSender): no-reply@, notifications@,
//     mailer-daemon@ and friends are dropped no matter how high their volume.
//
// Identity stitching is free (resolved ambiguity, §5A): SeedEntities's
// LookupMemoryAlias(aliases[0]) idempotency check unifies a sender whose email
// already aliases a seeded Slack person (seedPeople carries the users.email as
// an alias, and memory_aliases is COLLATE NOCASE), so no duplicate entity is
// minted — a genuinely external sender becomes a new person.
//
// internal_date is stored as an RFC3339 string by the Gmail sync (not the raw
// ms-epoch API value), so strftime('%s', internal_date) yields its whole-second
// unix time for the window comparison. gmail_messages is a migration-guaranteed
// base table, so a query failure propagates rather than being masked.
func seedGmailSenders(database *db.DB, cfg SeedConfig, since float64) ([]seedCandidate, error) {
	if !cfg.Gmail {
		return nil, nil // source dark — seed no senders
	}
	rows, err := database.Query(`
		SELECT lower(from_email) AS email, MAX(from_name) AS name
		FROM gmail_messages
		WHERE from_email != '' AND internal_date != ''
		  AND CAST(strftime('%s', internal_date) AS INTEGER) > ?
		GROUP BY lower(from_email)
		HAVING COUNT(*) >= ?
		ORDER BY email`, since, cfg.MinMessages)
	if err != nil {
		return nil, fmt.Errorf("memory: seed gmail senders query: %w", err)
	}
	defer rows.Close()

	var out []seedCandidate
	for rows.Next() {
		var email, name string
		if err := rows.Scan(&email, &name); err != nil {
			return nil, fmt.Errorf("memory: seed gmail senders scan: %w", err)
		}
		if isMachineSender(email) {
			continue // automated/no-reply sender — never a person entity
		}
		out = append(out, seedCandidate{
			title:   firstNonEmpty(name, emailLocalPart(email)),
			aliases: []string{email},
		})
	}
	return out, rows.Err()
}

// emailLocalPart returns the part of an email address before the first '@',
// the display fallback for a sender with no from_name.
func emailLocalPart(email string) string {
	if i := strings.IndexByte(email, '@'); i >= 0 {
		return email[:i]
	}
	return email
}

// firstNonEmpty returns the first non-empty string.
func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}
