package cmd

import (
	"database/sql"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/db"
	watchtowerslack "watchtower/internal/slack"
	"watchtower/internal/slackbackfill"
	"watchtower/internal/sync"
)

var slackBackfillCmd = &cobra.Command{
	Use:   "backfill",
	Short: "Fetch a past date range of one Slack account again, with its digests",
	Long: "Searches Slack for every message of the account between --from and --to\n" +
		"(local dates, both included) and saves them, newest days first, in the\n" +
		"history backfill's 2-day chunks. With digests on, it digests only the\n" +
		"messages no digest covered yet, never above a channel's newest digest\n" +
		"(those belong to the regular digests), and rebuilds the daily rollup of\n" +
		"each day that got a new digest; nothing is digested twice. It moves no\n" +
		"sync watermark and runs no inbox detection. Run it again after a rate\n" +
		"limit: fetched messages are kept.",
	Args: cobra.NoArgs,
	RunE: runSlackBackfill,
}

func init() {
	slackBackfillCmd.Flags().Int64("account", 0, "Slack account id (see `watchtower slack accounts`)")
	slackBackfillCmd.Flags().String("from", "", "first day to fetch, YYYY-MM-DD (local)")
	slackBackfillCmd.Flags().String("to", "", "last day to fetch, YYYY-MM-DD (local)")
	_ = slackBackfillCmd.MarkFlagRequired("account")
	_ = slackBackfillCmd.MarkFlagRequired("from")
	_ = slackBackfillCmd.MarkFlagRequired("to")
	slackCmd.AddCommand(slackBackfillCmd)
}

// runSlackBackfill wires one internal/slackbackfill run: the account checks,
// its orchestrator (with the issue-key detector, as wireSlackSyncers), the
// digest pipeline when digests are on, and the workspace's ledger, which is
// locked and frozen whether digests are on or off.
func runSlackBackfill(cmd *cobra.Command, _ []string) error {
	accountID, _ := cmd.Flags().GetInt64("account")
	fromArg, _ := cmd.Flags().GetString("from")
	toArg, _ := cmd.Flags().GetString("to")
	floor, upper, err := slackbackfill.ParseRange(fromArg, toArg, time.Now())
	if err != nil {
		return err
	}

	cfg, err := workspaceConfigFromFlags()
	if err != nil {
		return err
	}
	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	acct, err := database.GetSlackAccount(accountID)
	if errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("slack account %d not found (see `watchtower slack accounts`)", accountID)
	}
	if err != nil {
		return fmt.Errorf("loading slack account %d: %w", accountID, err)
	}
	switch {
	case acct.Status == "removed" || !acct.Enabled:
		return fmt.Errorf("slack account %d is removed or disabled; enable it first", accountID)
	case acct.Status == "revoked" || acct.Status == "purged":
		return fmt.Errorf("slack account %d needs a Re-login first (status %s)", accountID, acct.Status)
	}
	token, err := watchtowerslack.NewTokenStore(cfg.WorkspaceDir(), accountID).Load()
	if err != nil {
		return fmt.Errorf("loading the token of slack account %d: %w", accountID, err)
	}
	if token == nil {
		return fmt.Errorf("slack account %d has no token; Re-login first", accountID)
	}

	logger := log.New(io.Discard, "", 0)
	if flagVerbose {
		logger = log.New(os.Stderr, "", log.LstdFlags)
	}
	client := newSlackClientForToken(token.AccessToken)
	client.SetLogger(logger)
	orch := sync.NewOrchestrator(database, client, cfg, accountID)
	orch.SetLogger(logger)
	orch.SetTokenTeam(token.TeamID)
	det := newIssueKeyDetector(cfg, database, logger)
	if det != nil {
		orch.SetJiraKeyDetector(det)
	}
	run := &slackbackfill.Run{DB: database, Fetch: orch, Out: cmd.OutOrStdout()}
	// A purge deletes the account's rows in chunks; the run re-checks before
	// each chunk and digest day too (PURGE-01).
	if err := run.CheckPurge(); err != nil {
		return err
	}

	if cfg.Digest.Enabled {
		if err := validateModel(cfg); err != nil {
			return err
		}
		gen, savePool := cliPooledGenerator(cfg)
		defer savePool()
		run.Digest, _ = newLinkedDigestPipeline(cfg, database, gen, logger, det)
	}

	release, err := slackbackfill.LockLedger(cfg.WorkspaceDir())
	if err != nil {
		return err
	}
	defer release()
	if run.Ledger, err = slackbackfill.LoadLedger(cfg.WorkspaceDir()); err != nil {
		return err
	}
	return run.Range(cmd.Context(), floor, upper)
}
