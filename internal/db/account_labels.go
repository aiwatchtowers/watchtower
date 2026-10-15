package db

import (
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"net/url"
	"strconv"
	"strings"

	"golang.org/x/net/idna"
)

// Account labels — the name a connected account shows under in Settings, the
// tray and the AI prompt. The owner never types one when connecting: the
// account gets an automatic label from what the connect resolved (the Slack
// team, the mail domain, the Jira site, the calendar host), suffixed " 2",
// " 3", … when another account of the same kind already uses it. The owner
// renames it in Settings. This file is the one place that rule lives; the CLI
// and the Desktop (through the CLI) both go through it.

// publicMailDomains are consumer mail providers: an account there is named by
// its full address, since the domain alone ("gmail.com") tells two people's
// accounts apart no better than nothing.
var publicMailDomains = map[string]bool{
	"gmail.com": true, "googlemail.com": true,
	"outlook.com": true, "hotmail.com": true, "live.com": true, "msn.com": true,
	"yahoo.com": true, "ymail.com": true, "aol.com": true,
	"icloud.com": true, "me.com": true, "mac.com": true,
	"proton.me": true, "protonmail.com": true, "pm.me": true,
	"gmx.com": true, "gmx.net": true, "gmx.de": true, "mail.com": true,
	"yandex.ru": true, "yandex.com": true, "ya.ru": true, "mail.ru": true, "ukr.net": true,
	"fastmail.com": true, "hey.com": true, "zoho.com": true, "tutanota.com": true,
	"qq.com": true, "163.com": true,
}

// SlackAccountLabel is the automatic label of a Slack workspace: its team
// name, else its team domain ("acme" of acme.slack.com), else "".
func SlackAccountLabel(teamName, teamDomain string) string {
	if name := strings.TrimSpace(teamName); name != "" {
		return name
	}
	return strings.ToLower(strings.TrimSpace(teamDomain))
}

// JiraAccountLabel is the automatic label of a Jira site: its host without
// ".atlassian.net" ("acme" for https://acme.atlassian.net), a custom domain
// whole, else the site name, else "".
func JiraAccountLabel(siteURL, siteName string) string {
	if host := urlHost(siteURL); host != "" {
		if site := strings.TrimSuffix(host, ".atlassian.net"); site != "" {
			return site
		}
	}
	return strings.TrimSpace(siteName)
}

// MailAccountLabel is the automatic label of a mail account (Google, Outlook,
// IMAP): the address's domain, or the whole address on a public mail domain.
// An address without a domain falls back to fallbackHost (an IMAP login that
// is not an address names the account by its server).
func MailAccountLabel(address, fallbackHost string) string {
	address = strings.TrimSpace(address)
	at := strings.LastIndex(address, "@")
	if at <= 0 || at == len(address)-1 {
		return normalizeHost(fallbackHost)
	}
	domain := normalizeHost(address[at+1:])
	if domain == "" {
		return normalizeHost(fallbackHost)
	}
	if publicMailDomains[domain] {
		return address[:at+1] + domain
	}
	return domain
}

// CalDAVAccountLabel is the automatic label of a CalDAV account: its server
// host, else the username.
func CalDAVAccountLabel(serverURL, username string) string {
	if host := urlHost(serverURL); host != "" {
		return host
	}
	return strings.TrimSpace(username)
}

// ICSAccountLabel is the automatic label of an ICS feed: the calendar name the
// feed declares, else the feed's host. Only the host of the secret feed URL
// is ever kept.
func ICSAccountLabel(calendarName, feedURL string) string {
	if name := strings.TrimSpace(calendarName); name != "" {
		return name
	}
	return urlHost(feedURL)
}

// UniqueAccountLabel returns base, or base suffixed " 2", " 3", … when taken
// (compared case-insensitively) already holds it. An empty base stays empty.
func UniqueAccountLabel(base string, taken []string) string {
	base = strings.TrimSpace(base)
	if base == "" {
		return ""
	}
	used := make(map[string]bool, len(taken))
	for _, t := range taken {
		used[strings.ToLower(strings.TrimSpace(t))] = true
	}
	label := base
	for n := 2; used[strings.ToLower(label)]; n++ {
		label = base + " " + strconv.Itoa(n)
	}
	return label
}

