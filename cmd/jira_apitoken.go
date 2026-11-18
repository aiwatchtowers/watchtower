package cmd

import (
	"errors"
	"fmt"
	"log"
	"net/url"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/jira"
	"watchtower/internal/policy"
)

// Jira and Confluence by an Atlassian API token (#1887 §4b, D20): `jira add
// --api-token-stdin --email E --site S` and its re-auth `jira login
// --account N --api-token-stdin`. The token comes on stdin only — never
// argv, never a log line or an error.

// Seams so tests answer the site and the token check without the network.
var (
	jiraTenantInfo    = jira.TenantInfo
	jiraProbeAPIToken = jira.ProbeAPIToken
)

// errAPITokenOnStdinOnly refuses a positional argument of add/login without
// echoing it: it may be a pasted token.
var errAPITokenOnStdinOnly = errors.New("this command takes no arguments — pass an API token on stdin with --api-token-stdin")

// noArgsQuiet is cobra.NoArgs without the argument in its error (cobra's
// "unknown command %q" would print a token pasted as an argument).
func noArgsQuiet(_ *cobra.Command, args []string) error {
	if len(args) > 0 {
		return errAPITokenOnStdinOnly
	}
	return nil
}

// errAPITokenFlagValue replaces pflag's error for a value given to
// --api-token-stdin, which quotes the value — a pasted token.
var errAPITokenFlagValue = errors.New("--api-token-stdin takes no value — pipe the API token on stdin")

// quietAPITokenFlagError keeps a flag error about --api-token-stdin from
// echoing its value; other flag errors pass as they are.
func quietAPITokenFlagError(_ *cobra.Command, err error) error {
	if strings.Contains(err.Error(), "api-token-stdin") {
		return errAPITokenFlagValue
	}
	return err
}

func init() {
	jiraAddCmd.Args = noArgsQuiet
	jiraLoginCmd.Args = noArgsQuiet
	jiraAddCmd.SetFlagErrorFunc(quietAPITokenFlagError)
	jiraLoginCmd.SetFlagErrorFunc(quietAPITokenFlagError)
	for _, c := range []*cobra.Command{jiraAddCmd, jiraLoginCmd} {
		c.Flags().Bool("api-token-stdin", false, "connect with an Atlassian API token read from stdin (never an argument) instead of OAuth; with --email and, for add, --site")
		c.Flags().String("email", "", "the Atlassian account email the API token belongs to (--api-token-stdin)")
	}
}

// newJiraClientForAccount builds a short-lived client (a CLI command, a
// tool) of account: Basic auth from its token file for an API-token
// account, else its OAuth client in the resolver order. The daemon builds
// its own (buildAtlassianClients), with a refresh source that re-reads the
// row.
func newJiraClientForAccount(cfg *config.Config, account db.JiraAccount) (*jira.Client, error) {
	workspaceDir := cfg.WorkspaceDir()
	store := jira.NewTokenStore(workspaceDir, account.ID)
	if account.AuthKind == jira.AuthKindAPIToken {
		client := jira.NewAPITokenClient(account.CloudID, account.SiteURL, store)
		// A dead token seen by a command or a tool is recorded too (D22),
		// not only by the daemon: the row must not stay green.
		client.SetOnAPITokenDead(func() { recordAPITokenDead(cfg.DBPath(), account.ID) })
		return client, nil
	}
	jiraCfg, _, err := resolveJiraOAuthConfigForAccount(workspaceDir, account)
	if err != nil {
		return nil, err
	}
	client := jira.NewClient(account.CloudID, jiraCfg, store)
	client.SetOAuthSource(jiraAccountRowOAuthSource(workspaceDir, account))
	return client, nil
}

// recordAPITokenDead marks a Jira account's API token dead (status 'error',
// never 'revoked'), opening the database for the one write: the client that
// saw the 401 may belong to a command or tool without a handle of its own.
func recordAPITokenDead(dbPath string, accountID int64) {
	database, err := db.Open(dbPath)
	if err != nil {
		log.Printf("jira: account %d: record auth state: %v", accountID, err)
		return
	}
	defer database.Close()
	if err := database.SetJiraAccountAuthState(accountID, "error", jira.CodeAPITokenDead); err != nil {
		log.Printf("jira: account %d: record auth state: %v", accountID, err)
	}
}

// useAPIToken reports --api-token-stdin.
func useAPIToken(cmd *cobra.Command) bool {
	v, _ := cmd.Flags().GetBool("api-token-stdin")
	return v
}

