package cmd

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"path/filepath"
	"sort"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/confluence"
	"watchtower/internal/db"
	"watchtower/internal/extract"
	"watchtower/internal/extsync"
	"watchtower/internal/jira"
)

// providerConfluence is the ext_sources.provider every confluence command
// reads and writes.
const providerConfluence = "confluence"

var confluenceCmd = &cobra.Command{
	Use:   "confluence",
	Short: "Confluence spaces synced into knowledge search",
	Long: "Pick the Confluence spaces of a connected Atlassian site to sync into knowledge search.\n" +
		"Confluence rides the Jira account's OAuth grant; connect it with 'watchtower jira login --with-confluence'.",
}

var confluenceSpacesCmd = &cobra.Command{Use: "spaces", Short: "List the site's spaces and which are selected", RunE: runConfluenceSpaces}
var confluenceSelectCmd = &cobra.Command{Use: "select KEY...", Short: "Select spaces to sync", Args: cobra.MinimumNArgs(1), RunE: runConfluenceSelect}
var confluenceUnselectCmd = &cobra.Command{Use: "unselect KEY...", Short: "Stop syncing spaces and drop their synced content", Args: cobra.MinimumNArgs(1), RunE: runConfluenceUnselect}
var confluenceStatusCmd = &cobra.Command{Use: "status", Short: "Show every selected space's sync state", RunE: runConfluenceStatus}
var confluenceSyncCmd = &cobra.Command{Use: "sync", Short: "Sync the account's selected spaces now", RunE: runConfluenceSync}

var (
	confluenceFlagAccount int64
	confluenceSpacesJSON  bool
	confluenceStatusJSON  bool
	confluenceSyncForce   bool
)

func init() {
	rootCmd.AddCommand(confluenceCmd)
	confluenceCmd.AddCommand(confluenceSpacesCmd, confluenceSelectCmd, confluenceUnselectCmd, confluenceStatusCmd, confluenceSyncCmd)
	confluenceCmd.PersistentFlags().Int64Var(&confluenceFlagAccount, "account", 0,
		"Jira account id whose Atlassian site to use (default: the single enabled account)")
	confluenceSpacesCmd.Flags().BoolVar(&confluenceSpacesJSON, "json", false, "JSON output")
	confluenceStatusCmd.Flags().BoolVar(&confluenceStatusJSON, "json", false, "JSON output")
	confluenceSyncCmd.Flags().BoolVar(&confluenceSyncForce, "force", false, "sync even while the sync daemon is running")
}

// newConfluenceFetcher builds the fetcher for one account's client. A
// package var so tests can inject a fake.
var newConfluenceFetcher = func(client *jira.Client, siteURL string) extsync.Fetcher {
	return confluence.NewFetcher(client.Confluence(), siteURL)
}

// errConfluenceConsent is the re-consent hint (the extsync needs_consent
// text, R6). Keep "--with-confluence" in it and in the sign-in-expired hint:
// the Desktop's ConfluenceSpacesViewModel.needsConsent keys on that token.
func errConfluenceConsent(accountID int64) error {
	return fmt.Errorf("Confluence access not granted — run: watchtower jira login --account %d --with-confluence", accountID) //nolint:staticcheck // user-facing sentence, product name capitalized
}

// confluenceScopesOK reports whether account id's stored grant carries the
// Confluence scopes. An unreadable token counts as not granted.
func confluenceScopesOK(workspaceDir string, id int64) bool {
	tok, err := jira.NewTokenStore(workspaceDir, id).Load()
	return err == nil && jira.HasConfluenceScopes(tok)
}

// confluenceSession is the resolved account plus a fetcher over its grant.
type confluenceSession struct {
	cfg     *config.Config
	db      *db.DB
	account db.JiraAccount
	fetcher extsync.Fetcher
}

// openConfluenceSession resolves --account, checks the Confluence scopes
// (no network) and builds the fetcher. The caller closes s.db.
func openConfluenceSession() (*confluenceSession, error) {
	cfg, database, err := openJiraCmdDB()
	if err != nil {
		return nil, err
	}
	account, err := resolveJiraAccount(database, confluenceFlagAccount)
	if err != nil {
		database.Close()
		return nil, err
	}
	store := jira.NewTokenStore(cfg.WorkspaceDir(), account.ID)
	if account.CloudID == "" || !store.Exists() {
		database.Close()
		return nil, fmt.Errorf("jira account %d has no token or site — run: watchtower jira login --account %d --with-confluence", account.ID, account.ID)
	}
	if !confluenceScopesOK(cfg.WorkspaceDir(), account.ID) {
		database.Close()
		return nil, errConfluenceConsent(account.ID)
	}
	client := jira.NewClient(account.CloudID, resolveJiraOAuthConfig(), store)
	return &confluenceSession{cfg: cfg, db: database, account: account, fetcher: newConfluenceFetcher(client, account.SiteURL)}, nil
}

