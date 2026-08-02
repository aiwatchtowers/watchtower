package memory

import (
	"database/sql"
	"encoding/json"
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
	Calendar    bool // seed recurring calendar series as entities (memory.sources.calendar)
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

// gmailSenderMinMessages is the email-specific seeding floor: a human
// correspondent who sent >=3 emails in the 30-day window earns a person
// entity. Deliberately much lower than the Slack SeedConfig.MinMessages floor
// (chat and email volumes differ by an order of magnitude).
const gmailSenderMinMessages = 3

// isMachineSender reports whether an email's local part looks automated —
// dropped before seeding. Patterns match as a PREFIX of the local part (or the
// whole part), not a substring, so a human like jbouncer@ is not swept up by
// "bounce".
func isMachineSender(email string) bool {
	local := strings.ToLower(emailLocalPart(email))
	for _, m := range machineSenderLocalParts {
		if local == m || strings.HasPrefix(local, m) {
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
		seedPeople, seedChannels, seedJiraProjects, seedGmailSenders, seedCalendarSeries,
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
	mem := newOwnerEditedMemo(v)
	for _, n := range nodes {
		if err := upsertIndexNode(database, mem.lookup, n, now); err != nil {
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
// least gmailSenderMinMessages gmail messages inside the window (internal_date
// unix > since), titled from from_name (falling back to the email's
// local-part), aliased by the lower-cased email address. It is a no-op unless
// cfg.Gmail (memory.sources.gmail) is on — the source seeds no senders when
// dark, so the "independently dark" contract is literally true.
//
// Two noise gates keep the person graph from filling with automated traffic:
//   - a min-message threshold (gmailSenderMinMessages, NOT the Slack-calibrated
//     SeedConfig.MinMessages: 20 chat messages/month is normal, 20 emails from
//     one human correspondent is not — a Slack floor would leave email seeding
//     effectively inert; convergence-review calibration, 2026-07-16);
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
		ORDER BY email`, since, gmailSenderMinMessages)
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

// calendarSeriesAliasPrefix marks an entity as a recurring calendar series
// ("calseries:<recurringEventId>") — the idempotency key that unifies every
// instance of one Google recurring event under a single series entity.
const calendarSeriesAliasPrefix = "calseries:"

// seedCalendarSeries returns one candidate per distinct Google recurringEventId
// among currently-synced recurring events (is_recurring=1), the id parsed from
// raw_json (the JSON key recurringEventId). Title is the series' event title
// (any instance's, first by id); alias is "calseries:<recurringEventId>". It is
// a no-op unless cfg.Calendar (memory.sources.calendar) — the source seeds no
// series when dark. A non-recurring event, or a recurring event whose raw_json
// carries no recurringEventId, yields no series candidate; a malformed raw_json
// is skipped (the Gmail internal_date defensive-skip precedent), never an error.
// Identity stitching is free (SeedEntities's LookupMemoryAlias idempotency + the
// within-run claimed set).
func seedCalendarSeries(database *db.DB, cfg SeedConfig, _ float64) ([]seedCandidate, error) {
	if !cfg.Calendar {
		return nil, nil // source dark — seed no series
	}
	rows, err := database.Query(`
		SELECT title, raw_json FROM calendar_events
		WHERE is_recurring = 1 AND raw_json != ''
		ORDER BY id`)
	if err != nil {
		return nil, fmt.Errorf("memory: seed calendar series query: %w", err)
	}
	defer rows.Close()

	seen := make(map[string]bool)
	var out []seedCandidate
	for rows.Next() {
		var title, rawJSON string
		if err := rows.Scan(&title, &rawJSON); err != nil {
			return nil, fmt.Errorf("memory: seed calendar series scan: %w", err)
		}
		recurringID := parseRecurringEventID(rawJSON)
		if recurringID == "" || seen[recurringID] {
			continue // not a series instance, malformed json, or already claimed
		}
		seen[recurringID] = true
		out = append(out, seedCandidate{
			title:   firstNonEmpty(title, recurringID),
			aliases: []string{calendarSeriesAliasPrefix + recurringID},
		})
	}
	return out, rows.Err()
}

// parseRecurringEventID extracts the Google recurringEventId from an event's
// raw_json. A malformed raw_json (or one with no recurringEventId) yields "" —
// a skip, never an error (the seedCalendarSeries defensive-skip contract).
func parseRecurringEventID(rawJSON string) string {
	var probe struct {
		RecurringEventID string `json:"recurringEventId"`
	}
	if err := json.Unmarshal([]byte(rawJSON), &probe); err != nil {
		return ""
	}
	return probe.RecurringEventID
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
