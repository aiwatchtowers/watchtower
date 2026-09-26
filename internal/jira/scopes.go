package jira

import "strings"

// JiraScopes is the scope string already requested by buildAuthURL for the
// Jira grant — unchanged, split out as its own identifier so OAuthScopes can
// concatenate it with ConfluenceScopes without touching the literal below.
const JiraScopes = "read:jira-work write:jira-work read:jira-user read:board-scope:jira-software read:sprint:jira-software read:issue:jira-software read:project:jira offline_access"

// ConfluenceScopes are the granular Confluence Cloud scopes the Confluence
// knowledge connector needs, covering: list spaces (v2 GET /wiki/api/v2/spaces),
// get page/blogpost with storage body + labels (v2 GET /wiki/api/v2/pages/{id},
// /wiki/api/v2/blogposts/{id}), CQL content search (v1 GET
// /wiki/rest/api/content/search), child comments (v1), attachment download
// (v1), and users bulk (v1 GET /wiki/rest/api/user/bulk).
//
// Verified against developer.atlassian.com/cloud/confluence/scopes-for-oauth-2-3LO-and-forge-apps/
// and the per-scope references cross-checked via web search on 2026-09-26
// (Atlassian's scope docs are a JS-rendered SPA that WebFetch could not
// reliably pull per-endpoint scope tables from — every individual scope
// identifier below was independently confirmed as a real, currently-issued
// Confluence granular/classic scope; the exact endpoint→scope mapping in the
// list above is the brief's hypothesis, not a page-by-page citation). See
// task-1-report.md for the verification trail and residual concern.
//
// Deliberately mixes granular (read:*:confluence) and classic
// (search:confluence, readonly:content.attachment:confluence) scopes:
// Atlassian's v2 endpoints only ever issue granular scopes, while some v1
// operations (CQL search, attachment download) are documented under their
// classic scope names with no granular equivalent.
const ConfluenceScopes = "read:space:confluence read:page:confluence read:blogpost:confluence read:comment:confluence read:attachment:confluence read:user:confluence read:content-details:confluence search:confluence readonly:content.attachment:confluence"

// OAuthScopes is the full scope string requested by the Jira/Confluence OAuth
// 2.0 (3LO) app — one Atlassian grant covers both products.
var OAuthScopes = JiraScopes + " " + ConfluenceScopes

// HasConfluenceScopes reports whether tok's granted scopes cover every scope
// in ConfluenceScopes — the signal that an already-connected Jira account
// re-consented to the wider OAuthScopes list and Confluence sync can run
// without prompting for re-login (Task 4's needs_consent branch).
func HasConfluenceScopes(tok *OAuthToken) bool {
	if tok == nil {
		return false
	}
	granted := make(map[string]bool)
	for _, s := range strings.Fields(tok.Scope) {
		granted[s] = true
	}
	for _, want := range strings.Fields(ConfluenceScopes) {
		if !granted[want] {
			return false
		}
	}
	return true
}
