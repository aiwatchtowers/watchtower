package db

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

// AtlassianPerson is one Atlassian account id Watchtower stores for a Jira
// account (its site's rows plus the site-independent user caches), with the
// newest time a row naming it was fetched (zero when no row says).
type AtlassianPerson struct {
	ID        string
	UpdatedAt time.Time
}

// atlassianPeopleSQL collects every Atlassian account id stored for one Jira
// account (?1): the site's issue, linked-issue, comment and changelog
// people, the account's own owner, the authors on its Confluence spaces, and
// the site-independent jira_user_map and Confluence ext_users rows (Atlassian
// ids are global, so those caches belong to every site).
const atlassianPeopleSQL = `SELECT id, MAX(ts) FROM (
  SELECT assignee_account_id AS id, synced_at AS ts FROM jira_issues WHERE account_id = ?1
  UNION ALL SELECT reporter_account_id, synced_at FROM jira_issues WHERE account_id = ?1
  UNION ALL SELECT assignee_account_id, synced_at FROM jira_linked_issues WHERE account_id = ?1
  UNION ALL SELECT author_account_id, synced_at FROM jira_comments WHERE account_id = ?1
  UNION ALL SELECT author_account_id, '' FROM jira_issue_changelog WHERE account_id = ?1
  UNION ALL SELECT from_value, '' FROM jira_issue_changelog WHERE account_id = ?1 AND field = 'assignee'
  UNION ALL SELECT to_value, '' FROM jira_issue_changelog WHERE account_id = ?1 AND field = 'assignee'
  UNION ALL SELECT owner_account_id, '' FROM jira_accounts WHERE id = ?1
  UNION ALL SELECT d.author_id, d.synced_at FROM ext_documents d JOIN ext_sources s ON s.id = d.source_id WHERE s.jira_account_id = ?1
  UNION ALL SELECT c.author_id, '' FROM ext_comments c JOIN ext_sources s ON s.id = c.source_id WHERE s.jira_account_id = ?1
  UNION ALL SELECT jira_account_id, resolved_at FROM jira_user_map
  UNION ALL SELECT ext_user_id, fetched_at FROM ext_users WHERE provider = 'confluence'
) WHERE id != '' GROUP BY id ORDER BY id`

// AtlassianPeople returns the Atlassian account ids stored for Jira account
// accountID (atlassianPeopleSQL), sorted, each with the newest parseable
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
// tables the erase leaves alone, each with the reason.
var atlassianPeopleKeptColumns = map[string]string{
	// The issue's custom field values: a user-picker value is stored as the
	// display name only, with no account id to match it by; the next sync of
	// the issue rewrites it with what Atlassian returns (anonymised for a
	// closed account).
	"jira_issues.custom_fields_json": "user-picker values carry no account id; rewritten by the next issue sync",
}

