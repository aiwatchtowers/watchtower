package cmd

import (
	"encoding/json"
	"errors"
	"io"

	"watchtower/internal/db"
	"watchtower/internal/jira"
)

// The retirement banners' data (#1887 T10): `google accounts --json` and
// `jira accounts --json` say which accounts still run on our shared apps —
// Gmail on the shared Google client (D11), Jira on the retiring shared
// Atlassian app (D4, D15) — and the day Atlassian sharing ends. The Desktop
// shows the banners from these flags; Go owns the resolver that decides them.

// accountGone is a row that no longer syncs anything (removed or purged), so
// no banner counts it.
func accountGone(status string) bool {
	return status == "removed" || status == "purged"
}

// googleAccountJSON is one `google accounts --json` row.
type googleAccountJSON struct {
	ID              int64  `json:"id"`
	Label           string `json:"label"`
	Email           string `json:"email"`
	Status          string `json:"status"`
	Error           string `json:"error"`
	CalendarEnabled bool   `json:"calendar_enabled"`
	GmailEnabled    bool   `json:"gmail_enabled"`
	// CompanySlug is the company bundle whose OAuth client the account signed
	// in with; "" = no company (the shared client, or an own project).
	CompanySlug string `json:"company_slug"`
	// SharedGmail: the account syncs Gmail through our shared Google client,
	// which no longer grants Gmail (D11) — the shared-Google banner.
	SharedGmail bool `json:"shared_gmail"`
}

// googleSharedGmail reports an account that syncs Gmail on our shared Google
// client (googleOnSharedClient). An account whose client cannot be resolved
// is a Re-login row (the daemon records the error on it, carried in status
// and error), not a banner one.
func googleSharedGmail(workspaceDir string, a db.GoogleAccount) bool {
	if !a.GmailEnabled || accountGone(a.Status) {
		return false
	}
	cfg, _, err := resolveGoogleOAuthConfigForAccount(workspaceDir, a)
	return err == nil && googleOnSharedClient(cfg.ClientID)
}

func writeGoogleAccountsJSON(w io.Writer, workspaceDir string, accounts []db.GoogleAccount) error {
	rows := make([]googleAccountJSON, 0, len(accounts))
	for _, a := range accounts {
		rows = append(rows, googleAccountJSON{
			ID: a.ID, Label: a.Label, Email: a.Email, Status: a.Status, Error: a.Error,
			CalendarEnabled: a.CalendarEnabled, GmailEnabled: a.GmailEnabled,
			CompanySlug: a.CompanySlug, SharedGmail: googleSharedGmail(workspaceDir, a),
		})
	}
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(rows)
}

// jiraAccountJSON is one `jira accounts --json` row.
type jiraAccountJSON struct {
	ID       int64  `json:"id"`
	Label    string `json:"label"`
	SiteURL  string `json:"site_url"`
	Status   string `json:"status"`
	Enabled  bool   `json:"enabled"`
	Error    string `json:"error"`
	AuthKind string `json:"auth_kind"`
	// CompanySlug is the company bundle whose OAuth client the account signed
	// in with; "" = no company.
	CompanySlug string `json:"company_slug"`
	// SharedAtlassian: the account signed in through our retiring shared
	// Atlassian app (D4) — the shared-Atlassian banner.
	SharedAtlassian bool `json:"shared_atlassian"`
}

// jiraAccountsJSON is the `jira accounts --json` document.
type jiraAccountsJSON struct {
	// SharedAppCutoff is jira.SharedAppCutoff (YYYY-MM-DD; "" = not known):
	// the day Atlassian sharing on our shared app ends (D15).
	SharedAppCutoff string            `json:"shared_app_cutoff"`
	Accounts        []jiraAccountJSON `json:"accounts"`
}

// jiraOnSharedApp reports an OAuth account on our shared Atlassian app: no
// company and no client file of its own, so its client is the env or baked
// one — or none at all once the public build stops baking it (D4), when the
// account needs a company's app to sign in again (its status and error say
// so). An API-token site has no app; a tied account or an own client file is
// a company's app, and so is a flavoured build's baked client.
func jiraOnSharedApp(workspaceDir string, a db.JiraAccount) bool {
	if BuildFlavor != "" || a.AuthKind == "api_token" || a.CompanySlug != "" || accountGone(a.Status) {
		return false
	}
	_, src, err := resolveJiraOAuthConfigForAccount(workspaceDir, a)
	if err != nil {
		return errors.Is(err, errNoOAuthClient)
	}
	return src == clientSourceEnv || src == clientSourceBaked
}

func writeJiraAccountsJSON(w io.Writer, workspaceDir string, accounts []db.JiraAccount) error {
	doc := jiraAccountsJSON{SharedAppCutoff: jira.SharedAppCutoff, Accounts: make([]jiraAccountJSON, 0, len(accounts))}
	for _, a := range accounts {
		authKind := a.AuthKind
		if authKind == "" {
			authKind = "oauth"
		}
		doc.Accounts = append(doc.Accounts, jiraAccountJSON{
			ID: a.ID, Label: a.Label, SiteURL: a.SiteURL, Status: a.Status, Enabled: a.Enabled, Error: a.Error,
			AuthKind: authKind, CompanySlug: a.CompanySlug, SharedAtlassian: jiraOnSharedApp(workspaceDir, a),
		})
	}
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(doc)
}
