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
// people, the people its issues' user-picker custom fields name
// (CustomFieldPeopleKey), the account's own owner, the authors on its
// Confluence spaces, and the site-independent jira_user_map and Confluence
// ext_users rows. Atlassian
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
  UNION ALL SELECT json_extract(p.value, '$.id'), i.synced_at FROM jira_issues i,
    json_each(CASE WHEN instr(i.custom_fields_json, '"_people"') > 0 AND json_valid(i.custom_fields_json) THEN i.custom_fields_json ELSE '{}' END, '$._people') r,
    json_each(CASE WHEN r.type = 'array' THEN r.value ELSE '[]' END) p
    WHERE i.account_id = ?1 AND p.type = 'object'
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

// AtlassianErasePlan is what EraseAtlassianPeople writes, computed before
// its write transaction, so no scan of the issue payloads, custom fields or
// Confluence bodies runs while it holds the write lock. A row a concurrent
// sync writes between the plan and the transaction misses only its payload
// blanking, its custom field edit (guarded by the value the plan read) and
// its re-render mark: its person columns are erased in the transaction
// itself, and the next report (the id stays stored, so it is reported
// again) repeats the erase.
type AtlassianErasePlan struct {
	// RawJSONKeys are the account's issues whose stored payload names one
	// of the ids; the erase blanks the payload (a quiet issue is never
	// re-synced, so the next sync cannot be relied on to rewrite it).
	RawJSONKeys []string
	// CustomFields are the custom field values to rewrite: the closed
	// people's names removed from user-picker fields (by account id, one
	// entry of a multi-user field at a time; on a row written before the
	// ids were kept, a whole value equal to a name stored for the id, on
	// the issues RawJSONKeys lists).
	CustomFields []CustomFieldsEdit
	// Dirty are the knowledge documents rendered from rows naming one of
	// the ids, re-rendered on the next KB pass.
	Dirty []KBDocKey
}

// CustomFieldsEdit rewrites one issue's custom_fields_json from Old (the
// value the plan read; a row changed since is left alone) to New.
type CustomFieldsEdit struct{ Key, Old, New string }

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

// atlassianCustomFieldIssuesSQL lists the account's issues whose payload
// (?2 found in raw_json) or custom field values may name ?2, with their
// custom field values.
const atlassianCustomFieldIssuesSQL = `SELECT key, custom_fields_json, instr(raw_json, '"' || ?2 || '"') > 0 FROM jira_issues
  WHERE account_id = ?1 AND (instr(raw_json, '"' || ?2 || '"') > 0 OR instr(custom_fields_json, '"' || ?2 || '"') > 0)`

// PlanAtlassianErase reads, outside any write transaction, which issue
// payloads and knowledge documents the erase of ids on Jira account
// accountID touches, and computes the custom field rewrites.
func (db *DB) PlanAtlassianErase(ctx context.Context, accountID int64, ids []string) (AtlassianErasePlan, error) {
	var plan AtlassianErasePlan
	seen := map[string]bool{}
	add := func(list *[]string, kind, v string) {
		if v != "" && !seen[kind+"\x00"+v] {
			seen[kind+"\x00"+v] = true
			*list = append(*list, v)
		}
	}
	closed := make(map[string]bool, len(ids))
	for _, id := range ids {
		closed[id] = true
	}
	// The issues whose custom fields may change, in the order found, each
	// with the value read and whether its payload names a closed id.
	type candidate struct {
		custom string
		raw    bool
	}
	candidates := map[string]*candidate{}
	var candidateKeys []string
	names := map[string]bool{}
	for _, id := range ids {
		if err := db.scanCustomFieldIssues(ctx, accountID, id, func(key, custom string, raw bool) {
			c := candidates[key]
			if c == nil {
				c = &candidate{custom: custom}
				candidates[key] = c
				candidateKeys = append(candidateKeys, key)
			}
			if raw {
				c.raw = true
				add(&plan.RawJSONKeys, "raw", key)
			}
		}); err != nil {
			return plan, fmt.Errorf("planning atlassian erase (payloads): %w", err)
		}
		found, err := db.queryStrings(ctx, atlassianNamesSQL, accountID, id)
		if err != nil {
			return plan, fmt.Errorf("planning atlassian erase (names): %w", err)
		}
		for _, n := range found {
			if n != "" {
				names[n] = true
			}
		}
		keys, err := db.queryStrings(ctx, atlassianDirtyJiraSQL, accountID, id)
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
	for _, key := range candidateKeys {
		c := candidates[key]
		legacyNames := names
		if !c.raw {
			legacyNames = nil
		}
		if updated, changed := eraseCustomFieldPeople(c.custom, closed, legacyNames); changed {
			plan.CustomFields = append(plan.CustomFields, CustomFieldsEdit{Key: key, Old: c.custom, New: updated})
		}
	}
	return plan, nil
}

// scanCustomFieldIssues calls fn for each row of atlassianCustomFieldIssuesSQL.
func (db *DB) scanCustomFieldIssues(ctx context.Context, accountID int64, id string, fn func(key, custom string, raw bool)) error {
	rows, err := db.QueryContext(ctx, atlassianCustomFieldIssuesSQL, accountID, id)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var key, custom string
		var raw bool
		if err := rows.Scan(&key, &custom, &raw); err != nil {
			return err
		}
		fn(key, custom, raw)
	}
	return rows.Err()
}

