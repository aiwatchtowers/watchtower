// Package doclinks maintains doc_links (migration 00074), the mechanical
// cross-source mention graph of spec §10: Jira keys mentioned in Confluence
// text, and Confluence page URLs mentioned in Slack, mail and Jira. No AI
// call anywhere. Refs on both sides are knowledge-index document refs, so a
// link names the same document search_knowledge returns.
package doclinks

import (
	"context"
	"database/sql"
	"fmt"
	"net/url"
	"regexp"
	"strings"

	"watchtower/internal/jira"
)

// Queryer is the read/write surface shared by *db.DB and *sql.Tx (the
// internal/kb and internal/extsync precedent).
type Queryer interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

// Link kinds (doc_links.from_kind / to_kind).
const (
	KindConfluence     = "confluence"
	ToJiraIssue        = "jira_issue"
	ToConfluencePage   = "confluence_page"
	confluenceURLMatch = "atlassian.net/wiki/" // the SQL LIKE prefilter of every scanned text
)

// confluenceURL matches a page URL; the capture is the page id. Tiny links
// (/wiki/x/<code>) are deliberately not matched in v1: resolving one needs a
// lookup per link.
var confluenceURL = regexp.MustCompile(`https://[a-z0-9-]+\.atlassian\.net/wiki/spaces/[^/\s]+/pages/(\d+)`)

// JiraKeys returns the distinct Jira keys in text, in first-seen order. It
// is the bare key pattern (jira.KeyRegexp), not the known-project filter: a
// link to a key nobody synced is never looked up, so it is harmless.
func JiraKeys(text string) []string {
	return distinct(jira.KeyRegexp.FindAllString(text, -1))
}

// ConfluencePageIDs returns "<cloud_id>:<page_id>" for every page URL in
// text whose host is a connected site (siteHosts: lowercased host →
// cloud_id), distinct, in first-seen order.
func ConfluencePageIDs(text string, siteHosts map[string]string) []string {
	if len(siteHosts) == 0 {
		return nil
	}
	var out []string
	for _, m := range confluenceURL.FindAllStringSubmatch(text, -1) {
		rest := strings.TrimPrefix(m[0], "https://")
		host := rest[:strings.IndexByte(rest, '/')]
		if cloud, ok := siteHosts[host]; ok {
			out = append(out, cloud+":"+m[1])
		}
	}
	return distinct(out)
}

func distinct(in []string) []string {
	if len(in) == 0 {
		return nil
	}
	seen := make(map[string]bool, len(in))
	out := make([]string, 0, len(in))
	for _, s := range in {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}

// SiteHosts maps every connected Jira site's lowercased host to its
// cloud_id (removed accounts and rows without a site or cloud id excluded).
func SiteHosts(ctx context.Context, q Queryer) (map[string]string, error) {
	rows, err := q.QueryContext(ctx, `SELECT site_url, cloud_id FROM jira_accounts
		WHERE status != 'removed' AND cloud_id != '' AND site_url != ''`)
	if err != nil {
		return nil, fmt.Errorf("doclinks: listing sites: %w", err)
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var site, cloud string
		if err := rows.Scan(&site, &cloud); err != nil {
			return nil, fmt.Errorf("doclinks: scanning site: %w", err)
		}
		u, err := url.Parse(strings.TrimSpace(site))
		if err != nil || u.Hostname() == "" {
			continue // an unparsable site URL can match no link
		}
		out[strings.ToLower(u.Hostname())] = cloud
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("doclinks: listing sites: %w", err)
	}
	return out, nil
}

// LinkConfluenceDoc makes the Jira keys found in texts the whole set of
// fromRef's jira_issue links: a key no longer mentioned is deleted, a kept
// one keeps its detected_at, a new one is inserted. No texts = no links. It
// runs in the caller's transaction (extsync's batch tx).
func LinkConfluenceDoc(ctx context.Context, q Queryer, fromRef string, texts ...string) error {
	keys := JiraKeys(strings.Join(texts, "\n"))
	args := []any{KindConfluence, fromRef, ToJiraIssue}
	notIn := ""
	if len(keys) > 0 {
		notIn = ` AND to_ref NOT IN (` + strings.TrimSuffix(strings.Repeat("?,", len(keys)), ",") + `)`
		for _, k := range keys {
			args = append(args, k)
		}
	}
	if _, err := q.ExecContext(ctx, `DELETE FROM doc_links WHERE from_kind = ? AND from_ref = ? AND to_kind = ?`+notIn,
		args...); err != nil {
		return fmt.Errorf("doclinks: clearing links of %s: %w", fromRef, err)
	}
	for _, k := range keys {
		if _, err := q.ExecContext(ctx, `INSERT OR IGNORE INTO doc_links (from_kind, from_ref, to_kind, to_ref)
			VALUES (?, ?, ?, ?)`, KindConfluence, fromRef, ToJiraIssue, k); err != nil {
			return fmt.Errorf("doclinks: linking %s → %s: %w", fromRef, k, err)
		}
	}
	return nil
}