// apiTokenPolicyRefusal is the organization's refusal of API tokens
// (AllowAtlassianAPIToken = false, D24); nil when allowed.
func apiTokenPolicyRefusal() error {
	if !policy.Current().AtlassianAPITokenAllowed() {
		return jira.ErrAPITokenForbidden
	}
	return nil
}

// normalizeJiraTokenSite turns what a person types for --site
// (acme.atlassian.net, https://Acme.atlassian.net/) into an https origin;
// TenantInfo refuses anything else (http, a path).
func normalizeJiraTokenSite(site string) (string, error) {
	site = strings.TrimSpace(site)
	if site == "" {
		return "", errors.New("--site is required with --api-token-stdin (e.g. https://acme.atlassian.net)")
	}
	if !strings.Contains(site, "://") {
		site = "https://" + site
	}
	u, err := url.Parse(strings.TrimSuffix(site, "/"))
	if err != nil {
		return "", fmt.Errorf("%w: %q is not a site address", jira.ErrNotAtlassianCloud, site)
	}
	u.Host = strings.ToLower(u.Host)
	return u.String(), nil
}

// readJiraAPIToken reads the token from stdin (a hidden prompt on a
// terminal).
func readJiraAPIToken(cmd *cobra.Command) (string, error) {
	token, err := readSecret(cmd, "Atlassian API token: ")
	if err != nil {
		return "", fmt.Errorf("reading the API token: %w", err)
	}
	if token == "" {
		return "", errors.New("empty API token on stdin")
	}
	if strings.ContainsAny(token, " \t\r\n") {
		return "", errors.New("the API token on stdin must be one line without spaces")
	}
	return token, nil
}

// apiTokenScope is the scope string a new token is used for: Jira, plus
// Confluence (and its write scopes) as the flags ask.
func apiTokenScope(opts jira.LoginOptions) string {
	scope := jira.JiraScopes
	if opts.WithConfluence {
		scope += " " + jira.ConfluenceScopes
	}
	if opts.WithConfluenceWrite {
		scope += " " + jira.ConfluenceWriteScopes
	}
	return scope
}

// checkAPIToken reads the token and checks it on site before anything is
// stored: the site must be a <name>.atlassian.net origin answering as an
// Atlassian Cloud tenant (wantCloudID, when set: the account's own), then
// GET /myself must accept the token.
func checkAPIToken(cmd *cobra.Command, site, wantCloudID string, creds jira.APITokenCreds) (string, jira.APITokenCreds, jira.Myself, error) {
	if err := jira.ValidateAPITokenSite(site); err != nil {
		return "", jira.APITokenCreds{}, jira.Myself{}, err
	}
	token, err := readJiraAPIToken(cmd)
	if err != nil {
		return "", jira.APITokenCreds{}, jira.Myself{}, err
	}
	creds.Token = token
	cloudID, err := jiraTenantInfo(cmd.Context(), nil, site)
	if err != nil {
		return "", jira.APITokenCreds{}, jira.Myself{}, fmt.Errorf("checking the site: %w", err)
	}
	if wantCloudID != "" && cloudID != wantCloudID {
		return "", jira.APITokenCreds{}, jira.Myself{}, fmt.Errorf("%s now answers as another Atlassian site than this account's; the token was not sent", site)
	}
	creds, me, err := jiraProbeAPIToken(cmd.Context(), nil, cloudID, site, creds)
	if err != nil {
		return "", jira.APITokenCreds{}, jira.Myself{}, fmt.Errorf("checking the API token: %w", err)
	}
	return cloudID, creds, me, nil
}

