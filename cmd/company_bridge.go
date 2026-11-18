package cmd

import (
	"cmp"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/auth"
	"watchtower/internal/calendar"
	"watchtower/internal/company"
	"watchtower/internal/companybundle"
	"watchtower/internal/db"
	"watchtower/internal/fsutil"
	"watchtower/internal/imap"
	"watchtower/internal/jira"
	"watchtower/internal/linear"
	"watchtower/internal/media"
	"watchtower/internal/oauthclient"
)

// BuildCompanyName is the corp build's company (ldflags
// `-X watchtower/cmd.BuildCompanyName=…` from BUILD_COMPANY_NAME): the
// company the bridge stores the build's baked clients under. Empty on the
// public build.
var BuildCompanyName = ""

// companyMigratedMarker is <workspace>/company_migrated: the bridge stored
// the corp company and tied its accounts. The Desktop's UpdateService lets a
// flavored build take the public feed only once it exists (#1887 §5).
const companyMigratedMarker = "company_migrated"

// companyBridgeFault is a test seam: an error it returns for a step fails the
// bridge right before that step.
var companyBridgeFault = func(string) error { return nil }

// Bridge result values.
const (
	bridgeNoop     = "noop"
	bridgeMigrated = "migrated"
)

var companyBridgeCmd = &cobra.Command{
	Use:   "bridge",
	Short: "Move a corp build's accounts onto a company bundle built from its own clients",
	Long: `Stores the corp build's baked OAuth clients as a company bundle (the
company named at build time) and ties every account signed in through
them to it, then writes <workspace>/company_migrated. Run by the app at
launch before the daemon starts; a no-op on the public build. A failure
leaves everything as it was and the next launch retries.`,
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, _ []string) error {
		if res, ok := companyBridgeSkip(BuildFlavor, BuildCompanyName, currentCorpBaked()); !ok {
			return writeCompanyResult(cmd, res, func(w io.Writer) { _, _ = fmt.Fprintf(w, "nothing to do: %s\n", res.Reason) })
		}
		cfg, database, err := openJiraCmdDB()
		if err != nil {
			return err
		}
		defer database.Close()
		res, err := runCompanyBridge(cfg.WorkspaceDir(), database, BuildCompanyName, currentCorpBaked(), companyForcedBundle())
		if err != nil {
			return err
		}
		return writeCompanyResult(cmd, res, func(w io.Writer) {
			_, _ = fmt.Fprintf(w, "%s: %s, %d account(s) tied\n", res.Slug, res.Stored, len(res.Tied))
			for _, s := range res.Skipped {
				_, _ = fmt.Fprintf(w, "  not tied: %s account %d (%s)\n", s.Source, s.ID, s.Reason)
			}
		})
	},
}

func init() {
	companyCmd.AddCommand(companyBridgeCmd)
	companyBridgeCmd.Flags().Bool("json", false, "print JSON")
}

// corpBaked is what a corp build bakes in: one client id per source
// (CompanyAccountSources names; Outlook is the Microsoft app), the two
// secrets, and the build's link deny list.
type corpBaked struct {
	ids                      map[string]string
	googleSecret, jiraSecret string
	denyHosts                string
}

func currentCorpBaked() corpBaked {
	return corpBaked{
		ids: map[string]string{
			"slack": auth.DefaultClientID, "google": calendar.DefaultGoogleClientID, "jira": jira.DefaultJiraClientID,
			"linear": linear.DefaultLinearClientID, "outlook": imap.DefaultMicrosoftClientID,
		},
		googleSecret: calendar.DefaultGoogleClientSecret, jiraSecret: jira.DefaultJiraClientSecret,
		denyHosts: media.BuildDenyHosts,
	}
}

func (b corpBaked) empty() bool {
	for _, id := range b.ids {
		if id != "" {
			return false
		}
	}
	return true
}

type bridgeAccountJSON struct {
	Source string `json:"source"`
	ID     int64  `json:"id"`
}

type bridgeSkipJSON struct {
	Source string `json:"source"`
	ID     int64  `json:"id"`
	Reason string `json:"reason"`
}

