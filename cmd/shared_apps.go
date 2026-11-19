package cmd

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"time"

	"watchtower/internal/calendar"
	"watchtower/internal/company"
	"watchtower/internal/config"
	"watchtower/internal/daemon"
	"watchtower/internal/db"
	"watchtower/internal/jira"
	"watchtower/internal/purge"
)

// The retirement banners' data (#1887 T10): `google accounts --json` and
// `jira accounts --json` say which accounts still run on our shared apps —
// Gmail on the shared Google client (D11), Jira on the retired shared
// Atlassian app (D4; D15 amended, ask #1600: no countdown, its accounts
// sign in again through a company's app). The Desktop shows the banners
// from these flags; Go owns the resolver that decides them.

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
	// OwnProject: the account signs in through a Google project the person
	// owns (company.IsOwnProject: a personal bundle, or an untied legacy
	// credentials file) — the Desktop's "Your own Google project" group and
	// its AllowOwnGoogleProject lock (#1887 C4).
	OwnProject bool `json:"own_project"`
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
	// An unreadable company directory fails the listing rather than report
	// a personal bundle's rows as not own (they would leave the §5.4 lock);
	// the Desktop keeps its last flags. A damaged single file is a LoadError
	// and leaves only that company's rows untold.
	entries, _, err := company.NewStore(workspaceDir).LoadAll(companyForcedBundle())
	if err != nil {
		return fmt.Errorf("reading companies: %w", err)
	}
	rows := make([]googleAccountJSON, 0, len(accounts))
	for _, a := range accounts {
		rows = append(rows, googleAccountJSON{
			ID: a.ID, Label: a.Label, Email: a.Email, Status: a.Status, Error: a.Error,
			CalendarEnabled: a.CalendarEnabled, GmailEnabled: a.GmailEnabled,
			CompanySlug: a.CompanySlug, SharedGmail: googleSharedGmail(workspaceDir, a),
			OwnProject: company.IsOwnProject(a, entries, calendar.NewCredentialStore(workspaceDir, a.ID).Exists()),
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
	// SharedAtlassian: the account signed in through our retired shared
	// Atlassian app (D4) — the shared-Atlassian banner ("sign in again").
	SharedAtlassian bool `json:"shared_atlassian"`
	// PurgeLeaseAt is the day PURGE-01's 30-day lease would delete the
	// account (RFC 3339), set only while that lease counts for it: purge on
	// under a rule with leases, the account not stopped by the policy
	// (POLICY-03 holds a locked token site's lease). The dead-token row's
	// note (#1887 §6.3) shows it; the Desktop keeps no copy of the rule.
	PurgeLeaseAt string `json:"purge_lease_at,omitempty"`
}

// jiraOnSharedApp reports an OAuth account on our shared Atlassian app: no
// company of its own, and its client is the baked shared id (on any layer) —
// or none at all once the public build stops baking it (D4), when the
// account needs a company's app to sign in again (its status and error say
// so). An API-token site has no app; a tied account is a company's, a
// development env client of another id is the developer's own app, and a
// flavoured build's baked client is its company's app.
func jiraOnSharedApp(workspaceDir string, a db.JiraAccount) bool {
	if BuildFlavor != "" || a.AuthKind == "api_token" || a.CompanySlug != "" || accountGone(a.Status) {
		return false
	}
	cfg, _, err := resolveJiraOAuthConfigForAccount(workspaceDir, a)
	if err != nil {
		return errors.Is(err, errNoOAuthClient)
	}
	return jira.DefaultJiraClientID != "" && cfg.ClientID == jira.DefaultJiraClientID
}

// jiraPurgeLeases is each Jira account's lease deadline under the daemon's
// own rule (purge.Enabled, daemon.AccountSyncAllowed). An unreadable ledger
// gives none: the note is left out, never guessed.
func jiraPurgeLeases(cfg *config.Config, database *db.DB) map[int64]time.Time {
	accounts, err := database.ListPurgeAccounts()
	if err != nil {
		log.Printf("jira accounts: purge leases: %v", err)
		return nil
	}
	on, origin := purge.Enabled(cfg)
	return purge.LeaseDeadlines(accounts, purge.AccountRules(on, origin, daemon.AccountSyncAllowed), "jira")
}

func writeJiraAccountsJSON(w io.Writer, workspaceDir string, accounts []db.JiraAccount, leases map[int64]time.Time) error {
	rows := make([]jiraAccountJSON, 0, len(accounts))
	for _, a := range accounts {
		authKind := a.AuthKind
		if authKind == "" {
			authKind = "oauth"
		}
		row := jiraAccountJSON{
			ID: a.ID, Label: a.Label, SiteURL: a.SiteURL, Status: a.Status, Enabled: a.Enabled, Error: a.Error,
			AuthKind: authKind, CompanySlug: a.CompanySlug, SharedAtlassian: jiraOnSharedApp(workspaceDir, a),
		}
		if t, ok := leases[a.ID]; ok {
			row.PurgeLeaseAt = t.UTC().Format(time.RFC3339)
		}
		rows = append(rows, row)
	}
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(rows)
}
