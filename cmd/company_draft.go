package cmd

import (
	"context"
	"fmt"
	"io"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/company"
	"watchtower/internal/db"
)

// companyNow is the wizard draft's clock (a var so tests fix it).
var companyNow = time.Now

var companyDraftCmd = &cobra.Command{
	Use:   "draft",
	Short: "The Set up for my company wizard's draft (secrets included, mode 0600)",
}

var companyDraftShowCmd = &cobra.Command{
	Use:   "show",
	Short: "Show the wizard draft; an unreadable one is set aside as draft.json.bad-<time>",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, _ []string) error {
		cfg, err := workspaceConfigFromFlags()
		if err != nil {
			return err
		}
		res, err := showCompanyDraft(company.NewStore(cfg.WorkspaceDir()), companyNow())
		if err != nil {
			return err
		}
		return writeCompanyResult(cmd, res, func(w io.Writer) {
			_, _ = fmt.Fprintln(w, res.State)
			if res.BadFile != "" {
				_, _ = fmt.Fprintf(w, "kept as %s\n", res.BadFile)
			}
		})
	},
}

var companyDraftSaveCmd = &cobra.Command{
	Use:   "save",
	Short: "Save the wizard draft from stdin (JSON); a Slack configuration token is refused",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, _ []string) error {
		cfg, err := workspaceConfigFromFlags()
		if err != nil {
			return err
		}
		if err := saveCompanyDraft(company.NewStore(cfg.WorkspaceDir()), cmd.InOrStdin(), companyNow()); err != nil {
			return err
		}
		_, _ = fmt.Fprintln(cmd.OutOrStdout(), "draft saved")
		return nil
	},
}

var companyDraftDiscardCmd = &cobra.Command{
	Use:   "discard",
	Short: "Delete the wizard draft and any unreadable one kept beside it",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, _ []string) error {
		cfg, err := workspaceConfigFromFlags()
		if err != nil {
			return err
		}
		if err := company.NewStore(cfg.WorkspaceDir()).DiscardDraft(); err != nil {
			return err
		}
		_, _ = fmt.Fprintln(cmd.OutOrStdout(), "draft discarded")
		return nil
	},
}

var companyDiscoverCmd = &cobra.Command{
	Use:   "discover",
	Short: "List the company apps this Mac already knows (never our shared ones)",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, _ []string) error {
		cfg, database, err := openJiraCmdDB()
		if err != nil {
			return err
		}
		defer database.Close()
		res, err := discoverCompanyClients(cmd.Context(), cfg.WorkspaceDir(), database, companyForcedBundle())
		if err != nil {
			return err
		}
		return writeCompanyResult(cmd, res, func(w io.Writer) {
			for _, c := range res.Candidates {
				_, _ = fmt.Fprintf(w, "%s\t%s%s\t%s\n", c.Vendor, c.ClientID, c.AppID, c.SourceLabel)
			}
		})
	},
}

func init() {
	companyCmd.AddCommand(companyDraftCmd, companyDiscoverCmd)
	companyDraftCmd.AddCommand(companyDraftShowCmd, companyDraftSaveCmd, companyDraftDiscardCmd)
	for _, c := range []*cobra.Command{companyDraftShowCmd, companyDiscoverCmd} {
		c.Flags().Bool("json", false, "print JSON")
	}
}

type companyDraftResult struct {
	State   company.DraftState `json:"state"`
	Draft   *company.Draft     `json:"draft"`
	BadFile string             `json:"bad_file"`
	// Checked are the steps whose check passed with the values they hold.
	Checked []string `json:"checked_vendors"`
}

func showCompanyDraft(store company.Store, now time.Time) (companyDraftResult, error) {
	d, state, bad, err := store.LoadDraft(now)
	if err != nil {
		return companyDraftResult{}, err
	}
	res := companyDraftResult{State: state, BadFile: bad, Checked: []string{}}
	if state == company.DraftOK {
		res.Draft = &d
		res.Checked = d.CheckedVendors()
	}
	return res, nil
}

// saveCompanyDraft stores the draft on r. A first save stamps its start.
func saveCompanyDraft(store company.Store, r io.Reader, now time.Time) error {
	raw, err := io.ReadAll(io.LimitReader(r, companyStdinMax+1))
	if err != nil {
		return fmt.Errorf("reading the draft from stdin: %w", err)
	}
	d, err := company.ParseDraftJSON(raw)
	if err != nil {
		return err
	}
	if d.StartedAt.IsZero() {
		d.StartedAt = now.UTC()
	}
	return store.SaveDraft(d)
}

type companyDiscoverResult struct {
	Candidates []company.Candidate `json:"candidates"`
}

func discoverCompanyClients(ctx context.Context, workspaceDir string, database *db.DB, forced string) (companyDiscoverResult, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	c, err := company.Discover(ctx, workspaceDir, database, forced)
	if err != nil {
		return companyDiscoverResult{}, err
	}
	return companyDiscoverResult{Candidates: c}, nil
}
