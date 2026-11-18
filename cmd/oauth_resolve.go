package cmd

import (
	"errors"
	"fmt"
	"os"

	"watchtower/internal/company"
	"watchtower/internal/companybundle"
	"watchtower/internal/db"
	"watchtower/internal/jira"
	"watchtower/internal/oauthclient"
)

// clientSource names the layer an OAuth client came from (#1887 §1): the
// company's bundle (the forced MDM overlay first), the account's own client
// file, the development env, or the build's baked default.
type clientSource string

const (
	clientSourceCompany     clientSource = "company"
	clientSourceAccountFile clientSource = "account_file"
	clientSourceEnv         clientSource = "env"
	clientSourceBaked       clientSource = "baked"
)

// errUnknownCompany is a slug with no stored (or forced) company bundle.
var errUnknownCompany = errors.New("no stored company")

// errNoOAuthClient is a resolver that found no client on any layer.
var errNoOAuthClient = errors.New("no OAuth client configured")

// jiraClientVendor names the Atlassian client files (jira_client_<id>.json),
// next to the account's jira_token_<id>.json.
const jiraClientVendor = "jira"

// companyAtlassian returns the Atlassian block of the company stored (or
// forced) under slug: errUnknownCompany for no such company, errNoOAuthClient
// for a company without an Atlassian app.
func companyAtlassian(workspaceDir, slug string) (*companybundle.Atlassian, error) {
	e, ok, err := company.NewStore(workspaceDir).Get(slug, companyForcedBundle())
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, fmt.Errorf("%w %q: open your company's link or paste its code first", errUnknownCompany, slug)
	}
	if e.Bundle.Atlassian == nil {
		return nil, fmt.Errorf("company %q has no Atlassian app: %w", slug, errNoOAuthClient)
	}
	return e.Bundle.Atlassian, nil
}

// resolveJiraOAuthConfigForCompany is the Atlassian client for a sign-in
// through company slug: its bundle's client. slug "" is no company: the
// development env (WATCHTOWER_JIRA_CLIENT_ID/SECRET), then the baked default.
func resolveJiraOAuthConfigForCompany(workspaceDir, slug string) (jira.JiraOAuthConfig, clientSource, error) {
	if slug == "" {
		return jiraSharedOAuthConfig()
	}
	a, err := companyAtlassian(workspaceDir, slug)
	if err != nil {
		return jira.JiraOAuthConfig{}, "", err
	}
	return jira.JiraOAuthConfig{ClientID: a.ClientID, ClientSecret: a.ClientSecret}, clientSourceCompany, nil
}

// errClientChanged is a tied account whose company's Atlassian app is not the
// one its grant was issued to (its client file names another client id): a
// Replace stored the new app, or the account was re-tied. Refreshing through
// the new app could only fail, and Atlassian's answer to a foreign refresh
// token may read as a revoked grant; the account needs a new sign-in.
var errClientChanged = errors.New("your company changed its Atlassian app — sign in again")

