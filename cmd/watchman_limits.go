package cmd

import (
	"errors"
	"fmt"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/watchman"
	"watchtower/internal/watchmanact"
)

// The owner's extra limits (spec 2026-11-16-watchman-design §5): Watchman
// never takes these actions either, beside the built-in table. The owner
// adds and removes his own; a built-in row has no id and cannot be removed.
// Settings → Watchman edits them through these verbs.

var (
	watchmanLimitsListFlagJSON bool
	watchmanLimitsAddFlagKind  string
	watchmanLimitsAddFlagPat   string
	watchmanLimitsRemoveFlagID int64
)

func init() {
	limits := &cobra.Command{
		Use:   "limits",
		Short: "The hard limits Watchman never acts on: the built-in table and the ones you added",
	}
	list := &cobra.Command{
		Use:   "list",
		Short: "List the built-in limits and yours",
		Args:  cobra.NoArgs,
		RunE:  runWatchmanLimitsList,
	}
	list.Flags().BoolVar(&watchmanLimitsListFlagJSON, "json", false, "print JSON")
	add := &cobra.Command{
		Use:   "add",
		Short: "Add a limit: a shell command (--kind command) or a tool (--kind tool) Watchman leaves to you",
		Long: "--kind command --pattern 'terraform apply' parks every shell command whose words start with the\n" +
			"pattern's words (after env, sudo and similar wrappers). --kind tool --pattern create_jira_issue parks\n" +
			"the tool of that name, or an MCP tool whose name ends with __create_jira_issue.",
		Args: cobra.NoArgs,
		RunE: runWatchmanLimitsAdd,
	}
	add.Flags().StringVar(&watchmanLimitsAddFlagKind, "kind", "", "command or tool")
	add.Flags().StringVar(&watchmanLimitsAddFlagPat, "pattern", "", "the command's leading words, or the tool name")
	remove := &cobra.Command{
		Use:   "remove",
		Short: "Remove a limit you added (a built-in one cannot be removed)",
		Args:  cobra.NoArgs,
		RunE:  runWatchmanLimitsRemove,
	}
	remove.Flags().Int64Var(&watchmanLimitsRemoveFlagID, "id", 0, "the limit's id (watchman limits list)")
	limits.AddCommand(list, add, remove)
	watchmanCmd.AddCommand(limits)
}

// watchmanLimitsJSON is `watchman limits list --json` (keys pinned by
// TestWatchmanLimits_JSONKeysPinned; Settings → Watchman reads it).
type watchmanLimitsJSON struct {
	OK      bool                 `json:"ok"`
	Builtin []watchman.HardLimit `json:"builtin"`
	Owner   []watchmanOwnerLimit `json:"owner"`
}

type watchmanOwnerLimit struct {
	ID      int64  `json:"id"`
	Kind    string `json:"kind"`
	Pattern string `json:"pattern"`
}

// openWatchmanLimitsDB opens the workspace database for the limits verbs.
func openWatchmanLimitsDB() (*config.Config, *db.DB, error) {
	cfg, err := workspaceConfigFromFlags()
	if err != nil {
		return nil, nil, err
	}
	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return nil, nil, fmt.Errorf("opening database: %w", err)
	}
	return cfg, database, nil
}

// refreshLimitsSidecar rewrites the arm sidecar after a change of the
// owner's limits, so the guard applies them when it cannot read the
// database; a failure is a warning (the daemon's upkeep rewrites it next
// cycle).
func refreshLimitsSidecar(cmd *cobra.Command, cfg *config.Config, database *db.DB) {
	if _, err := watchmanact.RefreshSidecar(cmd.Context(), cfg.WorkspaceDir(), database); err != nil {
		sidecarWarning(cmd, err.Error())
	}
}

func runWatchmanLimitsList(cmd *cobra.Command, _ []string) error {
	_, database, err := openWatchmanLimitsDB()
	if err != nil {
		return err
	}
	defer database.Close()
	rows, err := database.WatchmanExtraLimits()
	if err != nil {
		return err
	}
	out := watchmanLimitsJSON{OK: true, Builtin: watchman.BuiltinLimits(), Owner: []watchmanOwnerLimit{}}
	for _, r := range rows {
		out.Owner = append(out.Owner, watchmanOwnerLimit{ID: r.ID, Kind: r.Kind, Pattern: r.Pattern})
	}
	if watchmanLimitsListFlagJSON {
		return writeJSON(cmd.OutOrStdout(), out)
	}
	w := cmd.OutOrStdout()
	names := make([]string, 0, len(out.Builtin))
	for _, b := range out.Builtin {
		names = append(names, string(b))
	}
	fmt.Fprintf(w, "Built in (cannot be removed): %s\n", strings.Join(names, ", "))
	if len(out.Owner) == 0 {
		fmt.Fprintln(w, "Yours: none (add one with `watchtower watchman limits add`)")
		return nil
	}
	fmt.Fprintln(w, "Yours:")
	for _, o := range out.Owner {
		fmt.Fprintf(w, "  %d  %-7s  %s\n", o.ID, o.Kind, o.Pattern)
	}
	return nil
}

func runWatchmanLimitsAdd(cmd *cobra.Command, _ []string) error {
	if err := refuseUnderAgent("add a Watchman limit"); err != nil {
		return err
	}
	kind, pattern := strings.TrimSpace(watchmanLimitsAddFlagKind), strings.TrimSpace(watchmanLimitsAddFlagPat)
	if err := watchman.ValidateLimitPattern(kind, pattern); err != nil {
		return err
	}
	cfg, database, err := openWatchmanLimitsDB()
	if err != nil {
		return err
	}
	defer database.Close()
	id, err := database.AddWatchmanExtraLimit(kind, pattern)
	if err != nil {
		return err
	}
	refreshLimitsSidecar(cmd, cfg, database)
	fmt.Fprintf(cmd.OutOrStdout(), "Limit %d: Watchman leaves %s %q to you.\n", id, kind, pattern)
	return nil
}

func runWatchmanLimitsRemove(cmd *cobra.Command, _ []string) error {
	if err := refuseUnderAgent("remove a Watchman limit"); err != nil {
		return err
	}
	if watchmanLimitsRemoveFlagID <= 0 {
		return errors.New("name the limit with --id N (watchman limits list); a built-in limit cannot be removed")
	}
	cfg, database, err := openWatchmanLimitsDB()
	if err != nil {
		return err
	}
	defer database.Close()
	removed, err := database.DeleteWatchmanExtraLimit(watchmanLimitsRemoveFlagID)
	if err != nil {
		return err
	}
	if !removed {
		return fmt.Errorf("no limit of yours has id %d (a built-in limit has no id and cannot be removed)", watchmanLimitsRemoveFlagID)
	}
	refreshLimitsSidecar(cmd, cfg, database)
	fmt.Fprintf(cmd.OutOrStdout(), "Limit %d removed.\n", watchmanLimitsRemoveFlagID)
	return nil
}
