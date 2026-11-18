package db

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// AtlassianPerson is one Atlassian account id Watchtower stores for a Jira
// account (its site's rows plus the site-independent user caches), with the
// oldest known time a row naming it was fetched from Atlassian (zero when no
// row says).
type AtlassianPerson struct {
	ID        string
	UpdatedAt time.Time
}

// atlassianPeopleSQL collects every Atlassian account id stored for one Jira
// account (?1): the site's issue, linked-issue, comment and changelog
// people, the account's own owner, the authors on its Confluence spaces, and
// the site-independent jira_user_map and Confluence ext_users rows. Atlassian
// ids are global, so the caches are reported through every account: a row
// left by a removed site is still reported by one that remains. The time is
// the OLDEST fetch of a row naming the id, so a fresh copy never hides a
// stale one from Atlassian's "updated" answer; jira_user_map has no fetch
// time (resolved_at is the Slack match).
const atlassianPeopleSQL = `SELECT id, MIN(NULLIF(ts, '')) FROM (
  SELECT assignee_account_id AS id, synced_at AS ts FROM jira_issues WHERE account_id = ?1
  UNION ALL SELECT reporter_account_id, synced_at FROM jira_issues WHERE account_id = ?1
  UNION ALL SELECT assignee_account_id, synced_at FROM jira_linked_issues WHERE account_id = ?1
  UNION ALL SELECT author_account_id, synced_at FROM jira_comments WHERE account_id = ?1
  UNION ALL SELECT c.author_account_id, COALESCE(s.synced_at, '') FROM jira_issue_changelog c
    LEFT JOIN jira_changelog_sync s ON s.account_id = c.account_id AND s.issue_key = c.issue_key WHERE c.account_id = ?1
  UNION ALL SELECT c.from_value, COALESCE(s.synced_at, '') FROM jira_issue_changelog c
    LEFT JOIN jira_changelog_sync s ON s.account_id = c.account_id AND s.issue_key = c.issue_key WHERE c.account_id = ?1 AND c.field = 'assignee'
  UNION ALL SELECT c.to_value, COALESCE(s.synced_at, '') FROM jira_issue_changelog c
    LEFT JOIN jira_changelog_sync s ON s.account_id = c.account_id AND s.issue_key = c.issue_key WHERE c.account_id = ?1 AND c.field = 'assignee'
  UNION ALL SELECT owner_account_id, '' FROM jira_accounts WHERE id = ?1
  UNION ALL SELECT d.author_id, d.synced_at FROM ext_documents d JOIN ext_sources s ON s.id = d.source_id WHERE s.jira_account_id = ?1
  UNION ALL SELECT c.author_id, COALESCE(d.synced_at, '') FROM ext_comments c JOIN ext_sources s ON s.id = c.source_id
    LEFT JOIN ext_documents d ON d.source_id = c.source_id AND d.ext_id = c.page_ext_id WHERE s.jira_account_id = ?1
  UNION ALL SELECT jira_account_id, '' FROM jira_user_map
  UNION ALL SELECT ext_user_id, fetched_at FROM ext_users WHERE provider = 'confluence'
) WHERE id != '' GROUP BY id ORDER BY id`

