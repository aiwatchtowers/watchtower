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
// with recent traffic, and Jira project keys (mechanical, no AI). It returns
// the number of pages CREATED; stitched ones (below) are not counted.
//
// Idempotency is decided over EVERY alias of a candidate, not just its natural
// key: a candidate whose aliases already live on a page is never re-created,
// and if that page is missing some of them (the pre-migration-00048 person page
// aliased by the bare "U123" while the candidate now arrives as "1:U123") the
// missing aliases are APPENDED to it — identity stitching, the same mechanism
// that unifies a Gmail sender with a Slack person. A candidate whose aliases
// span TWO existing pages is left alone entirely and logged: merging them is
// the semantic tier's job (Merge), not the seeder's.
//
// Nothing to write means no vault commit at all. Writes are committed once
// ("memory(seed): N entities") and mirrored into the SQLite index in the same
// call — index FIRST, inside one transaction, so a node is never in git history
// without being in the index for the same run and a failed run leaves neither
// (audit C2: before this, a duplicate page reached git and then died on the
// UNIQUE alias constraint, quarantining the orphan file every cycle after).
//
// logf may be nil (logging is dropped).
func SeedEntities(v *Vault, database *db.DB, cfg SeedConfig, logf func(string, ...any)) (int, error) {
	if logf == nil {
		logf = func(string, ...any) {}
	}
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

	plan, err := planSeedWrites(v, database, candidates, logf)
	if err != nil {
		return 0, err
	}
	if len(plan.write) == 0 {
		return 0, nil
	}

	summary := fmt.Sprintf("%d entities", len(plan.write))
	if plan.stitched > 0 {
		summary = fmt.Sprintf("%d entities (%d stitched)", len(plan.write), plan.stitched)
	}
	ids := make([]string, len(plan.write))
	for i, n := range plan.write {
		ids[i] = n.ID
	}
	msg := CommitMsg{Op: "seed", Summary: summary, Cause: "seed", NodeIDs: ids}

	if err := writeSeedNodes(v, database, plan.write, msg); err != nil {
		return 0, err
	}
	return plan.created, nil
}

// seedPlan is the decided write set of one seeding pass: the nodes to write
// (newly minted ones plus existing pages that gained aliases) and how many of
// each kind, for the returned count and the commit summary.
type seedPlan struct {
	write    []Node
	created  int
	stitched int
}

// planSeedWrites decides, candidate by candidate, what this run writes —
// create, stitch aliases onto an existing page, or stand down — without
// writing anything. See SeedEntities's doc for the rules.
func planSeedWrites(v *Vault, database *db.DB, candidates []seedCandidate, logf func(string, ...any)) (seedPlan, error) {
	// claimed maps an alias (lower-cased for the COLLATE NOCASE alias grammar)
	// to the node that owns it AMONG THE NODES ACCEPTED THIS RUN. The DB
	// idempotency check (LookupMemoryAlias) only sees nodes indexed before this
	// call — this run's writes are not mirrored until SeedEntities commits —
	// so without this map two candidates that share an alias (a Gmail sender
	// whose email is also a Slack person's email, seeded together on a fresh
	// workspace's first run) would both be created and collide on the UNIQUE
	// alias constraint. The map makes identity stitching hold WITHIN a run, not
	// only across runs.
	claimed := make(map[string]string)
	staged := make(map[string]int) // node id -> index into plan.write
	var plan seedPlan
	for _, c := range candidates {
		owners, unowned, err := resolveCandidate(database, claimed, c.aliases)
		if err != nil {
			return seedPlan{}, err
		}
		switch {
		case len(owners) > 1:
			// A merge, not a seed: leave both pages untouched.
			logf("memory: seed: candidate %q spans nodes %s and %s, skipping", c.aliases[0], owners[0], owners[1])
		case len(owners) == 1:
			if len(unowned) == 0 {
				continue // already seeded, with every alias — idempotency
			}
			idx, fromVault, err := stageSeedUpdate(v, staged, &plan.write, owners[0])
			if err != nil {
				// The index names a page the vault cannot produce. One broken
				// file must not brick the seed step (the Reconcile quarantine
				// discipline); Reconcile drops the stale row, and the next run
				// re-offers this candidate.
				logf("memory: seed: stitching %v onto %s: %v", unowned, owners[0], err)
				continue
			}
			plan.write[idx].Aliases = append(plan.write[idx].Aliases, unowned...)
			for _, a := range unowned {
				claimed[strings.ToLower(a)] = owners[0]
			}
			if fromVault {
				// Count only pages that PRE-EXISTED this run. Appending an
				// alias to a page minted moments ago (a second candidate
				// resolving to it through claimed) is part of creating it.
				plan.stitched++
			}
		default:
			n := Node{
				ID:      NewID("entity"),
				Type:    "entity",
				Tier:    "long",
				Status:  "active",
				Title:   c.title,
				Aliases: unowned, // == c.aliases: no alias resolved to anything
				Body:    entitySkeletonBody(c.title, c.what),
			}
			n.Refs.PeopleCard = c.peopleCard
			for _, a := range n.Aliases {
				claimed[strings.ToLower(a)] = n.ID
			}
			staged[n.ID] = len(plan.write)
			plan.write = append(plan.write, n)
			plan.created++
		}
	}
	return plan, nil
}

