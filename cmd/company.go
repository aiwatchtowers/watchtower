package cmd

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"reflect"

	"github.com/spf13/cobra"

	"watchtower/internal/company"
	"watchtower/internal/companybundle"
	"watchtower/internal/db"
	"watchtower/internal/policy"
)

// companyForcedBundle is the forced MDM CompanyBundle wire form ("" = none).
// Task 8 rewires it to the policy accessor.
var companyForcedBundle = func() string { return "" }

// companyStdinMax caps the bundle read from stdin; a wrapped code with its
// line breaks stays far below it.
const companyStdinMax = 64 << 10

// companyChangedAppCode is the account error a Replace leaves on the changed
// vendors' accounts of the company (Re-login needed).
const companyChangedAppCode = "company_changed_app"

// companyVendorAccountSource maps a bundle vendor to its account source in
// db.MarkCompanyAccounts / AccountsByCompany.
var companyVendorAccountSource = map[string]string{
	"slack": "slack", "google": "google", "atlassian": "jira", "microsoft": "outlook", "linear": "linear",
}

// companyVendorPolicySource maps a bundle vendor to its policy source
// (AllowedSources; Outlook is part of imap).
var companyVendorPolicySource = map[string]string{
	"slack": "slack", "google": "google", "atlassian": "jira", "microsoft": "imap", "linear": "linear",
}

var companyCmd = &cobra.Command{
	Use:   "company",
	Short: "Company bundles: the apps a company set Watchtower up with",
}

var companyListCmd = &cobra.Command{
	Use:   "list",
	Short: "List the stored companies (and the one your organization's profile sets)",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, _ []string) error {
		cfg, err := workspaceConfigFromFlags()
		if err != nil {
			return err
		}
		res, err := listCompanies(company.NewStore(cfg.WorkspaceDir()), companyForcedBundle())
		if err != nil {
			return err
		}
		return writeCompanyResult(cmd, res, func(w io.Writer) {
			for _, c := range res.Companies {
				forced := ""
				if c.Forced {
					forced = " (set by your organization)"
				}
				_, _ = fmt.Fprintf(w, "%s\t%s%s\n", c.Slug, c.Company, forced)
			}
			for _, e := range res.Errors {
				_, _ = fmt.Fprintf(w, "unreadable: %s: %s\n", e.File, e.Error)
			}
		})
	},
}

var companyInspectCmd = &cobra.Command{
	Use:   "inspect",
	Short: "Show what a company link or code (on stdin) would connect, without storing it",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, _ []string) error {
		wire, err := readCompanyWire(cmd.InOrStdin())
		if err != nil {
			return err
		}
		cfg, database, err := openJiraCmdDB()
		if err != nil {
			return err
		}
		defer database.Close()
		res, err := inspectCompany(company.NewStore(cfg.WorkspaceDir()), database, wire, companyForcedBundle())
		if err != nil {
			return err
		}
		return writeCompanyResult(cmd, res, func(w io.Writer) {
			if res.Refused != "" {
				_, _ = fmt.Fprintf(w, "refused: %s\n", res.Refused)
				return
			}
			_, _ = fmt.Fprintf(w, "%s (%s): %s\n", res.Company, res.Slug, res.State)
			for _, c := range res.Changes {
				_, _ = fmt.Fprintf(w, "  %s %s: %s → %s\n", c.Vendor, c.Field, c.Old, c.New)
			}
		})
	},
}

var companyConfirmFlags struct {
	source  string
	replace bool
}

var companyConfirmCmd = &cobra.Command{
	Use:   "confirm",
	Short: "Store a company link or code (on stdin) after the owner confirmed it",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, _ []string) error {
		origin, err := companyOrigin(companyConfirmFlags.source)
		if err != nil {
			return err
		}
		wire, err := readCompanyWire(cmd.InOrStdin())
		if err != nil {
			return err
		}
		cfg, database, err := openJiraCmdDB()
		if err != nil {
			return err
		}
		defer database.Close()
		res, err := confirmCompany(company.NewStore(cfg.WorkspaceDir()), database, wire, origin,
			companyConfirmFlags.replace, companyForcedBundle())
		if err != nil {
			return err
		}
		return writeCompanyResult(cmd, res, func(w io.Writer) {
			_, _ = fmt.Fprintf(w, "%s: %s\n", res.Slug, res.Result)
		})
	},
}

func init() {
	rootCmd.AddCommand(companyCmd)
	companyCmd.AddCommand(companyListCmd, companyInspectCmd, companyConfirmCmd)
	for _, c := range []*cobra.Command{companyListCmd, companyInspectCmd, companyConfirmCmd} {
		c.Flags().Bool("json", false, "print JSON")
	}
	companyConfirmCmd.Flags().StringVar(&companyConfirmFlags.source, "source", "",
		"where the bundle came from: link, code or mdm")
	companyConfirmCmd.Flags().BoolVar(&companyConfirmFlags.replace, "replace", false,
		"replace a stored company's changed apps; their accounts need a new login")
	_ = companyConfirmCmd.MarkFlagRequired("source")
}