// urlHost returns the normalized host of raw ("" when it has none); a bare
// host without a scheme is accepted too.
func urlHost(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	if !strings.Contains(raw, "://") {
		raw = "https://" + raw
	}
	u, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	return strings.TrimPrefix(normalizeHost(u.Hostname()), "www.")
}

// normalizeHost lowercases host, drops a trailing dot and shows an IDN host
// in Unicode ("xn--80ak6aa92e.com" → "пример.com"). A host idna rejects is
// kept lowercased as given.
func normalizeHost(host string) string {
	host = strings.TrimSuffix(strings.ToLower(strings.TrimSpace(host)), ".")
	if host == "" {
		return ""
	}
	if u, err := idna.ToUnicode(host); err == nil && u != "" {
		return u
	}
	return host
}

// accountLabelTables are the account tables with an automatic label. A
// removed account (slack_accounts/jira_accounts keep the row) neither takes a
// label nor blocks one, so reconnecting a removed workspace gets its plain
// name back.
var accountLabelTables = map[string]bool{
	"slack_accounts": true, "jira_accounts": true, "google_accounts": true,
	"email_accounts": true, "calendar_accounts": true,
}

// fillAccountLabel gives row id of table the automatic label built from base
// when its label is still empty; a label already set (the owner's, or an
// earlier automatic one) is never replaced. An empty base writes nothing.
func fillAccountLabel(tx *sql.Tx, table string, id int64, base string) error {
	if !accountLabelTables[table] {
		return fmt.Errorf("fill account label: unknown table %q", table)
	}
	if strings.TrimSpace(base) == "" {
		return nil
	}
	// The common case — a Slack resolve every sync — finds the label set
	// already: skip the scan of the other labels.
	var current string
	// #nosec G202 -- table is checked against accountLabelTables above.
	if err := tx.QueryRow(`SELECT label FROM `+table+` WHERE id = ?`, id).Scan(&current); err != nil {
		return fmt.Errorf("reading %s %d label: %w", table, id, err)
	}
	if current != "" {
		return nil
	}
	var taken []string
	// #nosec G202 -- table is checked against accountLabelTables above.
	err := eachLabelRow(tx, `SELECT label FROM `+table+` WHERE id != ? AND label != ''`+notRemoved(table),
		[]any{id}, func(rows *sql.Rows) error {
			var l string
			if err := rows.Scan(&l); err != nil {
				return err
			}
			taken = append(taken, l)
			return nil
		})
	if err != nil {
		return fmt.Errorf("reading %s labels: %w", table, err)
	}
	// #nosec G202 -- table is checked against accountLabelTables above.
	if _, err := tx.Exec(`UPDATE `+table+` SET label = ? WHERE id = ? AND label = ''`,
		UniqueAccountLabel(base, taken), id); err != nil {
		return fmt.Errorf("setting %s %d label: %w", table, id, err)
	}
	return nil
}

// eachLabelRow runs query on q (the DB or a transaction) and calls scan for
// each row.
func eachLabelRow(q interface {
	Query(string, ...any) (*sql.Rows, error)
}, query string, args []any, scan func(*sql.Rows) error) error {
	rows, err := q.Query(query, args...)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		if err := scan(rows); err != nil {
			return err
		}
	}
	return rows.Err()
}

func notRemoved(table string) string {
	if table == "slack_accounts" || table == "jira_accounts" {
		return ` AND status != 'removed'`
	}
	return ""
}

// inLabelTx runs fn in a write transaction — the read of the other labels and
// the write of this one must not interleave with another connect.
func (db *DB) inLabelTx(fn func(tx *sql.Tx) error) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("beginning transaction: %w", err)
	}
	defer tx.Rollback() //nolint:errcheck // no-op after Commit
	if err := fn(tx); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("committing: %w", err)
	}
	return nil
}

