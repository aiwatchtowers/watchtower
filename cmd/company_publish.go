package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/company"
	"watchtower/internal/companybundle"
	"watchtower/internal/db"
	"watchtower/internal/slackapp"
	"watchtower/internal/slackmanifest"
)

var companyPublishCmd = &cobra.Command{
	Use:   "publish",
	Short: "Publish the wizard's company setup: store the bundle and write the link to the Slack app (stdin JSON)",
	Long: "Reads {\"company\":…,\"config_token\":…} from stdin (the token only when Slack is part of\n" +
		"the setup; it is used for this run and never stored), packs the company bundle from the\n" +
		"wizard draft, stores it and writes the connect link and code to the About page of the\n" +
		"company's Slack app. On success the draft is deleted.",
	Args: noArgsToken,
	RunE: runCompanyPublish,
}

var companyProfileCmd = &cobra.Command{
	Use:   "profile",
	Short: "Print a .mobileconfig that sets a stored company for your organization's Macs",
	Args:  cobra.NoArgs,
	RunE:  runCompanyProfile,
}

func init() {
	companyCmd.AddCommand(companyPublishCmd, companyProfileCmd)
	companyPublishCmd.Flags().Bool("json", false, "print one JSON line per step and a final result line")
	companyProfileCmd.Flags().String("slug", "", "the stored company (company list)")
	_ = companyProfileCmd.MarkFlagRequired("slug")
}

// Publish results (the final JSON line's "result").
const (
	publishOK                 = "ok"
	publishNoSlack            = "no_slack" // stored and done; Slack is not part of the setup, so no About page
	publishTokenExpired       = "token_expired"
	publishNetwork            = "network"
	publishRefused            = "refused" // Reason says why; nothing changed unless the bundle step finished
	publishAtlassianUnchecked = "atlassian_unchecked"
)

// Reasons of a refused publish.
const (
	publishReasonNoDraft         = "no_draft"
	publishReasonDraftUnreadable = "draft_unreadable"
	publishReasonNoCompany       = "no_company"
	publishReasonRenamed         = "company_renamed" // a check stored the company under another name
	publishReasonSlackApp        = "slack_app_missing"
	publishReasonTokenMissing    = "token_missing"
	publishReasonBundle          = "invalid_bundle"
	publishReasonAboutTooLong    = "about_too_long"
	publishReasonWrongWorkspace  = "wrong_workspace"
	publishReasonIncomplete      = "vendor_incomplete" // a ticked step has no values (Google unchecked, no ids)
	publishReasonStoredChanged   = "stored_changed"    // another writer changed company/<slug>.json meanwhile
	publishReasonStorage         = "storage"           // a local write failed (detail on stderr only)
)

// Publish steps.
const (
	publishStepPack      = "pack"
	publishStepWriteLink = "write_link"
)

type companyPublishInput struct {
	Company     string `json:"company"`
	ConfigToken string `json:"config_token"`
}

type companyPublishResult struct {
	Result string `json:"result"`
	Slug   string `json:"slug,omitempty"`
	Link   string `json:"link,omitempty"`
	// Code is the connect code (the bundle's wire form).
	Code string `json:"code,omitempty"`
	// Reason is our reason for a refused publish, or Slack's error code.
	Reason  string `json:"reason,omitempty"`
	Message string `json:"message,omitempty"`
	// DraftError: published, but the draft could not be deleted.
	DraftError string `json:"draft_error,omitempty"`
}

// companyPublishDeps are the publish run's outside world.
type companyPublishDeps struct {
	store    company.Store
	database *db.DB
	api      slackapp.API
	lockPath string // the Slack app setup lock (slack app create|adopt|link share it)
	forced   string
	now      time.Time
	emit     func(slackapp.Step)
	warn     io.Writer
}