// AtlassianErasePlan is what EraseAtlassianPeople needs read before its
// write transaction, so no scan of the issue payloads or Confluence bodies
// runs while it holds the write lock.
type AtlassianErasePlan struct {
	// RawJSONKeys are the account's issues whose stored payload names one
	// of the ids; the erase blanks the payload (the next sync refills it).
	RawJSONKeys []string
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

// atlassianDirtyConfluenceSQL lists the account's Confluence documents that
// name ?2: as author, as a commenter on the page, or in a mention token.
const atlassianDirtyConfluenceSQL = `SELECT 'confluence:' || d.source_id || ':' || d.ext_id FROM ext_documents d JOIN ext_sources s ON s.id = d.source_id
    WHERE s.jira_account_id = ?1 AND (d.author_id = ?2 OR instr(d.sections_json, '@[~' || ?2 || ']') > 0)
  UNION SELECT 'confluence:' || c.source_id || ':' || c.page_ext_id FROM ext_comments c JOIN ext_sources s ON s.id = c.source_id
    WHERE s.jira_account_id = ?1 AND (c.author_id = ?2 OR instr(c.body_text, '@[~' || ?2 || ']') > 0)`

// PlanAtlassianErase reads, outside any write transaction, which issue
// payloads and knowledge documents of Jira account accountID name one of
// ids.
func (db *DB) PlanAtlassianErase(ctx context.Context, accountID int64, ids []string) (AtlassianErasePlan, error) {
	var plan AtlassianErasePlan
	rawSeen, dirtySeen := map[string]bool{}, map[KBDocKey]bool{}
	addDirty := func(k KBDocKey) {
		if !dirtySeen[k] {
			dirtySeen[k] = true
			plan.Dirty = append(plan.Dirty, k)
		}
	}
	for _, id := range ids {
		keys, err := queryStringsCtx(ctx, db, `SELECT key FROM jira_issues WHERE account_id = ? AND instr(raw_json, '"' || ? || '"') > 0`, accountID, id)
		if err != nil {
			return plan, fmt.Errorf("planning atlassian erase (payloads): %w", err)
		}
		for _, k := range keys {
			if !rawSeen[k] {
				rawSeen[k] = true
				plan.RawJSONKeys = append(plan.RawJSONKeys, k)
			}
		}
		keys, err = queryStringsCtx(ctx, db, atlassianDirtyJiraSQL, accountID, id)
		if err != nil {
			return plan, fmt.Errorf("planning atlassian erase (jira documents): %w", err)
		}
		for _, k := range keys {
			addDirty(KBDocKey{"jira", fmt.Sprintf("jira:%d:%s", accountID, k)})
		}
		keys, err = queryStringsCtx(ctx, db, atlassianDirtyConfluenceSQL, accountID, id)
		if err != nil {
			return plan, fmt.Errorf("planning atlassian erase (confluence documents): %w", err)
		}
		for _, k := range keys {
			addDirty(KBDocKey{"confluence", k})
		}
	}
	return plan, nil
}

func queryStringsCtx(ctx context.Context, db *DB, q string, args ...any) ([]string, error) {
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

// EraseAtlassianPeople erases, inside tx, what Atlassian told Watchtower
// about each closed account in ids, for Jira account accountID (#1887 §6,
// D17): the jira_user_map row (with its Slack mapping) and the Confluence
// ext_users row go; every atlassianPersonColumns column on the account's rows
// naming the id becomes empty; the payloads plan found are blanked; plan's
// documents are marked in kb_dirty. Memory and free-text derived texts are
// not touched (P6, ask #1518). Idempotent: a second run changes nothing.
func (db *DB) EraseAtlassianPeople(ctx context.Context, tx *sql.Tx, accountID int64, ids []string, plan AtlassianErasePlan) error {
	for _, id := range ids {
		for _, c := range atlassianPersonColumns {
			//nolint:gosec // G201: table and column names come from the package's constant atlassianPersonColumns; every value is a bound arg.
			q := fmt.Sprintf(`UPDATE %s SET %s = '' WHERE %s AND %s = ? AND %s != ''`, c.table, c.col, c.scope, c.idCol, c.col)
			if c.where != "" {
				q += " AND " + c.where
			}
			if _, err := tx.ExecContext(ctx, q, accountID, id); err != nil {
				return fmt.Errorf("erasing %s.%s: %w", c.table, c.col, err)
			}
		}
		for _, t := range atlassianPeopleDeletedTables {
			//nolint:gosec // G201: table and column names come from the package's constant atlassianPeopleDeletedTables; every value is a bound arg.
			q := fmt.Sprintf(`DELETE FROM %s WHERE %s = ?`, t.table, t.idCol)
			if t.where != "" {
				q += " AND " + t.where
			}
			if _, err := tx.ExecContext(ctx, q, id); err != nil {
				return fmt.Errorf("erasing %s: %w", t.table, err)
			}
		}
		for _, key := range plan.RawJSONKeys {
			if _, err := tx.ExecContext(ctx, `UPDATE jira_issues SET raw_json = '' WHERE account_id = ? AND key = ? AND instr(raw_json, '"' || ? || '"') > 0`,
				accountID, key, id); err != nil {
				return fmt.Errorf("erasing an issue payload: %w", err)
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

// MarkAtlassianPeopleStale makes the next Confluence sync that meets one of
// ids fetch its profile again (an "updated" report): the cached ext_users
// row reads as stale. jira_user_map is refreshed by the Jira sync from the
// issue payload (Syncer.ensureUserMap).
func (db *DB) MarkAtlassianPeopleStale(ctx context.Context, ids []string) error {
	if len(ids) == 0 {
		return nil
	}
	return db.WithTx(func(tx *sql.Tx) error {
		for _, id := range ids {
			if _, err := tx.ExecContext(ctx, `UPDATE ext_users SET fetched_at = '' WHERE provider = 'confluence' AND ext_user_id = ?`, id); err != nil {
				return fmt.Errorf("marking atlassian person stale: %w", err)
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