// companyBridgeResult is `company bridge --json`. Result "noop" carries
// Reason (public_build, no_company_name, no_baked_clients); "migrated" the
// slug, what happened to the company file (created, updated, unchanged), the
// accounts tied and the baked-client accounts left untied with why
// (other_team, other_tenant, no_tenant, no_site, company_app_differs,
// unresolved).
type companyBridgeResult struct {
	Result  string              `json:"result"`
	Reason  string              `json:"reason,omitempty"`
	Slug    string              `json:"slug,omitempty"`
	Stored  string              `json:"stored,omitempty"`
	Tied    []bridgeAccountJSON `json:"tied"`
	Skipped []bridgeSkipJSON    `json:"skipped"`
}

// companyBridgeSkip says whether this build has anything to bridge: a
// flavored build other than dev, with a company name and at least one baked
// client. ok false carries the no-op result.
func companyBridgeSkip(flavor, companyName string, baked corpBaked) (companyBridgeResult, bool) {
	noop := func(reason string) (companyBridgeResult, bool) {
		return companyBridgeResult{Result: bridgeNoop, Reason: reason, Tied: []bridgeAccountJSON{}, Skipped: []bridgeSkipJSON{}}, false
	}
	switch {
	case flavor == "" || flavor == "dev":
		return noop("public_build")
	case companyName == "":
		return noop("no_company_name")
	case baked.empty():
		return noop("no_baked_clients")
	}
	return companyBridgeResult{}, true
}

// bridgeAccount is one account the bridge looks at: its row facts, the
// client its grant resolves to now, and how to write its client record.
type bridgeAccount struct {
	source   string
	id       int64
	slug     string // company_slug now
	key      string // Slack team, Outlook mail domain, Jira site
	clientID string // the client its grant resolves to now
	resolved error
	// record writes the account's client record when it has none and
	// returns the path it created ("" when one was there).
	record func(baked corpBaked) (string, error)
}

// bridgeAccounts lists every live account of the five company sources, oldest
// first within a source.
func bridgeAccounts(workspaceDir string, database *db.DB) ([]bridgeAccount, error) {
	live := func(status string) bool { return status != "removed" && status != "purged" }
	var out []bridgeAccount

	slackAccts, err := database.ListSlackAccounts()
	if err != nil {
		return nil, err
	}
	// Slack keeps no per-account client: every account signed in through
	// the build's shared app (env, else baked).
	slackClient := os.Getenv("WATCHTOWER_OAUTH_CLIENT_ID")
	if slackClient == "" {
		slackClient = auth.DefaultClientID
	}
	for _, a := range slackAccts {
		if live(a.Status) {
			out = append(out, bridgeAccount{source: "slack", id: a.ID, slug: a.CompanySlug, key: a.TeamID, clientID: slackClient})
		}
	}

	googleAccts, err := database.ListGoogleAccounts()
	if err != nil {
		return nil, err
	}
	for _, a := range googleAccts {
		if !live(a.Status) {
			continue
		}
		cfg, _, rerr := resolveGoogleOAuthConfigForAccount(workspaceDir, a)
		id := a.ID
		out = append(out, bridgeAccount{source: "google", id: id, slug: a.CompanySlug, clientID: cfg.ClientID, resolved: rerr,
			record: func(b corpBaked) (string, error) {
				store := calendar.NewCredentialStore(workspaceDir, id)
				if store.Exists() {
					return "", nil
				}
				return store.Path(), store.Save(&calendar.Credentials{ClientID: b.ids["google"], ClientSecret: b.googleSecret})
			}})
	}

	jiraAccts, err := database.ListJiraAccounts()
	if err != nil {
		return nil, err
	}
	for _, a := range jiraAccts {
		if !live(a.Status) || a.AuthKind == "api_token" {
			continue
		}
		cfg, _, rerr := resolveJiraOAuthConfigForAccount(workspaceDir, a)
		out = append(out, bridgeAccount{source: "jira", id: a.ID, slug: a.CompanySlug, key: a.SiteURL, clientID: cfg.ClientID, resolved: rerr,
			record: clientRecordWriter(workspaceDir, jiraClientVendor, a.ID, func(b corpBaked) oauthclient.Client {
				return oauthclient.Client{ClientID: b.ids["jira"], ClientSecret: b.jiraSecret}
			})})
	}

	linearAccts, err := database.ListLinearAccounts()
	if err != nil {
		return nil, err
	}
	for _, a := range linearAccts {
		if !live(a.Status) {
			continue
		}
		cfg, _, rerr := resolveLinearAccountClient(workspaceDir, a)
		out = append(out, bridgeAccount{source: "linear", id: a.ID, slug: a.CompanySlug, clientID: cfg.ClientID, resolved: rerr,
			record: clientRecordWriter(workspaceDir, linearClientVendor, a.ID, func(b corpBaked) oauthclient.Client {
				return oauthclient.Client{ClientID: b.ids["linear"]}
			})})
	}

	emailAccts, err := database.ListEmailAccounts()
	if err != nil {
		return nil, err
	}
	for _, a := range emailAccts {
		if a.Provider != "outlook" || !live(a.Status) {
			continue
		}
		cfg, _, rerr := resolveOutlookAccountClient(workspaceDir, a)
		_, domain, _ := strings.Cut(a.EmailAddress, "@")
		out = append(out, bridgeAccount{source: "outlook", id: a.ID, slug: a.CompanySlug, key: strings.ToLower(domain),
			clientID: cfg.ClientID, resolved: rerr,
			// The grant was issued on the "common" tenant: the record keeps
			// no tenant, so the company's tenant is not a changed app.
			record: clientRecordWriter(workspaceDir, outlookClientVendor, a.ID, func(b corpBaked) oauthclient.Client {
				return oauthclient.Client{ClientID: b.ids["outlook"]}
			})})
	}
	return out, nil
}

