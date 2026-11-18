package cmd

import (
	"errors"
	"fmt"
	"os"

	"watchtower/internal/calendar"
	"watchtower/internal/company"
	"watchtower/internal/companybundle"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/imap"
	"watchtower/internal/jira"
	"watchtower/internal/linear"
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

// Per-account client files (<vendor>_client_<id>.json, internal/oauthclient),
// named after the account source so company discovery finds them. Google
// keeps its google_credentials_<id>.json (calendar.CredentialStore, #1887 P4).
const (
	jiraClientVendor    = "jira"
	linearClientVendor  = "linear"
	outlookClientVendor = "outlook"
)

// errClientChanged is a tied account whose company's app is not the one its
// grant was issued to (its client file names another client id): a Replace
// stored the new app, or the account was re-tied. Refreshing through the new
// app could only fail, and a vendor's answer to a foreign refresh token may
// read as a revoked grant; the account needs a new sign-in. Errors match it
// through clientChangedError, which names the vendor's app.
var errClientChanged = errors.New("your company changed its app — sign in again")

// clientChangedError is errClientChanged for one vendor's app.
type clientChangedError struct{ app string }

func (e clientChangedError) Error() string {
	return "your company changed its " + e.app + " app — sign in again"
}

func (e clientChangedError) Is(target error) bool { return target == errClientChanged }

// needsCompanyRelogin reports a resolver error that only a new sign-in can
// fix: no client on any layer, or a company app that is not the grant's.
// Callers record it as Re-login needed (invalid_client / unknown_client),
// never revoked; any other error (a damaged client file) is shown as is.
func needsCompanyRelogin(err error) bool {
	return errors.Is(err, errNoOAuthClient) || errors.Is(err, errClientChanged)
}

// companyApp returns the vendor's block (picked by block) of the company
// stored (or forced) under slug: errUnknownCompany for no such company,
// errNoOAuthClient for a company without that vendor's app.
func companyApp[T any](workspaceDir, slug, app string, block func(companybundle.Bundle) *T) (*T, error) {
	e, ok, err := company.NewStore(workspaceDir).Get(slug, companyForcedBundle())
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, fmt.Errorf("%w %q: open your company's link or paste its code first", errUnknownCompany, slug)
	}
	if v := block(e.Bundle); v != nil {
		return v, nil
	}
	return nil, fmt.Errorf("company %q has no %s app: %w", slug, app, errNoOAuthClient)
}

// accountClient is one existing account's resolver inputs, vendor-neutral.
type accountClient struct {
	app   string // the vendor's app as errClientChanged names it ("Atlassian")
	label string // the account in messages ("jira account 4")
	slug  string // the account's company_slug
	// file is the account's own client record; company the app of the
	// company slug (only asked when slug != ""); shared env, then baked.
	file    func() (oauthclient.Client, bool, error)
	company func() (oauthclient.Client, error)
	shared  func() (oauthclient.Client, clientSource, error)
}

// resolve is the resolver order for an existing account (#1887 §1): the
// bundle of the company the account is tied to → the account's own client
// file → env → baked. A tied account whose company is gone (or damaged, or
// lost the vendor's block) falls to its client file, which holds the client
// it signed in with, and never to the shared app (errNoOAuthClient without
// that file); a bundle whose client id differs from that file is
// errClientChanged (a new secret for the same id is the bundle's to give). A
// damaged client file is an error, never a silent fall to the shared app.
func (a accountClient) resolve() (oauthclient.Client, clientSource, error) {
	file, haveFile, fileErr := a.file()
	if fileErr != nil {
		return oauthclient.Client{}, "", fmt.Errorf("%s: %w", a.label, fileErr)
	}
	var companyErr error
	if a.slug != "" {
		c, err := a.company()
		if err == nil {
			// A Microsoft tenant is part of the app: the same client id in
			// another tenant is another app.
			if haveFile && (file.ClientID != c.ClientID || (file.TenantID != "" && file.TenantID != c.TenantID)) {
				return oauthclient.Client{}, "", fmt.Errorf("%s: %w", a.label, clientChangedError{app: a.app})
			}
			return c, clientSourceCompany, nil
		}
		companyErr = err
	}
	if haveFile {
		return file, clientSourceAccountFile, nil
	}
	if a.slug != "" {
		// A company's grant never goes to the shared app: a refresh through a
		// foreign client can read as a revoked grant (and a 72 h purge).
		return oauthclient.Client{}, "", fmt.Errorf("%s: company %q (%v): %w: re-login needed — open your company's link",
			a.label, a.slug, companyErr, errNoOAuthClient)
	}
	c, src, err := a.shared()
	if err != nil {
		return oauthclient.Client{}, "", fmt.Errorf("%s: %w: re-login needed — open your company's link", a.label, err)
	}
	return c, src, nil
}