// liveContainers lists the site's spaces, mapping a consent failure to the
// re-login hint.
func (s *confluenceSession) liveContainers(cmd *cobra.Command) ([]extsync.Container, error) {
	cs, err := s.fetcher.Containers(cmd.Context())
	switch {
	case errors.Is(err, extsync.ErrNeedsConsent):
		return nil, errConfluenceConsent(s.account.ID)
	case errors.Is(err, extsync.ErrAuthRevoked):
		return nil, fmt.Errorf("Atlassian sign-in expired — run: watchtower jira login --account %d --with-confluence", s.account.ID) //nolint:staticcheck // user-facing sentence
	case err != nil:
		return nil, fmt.Errorf("listing Confluence spaces: %w", err)
	}
	return cs, nil
}

// selectedKeys returns the account's selected sources by container key.
func (s *confluenceSession) selectedKeys() (map[string]db.ExtSource, error) {
	srcs, err := s.db.ListExtSourcesForJiraAccount(providerConfluence, s.account.ID)
	if err != nil {
		return nil, fmt.Errorf("listing selected spaces: %w", err)
	}
	out := make(map[string]db.ExtSource, len(srcs))
	for _, src := range srcs {
		out[src.ContainerKey] = src
	}
	return out, nil
}

// confluenceSpaceJSON is one `confluence spaces --json` row.
type confluenceSpaceJSON struct {
	Key      string `json:"key"`
	Name     string `json:"name"`
	ID       string `json:"id"`
	Selected bool   `json:"selected"`
}

func runConfluenceSpaces(cmd *cobra.Command, _ []string) error {
	s, err := openConfluenceSession()
	if err != nil {
		return err
	}
	defer s.db.Close()
	cs, err := s.liveContainers(cmd)
	if err != nil {
		return err
	}
	selected, err := s.selectedKeys()
	if err != nil {
		return err
	}
	rows := make([]confluenceSpaceJSON, 0, len(cs))
	for _, c := range cs {
		_, sel := selected[c.Key]
		rows = append(rows, confluenceSpaceJSON{Key: c.Key, Name: c.Name, ID: c.ExtID, Selected: sel})
	}
	out := cmd.OutOrStdout()
	if confluenceSpacesJSON {
		return json.NewEncoder(out).Encode(rows)
	}
	w := tabwriter.NewWriter(out, 0, 4, 2, ' ', 0)
	fmt.Fprintln(w, "KEY\tNAME\tSELECTED")
	for _, r := range rows {
		mark := ""
		if r.Selected {
			mark = "yes"
		}
		fmt.Fprintf(w, "%s\t%s\t%s\n", r.Key, r.Name, mark)
	}
	return w.Flush()
}

func runConfluenceSelect(cmd *cobra.Command, args []string) error {
	s, err := openConfluenceSession()
	if err != nil {
		return err
	}
	defer s.db.Close()
	cs, err := s.liveContainers(cmd)
	if err != nil {
		return err
	}
	picked, err := resolveSpaceKeys(cs, args)
	if err != nil {
		return err
	}
	out := cmd.OutOrStdout()
	for _, c := range picked {
		if _, err := s.db.CreateExtSource(providerConfluence, s.account.ID, c.Key, c.ExtID, c.Name); err != nil {
			return fmt.Errorf("selecting %s: %w", c.Key, err)
		}
		fmt.Fprintf(out, "Selected %s (%s)\n", c.Key, c.Name)
	}
	fmt.Fprintln(out, "The sync daemon picks it up on its next cycle; 'watchtower confluence sync' runs it now.")
	return nil
}

