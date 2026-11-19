package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"regexp"
	"strings"
	"syscall"

	"github.com/spf13/cobra"

	"watchtower/internal/company"
	"watchtower/internal/companybundle"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/jira"
	"watchtower/internal/oauthpage"
)

// `company check` is the Set up for my company wizard's check of one
// vendor's app (#1887 Task 13, S28). Google and Atlassian are checked by the
// person's own sign-in through the entered client, and that sign-in is their
// connection: on a token back the company bundle is stored (created by the
// first check, the vendor's block added or updated by later ones), the
// account row is tied to the company (the same user's row re-logged) and
// the draft's step is marked checked. Linear and Microsoft are public PKCE
// clients: one dry GET of the authorize URL checks them and stores nothing
// but the draft's mark.
//
// Failure paths: nothing is stored before a token comes back and the grant
// is known to land (it covers what the same user's row syncs, that row is
// not being purged), so a refused client, a cancelled or timed-out sign-in,
// or the Desktop terminating this process mid-wait (SIGTERM cancels the
// wait) leave no file and no row. A crash after the bundle was stored and
// before the row leaves a stored bundle whose client is proven and no
// account: the step stays unchecked, and the next check signs in again and
// makes the row. A crash after the row and before the draft's mark leaves
// the step unchecked: the re-check re-logs the same row (matched by the
// vendor's user id).
//
// Writers: company/<slug>.json under its flock with SaveIfUnchanged against
// the file read before the browser opened (a confirm, publish or another
// check that wrote meanwhile wins, and this check stores nothing); the
// account row as `google add --company` / `jira add --company` write it; the
// draft's mark only through RecordDraftCheck under draft.json.lock (a wizard
// save keeps it, an edit made during the sign-in leaves the step unchecked).

// Check results; the dry check's are company.Dry*.
const (
	checkOK            = company.DryOK
	checkRejected      = company.DryRejected
	checkNetwork       = company.DryNetwork
	checkAdminConsent  = company.DryAdminConsent
	checkCancelled     = "cancelled"
	checkReplaceNeeded = "replace_needed"
	checkForced        = "forced"
)

var companyCheckFlags struct {
	replace  bool
	clientID string
	tenant   string
}

var companyCheckCmd = &cobra.Command{
	Use:   "check google|atlassian|linear|microsoft",
	Short: "Check a company app for the setup wizard: your sign-in (Google, Atlassian) or a dry authorize (Linear, Microsoft)",
	Long: `Google and Atlassian: reads {"company","slug","google"|"atlassian"} on stdin and signs
you in through that client; the sign-in connects your account and stores the company's
bundle. Linear and Microsoft: --client-id (and --tenant) are checked without signing in.`,
	Args:      cobra.ExactArgs(1),
	ValidArgs: []string{"google", "atlassian", "linear", "microsoft"},
	RunE:      runCompanyCheck,
}

func init() {
	companyCmd.AddCommand(companyCheckCmd)
	f := companyCheckCmd.Flags()
	f.Bool("json", false, "print JSON")
	f.BoolVar(&companyCheckFlags.replace, "replace", false,
		"replace the company's stored app for this vendor; its other accounts need a new login")
	f.StringVar(&companyCheckFlags.clientID, "client-id", "", "the client id to check (linear, microsoft)")
	f.StringVar(&companyCheckFlags.tenant, "tenant", "", "the Microsoft directory (tenant) id")
	f.Bool("no-open", false, "don't open the browser automatically")
	f.Bool("app-return", false, "bring the Watchtower app back to the front when done")
}

// companyCheckResult is one check's answer. Checked reports the draft's step
// marked: false without a draft, when its values changed meanwhile, or when
// marking failed (DraftError).
type companyCheckResult struct {
	Result          string `json:"result"` // ok|rejected|network|cancelled|replace_needed|forced|admin_consent
	Slug            string `json:"slug"`
	AccountID       int64  `json:"account_id"`
	Email           string `json:"email"`
	Domain          string `json:"domain"`
	Site            string `json:"site"`
	Code            string `json:"code"`
	Message         string `json:"message"`
	Checked         bool   `json:"checked"`
	DraftError      string `json:"draft_error,omitempty"`
	AdminConsentURL string `json:"admin_consent_url,omitempty"`
	// Confluence: an Atlassian check's grant carries the Confluence scopes
	// (false = Atlassian refused them and Jira alone connected).
	Confluence *bool `json:"confluence,omitempty"`
}

