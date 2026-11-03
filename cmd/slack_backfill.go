package cmd

import (
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
	if days := int(upper.Sub(from).Hours()/24 + 0.5); days > slackBackfillMaxDays {
		return time.Time{}, time.Time{}, fmt.Errorf("the range is %d days; at most %d at a time", days, slackBackfillMaxDays)
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
	if acct.Status == "removed" || !acct.Enabled {
		return fmt.Errorf("slack account %d is removed or disabled; enable it first", accountID)
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

	out := cmd.OutOrStdout()
	return backfillSlackRange(cmd, out, orch, pipe, accountID, floor, upper)
}

// newBackfillDigestPipeline wires the digest pipeline the way the daemon does
// for its history backfill (prompt store, track linker, key detector).
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
// and says how to resume; everything fetched so far stays saved.
func backfillSlackRange(cmd *cobra.Command, out io.Writer, orch *sync.Orchestrator, pipe *digest.Pipeline, accountID int64, floor, upper time.Time) error {
	ctx := cmd.Context()
	floorTS := float64(floor.Unix())
	total := 0
	for reached := float64(upper.Unix()); ; {
		fromTS, toTS, ok := historybackfill.NextChunk(reached, floorTS)
		if !ok {
			break
		}
		from, to := time.Unix(int64(fromTS), 0), time.Unix(int64(toTS), 0)
		days := from.Format("2006-01-02") + ".." + to.Add(-time.Second).Format("2006-01-02")
		saved, err := orch.BackfillSearch(ctx, from, to)
		switch {
		case errors.Is(err, sync.ErrSlackTeamMismatch):
			var mismatch *sync.TeamMismatchError
			if errors.As(err, &mismatch) {
				return errors.New(mismatch.OwnerMessage())
			}
			return err
		case errors.Is(err, sync.ErrBackfillIncomplete):
			return fmt.Errorf("%s: Slack did not return every page (rate limit); run the same command again later", days)
		case err != nil:
			return fmt.Errorf("%s: %w", days, err)
		}
		total += saved
		line := fmt.Sprintf("%s: %d messages", days, saved)
		if pipe != nil {
			res, _, err := pipe.RunBackfillWindow(ctx, accountID, fromTS, toTS)
			if err != nil {
				return fmt.Errorf("%s: digests: %w", days, err)
			}
			if !res.Complete {
				return fmt.Errorf("%s: messages saved, digests not finished (another digest run holds the lock, "+
					"or the chunk needs more passes); run the same command again", days)
			}
			if err := pipe.RunBackfillRollupsForAccount(ctx, accountID, fromTS, toTS); err != nil {
				if errors.Is(err, digest.ErrDigestLocked) {
					return fmt.Errorf("%s: messages and digests saved, daily rollups wait for another digest run; "+
						"run the same command again", days)
				}
				return fmt.Errorf("%s: daily rollups: %w", days, err)
			}
			line += ", " + strconv.Itoa(res.Digests) + " digests, daily rollups done"
		}
		fmt.Fprintln(out, line)
		reached = fromTS
	}
	fmt.Fprintf(out, "Slack account %d: %d messages fetched for %s..%s\n", accountID, total,
		floor.Format("2006-01-02"), upper.AddDate(0, 0, -1).Format("2006-01-02"))
	return nil
}