// clientRecordWriter writes an oauthclient record from the baked client when
// the account has none.
func clientRecordWriter(workspaceDir, vendor string, id int64, client func(corpBaked) oauthclient.Client) func(corpBaked) (string, error) {
	return func(b corpBaked) (string, error) {
		store := oauthclient.NewStore(workspaceDir, vendor, id)
		if _, ok, err := store.Load(); err != nil || ok {
			return "", err
		}
		return filepath.Join(workspaceDir, fmt.Sprintf("%s_client_%d.json", vendor, id)), store.Save(client(b))
	}
}

// onBaked reports whether a's grant is on the build's baked client and a is
// the bridge's to tie (untied, or already on slug).
func (a bridgeAccount) onBaked(baked corpBaked, slug string) bool {
	id := baked.ids[a.source]
	if id == "" || a.resolved != nil || (a.slug != "" && a.slug != slug) {
		return false
	}
	if a.source == "outlook" {
		return strings.EqualFold(a.clientID, id)
	}
	return a.clientID == id
}

// bridgeBundle is the bundle the corp build's clients make: every baked
// vendor whose block it can fill. Slack's team, Atlassian's site and
// Microsoft's tenant come from the oldest account on the baked client (the
// tenant is its mail domain); a vendor without one is left out.
func bridgeBundle(companyName string, baked corpBaked, accts []bridgeAccount, slug, workspaceDir string) (companybundle.Bundle, error) {
	b := companybundle.Bundle{V: companybundle.Version, Company: companyName}
	first := func(source string) (bridgeAccount, bool) {
		for _, a := range accts {
			if a.source == source && a.onBaked(baked, slug) {
				return a, true
			}
		}
		return bridgeAccount{}, false
	}
	if a, ok := first("slack"); ok {
		b.Slack = &companybundle.Slack{TeamID: a.key, ClientID: baked.ids["slack"]}
	}
	if id := baked.ids["google"]; id != "" {
		b.Google = &companybundle.Google{ClientID: id, ClientSecret: baked.googleSecret}
	}
	if a, ok := first("jira"); ok {
		if site, ok := bridgeSite(a.key); ok {
			access, _ := readConfluenceAccess(workspaceDir, a.id) // unreadable token: no Confluence
			b.Atlassian = &companybundle.Atlassian{ClientID: baked.ids["jira"], ClientSecret: baked.jiraSecret, Site: site, Confluence: access.Read}
		}
	}
	if id := baked.ids["linear"]; id != "" {
		b.Linear = &companybundle.Linear{ClientID: id}
	}
	if a, ok := first("outlook"); ok {
		if tenant, ok := companybundle.DenyHost(a.key); ok {
			b.Microsoft = &companybundle.Microsoft{ClientID: baked.ids["outlook"], TenantID: tenant}
		}
	}
	for _, h := range strings.Split(baked.denyHosts, ",") {
		if h, ok := companybundle.DenyHost(h); ok && !slices.Contains(b.LinkDenyHosts, h) {
			b.LinkDenyHosts = append(b.LinkDenyHosts, h)
		}
	}
	wire, err := companybundle.Encode(b)
	if err != nil {
		return companybundle.Bundle{}, fmt.Errorf("building the company bundle: %w", err)
	}
	return companybundle.Parse(wire, companybundle.OriginLink)
}