// resolveSpaceKeys maps every key to a live container; any unknown key fails
// the whole call before anything is written.
func resolveSpaceKeys(cs []extsync.Container, keys []string) ([]extsync.Container, error) {
	byKey := make(map[string]extsync.Container, len(cs))
	for _, c := range cs {
		byKey[c.Key] = c
	}
	var picked []extsync.Container
	var unknown []string
	for _, k := range keys {
		c, ok := byKey[k]
		if !ok {
			unknown = append(unknown, k)
			continue
		}
		picked = append(picked, c)
	}
	if len(unknown) > 0 {
		return nil, fmt.Errorf("unknown Confluence space key(s): %s (see 'watchtower confluence spaces')", strings.Join(unknown, ", "))
	}
	return picked, nil
}

func runConfluenceUnselect(cmd *cobra.Command, args []string) error {
	cfg, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	account, err := resolveJiraAccount(database, confluenceFlagAccount)
	if err != nil {
		return err
	}
	s := &confluenceSession{cfg: cfg, db: database, account: account}
	selected, err := s.selectedKeys()
	if err != nil {
		return err
	}
	var unknown []string
	for _, k := range args {
		if _, ok := selected[k]; !ok {
			unknown = append(unknown, k)
		}
	}
	if len(unknown) > 0 {
		return fmt.Errorf("space(s) not selected: %s", strings.Join(unknown, ", "))
	}
	out := cmd.OutOrStdout()
	for _, k := range args {
		if err := database.DeleteExtSource(selected[k].ID); err != nil {
			return err
		}
		fmt.Fprintf(out, "Unselected %s; its synced content is removed and leaves search on the next index cycle.\n", k)
	}
	return nil
}

// confluenceStatusRow is one `confluence status --json` row.
type confluenceStatusRow struct {
	SourceID     int64          `json:"source_id"`
	AccountID    int64          `json:"account_id"`
	Key          string         `json:"key"`
	Name         string         `json:"name"`
	Status       string         `json:"status"`
	Error        string         `json:"error"`
	BackfillDone bool           `json:"backfill_done"`
	LastSyncedAt string         `json:"last_synced_at"`
	Pages        int            `json:"pages"`
	Blogposts    int            `json:"blogposts"`
	Attachments  int            `json:"attachments"`
	Comments     int            `json:"comments"`
	ByExtract    map[string]int `json:"by_extract_status"`
}

func confluenceStatusRows(database *db.DB, accountID int64) ([]confluenceStatusRow, error) {
	srcs, err := database.ListExtSources(providerConfluence)
	if err != nil {
		return nil, fmt.Errorf("listing sources: %w", err)
	}
	rows := make([]confluenceStatusRow, 0, len(srcs))
	for _, src := range srcs {
		if accountID > 0 && src.JiraAccountID != accountID {
			continue
		}
		c, err := database.ExtSourceCounts(src.ID)
		if err != nil {
			return nil, fmt.Errorf("counting source %d: %w", src.ID, err)
		}
		by := c.ByExtractStatus
		if by == nil {
			by = map[string]int{}
		}
		rows = append(rows, confluenceStatusRow{
			SourceID: src.ID, AccountID: src.JiraAccountID, Key: src.ContainerKey, Name: src.ContainerName,
			Status: src.Status, Error: src.Error, BackfillDone: src.BackfillDone, LastSyncedAt: src.LastSyncedAt,
			Pages: c.Pages, Blogposts: c.Blogposts, Attachments: c.Attachments, Comments: c.Comments, ByExtract: by,
		})
	}
	return rows, nil
}

func runConfluenceStatus(cmd *cobra.Command, _ []string) error {
	database, err := openDBFromConfig()
	if err != nil {
		return err
	}
	defer database.Close()
	rows, err := confluenceStatusRows(database, confluenceFlagAccount)
	if err != nil {
		return err
	}
	out := cmd.OutOrStdout()
	if confluenceStatusJSON {
		return json.NewEncoder(out).Encode(rows)
	}
	if len(rows) == 0 {
		fmt.Fprintln(out, "No Confluence spaces selected. See 'watchtower confluence spaces'.")
		return nil
	}
	w := tabwriter.NewWriter(out, 0, 4, 2, ' ', 0)
	fmt.Fprintln(w, "ACCOUNT\tKEY\tNAME\tSTATUS\tBACKFILL\tLAST SYNC\tPAGES\tBLOGS\tATTACH\tCOMMENTS")
	for _, r := range rows {
		fmt.Fprintf(w, "%d\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\n", r.AccountID, r.Key, r.Name, r.Status,
			backfillLabel(r.BackfillDone), dashIfEmpty(r.LastSyncedAt), r.Pages, r.Blogposts, r.Attachments, r.Comments)
	}
	if err := w.Flush(); err != nil {
		return err
	}
	printStatusDetails(cmd, rows)
	return nil
}

