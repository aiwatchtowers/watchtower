package company

import (
	"cmp"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"

	"watchtower/internal/auth"
	"watchtower/internal/calendar"
	"watchtower/internal/companybundle"
	"watchtower/internal/db"
	"watchtower/internal/imap"
	"watchtower/internal/jira"
	"watchtower/internal/linear"
)

// Candidate is a known company client (D19): a client id on this Mac that
// is not our shared baked one, with where it came from. Secrets are never
// part of it; HasSecret says the Mac holds one.
type Candidate struct {
	Vendor      string `json:"vendor"`
	ClientID    string `json:"client_id,omitempty"`
	AppID       string `json:"app_id,omitempty"`
	TenantID    string `json:"tenant_id,omitempty"`
	Label       string `json:"label"`
	Source      string `json:"source"` // stored | draft | credentials_file | account
	SourceLabel string `json:"source_label"`
	HasSecret   bool   `json:"has_secret"`
}

// Candidate sources, in the order a duplicate keeps the first.
const (
	SourceStored          = "stored"
	SourceDraft           = "draft"
	SourceCredentialsFile = "credentials_file"
	SourceAccount         = "account"
)

// vendorNames are the vendors as the source line names them.
var vendorNames = map[string]string{
	"slack": "Slack", "google": "Google", "atlassian": "Atlassian", "linear": "Linear", "microsoft": "Microsoft",
}

// clientFileVendor is the vendor part of an account's own client file
// (<workspace>/<vendor>_client_<accountID>.json, internal/oauthclient): the
// account source name.
var clientFileVendor = map[string]string{"atlassian": "jira", "linear": "linear", "microsoft": "outlook"}

// sharedClientIDs are our baked shared clients: never a company's.
func sharedClientIDs() map[string]string {
	return map[string]string{
		"slack": auth.DefaultClientID, "google": calendar.DefaultGoogleClientID, "atlassian": jira.DefaultJiraClientID,
		"linear": linear.DefaultLinearClientID, "microsoft": imap.DefaultMicrosoftClientID,
	}
}

// accountRef is one account whose own client file may name a client.
type accountRef struct {
	vendor   string
	id       int64
	label    string
	clientID string // the account row's own client id (Google only)
}

