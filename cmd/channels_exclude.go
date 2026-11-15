package cmd

import (
	"errors"
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"

	"github.com/spf13/cobra"
)

var (
	channelsExcludeFlagID   string
	channelsExcludeFlagJSON bool
)

var channelsExcludeCmd = &cobra.Command{
	Use:   "exclude [name|id]",
	Short: "Stop syncing a channel",
	Long: "Stop syncing a channel: the sync stores no new messages of it, except those mentioning you. " +
		"Messages already stored stay, and the channel is muted for AI unless it already was.",
	Args: cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error { return runChannelsExclude(cmd, args, true) },
}

var channelsIncludeCmd = &cobra.Command{
	Use:   "include [name|id]",
	Short: "Sync a channel again",
	Long: "Sync a channel again after Stop syncing: the sync fetches the period it skipped, a few pages per run, " +
		"and lifts the AI mute if Stop syncing set it.",
	Args: cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error { return runChannelsExclude(cmd, args, false) },
}

func init() {
	for _, c := range []*cobra.Command{channelsExcludeCmd, channelsIncludeCmd} {
		channelsCmd.AddCommand(c)
		c.Flags().StringVar(&channelsExcludeFlagID, "id", "", "the channel's id as stored (instead of a name)")
		c.Flags().BoolVar(&channelsExcludeFlagJSON, "json", false, "output as JSON")
	}
}

// channelExcludeResult is the --json answer of `channels exclude|include`.
type channelExcludeResult struct {
	OK           bool   `json:"ok"`
	ChannelID    string `json:"channel_id"`
	SyncExcluded bool   `json:"sync_excluded"`
	Muted        bool   `json:"muted"`
}

func runChannelsExclude(cmd *cobra.Command, args []string, excluded bool) error {
	ref := channelsExcludeFlagID
	byID := ref != ""
	switch {
	case byID && len(args) > 0:
		return errors.New("give a channel name or --id, not both")
	case !byID && len(args) == 0:
		return errors.New("give a channel name or --id")
	case !byID:
		ref = args[0]
	}

	database, err := openDBFromConfig()
	if err != nil {
		return err
	}
	defer database.Close()
	// A Desktop click: wait out the daemon's write lock (ownerWriteBusyTimeout).
	if err := database.SetBusyTimeout(ownerWriteBusyTimeout); err != nil {
		return err
	}

	ch, err := resolveChannelRef(database, ref, byID)
	if err != nil {
		return err
	}
	if err := database.SetSyncExcluded(ch.ID, excluded, time.Now()); err != nil {
		return err
	}
	cs, err := database.GetChannelSettings(ch.ID)
	if err != nil {
		return err
	}
	res := channelExcludeResult{OK: true, ChannelID: ch.ID}
	if cs != nil {
		res.SyncExcluded, res.Muted = cs.SyncExcluded, cs.IsMutedForLLM
	}

	out := cmd.OutOrStdout()
	if channelsExcludeFlagJSON {
		return writeJSON(out, res)
	}
	muted := ""
	if res.Muted {
		muted = " (muted for AI)"
	}
	if excluded {
		fmt.Fprintf(out, "Stopped syncing #%s%s\n", ch.Name, muted)
	} else {
		fmt.Fprintf(out, "Syncing #%s again%s\n", ch.Name, muted)
	}
	return nil
}

// resolveChannelRef finds the channel ref names: the stored id when byID,
// else a stored id or a channel name ("#" optional) that only one channel
// has.
func resolveChannelRef(database *db.DB, ref string, byID bool) (*db.Channel, error) {
	ch, err := database.GetChannelByID(ref)
	if err != nil {
		return nil, err
	}
	if ch != nil {
		return ch, nil
	}
	if byID {
		return nil, fmt.Errorf("no channel with id %q", ref)
	}
	name := strings.TrimPrefix(ref, "#")
	all, err := database.GetChannels(db.ChannelFilter{})
	if err != nil {
		return nil, err
	}
	var found []db.Channel
	for _, c := range all {
		if c.Name == name {
			found = append(found, c)
		}
	}
	switch len(found) {
	case 0:
		return nil, fmt.Errorf("no channel named %q", name)
	case 1:
		return &found[0], nil
	default:
		return nil, fmt.Errorf("%d channels are named %q; pass --id", len(found), name)
	}
}
