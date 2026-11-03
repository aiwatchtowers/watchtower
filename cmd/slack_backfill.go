package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"strconv"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/historybackfill"
	"watchtower/internal/issuekey"
	"watchtower/internal/prompts"
	watchtowerslack "watchtower/internal/slack"
	"watchtower/internal/sync"
	"watchtower/internal/tracks"
)

// slackBackfillMaxDays bounds one `slack backfill` run: Slack's search
// recall gets unreliable further back (maxSearchCatchUpDays in
// internal/sync), and a longer range belongs to several runs.
const slackBackfillMaxDays = 31

var slackBackfillCmd = &cobra.Command{
	Use:   "backfill",
	Short: "Fetch a past date range of one Slack account again, with its digests",
	Long: "Searches Slack for every message of the account between --from and --to\n" +
		"(local dates, both included) and saves them, newest days first, in the\n" +
		"history backfill's 2-day chunks. With digests on, each chunk then gets its\n" +
		"channel digests and the daily rollups of its days, the way the history\n" +
		"backfill makes them. It moves no sync watermark and runs no inbox\n" +
		"detection. Run it again after a rate limit: fetched messages are kept.",
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

// slackBackfillRange parses the inclusive local day range into the chunk
// convention's [floor, upper) (internal/historybackfill/chunk.go).
func slackBackfillRange(fromArg, toArg string, now time.Time) (floor, upper time.Time, err error) {
	from, err := time.ParseInLocation("2006-01-02", fromArg, time.Local)
	if err != nil {
		return time.Time{}, time.Time{}, fmt.Errorf("--from must be YYYY-MM-DD: %w", err)
	}
	to, err := time.ParseInLocation("2006-01-02", toArg, time.Local)
	if err != nil {
		return time.Time{}, time.Time{}, fmt.Errorf("--to must be YYYY-MM-DD: %w", err)
	}
	if to.Before(from) {
		return time.Time{}, time.Time{}, errors.New("--to is before --from")
	}
	if to.After(now) {
		return time.Time{}, time.Time{}, errors.New("--to is in the future")
	}
	upper = to.AddDate(0, 0, 1)
	if from.AddDate(0, 0, slackBackfillMaxDays).Before(upper) {
		return time.Time{}, time.Time{}, fmt.Errorf("at most %d days at a time", slackBackfillMaxDays)
	}
	return from, upper, nil
}

func runSlackBackfill(cmd *cobra.Command, _ []string) error {
	accountID, _ := cmd.Flags().GetInt64("account")
	fromArg, _ := cmd.Flags().GetString("from")
	toArg, _ := cmd.Flags().GetString("to")
	floor, upper, err := slackBackfillRange(fromArg, toArg, time.Now())
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
	if err != nil {
		return fmt.Errorf("account %d not found: %w", accountID, err)
	}
	switch {
	case acct.Status == "removed" || !acct.Enabled:
		return fmt.Errorf("slack account %d is removed or disabled; enable it first", accountID)
	case acct.Status == "revoked" || acct.Status == "purged":
		return fmt.Errorf("slack account %d needs a Re-login first (status %s)", accountID, acct.Status)
	}
	// A purge deletes the account's rows in chunks; a backfill must not
	// refill them behind it (PURGE-01).
	if err := refuseLoginDuringPurge(database, "slack", accountID); err != nil {
		return err
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

	var pipe *digest.Pipeline
	if cfg.Digest.Enabled {
		if err := validateModel(cfg); err != nil {
			return err
		}
		gen, savePool := cliPooledGenerator(cfg)
		defer savePool()
		pipe = newBackfillDigestPipeline(cfg, database, gen, logger, det)
	}

	return backfillSlackRange(cmd.Context(), cmd.OutOrStdout(), orch, pipe, floor, upper)
}

// newBackfillDigestPipeline wires the digest pipeline the way the daemon does
// for its history backfill (prompt store, track linker, key detector) in
// runSync (cmd/sync.go), which keeps its own copy because it also hands the
// tracks pipeline to the daemon.
func newBackfillDigestPipeline(cfg *config.Config, database *db.DB, gen digest.Generator, logger *log.Logger, det *issuekey.KeyDetector) *digest.Pipeline {
	tracksPipe := tracks.New(database, cfg, gen, logger)
	tracksPipe.SetPromptStore(prompts.New(database, nil))
	pipe := digest.New(database, cfg, gen, logger)
	pipe.SetPromptStore(prompts.New(database, nil))
	pipe.TrackLinker = tracksPipe
	if det != nil {
		pipe.SetJiraKeyDetector(det)
		tracksPipe.SetJiraKeyDetector(det)
	}
	return pipe
}

// backfillSlackRange walks [floor, upper) in history-backfill chunks, newest
// first: fetch (BackfillSearch), then — when pipe is set — the chunk's
// digests and daily rollups. It stops at the first chunk it cannot finish
// and names the --to that resumes there; everything fetched stays saved.
func backfillSlackRange(ctx context.Context, out io.Writer, orch *sync.Orchestrator, pipe *digest.Pipeline, floor, upper time.Time) error {
	floorTS := float64(floor.Unix())
	for reached := float64(upper.Unix()); ; {
		fromTS, toTS, ok := historybackfill.NextChunk(reached, floorTS)
		if !ok {
			break
		}
		from, to := time.Unix(int64(fromTS), 0), time.Unix(int64(toTS), 0)
		days := from.Format("2006-01-02") + ".." + to.Add(-time.Second).Format("2006-01-02")
		line, err := backfillSlackChunk(ctx, orch, pipe, from, to)
		if err != nil {
			var mismatch *sync.TeamMismatchError
			if errors.As(err, &mismatch) {
				return errors.New(mismatch.OwnerMessage())
			}
			return fmt.Errorf("%s: %w; resume with --to %s", days, err, to.Add(-time.Second).Format("2006-01-02"))
		}
		fmt.Fprintf(out, "%s: %s\n", days, line)
		reached = fromTS
	}
	fmt.Fprintf(out, "Slack account %d: %s..%s done\n", orch.AccountID(),
		floor.Format("2006-01-02"), upper.AddDate(0, 0, -1).Format("2006-01-02"))
	return nil
}

// backfillSlackChunk fetches one chunk and, with pipe set, digests it and
// rolls up its days. line is the chunk's report.
func backfillSlackChunk(ctx context.Context, orch *sync.Orchestrator, pipe *digest.Pipeline, from, to time.Time) (string, error) {
	saved, err := orch.BackfillSearch(ctx, from, to)
	if errors.Is(err, sync.ErrSlackTeamMismatch) {
		return "", err
	}
	if errors.Is(err, sync.ErrBackfillIncomplete) {
		return "", fmt.Errorf("slack did not return every page (rate limit), %d messages saved; run it again later", saved)
	}
	if err != nil {
		return "", err
	}
	line := strconv.Itoa(saved) + " messages"
	if pipe == nil {
		return line, nil
	}
	fromTS, toTS := float64(from.Unix()), float64(to.Unix())
	res, _, err := pipe.RunBackfillWindow(ctx, orch.AccountID(), fromTS, toTS)
	if err != nil {
		return "", fmt.Errorf("messages saved, digests failed: %w", err)
	}
	if !res.Complete {
		return "", errors.New("messages saved, digests not finished (another digest run holds the lock, " +
			"or the chunk needs more passes); run it again")
	}
	if err := pipe.RunBackfillRollupsForAccount(ctx, orch.AccountID(), fromTS, toTS); err != nil {
		if errors.Is(err, digest.ErrDigestLocked) {
			return "", errors.New("messages and digests saved, daily rollups wait for another digest run; run it again")
		}
		return "", fmt.Errorf("messages and digests saved, daily rollups failed: %w", err)
	}
	return line + ", " + strconv.Itoa(res.Digests) + " digests, daily rollups done", nil
}