func runCompanyPublish(cmd *cobra.Command, _ []string) error {
	asJSON, _ := cmd.Flags().GetBool("json")
	in, err := readPublishInput(cmd.InOrStdin())
	if err != nil {
		return err
	}
	cfg, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	out := cmd.OutOrStdout()
	enc := json.NewEncoder(out)
	deps := companyPublishDeps{
		store:    company.NewStore(cfg.WorkspaceDir()),
		database: database,
		api:      slackAppAPI(),
		lockPath: filepath.Join(cfg.WorkspaceDir(), slackAppSetupLock),
		forced:   companyForcedBundle(),
		now:      companyNow(),
		warn:     cmd.ErrOrStderr(),
		emit: func(s slackapp.Step) {
			if asJSON {
				_ = enc.Encode(s)
			} else if s.State != slackapp.StateRunning {
				fmt.Fprintf(out, "%s: %s\n", s.Name, s.State)
			}
		},
	}
	ctx := cmd.Context()
	if ctx == nil {
		ctx = context.Background()
	}
	res, err := publishCompany(ctx, deps, in)
	if err != nil {
		return err
	}
	if asJSON {
		return enc.Encode(res)
	}
	switch res.Result {
	case publishOK, publishNoSlack:
		fmt.Fprintf(out, "Published %s.\nConnect link: %s\nConnect code: %s\n", res.Slug, res.Link, res.Code)
		return nil
	}
	detail := res.Reason
	if res.Message != "" {
		detail = res.Message
	}
	if detail != "" {
		detail = ": " + detail
	}
	return fmt.Errorf("company publish ended with %s%s", res.Result, detail)
}

// readPublishInput reads the one JSON object on stdin; unknown fields are
// refused so a typo never drops the token silently.
func readPublishInput(r io.Reader) (companyPublishInput, error) {
	raw, err := io.ReadAll(io.LimitReader(r, companyStdinMax+1))
	if err != nil {
		return companyPublishInput{}, fmt.Errorf("reading the publish request from stdin: %w", err)
	}
	if len(raw) > companyStdinMax {
		return companyPublishInput{}, errors.New("publish request on stdin is too long")
	}
	var in companyPublishInput
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&in); err != nil {
		// The decoder's message never quotes a value, so the token stays out.
		return companyPublishInput{}, fmt.Errorf("publish request on stdin: %w", err)
	}
	in.Company = strings.TrimSpace(in.Company)
	in.ConfigToken = strings.TrimSpace(in.ConfigToken)
	return in, nil
}

func refusedPublish(reason, msg string) companyPublishResult {
	return companyPublishResult{Result: publishRefused, Reason: reason, Message: msg}
}