// companyOrigin is --source as a bundle origin.
func companyOrigin(source string) (companybundle.Origin, error) {
	switch source {
	case "link":
		return companybundle.OriginLink, nil
	case "code":
		return companybundle.OriginCode, nil
	case "mdm":
		return companybundle.OriginMDM, nil
	}
	return 0, fmt.Errorf("--source must be link, code or mdm, not %q", source)
}

// readCompanyWire reads the bundle from stdin with every whitespace character
// dropped (a pasted code arrives wrapped). Past companyStdinMax it is too
// long to be a bundle.
func readCompanyWire(r io.Reader) (string, error) {
	raw, err := io.ReadAll(io.LimitReader(r, companyStdinMax+1))
	if err != nil {
		return "", fmt.Errorf("reading the company bundle from stdin: %w", err)
	}
	if len(raw) > companyStdinMax {
		return "", &companybundle.ParseError{Reason: companybundle.RefusalTooLong, Detail: "stdin"}
	}
	return company.CleanCode(string(raw)), nil
}

func writeCompanyResult(cmd *cobra.Command, v any, text func(io.Writer)) error {
	if asJSON, _ := cmd.Flags().GetBool("json"); asJSON {
		return json.NewEncoder(cmd.OutOrStdout()).Encode(v)
	}
	text(cmd.OutOrStdout())
	return nil
}

// companyVendorJSON is a vendor block without its secret.
type companyVendorJSON struct {
	TeamID     string `json:"team_id,omitempty"`
	ClientID   string `json:"client_id"`
	Domain     string `json:"domain,omitempty"`
	Site       string `json:"site,omitempty"`
	Confluence *bool  `json:"confluence,omitempty"`
	TenantID   string `json:"tenant_id,omitempty"`
}

func companyVendorsJSON(b companybundle.Bundle) map[string]companyVendorJSON {
	out := map[string]companyVendorJSON{}
	if b.Slack != nil {
		out["slack"] = companyVendorJSON{TeamID: b.Slack.TeamID, ClientID: b.Slack.ClientID}
	}
	if b.Google != nil {
		out["google"] = companyVendorJSON{ClientID: b.Google.ClientID, Domain: b.Google.Domain}
	}
	if b.Atlassian != nil {
		confluence := b.Atlassian.Confluence
		out["atlassian"] = companyVendorJSON{ClientID: b.Atlassian.ClientID, Site: b.Atlassian.Site, Confluence: &confluence}
	}
	if b.Microsoft != nil {
		out["microsoft"] = companyVendorJSON{ClientID: b.Microsoft.ClientID, TenantID: b.Microsoft.TenantID}
	}
	if b.Linear != nil {
		out["linear"] = companyVendorJSON{ClientID: b.Linear.ClientID}
	}
	return out
}

type companyListItem struct {
	Slug     string                       `json:"slug"`
	Company  string                       `json:"company"`
	Forced   bool                         `json:"forced"`
	Personal bool                         `json:"personal"`
	Vendors  map[string]companyVendorJSON `json:"vendors"`
}

type companyLoadErrorJSON struct {
	File  string `json:"file"`
	Error string `json:"error"`
}

type companyListResult struct {
	Companies []companyListItem      `json:"companies"`
	Errors    []companyLoadErrorJSON `json:"errors"`
	Draft     struct {
		State string `json:"state"`
	} `json:"draft"`
}

func listCompanies(store company.Store, forced string) (companyListResult, error) {
	entries, errs, err := store.LoadAll(forced)
	if err != nil {
		return companyListResult{}, err
	}
	res := companyListResult{Companies: []companyListItem{}, Errors: []companyLoadErrorJSON{}}
	res.Draft.State = "none" // Task 12 reads the wizard draft
	for _, e := range entries {
		res.Companies = append(res.Companies, companyListItem{
			Slug: e.Slug, Company: e.Bundle.Company, Forced: e.Forced, Personal: e.Bundle.Personal,
			Vendors: companyVendorsJSON(e.Bundle),
		})
	}
	for _, le := range errs {
		res.Errors = append(res.Errors, companyLoadErrorJSON{File: le.File, Error: le.Err})
	}
	return res, nil
}

// companyChangeJSON is one changed client, ids shortened (A21); a secret's
// values are never printed.
type companyChangeJSON struct {
	Vendor string `json:"vendor"`
	Field  string `json:"field"`
	Old    string `json:"old"`
	New    string `json:"new"`
}

type companyInspectResult struct {
	Refused   string              `json:"refused,omitempty"`
	Company   string              `json:"company"`
	Slug      string              `json:"slug"`
	State     string              `json:"state"`
	Forced    bool                `json:"forced"`
	Vendors   []string            `json:"vendors"`
	Connected map[string]bool     `json:"connected"`
	Changes   []companyChangeJSON `json:"changes"`
	Forbidden []string            `json:"forbidden"`
}

// companyMatch is an incoming bundle against what this install has for the
// same company.
type companyMatch struct {
	bundle  companybundle.Bundle
	slug    string
	current company.Entry
	stored  bool // a stored or forced entry exists
	changes []company.Change
}

