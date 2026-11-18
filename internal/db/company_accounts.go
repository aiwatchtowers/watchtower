package db

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"slices"

	"watchtower/internal/oauthclient"
)

// Company ties on account rows (#1887, migration 00198): company_slug names
// the company bundle (<workspace>/company/<slug>.json) whose OAuth client an
// account signed in with; '' = our shared client. Go owns the column; Swift
// only reads it.

// CompanyAccountSources lists the sources whose accounts can belong to a
// company, in the order AccountsByCompany and MarkCompanyAccounts report them.
var CompanyAccountSources = []string{"slack", "google", "jira", "linear", "outlook"}

// companyAccountTable is one company source's table, plus the row filter that
// narrows a shared table to that source (Outlook shares email_accounts with
// IMAP). Both are fixed SQL, never built from input.
type companyAccountTable struct {
	table, filter string
	// markSet is appended to MarkCompanyAccounts' SET list (the table's own
	// updated_at, as its Set*AuthState writer keeps it).
	markSet string
}

var companyAccountTables = map[string]companyAccountTable{
	"slack":   {table: "slack_accounts"},
	"google":  {table: "google_accounts", markSet: `, updated_at = ` + nowSQL},
	"jira":    {table: "jira_accounts"},
	"linear":  {table: "linear_accounts"},
	"outlook": {table: "email_accounts", filter: ` AND provider = 'outlook'`, markSet: `, updated_at = ` + nowSQL},
}

func companyTable(source string) (companyAccountTable, error) {
	t, ok := companyAccountTables[source]
	if !ok {
		return companyAccountTable{}, fmt.Errorf("unknown company account source %q", source)
	}
	return t, nil
}

// CompanyAccountRef is one account tied to a company, as AccountsByCompany
// and MarkCompanyAccounts report it. IDs are per source, so Source is part of
// the key.
type CompanyAccountRef struct {
	Source string
	ID     int64
	Status string
	Error  string
}