// clientFile is an oauthclient.Store's Load as accountClient.file.
func clientFile(workspaceDir, vendor string, accountID int64) func() (oauthclient.Client, bool, error) {
	return oauthclient.NewStore(workspaceDir, vendor, accountID).Load
}

// sharedClient is the client of no company: the env pair when idEnv is set,
// else the baked pair, else errNoOAuthClient. The env and baked values never
// mix (an env id never goes out with the baked secret).
func sharedClient(idEnv, secretEnv, bakedID, bakedSecret string) (oauthclient.Client, clientSource, error) {
	if id := os.Getenv(idEnv); id != "" {
		c := oauthclient.Client{ClientID: id}
		if secretEnv != "" {
			c.ClientSecret = os.Getenv(secretEnv)
		}
		return c, clientSourceEnv, nil
	}
	if bakedID != "" {
		return oauthclient.Client{ClientID: bakedID, ClientSecret: bakedSecret}, clientSourceBaked, nil
	}
	return oauthclient.Client{}, "", errNoOAuthClient
}

// ---- Atlassian ----

// companyAtlassian returns the Atlassian block of the company stored (or
// forced) under slug.
func companyAtlassian(workspaceDir, slug string) (*companybundle.Atlassian, error) {
	return companyApp(workspaceDir, slug, "Atlassian", func(b companybundle.Bundle) *companybundle.Atlassian { return b.Atlassian })
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

// resolveJiraOAuthConfigForAccount is the Atlassian client of an existing
// account, in the resolver order (accountClient.resolve).
func resolveJiraOAuthConfigForAccount(workspaceDir string, account db.JiraAccount) (jira.JiraOAuthConfig, clientSource, error) {
	c, src, err := accountClient{
		app: "Atlassian", label: fmt.Sprintf("jira account %d", account.ID), slug: account.CompanySlug,
		file: clientFile(workspaceDir, jiraClientVendor, account.ID),
		company: func() (oauthclient.Client, error) {
			cfg, _, err := resolveJiraOAuthConfigForCompany(workspaceDir, account.CompanySlug)
			return oauthclient.Client{ClientID: cfg.ClientID, ClientSecret: cfg.ClientSecret}, err
		},
		shared: func() (oauthclient.Client, clientSource, error) {
			cfg, src, err := jiraSharedOAuthConfig()
			return oauthclient.Client{ClientID: cfg.ClientID, ClientSecret: cfg.ClientSecret}, src, err
		},
	}.resolve()
	return jira.JiraOAuthConfig{ClientID: c.ClientID, ClientSecret: c.ClientSecret}, src, err
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
		if needsCompanyRelogin(err) {
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
	c, src, err := sharedClient("WATCHTOWER_JIRA_CLIENT_ID", "WATCHTOWER_JIRA_CLIENT_SECRET", jira.DefaultJiraClientID, jira.DefaultJiraClientSecret)
	return jira.JiraOAuthConfig{ClientID: c.ClientID, ClientSecret: c.ClientSecret}, src, err
}

// ---- Google ----

// companyGoogle returns the Google block of the company stored (or forced)
// under slug.
func companyGoogle(workspaceDir, slug string) (*companybundle.Google, error) {
	return companyApp(workspaceDir, slug, "Google", func(b companybundle.Bundle) *companybundle.Google { return b.Google })
}

// resolveGoogleOAuthConfigForCompany is the Google client for a sign-in
// through company slug: its bundle's client. slug "" is no company: the
// development env (WATCHTOWER_GOOGLE_CLIENT_ID/SECRET), then the baked
// default.
func resolveGoogleOAuthConfigForCompany(workspaceDir, slug string) (calendar.GoogleOAuthConfig, clientSource, error) {
	if slug == "" {
		c, src, err := sharedClient("WATCHTOWER_GOOGLE_CLIENT_ID", "WATCHTOWER_GOOGLE_CLIENT_SECRET",
			calendar.DefaultGoogleClientID, calendar.DefaultGoogleClientSecret)
		return calendar.GoogleOAuthConfig{ClientID: c.ClientID, ClientSecret: c.ClientSecret}, src, err
	}
	g, err := companyGoogle(workspaceDir, slug)
	if err != nil {
		return calendar.GoogleOAuthConfig{}, "", err
	}
	return calendar.GoogleOAuthConfig{ClientID: g.ClientID, ClientSecret: g.ClientSecret}, clientSourceCompany, nil
}

// googleCredentialsFile reads the account's google_credentials_<id>.json —
// Google's per-account client record (an own project, or the company client
// the account signed in with) — as accountClient.file. A file without a
// client id is damaged.
func googleCredentialsFile(workspaceDir string, accountID int64) func() (oauthclient.Client, bool, error) {
	return func() (oauthclient.Client, bool, error) {
		store := calendar.NewCredentialStore(workspaceDir, accountID)
		if !store.Exists() {
			return oauthclient.Client{}, false, nil
		}
		creds, err := store.Load()
		if err != nil {
			return oauthclient.Client{}, false, fmt.Errorf("reading google_credentials_%d.json: %w", accountID, err)
		}
		if creds.ClientID == "" {
			return oauthclient.Client{}, false, fmt.Errorf("google_credentials_%d.json has no client id", accountID)
		}
		return oauthclient.Client{ClientID: creds.ClientID, ClientSecret: creds.ClientSecret}, true, nil
	}
}

// resolveGoogleOAuthConfigForAccount is the Google client of an existing
// account, in the resolver order (accountClient.resolve): its company's
// bundle → its google_credentials_<id>.json → env → baked.
func resolveGoogleOAuthConfigForAccount(workspaceDir string, account db.GoogleAccount) (calendar.GoogleOAuthConfig, clientSource, error) {
	c, src, err := accountClient{
		app: "Google", label: fmt.Sprintf("google account %d", account.ID), slug: account.CompanySlug,
		file: googleCredentialsFile(workspaceDir, account.ID),
		company: func() (oauthclient.Client, error) {
			cfg, _, err := resolveGoogleOAuthConfigForCompany(workspaceDir, account.CompanySlug)
			return oauthclient.Client{ClientID: cfg.ClientID, ClientSecret: cfg.ClientSecret}, err
		},
		shared: func() (oauthclient.Client, clientSource, error) {
			cfg, src, err := resolveGoogleOAuthConfigForCompany(workspaceDir, "")
			return oauthclient.Client{ClientID: cfg.ClientID, ClientSecret: cfg.ClientSecret}, src, err
		},
	}.resolve()
	return calendar.GoogleOAuthConfig{ClientID: c.ClientID, ClientSecret: c.ClientSecret}, src, err
}

// googleLoginOAuthConfig is the client a sign-in of an existing Google
// account uses: a tied account's company app as it stands (a changed app is
// what the re-login is for), else the account's resolver order.
func googleLoginOAuthConfig(workspaceDir string, account db.GoogleAccount) (calendar.GoogleOAuthConfig, error) {
	if account.CompanySlug != "" {
		if cfg, _, err := resolveGoogleOAuthConfigForCompany(workspaceDir, account.CompanySlug); err == nil {
			return cfg, nil
		}
	}
	cfg, _, err := resolveGoogleOAuthConfigForAccount(workspaceDir, account)
	return cfg, err
}

// ---- Linear ----

// companyLinear returns the Linear block of the company stored (or forced)
// under slug.
func companyLinear(workspaceDir, slug string) (*companybundle.Linear, error) {
	return companyApp(workspaceDir, slug, "Linear", func(b companybundle.Bundle) *companybundle.Linear { return b.Linear })
}

// resolveLinearOAuthConfigForCompany is the Linear client for a sign-in
// through company slug: its bundle's client (PKCE, no secret). slug "" is no
// company: WATCHTOWER_LINEAR_CLIENT_ID, then the baked default.
func resolveLinearOAuthConfigForCompany(workspaceDir, slug string) (linear.OAuthConfig, clientSource, error) {
	if slug == "" {
		c, src, err := sharedClient("WATCHTOWER_LINEAR_CLIENT_ID", "", linear.DefaultLinearClientID, "")
		return linear.OAuthConfig{ClientID: c.ClientID}, src, err
	}
	l, err := companyLinear(workspaceDir, slug)
	if err != nil {
		return linear.OAuthConfig{}, "", err
	}
	return linear.OAuthConfig{ClientID: l.ClientID}, clientSourceCompany, nil
}

// resolveLinearOAuthConfigForAccount is the Linear client of the account
// accountID as its row stands now, in the resolver order
// (accountClient.resolve): its company's bundle → linear_client_<id>.json →
// env → baked.
func resolveLinearOAuthConfigForAccount(cfg *config.Config, database *db.DB, accountID int64) (linear.OAuthConfig, clientSource, error) {
	account, err := database.GetLinearAccount(accountID)
	if err != nil {
		return linear.OAuthConfig{}, "", fmt.Errorf("linear account %d: %w", accountID, err)
	}
	return resolveLinearAccountClient(cfg.WorkspaceDir(), account)
}

// resolveLinearAccountClient is resolveLinearOAuthConfigForAccount over a row
// in hand.
func resolveLinearAccountClient(workspaceDir string, account db.LinearAccount) (linear.OAuthConfig, clientSource, error) {
	c, src, err := accountClient{
		app: "Linear", label: fmt.Sprintf("linear account %d", account.ID), slug: account.CompanySlug,
		file: clientFile(workspaceDir, linearClientVendor, account.ID),
		company: func() (oauthclient.Client, error) {
			cfg, _, err := resolveLinearOAuthConfigForCompany(workspaceDir, account.CompanySlug)
			return oauthclient.Client{ClientID: cfg.ClientID}, err
		},
		shared: func() (oauthclient.Client, clientSource, error) {
			cfg, src, err := resolveLinearOAuthConfigForCompany(workspaceDir, "")
			return oauthclient.Client{ClientID: cfg.ClientID}, src, err
		},
	}.resolve()
	return linear.OAuthConfig{ClientID: c.ClientID}, src, err
}

// linearAccountOAuthSource is the daemon's and the CLI's refresh source for
// Linear account accountID: its client resolved at each refresh, from its
// row as it is then. No client, or a company app that is not the grant's, is
// oauthclient.ErrClientRejected (Re-login needed, never revoked).
func linearAccountOAuthSource(cfg *config.Config, database *db.DB, accountID int64) func() (linear.OAuthConfig, error) {
	return func() (linear.OAuthConfig, error) {
		c, _, err := resolveLinearOAuthConfigForAccount(cfg, database, accountID)
		if needsCompanyRelogin(err) {
			return linear.OAuthConfig{}, fmt.Errorf("%w: %w", oauthclient.ErrClientRejected, err)
		}
		return c, err
	}
}

// ---- Microsoft ----

// companyMicrosoft returns the Microsoft block of the company stored (or
// forced) under slug.
func companyMicrosoft(workspaceDir, slug string) (*companybundle.Microsoft, error) {
	return companyApp(workspaceDir, slug, "Microsoft", func(b companybundle.Bundle) *companybundle.Microsoft { return b.Microsoft })
}

// resolveMicrosoftOAuthConfigForCompany is the Microsoft client for a
// sign-in through company slug: its bundle's Entra app and tenant (PKCE, no
// secret; #1887 D16). slug "" is no company: WATCHTOWER_MICROSOFT_CLIENT_ID,
// then the baked default, on the "common" tenant.
func resolveMicrosoftOAuthConfigForCompany(workspaceDir, slug string) (imap.MicrosoftOAuthConfig, clientSource, error) {
	if slug == "" {
		c, src, err := sharedClient("WATCHTOWER_MICROSOFT_CLIENT_ID", "", imap.DefaultMicrosoftClientID, "")
		return imap.MicrosoftOAuthConfig{ClientID: c.ClientID}, src, err
	}
	m, err := companyMicrosoft(workspaceDir, slug)
	if err != nil {
		return imap.MicrosoftOAuthConfig{}, "", err
	}
	return imap.MicrosoftOAuthConfig{ClientID: m.ClientID, TenantID: m.TenantID}, clientSourceCompany, nil
}

// resolveMicrosoftOAuthConfigForAccount is the Microsoft client of Outlook
// account accountID as its row stands now, in the resolver order
// (accountClient.resolve): its company's bundle → outlook_client_<id>.json →
// env → baked.
func resolveMicrosoftOAuthConfigForAccount(cfg *config.Config, database *db.DB, accountID int64) (imap.MicrosoftOAuthConfig, clientSource, error) {
	account, err := database.GetEmailAccount(accountID)
	if err != nil {
		return imap.MicrosoftOAuthConfig{}, "", fmt.Errorf("outlook account %d: %w", accountID, err)
	}
	return resolveOutlookAccountClient(cfg.WorkspaceDir(), account)
}

// resolveOutlookAccountClient is resolveMicrosoftOAuthConfigForAccount over a
// row in hand.
func resolveOutlookAccountClient(workspaceDir string, account db.EmailAccount) (imap.MicrosoftOAuthConfig, clientSource, error) {
	c, src, err := accountClient{
		app: "Microsoft", label: fmt.Sprintf("outlook account %d", account.ID), slug: account.CompanySlug,
		file: clientFile(workspaceDir, outlookClientVendor, account.ID),
		company: func() (oauthclient.Client, error) {
			cfg, _, err := resolveMicrosoftOAuthConfigForCompany(workspaceDir, account.CompanySlug)
			return oauthclient.Client{ClientID: cfg.ClientID, TenantID: cfg.TenantID}, err
		},
		shared: func() (oauthclient.Client, clientSource, error) {
			cfg, src, err := resolveMicrosoftOAuthConfigForCompany(workspaceDir, "")
			return oauthclient.Client{ClientID: cfg.ClientID}, src, err
		},
	}.resolve()
	return imap.MicrosoftOAuthConfig{ClientID: c.ClientID, TenantID: c.TenantID}, src, err
}