// resolveJiraOAuthConfigForAccount is the Atlassian client of an existing
// account, in the resolver order: the bundle of the company the account is
// tied to → the account's own client file → env → baked. A tied account
// whose company is gone (or damaged, or lost its Atlassian block) falls to
// its client file, which holds the client it signed in with, and never to
// the shared app (errNoOAuthClient without that file); a bundle whose
// client id differs from that file is errClientChanged (a new secret for the
// same id is the bundle's to give). A damaged client file is an error, never
// a silent fall to the shared app.
func resolveJiraOAuthConfigForAccount(workspaceDir string, account db.JiraAccount) (jira.JiraOAuthConfig, clientSource, error) {
	file, haveFile, fileErr := oauthclient.NewStore(workspaceDir, jiraClientVendor, account.ID).Load()
	if fileErr != nil {
		return jira.JiraOAuthConfig{}, "", fmt.Errorf("jira account %d: %w", account.ID, fileErr)
	}
	var companyErr error
	if account.CompanySlug != "" {
		cfg, src, err := resolveJiraOAuthConfigForCompany(workspaceDir, account.CompanySlug)
		if err == nil {
			if haveFile && file.ClientID != cfg.ClientID {
				return jira.JiraOAuthConfig{}, "", fmt.Errorf("jira account %d: %w", account.ID, errClientChanged)
			}
			return cfg, src, nil
		}
		companyErr = err
	}
	if haveFile {
		return jira.JiraOAuthConfig{ClientID: file.ClientID, ClientSecret: file.ClientSecret}, clientSourceAccountFile, nil
	}
	if account.CompanySlug != "" {
		// A company's grant never goes to the shared app: a refresh through a
		// foreign client can read as a revoked grant (and a 72 h purge).
		return jira.JiraOAuthConfig{}, "", fmt.Errorf("jira account %d: company %q (%v): %w: re-login needed — open your company's link",
			account.ID, account.CompanySlug, companyErr, errNoOAuthClient)
	}
	cfg, src, err := jiraSharedOAuthConfig()
	if err != nil {
		return jira.JiraOAuthConfig{}, "", fmt.Errorf("jira account %d: %w: re-login needed — open your company's link", account.ID, err)
	}
	return cfg, src, nil
}

// jiraAccountOAuthSource resolves an account's client at call time (load
// gives its row: the daemon re-reads it, so a re-tie is seen too): a client's
// refresh source, so a re-login through a company's new app made meanwhile
// is refreshed through that app.
// No client, or a company app that is not the grant's, is
// jira.ErrClientRejected (Re-login needed, never revoked); any other failure
// (a DB read, a damaged file) is a plain error that marks nothing.
func jiraAccountOAuthSource(workspaceDir string, load func() (db.JiraAccount, error)) func() (jira.JiraOAuthConfig, error) {
	return func() (jira.JiraOAuthConfig, error) {
		account, err := load()
		if err != nil {
			return jira.JiraOAuthConfig{}, err
		}
		cfg, _, err := resolveJiraOAuthConfigForAccount(workspaceDir, account)
		if errors.Is(err, errNoOAuthClient) || errors.Is(err, errClientChanged) {
			return jira.JiraOAuthConfig{}, fmt.Errorf("%w: %w", jira.ErrClientRejected, err)
		}
		return cfg, err
	}
}

// jiraAccountRowOAuthSource is jiraAccountOAuthSource over a row already in
// hand: a short-lived client (a CLI command, a tool) of that account.
func jiraAccountRowOAuthSource(workspaceDir string, account db.JiraAccount) func() (jira.JiraOAuthConfig, error) {
	return jiraAccountOAuthSource(workspaceDir, func() (db.JiraAccount, error) { return account, nil })
}

// jiraLoginOAuthConfig is the client a re-login of account signs in with: a
// tied account's company app as it stands (a changed app is what the
// re-login is for), else the account's resolver order.
func jiraLoginOAuthConfig(workspaceDir string, account db.JiraAccount) (jira.JiraOAuthConfig, error) {
	if account.CompanySlug != "" {
		if cfg, _, err := resolveJiraOAuthConfigForCompany(workspaceDir, account.CompanySlug); err == nil {
			return cfg, nil
		}
	}
	cfg, _, err := resolveJiraOAuthConfigForAccount(workspaceDir, account)
	return cfg, err
}

// jiraSharedOAuthConfig is the client of no company: env, then baked.
func jiraSharedOAuthConfig() (jira.JiraOAuthConfig, clientSource, error) {
	if id := os.Getenv("WATCHTOWER_JIRA_CLIENT_ID"); id != "" {
		return jira.JiraOAuthConfig{ClientID: id, ClientSecret: os.Getenv("WATCHTOWER_JIRA_CLIENT_SECRET")}, clientSourceEnv, nil
	}
	if jira.DefaultJiraClientID != "" {
		return jira.JiraOAuthConfig{ClientID: jira.DefaultJiraClientID, ClientSecret: jira.DefaultJiraClientSecret}, clientSourceBaked, nil
	}
	return jira.JiraOAuthConfig{}, "", errNoOAuthClient
}