// SetAccountCompany ties one account to slug (empty unties it). source is
// one of CompanyAccountSources; a missing row (or an IMAP mailbox named as
// "outlook") is an error.
func (db *DB) SetAccountCompany(source string, id int64, slug string) error {
	t, err := companyTable(source)
	if err != nil {
		return err
	}
	res, err := db.Exec(`UPDATE `+t.table+` SET company_slug = ? WHERE id = ?`+t.filter, slug, id)
	if err != nil {
		return fmt.Errorf("setting company of %s account %d: %w", source, id, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("setting company: no %s account %d", source, id)
	}
	return nil
}

// RetieAccounts moves every account in refs from company from to company to
// (an empty slug is the shared client) in one write transaction — the corp bridge's tie
// and its undo (#1887 T11a). A row already on to counts as moved. A row on
// a third company, a missing row, or an unknown source fails the whole call
// and changes nothing.
func (db *DB) RetieAccounts(refs []CompanyAccountRef, from, to string) error {
	if len(refs) == 0 {
		return nil
	}
	ctx := context.Background()
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("retying accounts: begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	for _, r := range refs {
		t, err := companyTable(r.Source)
		if err != nil {
			return fmt.Errorf("retying accounts: %w", err)
		}
		res, err := tx.ExecContext(ctx, `UPDATE `+t.table+` SET company_slug = ?
			WHERE id = ? AND company_slug IN (?, ?)`+t.filter, to, r.ID, from, to)
		if err != nil {
			return fmt.Errorf("retying %s account %d: %w", r.Source, r.ID, err)
		}
		if n, _ := res.RowsAffected(); n == 0 {
			return fmt.Errorf("retying accounts: %s account %d is gone or tied to another company", r.Source, r.ID)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("retying accounts: commit: %w", err)
	}
	return nil
}

// AccountsByCompany returns every account tied to slug, whatever its status,
// in CompanyAccountSources order and by id within a source. An empty slug is
// refused: it is the shared client, not a company.
func (db *DB) AccountsByCompany(slug string) ([]CompanyAccountRef, error) {
	if slug == "" {
		return nil, errors.New("accounts by company: empty company slug")
	}
	var out []CompanyAccountRef
	for _, source := range CompanyAccountSources {
		t := companyAccountTables[source]
		refs, err := queryCompanyAccountRefs(context.Background(), db.DB, source, slug,
			`SELECT id, status, error FROM `+t.table+` WHERE company_slug = ?`+t.filter, slug)
		if err != nil {
			return nil, err
		}
		out = append(out, refs...)
	}
	return out, nil
}

// markableStatusSQL limits MarkCompanyAccounts to live rows: a revoked row
// keeps its purge clock (PURGE-01), a removed or purged row stays as it is.
const markableStatusSQL = ` AND status IN ('ok','error')`

// MarkCompanyAccounts puts every live account of slug from sources into
// status 'error' with error text code (e.g. company_changed_app), in one
// write transaction, and returns the rows it marked. Revoked, removed and
// purged rows are left alone. An unknown source, an empty slug or an empty
// code marks nothing.
func (db *DB) MarkCompanyAccounts(slug string, sources []string, code string) ([]CompanyAccountRef, error) {
	if slug == "" {
		return nil, errors.New("marking company accounts: empty company slug")
	}
	if code == "" {
		return nil, errors.New("marking company accounts: empty error code")
	}
	want := map[string]bool{}
	for _, source := range sources {
		if _, err := companyTable(source); err != nil {
			return nil, fmt.Errorf("marking company accounts: %w", err)
		}
		want[source] = true
	}

	ctx := context.Background()
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("marking company accounts: begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	var out []CompanyAccountRef
	for _, source := range CompanyAccountSources {
		if !want[source] {
			continue
		}
		t := companyAccountTables[source]
		refs, err := queryCompanyAccountRefs(ctx, tx, source, slug, `UPDATE `+t.table+` SET status = 'error', error = ?`+t.markSet+`
			WHERE company_slug = ?`+t.filter+markableStatusSQL+` RETURNING id, status, error`, code, slug)
		if err != nil {
			return nil, err
		}
		out = append(out, refs...)
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("marking company accounts: commit: %w", err)
	}
	return out, nil
}

// MarkAccountClientRejected records that the vendor refused the OAuth client
// of source's account id: status 'error' with oauthclient.RejectedCode of the
// row's own company_slug (invalid_client when tied, unknown_client when not),
// in one statement, so a re-tie between a read and the write cannot pick the
// wrong code. Like MarkCompanyAccounts it marks only a live row — a revoked
// row keeps its purge clock (PURGE-01), a removed or purged row stays — and
// reports whether it marked one.
func (db *DB) MarkAccountClientRejected(source string, id int64) (bool, error) {
	t, err := companyTable(source)
	if err != nil {
		return false, err
	}
	res, err := db.Exec(`UPDATE `+t.table+` SET status = 'error',
		error = CASE WHEN company_slug <> '' THEN ? ELSE ? END`+t.markSet+`
		WHERE id = ?`+t.filter+markableStatusSQL,
		oauthclient.CodeInvalidClient, oauthclient.CodeUnknownClient, id)
	if err != nil {
		return false, fmt.Errorf("marking %s account %d client rejected: %w", source, id, err)
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// queryCompanyAccountRefs runs query, which answers (id, status, error) rows
// of source's accounts of slug, and returns them sorted by id (RETURNING
// promises no order).
func queryCompanyAccountRefs(ctx context.Context, q ContextQueryer, source, slug, query string, args ...any) ([]CompanyAccountRef, error) {
	rows, err := q.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("reading %s accounts of company %q: %w", source, slug, err)
	}
	defer rows.Close()
	var out []CompanyAccountRef
	for rows.Next() {
		r := CompanyAccountRef{Source: source}
		if err := rows.Scan(&r.ID, &r.Status, &r.Error); err != nil {
			return nil, fmt.Errorf("scanning %s account of company %q: %w", source, slug, err)
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading %s accounts of company %q: %w", source, slug, err)
	}
	slices.SortFunc(out, func(a, b CompanyAccountRef) int { return cmp.Compare(a.ID, b.ID) })
	return out, nil
}