// printStatusDetails prints each source's error and attachment extraction
// breakdown under the table.
func printStatusDetails(cmd *cobra.Command, rows []confluenceStatusRow) {
	out := cmd.OutOrStdout()
	for _, r := range rows {
		if r.Error != "" {
			fmt.Fprintf(out, "%s: %s\n", r.Key, r.Error)
		}
		if len(r.ByExtract) == 0 {
			continue
		}
		keys := make([]string, 0, len(r.ByExtract))
		for k := range r.ByExtract {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		parts := make([]string, len(keys))
		for i, k := range keys {
			parts[i] = fmt.Sprintf("%s=%d", k, r.ByExtract[k])
		}
		fmt.Fprintf(out, "%s extraction: %s\n", r.Key, strings.Join(parts, " "))
	}
}

// backfillLabel keeps a budget-cut first sync from reading as finished.
func backfillLabel(done bool) string {
	if done {
		return "done"
	}
	return "in progress"
}

func dashIfEmpty(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

// checkConfluenceSyncAllowed refuses a manual sync while the daemon runs:
// its external-sync phase would race this run's cursor and page-token writes.
func checkConfluenceSyncAllowed(pid int, force bool) error {
	if pid == 0 || force {
		return nil
	}
	return fmt.Errorf("the sync daemon is running (PID %d) and syncs Confluence in the background; "+
		"quit Watchtower (or run 'watchtower sync stop') before syncing by hand, or pass --force", pid)
}

func runConfluenceSync(cmd *cobra.Command, _ []string) error {
	pid, err := kbDaemonPID()
	if err != nil {
		return fmt.Errorf("checking for a running daemon: %w", err)
	}
	if err := checkConfluenceSyncAllowed(pid, confluenceSyncForce); err != nil {
		return err
	}
	s, err := openConfluenceSession()
	if err != nil {
		return err
	}
	defer s.db.Close()
	srcs, err := s.db.ListExtSourcesForJiraAccount(providerConfluence, s.account.ID)
	if err != nil {
		return fmt.Errorf("listing selected spaces: %w", err)
	}
	if len(srcs) == 0 {
		fmt.Fprintln(cmd.OutOrStdout(), "No spaces selected for this account. See 'watchtower confluence select'.")
		return nil
	}
	engine := extsync.New(s.db, extSyncOptions(s.cfg, jiraCmdLogger(cmd), 0))
	engine.SetFetcher(s.account.ID, s.fetcher)
	return syncConfluenceSources(cmd, engine, srcs)
}

// extSyncOptions is the engine configuration shared by the daemon phase and
// `confluence sync` (budget 0 = unbounded): the scopes check and the
// attachment extractor, whose temp files live under
// <workspace>/tmp/extract (EXT-03), whose PDFs are parsed by the hidden
// extract-pdf-text helper process, and whose scans and images are
// recognized by the watchtower-ocr helper shipped next to the CLI (none
// found = OCR unavailable, rows stored ocr_unavailable and recognized once
// the helper appears).
func extSyncOptions(cfg *config.Config, logger *log.Logger, budget time.Duration) extsync.Options {
	wd := cfg.WorkspaceDir()
	return extsync.Options{
		Budget: budget,
		Logger: logger,
		Extractor: &extract.Extractor{
			TempDir:   filepath.Join(wd, "tmp", "extract"),
			PDFHelper: pdfHelperArgv(),
			OCR:       extract.NewHelperOCR(extract.ResolveHelperPath(), extract.OCRTimeout, extract.WithLogger(logger)),
		},
		ScopesOK: func(id int64) bool { return confluenceScopesOK(wd, id) },
	}
}

// syncConfluenceSources runs each source in turn and stops at the first
// failure — a consent/revoked error carries the re-login hint.
func syncConfluenceSources(cmd *cobra.Command, engine *extsync.Engine, srcs []db.ExtSource) error {
	out := cmd.OutOrStdout()
	for _, src := range srcs {
		st, err := engine.RunSource(cmd.Context(), src)
		if err != nil {
			return fmt.Errorf("%s: %w", src.ContainerKey, err)
		}
		fmt.Fprintf(out, "%s: %d fetched, %d unchanged, %d deleted, %d comments\n",
			src.ContainerKey, st.Fetched, st.Unchanged, st.Deleted, st.Comments)
	}
	return nil
}