// bridgeSite is a Jira site URL as a bundle's https://<host>, if it is one.
func bridgeSite(siteURL string) (string, bool) {
	host, ok := strings.CutPrefix(strings.ToLower(strings.TrimSpace(siteURL)), "https://")
	if !ok {
		return "", false
	}
	host, ok = companybundle.DenyHost(strings.TrimSuffix(host, "/"))
	return "https://" + host, ok
}

// mergeBridgeBundle is the stored bundle of the company with the vendors it
// lacks filled from the bridge's and the bridge's deny hosts added: a block
// stored before (a previous run, or the company's own link) is never
// replaced. No stored bundle is the bridge's own.
func mergeBridgeBundle(stored *companybundle.Bundle, ours companybundle.Bundle) companybundle.Bundle {
	if stored == nil {
		return ours
	}
	m := *stored
	m.Slack = cmp.Or(m.Slack, ours.Slack)
	m.Google = cmp.Or(m.Google, ours.Google)
	m.Atlassian = cmp.Or(m.Atlassian, ours.Atlassian)
	m.Linear = cmp.Or(m.Linear, ours.Linear)
	m.Microsoft = cmp.Or(m.Microsoft, ours.Microsoft)
	m.LinkDenyHosts = slices.Clone(stored.LinkDenyHosts)
	for _, h := range ours.LinkDenyHosts {
		if !slices.Contains(m.LinkDenyHosts, h) {
			m.LinkDenyHosts = append(m.LinkDenyHosts, h)
		}
	}
	return m
}

// bridgeTie says whether the effective bundle (the stored file, or the forced
// MDM bundle that wins over it) gives account a its own baked client — the
// only case where tying it changes nothing for its grant — and why not.
func bridgeTie(a bridgeAccount, eff companybundle.Bundle, baked corpBaked) (bool, string) {
	id := baked.ids[a.source]
	switch a.source {
	case "slack":
		if eff.Slack == nil || eff.Slack.ClientID != id {
			return false, "company_app_differs"
		}
		if eff.Slack.TeamID != a.key {
			return false, "other_team"
		}
	case "google":
		if eff.Google == nil || eff.Google.ClientID != id {
			return false, "company_app_differs"
		}
	case "jira":
		if eff.Atlassian == nil {
			return false, "no_site"
		}
		if eff.Atlassian.ClientID != id {
			return false, "company_app_differs"
		}
	case "linear":
		if eff.Linear == nil || eff.Linear.ClientID != id {
			return false, "company_app_differs"
		}
	case "outlook":
		if eff.Microsoft == nil {
			return false, "no_tenant"
		}
		if !strings.EqualFold(eff.Microsoft.ClientID, id) {
			return false, "company_app_differs"
		}
		if eff.Microsoft.TenantID != a.key {
			return false, "other_tenant"
		}
	}
	return true, ""
}

