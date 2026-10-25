package cmd

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"

	"github.com/spf13/cobra"

	"watchtower/internal/db"
	"watchtower/internal/policy"
	"watchtower/internal/purge"
)

// accountsCmd groups commands over every source's accounts; the per-source
// `<source> accounts` subcommands stay where they are.
var accountsCmd = &cobra.Command{Use: "accounts", Short: "Commands over the accounts of every source"}

var accountsPurgesCmd = &cobra.Command{
	Use:   "purges",
	Short: "Scheduled and finished purges of revoked or stale accounts' data",
	Long: `Lists the purge ledger, newest first: when an account's access is revoked,
or no account of a source was reached for 30 days, and purge on revoked access
is on, the account's synced data is deleted after a 72-hour notice unless you
reconnect. There is no command to purge sooner.`,
	Args: cobra.NoArgs,
	RunE: runAccountsPurges,
}

var flagAccountsPurgesJSON bool

func init() {
	accountsPurgesCmd.Flags().BoolVar(&flagAccountsPurgesJSON, "json", false, "print JSON")
	accountsCmd.AddCommand(accountsPurgesCmd)
	rootCmd.AddCommand(accountsCmd)
}

// accountPurgeJSON is one pinned --json ledger row (the Desktop reads it).
type accountPurgeJSON struct {
	ID           int64  `json:"id"`
	Source       string `json:"source"`
	AccountID    int64  `json:"account_id"`
	AccountLabel string `json:"account_label"`
	Reason       string `json:"reason"`
	State        string `json:"state"`
	ScheduledAt  string `json:"scheduled_at"`
	DueAt        string `json:"due_at"`
	StartedAt    string `json:"started_at"`
	FinishedAt   string `json:"finished_at"`
	RowsDeleted  int64  `json:"rows_deleted"`
	Error        string `json:"error"`
}

// accountPurgesJSON is the pinned --json document: the effective switch and
// what set it, so the Desktop never re-implements the rule, and every ledger
// row.
type accountPurgesJSON struct {
	Enabled    bool               `json:"enabled"`
	EnabledBy  string             `json:"enabled_by"`
	GraceHours int                `json:"grace_hours"`
	LeaseDays  int                `json:"lease_days"`
	Purges     []accountPurgeJSON `json:"purges"`
}

var purgeOriginText = map[purge.Origin]string{
	purge.OriginPolicy:  "set by your organisation",
	purge.OriginSetting: "your setting",
	purge.OriginBuild:   "build default",
	purge.OriginDefault: "default",
}

func runAccountsPurges(cmd *cobra.Command, _ []string) error {
	cfg, err := workspaceConfigFromFlags()
	if err != nil {
		return err
	}
	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	rows, err := database.ListAccountPurges(false)
	if err != nil {
		return err
	}
	accounts, err := database.ListPurgeAccounts()
	if err != nil {
		return err
	}
	labels := make(map[string]string, len(accounts))
	for _, a := range accounts {
		labels[fmt.Sprintf("%s:%d", a.Source, a.ID)] = a.Label
	}
	on, origin := purge.Enabled(cfg)
	doc := accountPurgesJSON{
		Enabled:    on,
		EnabledBy:  string(origin),
		GraceHours: int(purge.Grace.Hours()),
		LeaseDays:  int(purge.Lease.Hours() / 24),
		Purges:     make([]accountPurgeJSON, 0, len(rows)),
	}
	for _, r := range rows {
		doc.Purges = append(doc.Purges, accountPurgeJSON{
			ID: r.ID, Source: r.Source, AccountID: r.AccountID,
			AccountLabel: labels[fmt.Sprintf("%s:%d", r.Source, r.AccountID)],
			Reason:       r.Reason, State: r.State, ScheduledAt: r.ScheduledAt, DueAt: r.DueAt,
			StartedAt: r.StartedAt, FinishedAt: r.FinishedAt, RowsDeleted: r.RowsDeleted, Error: r.Error,
		})
	}

	w := cmd.OutOrStdout()
	if flagAccountsPurgesJSON {
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		return enc.Encode(doc)
	}
	state := "off"
	if on {
		state = "on"
	}
	fmt.Fprintf(w, "Purge on revoked access: %s (%s)\n", state, purgeOriginText[origin])
	if len(doc.Purges) == 0 {
		fmt.Fprintln(w, "No purges.")
		return nil
	}
	for _, p := range doc.Purges {
		fmt.Fprintln(w, purgeLine(p))
	}
	return nil
}

// purgeLine renders one ledger row for the text output.
func purgeLine(p accountPurgeJSON) string {
	label := p.AccountLabel
	if label == "" {
		label = fmt.Sprintf("#%d", p.AccountID)
	}
	parts := []string{fmt.Sprintf("%s %s", p.Source, label), p.Reason, p.State}
	switch p.State {
	case "done", "cancelled", "failed":
		parts = append(parts, p.FinishedAt)
	default:
		parts = append(parts, "due "+p.DueAt)
	}
	if p.RowsDeleted > 0 {
		parts = append(parts, fmt.Sprintf("%d rows deleted", p.RowsDeleted))
	}
	line := strings.Join(parts, "  ")
	if p.Error != "" {
		line += "  — " + p.Error
	}
	return line
}