// writeSeedNodes validates the write set's aliases against the index, commits
// it to the vault, and then mirrors it into the index in one short transaction.
//
// Validate-FIRST, not index-first: **a validate-first run never creates a
// UNIQUE collision** — after planSeedWrites every alias either belongs to the
// node that carries it or belongs to nobody, so validateSeedAliases is an
// internal-consistency assertion that aborts with NOTHING written if the plan
// and the index ever disagree. Wrapping the git commit inside the index
// transaction instead would be a stronger guarantee on paper and a worse one in
// practice: WriteNodes runs a go-git `wt.Add` per node, each of which walks the
// whole worktree, so on a large vault the SQLite write lock would be held for
// minutes — and the pool is one connection with a 5 s busy_timeout, so every
// concurrent Desktop write would fail with "database is locked".
//
// The residual window is therefore a node in git whose index write failed; the
// next Reconcile picks it up as Added (it is a file with no index row), which is
// exactly the self-healing path MEM-02 already guarantees. Every DB read the
// index rows need is hoisted out of the transaction (prepareIndexNode) because
// the SQLite handle is single-connection (db.Open sets SetMaxOpenConns(1)) and a
// read issued while the transaction holds that connection would deadlock.
func writeSeedNodes(v *Vault, database *db.DB, write []Node, msg CommitMsg) error {
	if err := validateSeedAliases(database, write); err != nil {
		return err
	}
	if _, err := v.WriteNodes(write, msg); err != nil {
		return err
	}

	now := time.Now().UTC().Format(time.RFC3339)
	mem := newOwnerEditedMemo(v)
	prepared := make([]preparedIndexNode, len(write))
	for i, n := range write {
		p, err := prepareIndexNode(database, mem.lookup, n, now)
		if err != nil {
			return err
		}
		prepared[i] = p
	}

	tx, err := database.Begin()
	if err != nil {
		return fmt.Errorf("memory: seed index tx: %w", err)
	}
	defer tx.Rollback()
	for _, p := range prepared {
		if err := p.upsertTx(tx); err != nil {
			return err
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("memory: seed index commit: %w", err)
	}
	return nil
}

// validateSeedAliases checks that every alias of every node about to be written
// is free or already owned by that same node — both across the write set and
// against the index. A violation is unreachable after planSeedWrites, so it is
// reported as an internal inconsistency and aborts the pass before anything is
// written, rather than surfacing later as a UNIQUE constraint failure with a
// duplicate page already committed to git (audit C2).
func validateSeedAliases(database *db.DB, write []Node) error {
	claimant := make(map[string]string) // lower(alias) -> node id claiming it here
	for _, n := range write {
		for _, a := range n.Aliases {
			key := strings.ToLower(a)
			if other, ok := claimant[key]; ok && other != n.ID {
				return fmt.Errorf("memory: seed: alias %q claimed by both %s and %s", a, other, n.ID)
			}
			claimant[key] = n.ID

			owner, err := database.LookupMemoryAlias(a)
			switch {
			case errors.Is(err, sql.ErrNoRows):
			case err != nil:
				return fmt.Errorf("memory: seed validate %q: %w", a, err)
			case owner != n.ID:
				return fmt.Errorf("memory: seed: alias %q already belongs to %s, not %s", a, owner, n.ID)
			}
		}
	}
	return nil
}

// resolveCandidate resolves every alias of a candidate against the nodes
// accepted earlier in this run and then the index, returning the distinct
// owning node ids in first-seen order plus the aliases nobody owns yet (in
// the candidate's own casing, deduplicated case-insensitively so a candidate
// carrying two spellings of one alias cannot collide with itself).
func resolveCandidate(database *db.DB, claimed map[string]string, aliases []string) ([]string, []string, error) {
	var owners, unowned []string
	seenOwner := make(map[string]bool, len(aliases))
	seenFree := make(map[string]bool, len(aliases))
	for _, a := range aliases {
		key := strings.ToLower(a)
		id, ok := claimed[key]
		if !ok {
			var lookupErr error
			id, lookupErr = database.LookupMemoryAlias(a)
			switch {
			case lookupErr == nil:
			case errors.Is(lookupErr, sql.ErrNoRows):
				if !seenFree[key] {
					seenFree[key] = true
					unowned = append(unowned, a)
				}
				continue
			default:
				return nil, nil, fmt.Errorf("memory: seed lookup %q: %w", a, lookupErr)
			}
		}
		if !seenOwner[id] {
			seenOwner[id] = true
			owners = append(owners, id)
		}
	}
	return owners, unowned, nil
}

// stageSeedUpdate returns the index in write of the node to stitch aliases
// onto, reading it from the vault the first time this run touches it.
// fromVault reports whether this call did that read — false for a node already
// in the write set, which is how the caller tells a stitch onto a pre-existing
// page from one onto a page minted earlier in the same run.
func stageSeedUpdate(v *Vault, staged map[string]int, write *[]Node, nodeID string) (idx int, fromVault bool, err error) {
	if idx, ok := staged[nodeID]; ok {
		return idx, false, nil
	}
	n, err := v.ReadNode(nodeID)
	if err != nil {
		return 0, false, err
	}
	staged[nodeID] = len(*write)
	*write = append(*write, n)
	return staged[nodeID], true, nil
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
	keys, err := database.ListJiraProjectKeys()
	if err != nil {
		return nil, fmt.Errorf("memory: seed jira projects: %w", err)
	}
	out := make([]seedCandidate, 0, len(keys))
	for _, key := range keys {
		out = append(out, seedCandidate{title: key, aliases: []string{key}})
	}
	return out, nil
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