// runCompanyBridge moves a corp build onto a company bundle (#1887 T11a): it
// stores the bundle its baked clients make under companyName (merged into a
// stored bundle of that company, never replacing a block), writes a client
// record for every account on a baked client that lacks one, ties those
// accounts to the company in one transaction, and writes the
// company_migrated marker last. It runs at every launch of the corp build,
// so accounts added since the last run are tied too. Any failure undoes
// what this run wrote (bundle, records, ties) and leaves no marker: the next
// launch retries.
func runCompanyBridge(workspaceDir string, database *db.DB, companyName string, baked corpBaked, forced string) (companyBridgeResult, error) {
	store := company.NewStore(workspaceDir)
	slug, err := store.SlugFor(companyName, forced)
	if err != nil {
		return companyBridgeResult{}, err
	}
	accts, err := bridgeAccounts(workspaceDir, database)
	if err != nil {
		return companyBridgeResult{}, err
	}
	ours, err := bridgeBundle(companyName, baked, accts, slug, workspaceDir)
	if err != nil {
		return companyBridgeResult{}, err
	}

	var undo []func() error
	fail := func(err error) (companyBridgeResult, error) {
		for i := len(undo) - 1; i >= 0; i-- {
			if uerr := undo[i](); uerr != nil {
				err = errors.Join(err, fmt.Errorf("undoing the bridge: %w", uerr))
			}
		}
		return companyBridgeResult{}, err
	}

	res := companyBridgeResult{Result: bridgeMigrated, Slug: slug, Stored: "unchanged", Tied: []bridgeAccountJSON{}, Skipped: []bridgeSkipJSON{}}
	cur, haveFile, err := store.Get(slug, "")
	if err != nil {
		return companyBridgeResult{}, err
	}
	var prev *companybundle.Bundle
	if haveFile {
		if cur.Bundle.Personal {
			return companyBridgeResult{}, fmt.Errorf("company %q is stored as a personal project", companyName)
		}
		prev = &cur.Bundle
	}
	merged := mergeBridgeBundle(prev, ours)
	if prev == nil || !reflect.DeepEqual(*prev, merged) {
		if err := companyBridgeFault("store"); err != nil {
			return fail(err)
		}
		if err := store.SaveIfUnchanged(slug, prev, merged); err != nil {
			return fail(err)
		}
		if prev == nil {
			res.Stored = "created"
			undo = append(undo, func() error {
				if err := os.Remove(filepath.Join(store.Dir, slug+".json")); err != nil && !errors.Is(err, os.ErrNotExist) {
					return err
				}
				return nil
			})
		} else {
			res.Stored = "updated"
			was := *prev
			undo = append(undo, func() error { return store.SaveIfUnchanged(slug, &merged, was) })
		}
	}
	eff, _, err := store.Get(slug, forced)
	if err != nil {
		return fail(err)
	}

	var tie, newlyTied []db.CompanyAccountRef
	for _, a := range accts {
		if !a.onBaked(baked, slug) {
			if a.resolved != nil && (a.slug == "" || a.slug == slug) && baked.ids[a.source] != "" {
				res.Skipped = append(res.Skipped, bridgeSkipJSON{Source: a.source, ID: a.id, Reason: "unresolved"})
			}
			continue
		}
		if ok, why := bridgeTie(a, eff.Bundle, baked); !ok {
			res.Skipped = append(res.Skipped, bridgeSkipJSON{Source: a.source, ID: a.id, Reason: why})
			continue
		}
		if a.record != nil {
			if err := companyBridgeFault("record"); err != nil {
				return fail(err)
			}
			created, err := a.record(baked)
			if err != nil {
				return fail(fmt.Errorf("%s account %d client record: %w", a.source, a.id, err))
			}
			if created != "" {
				undo = append(undo, func() error {
					if err := os.Remove(created); err != nil && !errors.Is(err, os.ErrNotExist) {
						return err
					}
					return nil
				})
			}
		}
		ref := db.CompanyAccountRef{Source: a.source, ID: a.id}
		tie = append(tie, ref)
		if a.slug == "" {
			newlyTied = append(newlyTied, ref)
		}
		res.Tied = append(res.Tied, bridgeAccountJSON{Source: a.source, ID: a.id})
	}

	if err := companyBridgeFault("tie"); err != nil {
		return fail(err)
	}
	if err := database.RetieAccounts(tie, "", slug); err != nil {
		return fail(err)
	}
	undo = append(undo, func() error { return database.RetieAccounts(newlyTied, slug, "") })

	if err := companyBridgeFault("marker"); err != nil {
		return fail(err)
	}
	marker := filepath.Join(workspaceDir, companyMigratedMarker)
	if _, err := os.Stat(marker); errors.Is(err, os.ErrNotExist) {
		if err := fsutil.WriteFileAtomic(marker, []byte(slug+"\n"), 0o600); err != nil {
			return fail(fmt.Errorf("writing %s: %w", companyMigratedMarker, err))
		}
	} else if err != nil {
		return fail(err)
	}
	return res, nil
}