// errLoginDuringPurge refuses a login or re-auth of an account whose purge is
// running: the purge would delete the credentials it writes when it finishes.
var errLoginDuringPurge = errors.New("watchtower is deleting this account's data; " +
	"log in again once it finishes (see 'watchtower accounts purges')")

// guardSource refuses, before run starts, a command of a source the
// organization's policy (AllowedSources, #608) forbids: no network call,
// browser or write happens.
func guardSource(src string, run func(*cobra.Command, []string) error) func(*cobra.Command, []string) error {
	return func(cmd *cobra.Command, args []string) error {
		if err := sourceRefusal(src); err != nil {
			return err
		}
		return run(cmd, args)
	}
}

// sourceRefusal is the organization's refusal of src (AllowedSources,
// #608); nil when it may be used. The commands (guardSource), the one-shot
// sync and the assistant's tool clients ask it.
func sourceRefusal(src string) error {
	if p := policy.Current(); !p.SourceAllowed(src) {
		return p.SourceError(src)
	}
	return nil
}

// sourceCommandGroups are the command groups of each policy source (google
// = Gmail + Calendar, imap includes Outlook, jira includes Confluence; auth
// is the Slack OAuth login, reaction-commands polls Slack reactions).
var sourceCommandGroups = map[string]string{
	"auth": "slack", "slack": "slack", "reaction-commands": "slack",
	"google": "google", "gmail": "google", "calendar": "google",
	"imap": "imap", "outlook": "imap",
	"caldav": "caldav",
	"jira":   "jira", "confluence": "jira",
	"linear": "linear",
}

// sourceGuardExempt are the source commands a forbidden source keeps: they
// make no call to the source and connect nothing — local reads, local
// settings, and taking an account away (logout, remove, disable, purge).
var sourceGuardExempt = map[string]bool{
	"auth check-cert": true, "auth trust-cert": true, "auth logout": true, "reaction-commands list": true,
	"slack accounts": true, "slack disable": true, "slack remove": true, "slack rename": true,
	"google accounts": true, "google remove": true, "google rename": true,
	"gmail logout": true, "gmail purge": true, "gmail status": true,
	"calendar logout": true, "calendar status": true, "calendar list": true, "calendar events": true, "calendar select": true,
	"imap list": true, "imap remove": true, "imap rename": true,
	"outlook logout": true, "outlook rename": true,
	"caldav list": true, "caldav remove": true, "caldav rename": true,
	"jira accounts": true, "jira disable": true, "jira remove": true, "jira rename": true, "jira logout": true,
	"jira status": true, "jira blockers": true, "jira workload": true, "jira project-map": true, "jira releases": true,
	"jira features enable": true, "jira features disable": true, "jira features reset": true,
	"jira boards override": true, "jira boards deselect": true, "jira users map": true,
	"confluence status": true, "confluence unselect": true,
	"linear accounts": true, "linear disable": true, "linear remove": true, "linear status": true,
	"linear teams deselect": true,
}

// sourceGuarded records the commands applySourceGuards wrapped, by source.
var sourceGuarded = map[*cobra.Command]string{}

var sourceGuardsOnce sync.Once

// applySourceGuards wraps every runnable command of sourceCommandGroups,
// except sourceGuardExempt, in guardSource — new subcommands are guarded by
// default. It runs once, after every init has added its subcommands: from
// cobra's initializers (any Execute) and from the cmd tests' TestMain.
func applySourceGuards() {
	sourceGuardsOnce.Do(func() {
		var walk func(c *cobra.Command, src string)
		walk = func(c *cobra.Command, src string) {
			if c.RunE != nil && !sourceGuardExempt[sourceCommandKey(c)] {
				c.RunE = guardSource(src, c.RunE)
				sourceGuarded[c] = src
			}
			for _, sub := range c.Commands() {
				walk(sub, src)
			}
		}
		for _, c := range rootCmd.Commands() {
			if src, ok := sourceCommandGroups[c.Name()]; ok {
				walk(c, src)
			}
		}
	})
}

// sourceCommandKey is c's path below the root ("jira boards select").
func sourceCommandKey(c *cobra.Command) string {
	return strings.TrimPrefix(c.CommandPath(), rootCmd.Name()+" ")
}

func init() { cobra.OnInitialize(applySourceGuards) }

// refuseLoginDuringPurge returns errLoginDuringPurge when the account's purge
// is running. Every login path calls it before its first write.
func refuseLoginDuringPurge(database *db.DB, source string, accountID int64) error {
	running, err := database.AccountPurgeRunning(source, accountID)
	if err != nil {
		return err
	}
	if running {
		return fmt.Errorf("%s account %d: %w", source, accountID, errLoginDuringPurge)
	}
	return nil
}