func matchCompany(store company.Store, wire string, origin companybundle.Origin, forced string) (companyMatch, error) {
	b, err := companybundle.Parse(wire, origin)
	if err != nil {
		return companyMatch{}, err
	}
	m := companyMatch{bundle: b}
	if m.slug, err = store.SlugFor(b.Company, forced); err != nil {
		return companyMatch{}, err
	}
	if m.current, m.stored, err = store.Get(m.slug, forced); err != nil {
		return companyMatch{}, err
	}
	if m.stored {
		m.changes = company.Changes(m.current.Bundle, b)
	}
	return m, nil
}

// inspectCompany reports what confirming wire would do. A refused bundle is
// a result (Refused), not an error: the Desktop shows why.
func inspectCompany(store company.Store, database *db.DB, wire, forced string) (companyInspectResult, error) {
	m, err := matchCompany(store, wire, companybundle.OriginCode, forced)
	var pe *companybundle.ParseError
	if errors.As(err, &pe) {
		return companyInspectResult{Refused: string(pe.Reason), Vendors: []string{}, Connected: map[string]bool{},
			Changes: []companyChangeJSON{}, Forbidden: []string{}}, nil
	}
	if err != nil {
		return companyInspectResult{}, err
	}
	res := companyInspectResult{
		Company: m.bundle.Company, Slug: m.slug, State: "new", Forced: m.current.Forced,
		Vendors: m.bundle.Vendors(), Connected: map[string]bool{}, Changes: []companyChangeJSON{}, Forbidden: []string{},
	}
	if res.Vendors == nil {
		res.Vendors = []string{}
	}
	if m.stored {
		res.State = "same"
		if len(m.changes) > 0 {
			res.State = "changed"
		}
		refs, err := database.AccountsByCompany(m.slug)
		if err != nil {
			return companyInspectResult{}, err
		}
		for _, r := range refs {
			if r.Status != "ok" {
				continue
			}
			for vendor, src := range companyVendorAccountSource {
				if src == r.Source {
					res.Connected[vendor] = true
				}
			}
		}
	}
	for _, c := range m.changes {
		res.Changes = append(res.Changes, companyChangeJSON{
			Vendor: c.Vendor, Field: c.Field, Old: company.ShortID(c.Old), New: company.ShortID(c.New),
		})
	}
	for _, v := range res.Vendors {
		if !policy.SourceAllowed(companyVendorPolicySource[v]) {
			res.Forbidden = append(res.Forbidden, v)
		}
	}
	return res, nil
}

type companyMarkedJSON struct {
	Source string `json:"source"`
	ID     int64  `json:"id"`
}

type companyConfirmResult struct {
	Result string              `json:"result"` // stored | unchanged | needs_replace
	Slug   string              `json:"slug"`
	Marked []companyMarkedJSON `json:"marked"`
}

// confirmCompany stores wire after the owner's confirmation. A bundle that
// changes a stored company's clients is stored only with replace, which
// first marks the changed vendors' accounts Re-login (so a failed write is
// retried by the next confirm, not lost). A forced MDM bundle is never
// written and always wins: confirming it (source mdm) only names its slug,
// and a link or code for the same company changes nothing ("unchanged").
func confirmCompany(store company.Store, database *db.DB, wire string, origin companybundle.Origin, replace bool, forced string) (companyConfirmResult, error) {
	m, err := matchCompany(store, wire, origin, forced)
	if err != nil {
		return companyConfirmResult{}, err
	}
	res := companyConfirmResult{Slug: m.slug, Marked: []companyMarkedJSON{}}
	if origin == companybundle.OriginMDM {
		if !m.current.Forced || !reflect.DeepEqual(m.current.Bundle, m.bundle) {
			return companyConfirmResult{}, errors.New("this bundle is not the one your organization's profile sets")
		}
		res.Result = "unchanged"
		return res, nil
	}
	switch {
	case !m.stored:
	case m.current.Forced || reflect.DeepEqual(m.current.Bundle, m.bundle):
		res.Result = "unchanged"
		return res, nil
	case len(m.changes) > 0 && !replace:
		res.Result = "needs_replace"
		return res, nil
	}
	if len(m.changes) > 0 {
		marked, err := database.MarkCompanyAccounts(m.slug, companyChangedSources(m.changes), companyChangedAppCode)
		if err != nil {
			return companyConfirmResult{}, err
		}
		for _, r := range marked {
			res.Marked = append(res.Marked, companyMarkedJSON{Source: r.Source, ID: r.ID})
		}
	}
	if err := store.Save(m.slug, m.bundle); err != nil {
		return companyConfirmResult{}, err
	}
	res.Result = "stored"
	return res, nil
}

// companyChangedSources are the account sources of the changed vendors.
func companyChangedSources(changes []company.Change) []string {
	var out []string
	seen := map[string]bool{}
	for _, c := range changes {
		if src := companyVendorAccountSource[c.Vendor]; !seen[src] {
			seen[src] = true
			out = append(out, src)
		}
	}
	return out
}