// companyDryHTTP is the dry check's HTTP client (nil = default); a var so
// tests answer it.
var companyDryHTTP *http.Client

func runCompanyCheck(cmd *cobra.Command, args []string) error {
	vendor := args[0]
	dry := false
	switch vendor {
	case "linear", "microsoft":
		dry = true
	case "google", "atlassian":
	default:
		return usageError("company check: unknown service %q (google, atlassian, linear or microsoft)", vendor)
	}
	if err := sourceRefusal(companyVendorPolicySource[vendor]); err != nil {
		return err
	}
	// The Desktop stops a check by terminating this process: the wait for
	// the browser ends as a cancel, and nothing is stored.
	ctx, stop := signal.NotifyContext(cmd.Context(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	cmd.SetContext(ctx)

	var res companyCheckResult
	var err error
	if dry {
		res, err = runDryCompanyCheck(cmd, vendor)
	} else {
		res, err = runSignInCompanyCheck(cmd, vendor)
	}
	if err != nil {
		return err
	}
	return writeCompanyResult(cmd, res, func(w io.Writer) {
		_, _ = fmt.Fprintf(w, "%s %s %s\n", res.Result, res.Code, res.Message)
	})
}

func runDryCompanyCheck(cmd *cobra.Command, vendor string) (companyCheckResult, error) {
	switch {
	case companyCheckFlags.replace:
		return companyCheckResult{}, usageError("--replace is for google and atlassian")
	case companyCheckFlags.clientID == "":
		return companyCheckResult{}, usageError("company check %s needs --client-id", vendor)
	case (vendor == "microsoft") != (companyCheckFlags.tenant != ""):
		return companyCheckResult{}, usageError("--tenant is for microsoft, and microsoft needs it")
	}
	cfg, err := workspaceConfigFromFlags()
	if err != nil {
		return companyCheckResult{}, err
	}
	return dryCheckCompany(cmd.Context(), cmd.ErrOrStderr(), company.NewStore(cfg.WorkspaceDir()), vendor,
		companyCheckFlags.clientID, companyCheckFlags.tenant, companyDryHTTP), nil
}

func runSignInCompanyCheck(cmd *cobra.Command, vendor string) (companyCheckResult, error) {
	if companyCheckFlags.clientID != "" || companyCheckFlags.tenant != "" {
		return companyCheckResult{}, usageError("company check %s reads its client on stdin", vendor)
	}
	in, err := readCompanyCheckInput(cmd.InOrStdin())
	if err != nil {
		return companyCheckResult{}, err
	}
	cfg, database, err := openJiraCmdDB()
	if err != nil {
		return companyCheckResult{}, err
	}
	defer database.Close()
	return signInCheckCompany(cmd, cfg, database, vendor, in, companyCheckFlags.replace, companyForcedBundle())
}

// companyCheckInput is the sign-in check's stdin.
type companyCheckInput struct {
	Company   string                   `json:"company"`
	Slug      string                   `json:"slug"`
	Google    *companybundle.Google    `json:"google"`
	Atlassian *companybundle.Atlassian `json:"atlassian"`
}

func readCompanyCheckInput(r io.Reader) (companyCheckInput, error) {
	raw, err := io.ReadAll(io.LimitReader(r, companyStdinMax+1))
	if err != nil {
		return companyCheckInput{}, fmt.Errorf("reading the check from stdin: %w", err)
	}
	if len(raw) > companyStdinMax {
		return companyCheckInput{}, errors.New("the check on stdin is too long")
	}
	var in companyCheckInput
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&in); err != nil {
		return companyCheckInput{}, fmt.Errorf("decoding the check from stdin: %w", err)
	}
	return in, nil
}

// markCompanyDraft records a passed check in the wizard's draft into res.
// The check has done its work by then, so no draft (discarded, or a check
// run without the wizard) or values edited meanwhile only leave the step
// unchecked, and a failed write is reported in DraftError, not as a failed
// check.
func markCompanyDraft(res *companyCheckResult, store company.Store, c company.DraftCheck) {
	err := store.RecordDraftCheck(c)
	if err == nil {
		res.Checked = true
		return
	}
	if !errors.Is(err, fs.ErrNotExist) && !errors.Is(err, company.ErrDraftValuesChanged) {
		res.DraftError = err.Error()
	}
}

// dryCheckCompany is the Linear or Microsoft check: one dry authorize GET,
// the draft's step marked when it passes. Nothing else is stored. The hash
// is of the values as the wizard sent them, as its draft holds them.
func dryCheckCompany(ctx context.Context, warn io.Writer, store company.Store, vendor, clientID, tenantID string, hc *http.Client) companyCheckResult {
	var d company.Draft
	if vendor == "linear" {
		d.Linear = &companybundle.Linear{ClientID: clientID}
	} else {
		d.Microsoft = &companybundle.Microsoft{ClientID: clientID, TenantID: tenantID}
	}
	hash := company.CheckHash(vendor, d)
	clientID, tenantID = strings.TrimSpace(clientID), strings.ToLower(strings.TrimSpace(tenantID))
	r := company.DryAuthorize(ctx, hc, vendor, clientID, tenantID)
	res := companyCheckResult{Result: r.Result, Code: r.Code, Message: r.Message}
	switch r.Result {
	case checkAdminConsent:
		res.AdminConsentURL = company.AdminConsentURL(tenantID, clientID)
	case checkOK:
		markCompanyDraft(&res, store, company.DraftCheck{Vendor: vendor, Hash: hash})
		if res.DraftError != "" {
			_, _ = fmt.Fprintf(warn, "warning: the check passed, but marking the wizard's step failed: %s\n", res.DraftError)
		}
	}
	return res
}

// companyCheckPlan is what a sign-in check decided before the browser opens.
type companyCheckPlan struct {
	vendor string
	slug   string
	// hash is CheckHash of the values as the wizard sent them (as its draft
	// holds them).
	hash string
	// prev is the stored file of the company (nil = none); next is what the
	// check stores: prev with this vendor's checked block.
	prev *companybundle.Bundle
	next companybundle.Bundle
	// forced is the organization's MDM bundle of this company (nil = none):
	// it wins at read, so the check is stored but changes no account.
	forced *companybundle.Bundle
	// changes are the vendor's client changes over prev: a Replace.
	changes []company.Change
	// stop, when set, is the check's answer before any browser (a refused
	// value, or a Replace without --replace).
	stop *companyCheckResult
}

// planCompanyCheck validates the check and decides, before any browser, what
// it will store.
func planCompanyCheck(store company.Store, vendor string, in companyCheckInput, replace bool, forced string) (companyCheckPlan, error) {
	if (vendor == "google") != (in.Google != nil) || (vendor == "atlassian") != (in.Atlassian != nil) {
		return companyCheckPlan{}, fmt.Errorf("company check %s: stdin must carry the %s block only", vendor, vendor)
	}
	p := companyCheckPlan{vendor: vendor, hash: company.CheckHash(vendor, company.Draft{Google: in.Google, Atlassian: in.Atlassian})}
	raw, err := json.Marshal(companybundle.Bundle{V: 1, Company: in.Company, Google: in.Google, Atlassian: in.Atlassian})
	if err != nil {
		return p, err
	}
	n, err := companybundle.ParseJSON(raw, companybundle.OriginLocal)
	var pe *companybundle.ParseError
	if errors.As(err, &pe) {
		p.stop = &companyCheckResult{Result: checkRejected, Code: string(pe.Reason), Message: pe.Error()}
		return p, nil
	}
	if err != nil {
		return p, err
	}
	// The company's slug is SlugFor's (its file, its forced or pinned slug,
	// else a free one); a slug the wizard kept must be that one, never a
	// file or an MDM company's slug it would take over.
	if p.slug, err = store.SlugFor(n.Company, forced); err != nil {
		return p, err
	}
	if in.Slug != "" && in.Slug != p.slug {
		return p, usageError("company check: %s is stored under %q, not %q", n.Company, p.slug, in.Slug)
	}
	stored, ok, err := store.Get(p.slug, "")
	if err != nil {
		return p, err
	}
	p.next = companybundle.Bundle{V: 1, Company: n.Company}
	if ok {
		if stored.Bundle.Company != n.Company || stored.Bundle.Personal {
			return p, fmt.Errorf("company %s holds another setup (%s)", p.slug, stored.Bundle.Company)
		}
		p.prev, p.next = &stored.Bundle, stored.Bundle
	}
	// A forced bundle that does not parse forces nothing (the overlay
	// ignores it too, and reports it in `company list`).
	if fb, err := companybundle.Parse(forced, companybundle.OriginMDM); err == nil && fb.Company == n.Company {
		p.forced = &fb
	}
	if vendor == "google" {
		g := *n.Google
		if g.Domain == "" && p.prev != nil && p.prev.Google != nil && p.prev.Google.ClientID == g.ClientID {
			g.Domain = p.prev.Google.Domain
		}
		p.next.Google = &g
	} else {
		p.next.Atlassian = n.Atlassian
	}
	if p.prev != nil && p.forced == nil {
		p.changes = companyClientChanges(*p.prev, p.next, vendor)
	}
	if len(p.changes) > 0 && !replace {
		p.stop = &companyCheckResult{Result: checkReplaceNeeded, Slug: p.slug, Code: p.changes[0].Field,
			Message: fmt.Sprintf("%s's stored %s app will be replaced; its other accounts will need to log in again", n.Company, vendor)}
	}
	return p, nil
}

// companyClientChanges are vendor's changes from stored to next that move
// its accounts to another client: a rotated secret of the same client id is
// just used (Task 7a), not a Replace.
func companyClientChanges(stored, next companybundle.Bundle, vendor string) []company.Change {
	var out []company.Change
	for _, c := range company.Changes(stored, next) {
		if c.Vendor == vendor && c.Field != "client_secret" {
			out = append(out, c)
		}
	}
	return out
}

// storeCompanyCheck writes the checked bundle over the file the plan read
// and, for a Replace, marks the company's other accounts of the vendor for a
// new login (the re-logged row clears its own mark when it connects).
func storeCompanyCheck(store company.Store, database *db.DB, p companyCheckPlan) error {
	if err := store.SaveIfUnchanged(p.slug, p.prev, p.next); err != nil {
		if errors.Is(err, company.ErrStoredChanged) {
			return fmt.Errorf("%s's setup changed during the sign-in; check again: %w", p.next.Company, err)
		}
		return err
	}
	if len(p.changes) == 0 {
		return nil
	}
	if _, err := database.MarkCompanyAccounts(p.slug, company.ChangedAccountSources(p.changes), company.ChangedAppCode); err != nil {
		return fmt.Errorf("stored %s, but marking its accounts for a new login failed: %w", p.slug, err)
	}
	return nil
}

// signInCheckCompany is the Google or Atlassian check.
func signInCheckCompany(cmd *cobra.Command, cfg *config.Config, database *db.DB, vendor string, in companyCheckInput, replace bool, forced string) (companyCheckResult, error) {
	store := company.NewStore(cfg.WorkspaceDir())
	p, err := planCompanyCheck(store, vendor, in, replace, forced)
	if err != nil {
		return companyCheckResult{}, err
	}
	if p.stop != nil {
		return *p.stop, nil
	}
	// The sign-in helpers print through cmd.OutOrStdout(); a child command
	// sends that (the URL, the browser line) to stderr, so stdout carries the
	// result only. It shares cmd's flag set (--no-open, --app-return).
	inner := &cobra.Command{}
	inner.SetOut(cmd.ErrOrStderr())
	inner.SetErr(cmd.ErrOrStderr())
	inner.SetContext(cmd.Context())
	inner.Flags().AddFlagSet(cmd.Flags())

	var res companyCheckResult
	if vendor == "google" {
		res, err = checkGoogleCompany(inner, cfg, database, store, p, in.Company)
	} else {
		res, err = checkAtlassianCompany(inner, cfg, database, store, p, in.Company)
	}
	if err != nil || res.Result != checkOK {
		return res, err
	}
	if res.DraftError != "" {
		_, _ = fmt.Fprintf(cmd.ErrOrStderr(), "warning: the check passed, but marking the wizard's step failed: %s\n", res.DraftError)
	}
	res.Slug = p.slug
	if p.forced != nil {
		res.Result = checkForced
	}
	return res, nil
}

// checkGoogleCompany signs in through the plan's Google client, stores the
// bundle with the account's Workspace domain, and lands the grant on the
// same user's row (Gmail address) or a new one tied to the company.
func checkGoogleCompany(cmd *cobra.Command, cfg *config.Config, database *db.DB, store company.Store, p companyCheckPlan, companyName string) (companyCheckResult, error) {
	grant, err := googleCompanyConsent(cmd, p.next.Google, true, true)
	if err != nil {
		return classifySignInError(cmd.Context(), err), nil
	}
	// Refusals of the grant come before anything is stored.
	if _, err := googleCompanyGrantRow(database, grant); err != nil {
		return refusedGrant(err)
	}
	domain := googleWorkspaceDomain(grant.result.email)
	if domain != "" {
		g := *p.next.Google
		g.Domain = domain
		p.next.Google = &g
	}
	if err := storeCompanyCheck(store, database, p); err != nil {
		return companyCheckResult{}, err
	}
	id, err := recordGoogleCompanyGrant(cmd, cfg, database, grant, p.slug, "")
	if err != nil {
		return companyCheckResult{}, err
	}
	if p.forced != nil && (p.forced.Google == nil || p.forced.Google.ClientID != p.next.Google.ClientID) {
		if err := database.SetGoogleAccountAuthState(id, "error", company.ChangedAppCode); err != nil {
			return companyCheckResult{}, err
		}
	}
	res := companyCheckResult{Result: checkOK, AccountID: id, Email: grant.result.email, Domain: p.next.Google.Domain}
	markCompanyDraft(&res, store, company.DraftCheck{Vendor: "google", Hash: p.hash, Company: companyName, Slug: p.slug, GoogleDomain: domain})
	return res, nil
}

// refusedGrant is a grant that cannot land on its user's row: a rejected
// result, nothing stored. Any other error is the command's.
func refusedGrant(err error) (companyCheckResult, error) {
	switch {
	case errors.Is(err, errGrantTooNarrow):
		return companyCheckResult{Result: checkRejected, Code: "grant_too_narrow", Message: err.Error()}, nil
	case errors.Is(err, errLoginDuringPurge):
		return companyCheckResult{Result: checkRejected, Code: "purge_running", Message: err.Error()}, nil
	}
	return companyCheckResult{}, err
}

// googleWorkspaceDomain is the Workspace domain of a Google address ("" for
// a consumer address or none).
func googleWorkspaceDomain(email string) string {
	_, d, ok := strings.Cut(strings.ToLower(strings.TrimSpace(email)), "@")
	if !ok || d == "gmail.com" || d == "googlemail.com" {
		return ""
	}
	return d
}

// jiraFetchMyself is jira.FetchMyself; a var so tests answer it.
var jiraFetchMyself = jira.FetchMyself

// checkAtlassianCompany signs in through the plan's Atlassian app on its
// site, stores the bundle, and lands the grant on the same Atlassian user's
// OAuth row on that site (re-logged) or a new row tied to the company. The
// sign-in asks for the Confluence scopes the site's accounts already use,
// so re-logging one never strips them.
func checkAtlassianCompany(cmd *cobra.Command, cfg *config.Config, database *db.DB, store company.Store, p companyCheckPlan, companyName string) (companyCheckResult, error) {
	a := p.next.Atlassian
	target := jiraAddTarget{
		OAuth: jira.JiraOAuthConfig{ClientID: a.ClientID, ClientSecret: a.ClientSecret},
		Slug:  p.slug, Site: a.Site, Confluence: a.Confluence,
	}
	uses, write, err := jiraSiteConfluenceUse(cfg.WorkspaceDir(), database, a.Site, cmd.ErrOrStderr())
	if err != nil {
		return companyCheckResult{}, err
	}
	target.Confluence = target.Confluence || uses
	target.ConfluenceWrite = write
	token, chosen, err := jiraSignIn(cmd, cfg, database, target)
	if err != nil {
		return classifySignInError(cmd.Context(), err), nil
	}
	me, err := jiraFetchMyself(cmd.Context(), token.AccessToken, chosen.ID)
	if err != nil {
		return classifySignInError(cmd.Context(), err), nil
	}
	id, err := companyJiraGrantRow(cfg.WorkspaceDir(), database, me.AccountID, chosen.ID, token, cmd.ErrOrStderr())
	if err != nil {
		return refusedGrant(err)
	}
	if err := storeCompanyCheck(store, database, p); err != nil {
		return companyCheckResult{}, err
	}
	if id, err = connectCompanyJiraAccount(cmd, cfg, database, target, token, chosen, me, id); err != nil {
		return companyCheckResult{}, err
	}
	if p.forced != nil && (p.forced.Atlassian == nil || p.forced.Atlassian.ClientID != a.ClientID) {
		if err := database.SetJiraAccountAuthState(id, "error", company.ChangedAppCode); err != nil {
			return companyCheckResult{}, err
		}
	}
	confluence := jira.HasConfluenceScopes(token)
	res := companyCheckResult{Result: checkOK, AccountID: id, Email: me.EmailAddress, Site: chosen.URL, Confluence: &confluence}
	markCompanyDraft(&res, store, company.DraftCheck{Vendor: "atlassian", Hash: p.hash, Company: companyName, Slug: p.slug})
	return res, nil
}

// companyJiraOAuthRows are the OAuth rows (not removed) that match.
func companyJiraOAuthRows(database *db.DB, match func(db.JiraAccount) bool) ([]db.JiraAccount, error) {
	accounts, err := database.ListJiraAccounts()
	if err != nil {
		return nil, fmt.Errorf("listing jira accounts: %w", err)
	}
	var out []db.JiraAccount
	for _, a := range accounts {
		if a.Status != "removed" && a.AuthKind != "api_token" && match(a) {
			out = append(out, a)
		}
	}
	return out, nil
}

// jiraSiteConfluenceUse reports whether an OAuth account on site uses
// Confluence, and its write scopes (jira login's re-login rule): a check
// that re-logs one of them asks for them again.
func jiraSiteConfluenceUse(workspaceDir string, database *db.DB, site string, warn io.Writer) (uses, write bool, err error) {
	rows, err := companyJiraOAuthRows(database, func(a db.JiraAccount) bool { return sameJiraSite(a.SiteURL, site) })
	if err != nil {
		return false, false, err
	}
	for _, a := range rows {
		u, err := accountUsesConfluence(workspaceDir, database, a.ID, warn)
		if err != nil {
			return false, false, err
		}
		uses = uses || u
		write = write || accountUsesConfluenceWrite(workspaceDir, a.ID, warn)
	}
	return uses, write, nil
}

// companyJiraGrantRow is the row an Atlassian grant of accountID on cloudID
// lands on: that person's OAuth row on the site, or 0 for a new row. A
// grant that cannot replace that row's — it lacks the Confluence scopes the
// row uses (errGrantTooNarrow; Atlassian refused them at the sign-in), or
// the row's purge is running — is refused. It writes nothing.
func companyJiraGrantRow(workspaceDir string, database *db.DB, accountID, cloudID string, token *jira.OAuthToken, warn io.Writer) (int64, error) {
	rows, err := companyJiraOAuthRows(database, func(a db.JiraAccount) bool {
		return a.OwnerAccountID == accountID && a.CloudID == cloudID
	})
	if err != nil || len(rows) == 0 {
		return 0, err
	}
	id := rows[0].ID
	uses, err := accountUsesConfluence(workspaceDir, database, id, warn)
	if err != nil {
		return 0, err
	}
	if (uses && !jira.HasConfluenceScopes(token)) || (accountUsesConfluenceWrite(workspaceDir, id, warn) && !jira.HasConfluenceWriteScopes(token)) {
		return 0, fmt.Errorf("%w: jira account %d uses Confluence access the sign-in did not grant", errGrantTooNarrow, id)
	}
	if err := refuseLoginDuringPurge(database, "jira", id); err != nil {
		return 0, err
	}
	return id, nil
}

// connectCompanyJiraAccount lands an Atlassian grant on row id (re-logged
// on the company's app and tied to it), or on a new row tied to the
// company when id is 0, and returns the row.
func connectCompanyJiraAccount(cmd *cobra.Command, cfg *config.Config, database *db.DB, target jiraAddTarget, token *jira.OAuthToken, site jira.CloudResource, me jira.Myself, id int64) (int64, error) {
	isNewRow := id == 0
	if isNewRow {
		var err error
		if id, err = database.CreateJiraAccount(db.JiraAccount{CompanySlug: target.Slug}); err != nil {
			return 0, fmt.Errorf("creating jira account: %w", err)
		}
	}
	if _, err := connectJiraAccount(cmd, cfg, database, id, target.OAuth, true, token, site, isNewRow); err != nil {
		return 0, err
	}
	if !isNewRow {
		if err := database.SetAccountCompany("jira", id, target.Slug); err != nil {
			return 0, fmt.Errorf("tying jira account %d to %s: %w", id, target.Slug, err)
		}
	}
	// The identity the row is matched by next time, whatever /myself in
	// connectJiraAccount managed.
	if err := database.SetJiraAccountOwner(id, me.AccountID, me.EmailAddress, me.DisplayName); err != nil {
		return 0, fmt.Errorf("recording jira account %d's owner: %w", id, err)
	}
	if err := enableJiraPhase(); err != nil {
		return 0, fmt.Errorf("saving jira config: %w", err)
	}
	return id, nil
}

// The sign-in failure markers (S1.7 pending: the reason Atlassian gives when
// an organization blocks user-installed apps passes through as the code;
// every marker lives here).
var (
	// signInDeniedRE is the error key the vendor redirected back with
	// (calendar/jira Login: "… authorization denied: <key>").
	signInDeniedRE = regexp.MustCompile(`authorization denied: ([A-Za-z0-9_.-]+)`)
	// signInErrorKeyRE is the error key of a refused code exchange (the
	// vendor's JSON body in "token exchange failed (<status>): <body>").
	signInErrorKeyRE = regexp.MustCompile(`"error"\s*:\s*"([A-Za-z0-9_.-]+)"`)
	// signInServerErrorRE is a vendor's 5xx answer ("… failed (503): …").
	signInServerErrorRE = regexp.MustCompile(`failed \(5\d\d\)`)
	// signInCancelKeys are redirect errors of a person who said no.
	signInCancelKeys = map[string]bool{"access_denied": true}
)

// classifySignInError reads a failed check sign-in: the person cancelled or
// never finished (cancelled), the vendor refused the client or the site
// (rejected, with its error key as the code), or it could not be reached or
// was down (network). Nothing was stored.
func classifySignInError(ctx context.Context, err error) companyCheckResult {
	msg := err.Error()
	switch {
	case ctx.Err() != nil || errors.Is(err, context.Canceled):
		return companyCheckResult{Result: checkCancelled, Message: "the sign-in was stopped"}
	case errors.Is(err, oauthpage.ErrLoginTimedOut):
		return companyCheckResult{Result: checkCancelled, Code: "timed_out", Message: msg}
	case errors.Is(err, jira.ErrNotAtlassianCloud):
		return companyCheckResult{Result: checkRejected, Code: "not_atlassian_cloud", Message: msg}
	case errors.Is(err, errCompanySiteNotReached):
		return companyCheckResult{Result: checkRejected, Code: "site_not_reached", Message: msg}
	}
	if m := signInDeniedRE.FindStringSubmatch(msg); m != nil {
		if signInCancelKeys[m[1]] {
			return companyCheckResult{Result: checkCancelled, Code: m[1], Message: msg}
		}
		return companyCheckResult{Result: checkRejected, Code: m[1], Message: msg}
	}
	if signInServerErrorRE.MatchString(msg) {
		return companyCheckResult{Result: checkNetwork, Message: msg}
	}
	if m := signInErrorKeyRE.FindStringSubmatch(msg); m != nil {
		return companyCheckResult{Result: checkRejected, Code: m[1], Message: msg}
	}
	var ue *url.Error
	var ne net.Error
	if errors.As(err, &ue) || errors.As(err, &ne) {
		return companyCheckResult{Result: checkNetwork, Message: msg}
	}
	return companyCheckResult{Result: checkRejected, Message: msg}
}