// AtlassianPeople returns the Atlassian account ids stored for Jira account
// accountID (atlassianPeopleSQL), sorted, each with the oldest parseable
// fetch time of a row naming it. A read: it never opens a write transaction.
func (db *DB) AtlassianPeople(ctx context.Context, accountID int64) ([]AtlassianPerson, error) {
	rows, err := db.QueryContext(ctx, atlassianPeopleSQL, accountID)
	if err != nil {
		return nil, fmt.Errorf("listing atlassian people of jira account %d: %w", accountID, err)
	}
	defer rows.Close()
	var out []AtlassianPerson
	for rows.Next() {
		var p AtlassianPerson
		var ts sql.NullString
		if err := rows.Scan(&p.ID, &ts); err != nil {
			return nil, fmt.Errorf("scanning atlassian person: %w", err)
		}
		if t, err := time.Parse(time.RFC3339Nano, ts.String); err == nil {
			p.UpdatedAt = t.UTC()
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// atlassianPersonColumn is one column holding what Atlassian told Watchtower
// about a person (a name, an email, the Slack id matched from them), erased
// to empty on rows whose idCol names a closed account. The bare id stays: the
// UI shows "Former user" for an id without a name.
type atlassianPersonColumn struct {
	table, idCol, col string
	// scope restricts the update to the Jira account (?), always set.
	scope string
	// where is an extra predicate ("" = none).
	where string
}

// atlassianPersonColumns is every Atlassian person column the erase clears.
// TestPDR_EraseCoversEveryAtlassianPersonColumn checks the schema against it
// and atlassianPeopleKeptColumns; the erase statements are built from it.
var atlassianPersonColumns = []atlassianPersonColumn{
	{table: "jira_issues", idCol: "assignee_account_id", col: "assignee_email", scope: "account_id = ?"},
	{table: "jira_issues", idCol: "assignee_account_id", col: "assignee_display_name", scope: "account_id = ?"},
	{table: "jira_issues", idCol: "assignee_account_id", col: "assignee_slack_id", scope: "account_id = ?"},
	{table: "jira_issues", idCol: "reporter_account_id", col: "reporter_email", scope: "account_id = ?"},
	{table: "jira_issues", idCol: "reporter_account_id", col: "reporter_display_name", scope: "account_id = ?"},
	{table: "jira_issues", idCol: "reporter_account_id", col: "reporter_slack_id", scope: "account_id = ?"},
	{table: "jira_linked_issues", idCol: "assignee_account_id", col: "assignee_display_name", scope: "account_id = ?"},
	{table: "jira_comments", idCol: "author_account_id", col: "author", scope: "account_id = ?"},
	{table: "jira_issue_changelog", idCol: "author_account_id", col: "author_display_name", scope: "account_id = ?"},
	{table: "jira_issue_changelog", idCol: "from_value", col: "from_string", scope: "account_id = ?", where: "field = 'assignee'"},
	{table: "jira_issue_changelog", idCol: "to_value", col: "to_string", scope: "account_id = ?", where: "field = 'assignee'"},
	{table: "jira_accounts", idCol: "owner_account_id", col: "owner_email", scope: "id = ?"},
	{table: "jira_accounts", idCol: "owner_account_id", col: "owner_display_name", scope: "id = ?"},
}

// atlassianPeopleDeletedTables are the person caches whose row for a closed
// account is deleted outright: table → its id column (and predicate).
var atlassianPeopleDeletedTables = []struct{ table, idCol, where string }{
	{"jira_user_map", "jira_account_id", ""}, // email, display name and the Jira→Slack mapping
	{"ext_users", "ext_user_id", "provider = 'confluence'"},
}

// atlassianPeopleKeptColumns are person-looking columns of the jira_*/ext_*
// tables the erase leaves alone, each with the reason. Empty today; the
// coverage test reads it.
var atlassianPeopleKeptColumns = map[string]string{}

// AtlassianErasePlan is what EraseAtlassianPeople needs read before its
// write transaction, so no scan of the issue payloads or Confluence bodies
// runs while it holds the write lock. A row a concurrent sync writes between
// the plan and the transaction misses only its payload blanking and its
// re-render mark: its person columns are erased in the transaction itself,
// and the next report (the id stays stored, so it is reported again)
// repeats the erase.
type AtlassianErasePlan struct {
	// RawJSONKeys are the account's issues whose stored payload names one
	// of the ids; the erase blanks the payload and removes the names below
	// from their custom field values (a quiet issue is never re-synced, so
	// the next sync cannot be relied on to rewrite them).
	RawJSONKeys []string
	// Names are the display names stored for the ids: a user-picker custom
	// field keeps only the name, with no account id to match it by.
	Names []string
	// Dirty are the knowledge documents rendered from rows naming one of
	// the ids, re-rendered on the next KB pass.
	Dirty []KBDocKey
}

// KBDocKey is one knowledge-index document (kb_dirty's source and key).
type KBDocKey struct{ Source, Key string }

// atlassianDirtyJiraSQL lists the account's issues whose rows name ?2.
const atlassianDirtyJiraSQL = `SELECT key FROM jira_issues WHERE account_id = ?1 AND (assignee_account_id = ?2 OR reporter_account_id = ?2)
  UNION SELECT issue_key FROM jira_comments WHERE account_id = ?1 AND author_account_id = ?2
  UNION SELECT issue_key FROM jira_issue_changelog WHERE account_id = ?1 AND (author_account_id = ?2 OR (field = 'assignee' AND (from_value = ?2 OR to_value = ?2)))
  UNION SELECT key FROM jira_issues WHERE account_id = ?1 AND instr(raw_json, '"' || ?2 || '"') > 0`

// atlassianDirtyConfluenceSQL lists the Confluence documents, on every
// source, that name ?1 — as author, as a commenter on the page, or in a
// mention token: the erase deletes the shared ext_users row their render
// reads the name from.
const atlassianDirtyConfluenceSQL = `SELECT 'confluence:' || source_id || ':' || ext_id FROM ext_documents
    WHERE author_id = ?1 OR instr(sections_json, '@[~' || ?1 || ']') > 0
  UNION SELECT 'confluence:' || source_id || ':' || page_ext_id FROM ext_comments
    WHERE author_id = ?1 OR instr(body_text, '@[~' || ?1 || ']') > 0`

// atlassianNamesSQL lists the display names stored for ?2.
const atlassianNamesSQL = `SELECT display_name FROM jira_user_map WHERE jira_account_id = ?2
  UNION SELECT display_name FROM ext_users WHERE provider = 'confluence' AND ext_user_id = ?2
  UNION SELECT assignee_display_name FROM jira_issues WHERE account_id = ?1 AND assignee_account_id = ?2
  UNION SELECT reporter_display_name FROM jira_issues WHERE account_id = ?1 AND reporter_account_id = ?2`

// PlanAtlassianErase reads, outside any write transaction, which issue
// payloads, names and knowledge documents the erase of ids on Jira account
// accountID touches.
func (db *DB) PlanAtlassianErase(ctx context.Context, accountID int64, ids []string) (AtlassianErasePlan, error) {
	var plan AtlassianErasePlan
	seen := map[string]bool{}
	add := func(list *[]string, kind, v string) {
		if v != "" && !seen[kind+"\x00"+v] {
			seen[kind+"\x00"+v] = true
			*list = append(*list, v)
		}
	}
	for _, id := range ids {
		keys, err := db.queryStrings(ctx, `SELECT key FROM jira_issues WHERE account_id = ? AND instr(raw_json, '"' || ? || '"') > 0`, accountID, id)
		if err != nil {
			return plan, fmt.Errorf("planning atlassian erase (payloads): %w", err)
		}
		for _, k := range keys {
			add(&plan.RawJSONKeys, "raw", k)
		}
		names, err := db.queryStrings(ctx, atlassianNamesSQL, accountID, id)
		if err != nil {
			return plan, fmt.Errorf("planning atlassian erase (names): %w", err)
		}
		for _, n := range names {
			add(&plan.Names, "name", n)
		}
		keys, err = db.queryStrings(ctx, atlassianDirtyJiraSQL, accountID, id)
		if err != nil {
			return plan, fmt.Errorf("planning atlassian erase (jira documents): %w", err)
		}
		var docs []string
		for _, k := range keys {
			add(&docs, "jira", fmt.Sprintf("jira:%d:%s", accountID, k))
		}
		for _, k := range docs {
			plan.Dirty = append(plan.Dirty, KBDocKey{"jira", k})
		}
		keys, err = db.queryStrings(ctx, atlassianDirtyConfluenceSQL, id)
		if err != nil {
			return plan, fmt.Errorf("planning atlassian erase (confluence documents): %w", err)
		}
		docs = nil
		for _, k := range keys {
			add(&docs, "confluence", k)
		}
		for _, k := range docs {
			plan.Dirty = append(plan.Dirty, KBDocKey{"confluence", k})
		}
	}
	return plan, nil
}

func (db *DB) queryStrings(ctx context.Context, q string, args ...any) ([]string, error) {
	rows, err := db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// eraseChunk bounds the ids one erase statement names.
const eraseChunk = 200

// EraseAtlassianPeople erases, inside tx, what Atlassian told Watchtower
// about each closed account in ids, for Jira account accountID (#1887 §6,
// D17): the jira_user_map row (with its Slack mapping) and the Confluence
// ext_users row go; every atlassianPersonColumns column on the account's rows
// naming the id becomes empty; the payloads plan found are blanked and the
// names it found removed from their custom field values; plan's documents
// are marked in kb_dirty. One statement per column for all ids, so each
// table is walked once. Memory and free-text derived texts are not touched
// (P6, ask #1518). Idempotent: a second run changes nothing.
func (db *DB) EraseAtlassianPeople(ctx context.Context, tx *sql.Tx, accountID int64, ids []string, plan AtlassianErasePlan) error {
	for start := 0; start < len(ids); start += eraseChunk {
		chunk := ids[start:min(start+eraseChunk, len(ids))]
		in := strings.TrimSuffix(strings.Repeat("?,", len(chunk)), ",")
		idArgs := make([]any, len(chunk))
		for i, id := range chunk {
			idArgs[i] = id
		}
		for _, c := range atlassianPersonColumns {
			//nolint:gosec // G201: table and column names come from the package's constant atlassianPersonColumns, the IN list is only "?" placeholders; every value is a bound arg.
			q := fmt.Sprintf(`UPDATE %s SET %s = '' WHERE %s AND %s IN (%s) AND %s != ''`, c.table, c.col, c.scope, c.idCol, in, c.col)
			if c.where != "" {
				q += " AND " + c.where
			}
			if _, err := tx.ExecContext(ctx, q, append([]any{accountID}, idArgs...)...); err != nil {
				return fmt.Errorf("erasing %s.%s: %w", c.table, c.col, err)
			}
		}
		for _, t := range atlassianPeopleDeletedTables {
			//nolint:gosec // G201: table and column names come from the package's constant atlassianPeopleDeletedTables, the IN list is only "?" placeholders; every value is a bound arg.
			q := fmt.Sprintf(`DELETE FROM %s WHERE %s IN (%s)`, t.table, t.idCol, in)
			if t.where != "" {
				q += " AND " + t.where
			}
			if _, err := tx.ExecContext(ctx, q, idArgs...); err != nil {
				return fmt.Errorf("erasing %s: %w", t.table, err)
			}
		}
	}
	for _, key := range plan.RawJSONKeys {
		if _, err := tx.ExecContext(ctx, `UPDATE jira_issues SET raw_json = '' WHERE account_id = ? AND key = ? AND raw_json != ''`, accountID, key); err != nil {
			return fmt.Errorf("erasing an issue payload: %w", err)
		}
		for _, name := range plan.Names {
			quoted, err := json.Marshal(name)
			if err != nil {
				return fmt.Errorf("erasing a custom field name: %w", err)
			}
			if _, err := tx.ExecContext(ctx, `UPDATE jira_issues SET custom_fields_json = replace(custom_fields_json, ?, '""')
				WHERE account_id = ? AND key = ? AND instr(custom_fields_json, ?) > 0`, string(quoted), accountID, key, string(quoted)); err != nil {
				return fmt.Errorf("erasing a custom field name: %w", err)
			}
		}
	}
	for _, k := range plan.Dirty {
		if _, err := tx.ExecContext(ctx, `INSERT INTO kb_dirty (source, key) VALUES (?, ?)
			ON CONFLICT (source, key) DO UPDATE SET gen = gen + 1`, k.Source, k.Key); err != nil {
			return fmt.Errorf("marking %s for re-render: %w", k.Key, err)
		}
	}
	return nil
}

// AtlassianProfile is a person's current profile as Atlassian answers it.
type AtlassianProfile struct {
	ID, DisplayName, Email string
}

// RefreshAtlassianProfiles writes the refetched profiles of "updated"
// accounts into the cached rows that hold them (jira_user_map, Confluence
// ext_users, stamped fetchedAt), in one short write transaction. An empty
// name or email (Atlassian hides it) keeps the stored one; no row is
// created. Rows synced per issue follow the next sync of that issue.
func (db *DB) RefreshAtlassianProfiles(ctx context.Context, profiles []AtlassianProfile, fetchedAt time.Time) error {
	if len(profiles) == 0 {
		return nil
	}
	at := fetchedAt.UTC().Format(time.RFC3339)
	return db.WithTx(func(tx *sql.Tx) error {
		for _, p := range profiles {
			if _, err := tx.ExecContext(ctx, `UPDATE jira_user_map SET display_name = COALESCE(NULLIF(?, ''), display_name),
				email = COALESCE(NULLIF(?, ''), email) WHERE jira_account_id = ?`, p.DisplayName, p.Email, p.ID); err != nil {
				return fmt.Errorf("refreshing atlassian profile: %w", err)
			}
			if _, err := tx.ExecContext(ctx, `UPDATE ext_users SET display_name = COALESCE(NULLIF(?, ''), display_name),
				email = COALESCE(NULLIF(?, ''), email), fetched_at = ? WHERE provider = 'confluence' AND ext_user_id = ?`,
				p.DisplayName, p.Email, at, p.ID); err != nil {
				return fmt.Errorf("refreshing atlassian profile: %w", err)
			}
		}
		return nil
	})
}

// PDRScopeMissingCode is the hint code the PDR phase leaves in a Jira
// account's error column, status unchanged, while its grant lacks the
// report:personal-data scope ("Re-login to finish the setup").
const PDRScopeMissingCode = "pdr_scope_missing"

// SetJiraPDRScopeHint sets (missing) or clears the PDR scope hint on Jira
// account id, never touching its status: it is set only over an empty error
// (a real error stays shown) and cleared only when it is the hint.
func (db *DB) SetJiraPDRScopeHint(id int64, missing bool) error {
	q := `UPDATE jira_accounts SET error = '' WHERE id = ? AND error = '` + PDRScopeMissingCode + `'`
	if missing {
		q = `UPDATE jira_accounts SET error = '` + PDRScopeMissingCode + `' WHERE id = ? AND error = ''`
	}
	if _, err := db.Exec(q, id); err != nil {
		return fmt.Errorf("setting jira account %d PDR scope hint: %w", id, err)
	}
	return nil
}