// publishCompany is `company publish`: refuse what cannot be published, pack
// the complete bundle and store it, write the About text to the Slack app,
// and on success delete the draft (and any set-aside draft).
//
// Failures: everything before the bundle is stored changes nothing. After
// it, a Slack failure (token_expired, network, refused) keeps the stored
// bundle and the draft, so Publish runs again; the stored bundle is the same
// one, so the rerun rewrites it unchanged. A crash after the Slack write and
// before the draft is deleted leaves the draft: the rerun writes the same
// About text again.
func publishCompany(ctx context.Context, deps companyPublishDeps, in companyPublishInput) (companyPublishResult, error) {
	d, state, _, err := deps.store.LoadDraft(deps.now)
	if err != nil {
		return companyPublishResult{}, fmt.Errorf("reading the company setup draft: %w", err)
	}
	switch state {
	case company.DraftOK:
	case company.DraftNone:
		return refusedPublish(publishReasonNoDraft, "there is no company setup to publish"), nil
	case company.DraftUnreadable:
		return refusedPublish(publishReasonDraftUnreadable, "the company setup could not be read"), nil
	}
	name := in.Company
	if name == "" {
		name = strings.TrimSpace(d.Company)
	}
	if name == "" {
		return refusedPublish(publishReasonNoCompany, "the company name is empty"), nil
	}
	active := func(v string) bool { return slices.Contains(d.Services, v) && !slices.Contains(d.Skipped, v) }
	if active("atlassian") && !d.IsChecked("atlassian") {
		return companyPublishResult{Result: publishAtlassianUnchecked,
			Message: "Publish waits for the Atlassian check: sign in on the Atlassian step, or skip Atlassian."}, nil
	}

	slug := d.Slug
	if slug == "" {
		if slug, err = deps.store.SlugFor(name, deps.forced); err != nil {
			return companyPublishResult{}, fmt.Errorf("choosing the company's file name: %w", err)
		}
	}
	// The stored file (never the forced overlay): what the checks wrote.
	stored, haveStored, err := deps.store.Get(slug, "")
	if err != nil {
		return companyPublishResult{}, fmt.Errorf("reading the stored company %s: %w", slug, err)
	}
	if haveStored && stored.Bundle.Company != name {
		return refusedPublish(publishReasonRenamed, fmt.Sprintf("this setup is stored as %q; publish it under that name", stored.Bundle.Company)), nil
	}

	var setup db.SlackAppSetup
	withSlack := active("slack")
	if withSlack {
		if setup, _, err = slackapp.SetupByAppID(deps.database, d.Slack.AppID); err != nil {
			return companyPublishResult{}, err
		}
		if setup.ClientID == "" {
			return refusedPublish(publishReasonSlackApp, "the Slack step has no finished app: finish or skip the Slack step"), nil
		}
		if in.ConfigToken == "" {
			return refusedPublish(publishReasonTokenMissing, "paste a configuration token to write the link to the Slack page"), nil
		}
	}

	b := packCompanyBundle(name, d, stored.Bundle, setup, active)
	// A ticked vendor without its block (Google never checked, Linear or
	// Microsoft without ids) would be dropped from the link unseen.
	for _, v := range d.Services {
		if active(v) && !slices.Contains(b.Vendors(), v) {
			return refusedPublish(publishReasonIncomplete, fmt.Sprintf("Publish waits for the %s step: finish it, or skip it.", v)), nil
		}
	}
	deps.emitStep(publishStepPack, slackapp.StateRunning)
	wire, err := companybundle.Encode(b)
	if err != nil {
		deps.emitStep(publishStepPack, slackapp.StateFailed)
		return refusedPublish(publishReasonBundle, err.Error()), nil
	}
	res := companyPublishResult{Slug: slug, Link: company.ConnectLink(wire), Code: wire}
	about := company.AboutText(name, res.Link, res.Code)
	if withSlack {
		if _, err := slackmanifest.Description(about); err != nil {
			deps.emitStep(publishStepPack, slackapp.StateFailed)
			return refusedPublish(publishReasonAboutTooLong, err.Error()), nil
		}
	}
	// Packed from this read of the file: a check or confirm that lands in
	// between is never overwritten with the older blocks (try again).
	var prev *companybundle.Bundle
	if haveStored {
		prev = &stored.Bundle
	}
	if err := deps.store.SaveIfUnchanged(slug, prev, b); err != nil {
		deps.emitStep(publishStepPack, slackapp.StateFailed)
		if errors.Is(err, company.ErrStoredChanged) {
			return refusedPublish(publishReasonStoredChanged, "the company setup changed while it was published: publish again"), nil
		}
		fmt.Fprintf(deps.warn, "company publish: storing the company bundle: %v\n", err)
		return refusedPublish(publishReasonStorage, "the company setup could not be stored on this Mac"), nil
	}
	deps.emitStep(publishStepPack, slackapp.StateDone)

	res.Result = publishNoSlack
	if withSlack {
		deps.emitStep(publishStepWriteLink, slackapp.StateRunning)
		r := &slackapp.Runner{DB: deps.database, API: deps.api, LockPath: deps.lockPath}
		linkRes, err := r.LinkAbout(ctx, in.ConfigToken, setup.TeamID, about)
		if err != nil {
			// The setup lock or the database, before anything reached Slack.
			linkRes = slackapp.Result{Kind: slackapp.KindStorage, Err: err}
		}
		if fail := publishSlackFailure(linkRes); fail != nil {
			deps.emitStep(publishStepWriteLink, slackapp.StateFailed)
			if linkRes.Err != nil {
				fmt.Fprintf(deps.warn, "company publish: %v\n", linkRes.Err)
			}
			fail.Slug, fail.Link, fail.Code = res.Slug, res.Link, res.Code
			return *fail, nil
		}
		deps.emitStep(publishStepWriteLink, slackapp.StateDone)
		res.Result = publishOK
	}
	if err := deps.store.DiscardDraft(); err != nil {
		// Published all the same; the wizard says the draft is still there
		// (it shows as in progress until the next Discard or Publish).
		res.DraftError = err.Error()
		fmt.Fprintf(deps.warn, "company publish: deleting the draft: %v\n", err)
	}
	return res, nil
}