// Discover lists the known company clients for every vendor, from the
// stored (and forced) company bundles, the wizard draft, the per-account
// credentials files and accounts connected through a non-shared client.
// A client found twice is listed once (the first source wins; HasSecret if
// any source holds the secret). Personal Google projects are not a
// company's. It only reads: an unreadable draft or file is skipped.
func Discover(ctx context.Context, workspaceDir string, database *db.DB, forced string) ([]Candidate, error) {
	store := NewStore(workspaceDir)
	var out []Candidate
	entries, _, err := store.LoadAll(forced)
	if err != nil {
		return nil, err
	}
	// A personal project's client (and the accounts on it) is the person's
	// own, never offered as a company's whatever source finds it.
	personal := map[string]bool{}
	for _, e := range entries {
		if e.Bundle.Personal {
			for _, c := range bundleCandidates(e.Bundle, "", "") {
				personal[candidateKey(c)] = true
			}
			continue
		}
		out = append(out, bundleCandidates(e.Bundle, SourceStored, e.Bundle.Company)...)
	}
	if d, err := readDraft(store.draftPath()); err == nil {
		out = append(out, draftCandidates(d)...)
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	accounts, err := discoverAccounts(database)
	if err != nil {
		return nil, err
	}
	for _, a := range accounts {
		if c, ok := clientFileCandidate(workspaceDir, a); ok {
			out = append(out, c)
		}
		if a.clientID != "" {
			out = append(out, Candidate{
				Vendor: a.vendor, ClientID: a.clientID, Label: a.label, Source: SourceAccount,
				SourceLabel: fmt.Sprintf("%s app — your connected account %s", vendorNames[a.vendor], a.label),
			})
		}
	}
	return dedupeCandidates(out, personal), nil
}

func savedSetupLabel(company string) string {
	if company == "" {
		return "your unfinished company setup"
	}
	return company + "'s saved company setup"
}

func bundleCandidates(b companybundle.Bundle, source, company string) []Candidate {
	label := savedSetupLabel(company)
	var out []Candidate
	add := func(vendor, clientID, tenant string, hasSecret bool) {
		if clientID != "" {
			out = append(out, Candidate{Vendor: vendor, ClientID: clientID, TenantID: tenant, Label: company,
				Source: source, SourceLabel: label, HasSecret: hasSecret})
		}
	}
	if b.Slack != nil {
		add("slack", b.Slack.ClientID, "", false)
	}
	if b.Google != nil {
		add("google", b.Google.ClientID, "", b.Google.ClientSecret != "")
	}
	if b.Atlassian != nil {
		add("atlassian", b.Atlassian.ClientID, "", b.Atlassian.ClientSecret != "")
	}
	if b.Linear != nil {
		add("linear", b.Linear.ClientID, "", false)
	}
	if b.Microsoft != nil {
		add("microsoft", b.Microsoft.ClientID, b.Microsoft.TenantID, false)
	}
	return out
}

func draftCandidates(d Draft) []Candidate {
	out := bundleCandidates(companybundle.Bundle{Google: d.Google, Atlassian: d.Atlassian, Linear: d.Linear, Microsoft: d.Microsoft},
		SourceDraft, d.Company)
	if d.Slack.AppID != "" {
		out = append(out, Candidate{Vendor: "slack", AppID: d.Slack.AppID, Label: d.Company,
			Source: SourceDraft, SourceLabel: savedSetupLabel(d.Company)})
	}
	return out
}

// discoverAccounts lists the live accounts of every vendor with a label.
// Removed and purged accounts are gone.
func discoverAccounts(database *db.DB) ([]accountRef, error) {
	gone := func(status string) bool { return status == "removed" || status == "purged" }
	var out []accountRef
	google, err := database.ListGoogleAccounts()
	if err != nil {
		return nil, err
	}
	for _, a := range google {
		if !gone(a.Status) {
			out = append(out, accountRef{vendor: "google", id: a.ID, label: cmp.Or(a.Label, a.Email), clientID: a.ClientID})
		}
	}
	jiraAccounts, err := database.ListJiraAccounts()
	if err != nil {
		return nil, err
	}
	for _, a := range jiraAccounts {
		if !gone(a.Status) {
			out = append(out, accountRef{vendor: "atlassian", id: a.ID, label: cmp.Or(a.Label, a.SiteName, a.SiteURL)})
		}
	}
	linearAccounts, err := database.ListLinearAccounts()
	if err != nil {
		return nil, err
	}
	for _, a := range linearAccounts {
		if !gone(a.Status) {
			out = append(out, accountRef{vendor: "linear", id: a.ID, label: cmp.Or(a.Label, a.OrgName)})
		}
	}
	email, err := database.ListEmailAccounts()
	if err != nil {
		return nil, err
	}
	for _, a := range email {
		if a.Provider == "outlook" && !gone(a.Status) {
			out = append(out, accountRef{vendor: "microsoft", id: a.ID, label: cmp.Or(a.EmailAddress, a.Label)})
		}
	}
	return out, nil
}

// clientFileJSON is an account's own client file: google_credentials_<id>.json
// (calendar.CredentialStore) or <vendor>_client_<id>.json (oauthclient).
type clientFileJSON struct {
	ClientID     string `json:"client_id"`
	ClientSecret string `json:"client_secret"`
	TenantID     string `json:"tenant_id"`
}

func clientFileCandidate(workspaceDir string, a accountRef) (Candidate, bool) {
	name := fmt.Sprintf("google_credentials_%d.json", a.id)
	if a.vendor != "google" {
		name = fmt.Sprintf("%s_client_%d.json", clientFileVendor[a.vendor], a.id)
	}
	path := filepath.Join(workspaceDir, name)
	fi, err := os.Lstat(path)
	if err != nil || !fi.Mode().IsRegular() || fi.Size() > maxFileBytes {
		return Candidate{}, false
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return Candidate{}, false
	}
	var f clientFileJSON
	if err := json.Unmarshal(raw, &f); err != nil || f.ClientID == "" {
		return Candidate{}, false
	}
	return Candidate{
		Vendor: a.vendor, ClientID: f.ClientID, TenantID: f.TenantID, Label: a.label, Source: SourceCredentialsFile,
		SourceLabel: "the credentials file of " + a.label, HasSecret: f.ClientSecret != "",
	}, true
}

// candidateKey identifies a client: vendor and client id, or app id.
func candidateKey(c Candidate) string { return c.Vendor + "\x00" + c.ClientID + "\x00" + c.AppID }

// dedupeCandidates drops our shared clients, the excluded (personal) ones
// and repeats, keeping the first and OR-ing HasSecret; vendors in the
// wizard's order.
func dedupeCandidates(in []Candidate, excluded map[string]bool) []Candidate {
	shared := sharedClientIDs()
	out := []Candidate{}
	at := map[string]int{}
	for _, c := range in {
		if c.ClientID != "" && c.ClientID == shared[c.Vendor] {
			continue
		}
		key := candidateKey(c)
		if excluded[key] {
			continue
		}
		if i, ok := at[key]; ok {
			out[i].HasSecret = out[i].HasSecret || c.HasSecret
			continue
		}
		at[key] = len(out)
		out = append(out, c)
	}
	slices.SortStableFunc(out, func(a, b Candidate) int {
		return slices.Index(draftVendors, a.Vendor) - slices.Index(draftVendors, b.Vendor)
	})
	return out
}