// fillAccountLabelBestEffort fills the automatic label of a row whose
// identity is already saved, in its own transaction. The label is cosmetic:
// a failure here must never undo the connect or stop a sync, so it is logged
// and the account shows under its fallback name until the next try (every
// Slack sync, the daemon-start backfill).
func (db *DB) fillAccountLabelBestEffort(table string, id int64, base string) {
	if err := db.inLabelTx(func(tx *sql.Tx) error {
		return fillAccountLabel(tx, table, id, base)
	}); err != nil {
		slog.Warn("account label not set", "table", table, "id", id, "error", err)
	}
}

// FillEmptyAccountLabels gives every account still without a label (one
// connected before labels were automatic) its automatic label, oldest account
// first so the older one keeps the plain name. An ICS feed stays empty: its
// calendar name and host live only in the feed, never in the database.
// Idempotent; run once at daemon start.
func (db *DB) FillEmptyAccountLabels() error {
	// Each query reads id plus the two columns its rule takes.
	sources := []struct {
		table, query string
		base         func(a, b string) string
	}{
		{"slack_accounts", `SELECT id, team_name, team_domain FROM slack_accounts WHERE label = '' AND status != 'removed' ORDER BY id`,
			SlackAccountLabel},
		{"jira_accounts", `SELECT id, site_url, site_name FROM jira_accounts WHERE label = '' AND status != 'removed' ORDER BY id`,
			JiraAccountLabel},
		{"google_accounts", `SELECT id, email, '' FROM google_accounts WHERE label = '' ORDER BY id`,
			MailAccountLabel},
		{"email_accounts", `SELECT id, email_address, host FROM email_accounts WHERE label = '' ORDER BY id`,
			MailAccountLabel},
		{"calendar_accounts", `SELECT id, url, username FROM calendar_accounts WHERE label = '' AND provider = 'caldav' ORDER BY id`,
			CalDAVAccountLabel},
	}
	type pending struct {
		table string
		id    int64
		base  string
	}
	var todo []pending
	for _, s := range sources {
		err := eachLabelRow(db, s.query, nil, func(rows *sql.Rows) error {
			var id int64
			var a, b string
			if err := rows.Scan(&id, &a, &b); err != nil {
				return err
			}
			todo = append(todo, pending{s.table, id, s.base(a, b)})
			return nil
		})
		if err != nil {
			return fmt.Errorf("listing unlabeled %s: %w", s.table, err)
		}
	}
	// One transaction per account: one that fails leaves the others named.
	var errs []error
	for _, p := range todo {
		if strings.TrimSpace(p.base) == "" {
			slog.Info("account has nothing to name it by yet; it shows under its fallback name",
				"table", p.table, "id", p.id)
			continue
		}
		if err := db.inLabelTx(func(tx *sql.Tx) error {
			return fillAccountLabel(tx, p.table, p.id, p.base)
		}); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}

// RenameAccount sets the label of account id in table ("slack_accounts", …)
// to label, trimmed. An empty label is refused — the automatic label is only
// given at connect — and so are a missing account and a removed Slack/Jira
// one (its row is kept, but nothing shows it).
func (db *DB) RenameAccount(table string, id int64, label string) error {
	if !accountLabelTables[table] {
		return fmt.Errorf("rename account: unknown table %q", table)
	}
	label = strings.TrimSpace(label)
	if label == "" {
		return errors.New("rename account: the name must not be empty")
	}
	// #nosec G202 -- table is checked against accountLabelTables above.
	res, err := db.Exec(`UPDATE `+table+` SET label = ? WHERE id = ?`+notRemoved(table), label, id)
	if err != nil {
		return fmt.Errorf("renaming account %d: %w", id, err)
	}
	if n, _ := res.RowsAffected(); n > 0 {
		return nil
	}
	var exists bool
	// #nosec G202 -- table is checked against accountLabelTables above.
	if err := db.QueryRow(`SELECT EXISTS(SELECT 1 FROM `+table+` WHERE id = ?)`, id).Scan(&exists); err != nil {
		return fmt.Errorf("renaming account %d: %w", id, err)
	}
	if exists {
		return fmt.Errorf("renaming account: account %d was removed — reconnect it to use it again", id)
	}
	return fmt.Errorf("renaming account: no account %d", id)
}