// eraseCustomFieldPeople returns custom (a custom_fields_json value) with
// the closed people's names removed: each CustomFieldPeopleKey entry whose
// id is closed keeps its bare id with an empty name, and its role's display
// value is rebuilt from the names left. A role without ids (a row written
// before they were kept) whose whole value is one of names becomes "".
// changed is false when nothing was removed. A value that is not a JSON
// object only loses the quoted names (the textual replace of old).
func eraseCustomFieldPeople(custom string, closed, names map[string]bool) (string, bool) {
	if custom == "" {
		return custom, false
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal([]byte(custom), &fields); err != nil || fields == nil {
		out := custom
		for n := range names {
			if quoted, err := json.Marshal(n); err == nil {
				out = strings.ReplaceAll(out, string(quoted), `""`)
			}
		}
		return out, out != custom
	}
	changed := false
	var people map[string][]CustomFieldPerson
	if raw, ok := fields[CustomFieldPeopleKey]; ok && json.Unmarshal(raw, &people) != nil {
		people = nil
	}
	for role, list := range people {
		roleChanged := false
		for i, p := range list {
			if closed[p.ID] && p.Name != "" {
				list[i].Name = ""
				roleChanged = true
			}
		}
		if !roleChanged {
			continue
		}
		var left []string
		for _, p := range list {
			if p.Name != "" {
				left = append(left, p.Name)
			}
		}
		display, _ := json.Marshal(strings.Join(left, ", "))
		fields[role] = display
		changed = true
	}
	if changed {
		raw, err := json.Marshal(people)
		if err != nil {
			return custom, false
		}
		fields[CustomFieldPeopleKey] = raw
	}
	for role, raw := range fields {
		if role == CustomFieldPeopleKey || people[role] != nil {
			continue
		}
		var v string
		if json.Unmarshal(raw, &v) == nil && names[v] {
			fields[role] = json.RawMessage(`""`)
			changed = true
		}
	}
	if !changed {
		return custom, false
	}
	out, err := json.Marshal(fields)
	if err != nil {
		return custom, false
	}
	return string(out), true
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

// eraseChunk bounds the ids (or rows) one erase statement names.
const eraseChunk = 200

// valueRows returns n copies of row ("(?,?)") separated by commas, for a
// multi-row VALUES list.
func valueRows(n int, row string) string {
	return strings.TrimSuffix(strings.Repeat(row+",", n), ",")
}

// EraseAtlassianPeople erases, inside tx, what Atlassian told Watchtower
// about each closed account in ids, for Jira account accountID (#1887 §6,
// D17): the jira_user_map row (with its Slack mapping) and the Confluence
// ext_users row go; every atlassianPersonColumns column on the account's rows
// naming the id becomes empty; the payloads plan found are blanked, its
// custom field rewrites applied and its documents marked in kb_dirty. Every
// write is batched (one statement per column, per payload chunk, per edit
// chunk, per mark chunk), and everything it writes was computed by
// PlanAtlassianErase, so the write lock is held only for the writes. Memory
// and free-text derived texts are not touched (P6, ask #1518). Idempotent: a
// second run changes nothing.
func (db *DB) EraseAtlassianPeople(ctx context.Context, tx *sql.Tx, accountID int64, ids []string, plan AtlassianErasePlan) error {
	for start := 0; start < len(ids); start += eraseChunk {
		chunk := ids[start:min(start+eraseChunk, len(ids))]
		in := placeholders(len(chunk))
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
	for start := 0; start < len(plan.RawJSONKeys); start += eraseChunk {
		chunk := plan.RawJSONKeys[start:min(start+eraseChunk, len(plan.RawJSONKeys))]
		args := []any{accountID}
		for _, k := range chunk {
			args = append(args, k)
		}
		//nolint:gosec // G202: the IN list is only "?" placeholders; every value is a bound arg.
		q := `UPDATE jira_issues SET raw_json = '' WHERE account_id = ? AND raw_json != '' AND key IN (` + placeholders(len(chunk)) + `)`
		if _, err := tx.ExecContext(ctx, q, args...); err != nil {
			return fmt.Errorf("erasing issue payloads: %w", err)
		}
	}
	for start := 0; start < len(plan.CustomFields); start += eraseChunk {
		chunk := plan.CustomFields[start:min(start+eraseChunk, len(plan.CustomFields))]
		args := make([]any, 0, 3*len(chunk)+1)
		for _, e := range chunk {
			args = append(args, e.Key, e.Old, e.New)
		}
		args = append(args, accountID)
		//nolint:gosec // G202: the VALUES list is only "?" placeholders; every value is a bound arg.
		q := `UPDATE jira_issues SET custom_fields_json = e.column3 FROM (VALUES ` + valueRows(len(chunk), "(?,?,?)") + `) AS e
			WHERE jira_issues.account_id = ? AND jira_issues.key = e.column1 AND jira_issues.custom_fields_json = e.column2`
		if _, err := tx.ExecContext(ctx, q, args...); err != nil {
			return fmt.Errorf("erasing custom field names: %w", err)
		}
	}
	for start := 0; start < len(plan.Dirty); start += eraseChunk {
		chunk := plan.Dirty[start:min(start+eraseChunk, len(plan.Dirty))]
		args := make([]any, 0, 2*len(chunk))
		for _, k := range chunk {
			args = append(args, k.Source, k.Key)
		}
		//nolint:gosec // G202: the VALUES list is only "?" placeholders; every value is a bound arg.
		q := `INSERT INTO kb_dirty (source, key) VALUES ` + valueRows(len(chunk), "(?,?)") + `
			ON CONFLICT (source, key) DO UPDATE SET gen = gen + 1`
		if _, err := tx.ExecContext(ctx, q, args...); err != nil {
			return fmt.Errorf("marking documents for re-render: %w", err)
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