// addJiraAPITokenAccount is `jira add --api-token-stdin`: everything is
// checked on the network before a row or a file is written, so a refused or
// unreachable check leaves nothing behind.
func addJiraAPITokenAccount(cmd *cobra.Command, cfg *config.Config, database *db.DB) error {
	if err := apiTokenPolicyRefusal(); err != nil {
		return err
	}
	if slug, _ := cmd.Flags().GetString("company"); slug != "" {
		return errors.New("--company signs in through the company's Atlassian app; an API token is your own — drop one of them")
	}
	email, _ := cmd.Flags().GetString("email")
	email = strings.TrimSpace(email)
	if !strings.Contains(email, "@") {
		return errors.New("--email is required with --api-token-stdin: the Atlassian account email the token belongs to")
	}
	siteFlag, _ := cmd.Flags().GetString("site")
	site, err := normalizeJiraTokenSite(siteFlag)
	if err != nil {
		return err
	}
	label, _ := cmd.Flags().GetString("label")
	creds := jira.APITokenCreds{Email: email, Scope: apiTokenScope(jiraLoginOptionsFromFlags(cmd))}
	cloudID, creds, me, err := checkAPIToken(cmd, site, "", creds)
	if err != nil {
		return err
	}

	if _, err := ensureLegacyJiraAccount(cfg, database, jiraCmdLogger(cmd)); err != nil {
		fmt.Fprintf(cmd.ErrOrStderr(), "Warning: legacy account seed failed: %v\n", err)
	}
	host := strings.TrimPrefix(site, "https://")
	accountID, err := database.CreateJiraAccount(db.JiraAccount{
		CloudID: cloudID, SiteURL: site, SiteName: host, Label: label, AuthKind: jira.AuthKindAPIToken,
	})
	if err != nil {
		return fmt.Errorf("creating jira account: %w", err)
	}
	if err := jira.NewTokenStore(cfg.WorkspaceDir(), accountID).SaveAPIToken(creds); err != nil {
		rollbackNewJiraAccount(cfg, database, accountID)
		return err
	}
	if err := finishAPITokenConnect(cmd, database, accountID, me); err != nil {
		rollbackNewJiraAccount(cfg, database, accountID)
		return err
	}
	out := cmd.OutOrStdout()
	fmt.Fprintf(out, "\nJira Cloud connected with an API token as account %d!\n", accountID)
	fmt.Fprintf(out, "Site: %s\n", site)
	fmt.Fprintf(out, "\nRun 'watchtower jira boards --account %d' to see available boards.\n", accountID)
	return nil
}

// reauthJiraAPIToken is `jira login --api-token-stdin`: a new token for an
// API-token account, checked against the account's own site (the same
// tenant) before it replaces the old one; it clears the account's error and
// stamps access_ok_at.
func reauthJiraAPIToken(cmd *cobra.Command, cfg *config.Config, database *db.DB, account db.JiraAccount) error {
	if account.AuthKind != jira.AuthKindAPIToken {
		return fmt.Errorf("jira account %d signs in with OAuth: run 'watchtower jira login --account %d' without --api-token-stdin, or connect a new site with 'watchtower jira add --api-token-stdin'", account.ID, account.ID)
	}
	if err := apiTokenPolicyRefusal(); err != nil {
		return err
	}
	if err := refuseLoginDuringPurge(database, "jira", account.ID); err != nil {
		return err
	}
	store := jira.NewTokenStore(cfg.WorkspaceDir(), account.ID)
	prev, _ := store.LoadAPIToken() // only the email default; a damaged file is what the re-auth replaces
	email, _ := cmd.Flags().GetString("email")
	if email = strings.TrimSpace(email); email == "" {
		email = prev.Email
	}
	if !strings.Contains(email, "@") {
		return errors.New("--email is required: the Atlassian account email the token belongs to")
	}
	// The OAuth re-login's carry-over: Confluence (and write) stay when the
	// stored token had them or the account has spaces selected.
	opts, _, err := jiraReloginOptions(cmd, cfg.WorkspaceDir(), database, account.ID)
	if err != nil {
		return err
	}
	scope := apiTokenScope(opts)
	_, creds, me, err := checkAPIToken(cmd, account.SiteURL, account.CloudID, jira.APITokenCreds{Email: email, Scope: scope})
	if err != nil {
		return err
	}
	unlock, err := store.Lock(cmd.Context())
	if err != nil {
		return err
	}
	err = store.SaveAPIToken(creds)
	unlock()
	if err != nil {
		return err
	}
	if err := finishAPITokenConnect(cmd, database, account.ID, me); err != nil {
		return err
	}
	fmt.Fprintf(cmd.OutOrStdout(), "\nJira account %d has a new API token.\n", account.ID)
	return nil
}

// finishAPITokenConnect records the person the token belongs to and marks
// the account ok (clearing api_token_dead, stamping access_ok_at), then
// turns the Jira phase on.
func finishAPITokenConnect(cmd *cobra.Command, database *db.DB, accountID int64, me jira.Myself) error {
	if err := database.SetJiraAccountOwner(accountID, me.AccountID, me.EmailAddress, me.DisplayName); err != nil {
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: could not save your Jira identity (/myself): %v\n", err)
	}
	if err := database.SetJiraAccountAuthState(accountID, "ok", ""); err != nil {
		return fmt.Errorf("recording auth state: %w", err)
	}
	if err := enableJiraPhase(); err != nil {
		return fmt.Errorf("saving jira config: %w", err)
	}
	return nil
}
