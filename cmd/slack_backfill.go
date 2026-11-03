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
		"history backfill's 2-day chunks. With digests on, it digests only the\n" +
		"channels and days no digest covered yet and rebuilds the daily rollup of\n" +
		"each day that got a new digest; nothing is digested twice. It moves no\n" +
		"sync watermark and runs no inbox\n" +
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

	return backfillSlackRange(cmd.Context(), cmd.OutOrStdout(), database, orch, pipe, floor, upper)
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
// first: fetch (BackfillSearch), then — when pipe is set — digests for what
// no digest covered yet (backfillSlackDigests). It stops at the first chunk
// it cannot finish and names the --to that resumes there; everything fetched
// stays saved.
func backfillSlackRange(ctx context.Context, out io.Writer, database *db.DB, orch *sync.Orchestrator, pipe *digest.Pipeline, floor, upper time.Time) error {
	floorTS := float64(floor.Unix())
	for reached := float64(upper.Unix()); ; {
		fromTS, toTS, ok := historybackfill.NextChunk(reached, floorTS)
		if !ok {
			break
		}
		from, to := time.Unix(int64(fromTS), 0), time.Unix(int64(toTS), 0)
		days := from.Format("2006-01-02") + ".." + to.Add(-time.Second).Format("2006-01-02")
		line, err := backfillSlackChunk(ctx, database, orch, pipe, from, to)
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

// backfillSlackChunk fetches one chunk and, with pipe set, digests what no
// digest covered before the fetch. line is the chunk's report.
func backfillSlackChunk(ctx context.Context, database *db.DB, orch *sync.Orchestrator, pipe *digest.Pipeline, from, to time.Time) (string, error) {
	var covered []map[string]bool
	if pipe != nil {
		var err error
		if covered, err = digestedChannelDays(database, orch.AccountID(), from, to); err != nil {
			return "", err
		}
	}
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
	digests, rolled, err := backfillSlackDigests(ctx, database, pipe, orch.AccountID(), from, to, covered)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%s, %d digests, daily rollups run for %d days", line, digests, rolled), nil
}

// backfillDays splits [from, to) into the UTC days the daily rollups use,
// each clipped to the chunk.
func backfillDays(from, to time.Time) [][2]time.Time {
	var out [][2]time.Time
	for d := from.UTC().Truncate(24 * time.Hour); d.Before(to); d = d.Add(24 * time.Hour) {
		out = append(out, [2]time.Time{maxTime(d, from), minTime(d.Add(24*time.Hour), to)})
	}
	return out
}

func maxTime(a, b time.Time) time.Time {
	if a.After(b) {
		return a
	}
	return b
}

func minTime(a, b time.Time) time.Time {
	if a.Before(b) {
		return a
	}
	return b
}

// digestedChannelDays is, per day of backfillDays, the channels a digest has
// already covered: the channel held messages that day before the fetch and
// a channel digest's period overlaps the day. A digest period alone is not
// enough: the first forward digest after a sync gap starts at the previous
// digest's end, so its period spans the gap days it never saw a message of.
func digestedChannelDays(database *db.DB, accountID int64, from, to time.Time) ([]map[string]bool, error) {
	days := backfillDays(from, to)
	out := make([]map[string]bool, len(days))
	for i, day := range days {
		dayFrom, dayTo := float64(day[0].Unix()), float64(day[1].Unix())
		candidates, err := database.ChannelsWithMessagesInRange(accountID, dayFrom, dayTo)
		if err != nil {
			return nil, err
		}
		out[i] = map[string]bool{}
		for _, c := range candidates {
			has, err := database.ChannelDigestOverlaps(c.ChannelID, dayFrom, dayTo)
			if err != nil {
				return nil, err
			}
			if has {
				out[i][c.ChannelID] = true
			}
		}
	}
	return out, nil
}

// backfillSlackDigests digests, day by day, the channels of the account that
// hold messages and were not covered before the fetch (covered, from
// digestedChannelDays), then rebuilds the daily rollup of each day that got
// a new digest. An already-digested channel day keeps its digest: its newly
// fetched messages are stored and nothing else.
func backfillSlackDigests(ctx context.Context, database *db.DB, pipe *digest.Pipeline, accountID int64, from, to time.Time, covered []map[string]bool) (digests, rolled int, err error) {
	for i, day := range backfillDays(from, to) {
		dayFrom, dayTo := float64(day[0].Unix()), float64(day[1].Unix())
		candidates, err := database.ChannelsWithMessagesInRange(accountID, dayFrom, dayTo)
		if err != nil {
			return digests, rolled, err
		}
		var channels []string
		for _, c := range candidates {
			if !covered[i][c.ChannelID] {
				channels = append(channels, c.ChannelID)
			}
		}
		res, _, err := pipe.RunBackfillWindowChannels(ctx, accountID, dayFrom, dayTo, channels)
		if err != nil {
			return digests, rolled, fmt.Errorf("messages saved, digests failed: %w", err)
		}
		if !res.Complete {
			return digests, rolled, errors.New("messages saved, digests not finished (another digest run holds the lock, " +
				"or the day needs more passes); run it again")
		}
		digests += res.Digests
		if res.Digests == 0 {
			continue
		}
		if err := pipe.RunBackfillRollupsForAccount(ctx, accountID, dayFrom, dayTo); err != nil {
			if errors.Is(err, digest.ErrDigestLocked) {
				return digests, rolled, errors.New("messages and digests saved, a daily rollup waits for another digest run")
			}
			return digests, rolled, fmt.Errorf("messages and digests saved, daily rollup failed: %w", err)
		}
		rolled++
	}
	return digests, rolled, nil
}