func (deps companyPublishDeps) emitStep(name, state string) {
	deps.emit(slackapp.Step{Name: name, State: state})
}

// packCompanyBundle is the complete bundle: Google and Atlassian as their
// checks stored them (a check's sign-in proved them; an edited, unchecked
// pair stays the stored one), Linear and Microsoft and the deny list from
// the draft, Slack's ids from the app's setup record. A vendor that is not
// ticked, or skipped, is left out.
func packCompanyBundle(name string, d company.Draft, stored companybundle.Bundle, setup db.SlackAppSetup, active func(string) bool) companybundle.Bundle {
	b := companybundle.Bundle{V: companybundle.Version, Company: name, LinkDenyHosts: d.DenyHosts}
	if active("slack") {
		b.Slack = &companybundle.Slack{TeamID: setup.TeamID, ClientID: setup.ClientID}
	}
	if active("google") {
		b.Google = stored.Google
	}
	if active("atlassian") {
		b.Atlassian = stored.Atlassian
	}
	if active("linear") {
		b.Linear = d.Linear
	}
	if active("microsoft") {
		b.Microsoft = d.Microsoft
	}
	return b
}

// publishSlackFailure maps a write_link run that did not end ok; nil for ok.
func publishSlackFailure(r slackapp.Result) *companyPublishResult {
	switch r.Kind {
	case slackapp.KindOK:
		return nil
	case slackapp.KindBadToken:
		return &companyPublishResult{Result: publishTokenExpired, Reason: r.Code,
			Message: "The configuration token has expired, so the link is not on the Slack page yet. Your setup is kept."}
	case slackapp.KindNetwork:
		return &companyPublishResult{Result: publishNetwork, Message: "Could not reach Slack: " + r.Error + ". Your setup is kept."}
	case slackapp.KindWrongTeam:
		return &companyPublishResult{Result: publishRefused, Reason: publishReasonWrongWorkspace,
			Message: "the configuration token is for another Slack workspace than the company's app"}
	}
	reason := r.Code
	if reason == "" {
		reason = r.Kind
	}
	return &companyPublishResult{Result: publishRefused, Reason: reason, Message: r.Error}
}

func runCompanyProfile(cmd *cobra.Command, _ []string) error {
	slug, _ := cmd.Flags().GetString("slug")
	cfg, err := workspaceConfigFromFlags()
	if err != nil {
		return err
	}
	raw, err := companyProfile(company.NewStore(cfg.WorkspaceDir()), strings.TrimSpace(slug), company.NewUUID)
	if err != nil {
		return err
	}
	_, err = cmd.OutOrStdout().Write(raw)
	return err
}

// companyProfile is the .mobileconfig of the company stored under slug.
func companyProfile(store company.Store, slug string, newUUID func() string) ([]byte, error) {
	e, ok, err := store.Get(slug, "")
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, fmt.Errorf("no company is stored as %q (see company list)", slug)
	}
	if e.Bundle.Personal {
		return nil, errors.New("a personal Google project is not a company: there is no profile for it")
	}
	wire, err := companybundle.Encode(e.Bundle)
	if err != nil {
		return nil, err
	}
	return company.Mobileconfig(slug, wire, newUUID)
}
