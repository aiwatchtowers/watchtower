package digest

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"watchtower/internal/db"
	"watchtower/internal/fsutil"
)

// This is the scheduled Slack batch's input descriptor, not a job queue or a
// success cursor. Actual per-channel DB marks alone decide what is still due.
type pendingChannel struct {
	ID   string
	From float64
}
type digestWindow struct {
	To       float64
	Channels []pendingChannel
}

func (p *Pipeline) runScheduledChannelWindows(ctx context.Context, windows []channelWindow, to float64) (int, *Usage, error) {
	if !p.DeferredSchedule || !RoutingEnabled(p.generator) {
		return p.runChannelWindows(ctx, windows, to)
	}
	path := filepath.Join(p.cfg.WorkspaceDir(), "digest_pending_window.json")
	data, err := os.ReadFile(path)
	var pending digestWindow
	if err == nil {
		if err := json.Unmarshal(data, &pending); err != nil {
			return 0, nil, fmt.Errorf("reading pending digest window: %w", err)
		}
		if pending.To <= 0 || len(pending.Channels) == 0 {
			return 0, nil, fmt.Errorf("invalid pending digest window")
		}
		for _, c := range pending.Channels {
			if c.ID == "" || c.From <= 0 || c.From >= pending.To {
				return 0, nil, fmt.Errorf("invalid pending digest channel window")
			}
		}
		to = pending.To
		windows = nil
		// Re-read within the original upper bound: committed digests and considered
		// marks exclude saved channels, even after a restart or midnight rollover.
		candidates, err := p.db.ChannelsWithUndigestedMessages(earliestPending(pending), to)
		if err != nil {
			return 0, nil, err
		}
		floor, err := p.db.GetDigestFastForwardTS()
		if err != nil {
			return 0, nil, fmt.Errorf("reading fast-forward ts: %w", err)
		}
		due := make(map[string]db.ChannelDigestCandidate, len(candidates))
		for _, c := range candidates {
			due[c.ChannelID] = c
		}
		for _, c := range pending.Channels {
			if candidate, ok := due[c.ID]; ok {
				since := max(c.From, channelDigestSince(candidate, c.From, floor))
				if since < to {
					windows = append(windows, channelWindow{channelID: c.ID, since: since})
				}
			}
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return 0, nil, fmt.Errorf("reading pending digest window: %w", err)
	} else {
		if len(windows) == 0 {
			return 0, nil, nil
		}
		pending.To = to
		for _, w := range windows {
			pending.Channels = append(pending.Channels, pendingChannel{w.channelID, w.since})
		}
		data, err = json.Marshal(pending)
		if err == nil {
			err = fsutil.WriteFileAtomic(path, data, 0o600)
		}
		if err != nil {
			return 0, nil, fmt.Errorf("saving pending digest window: %w", err)
		}
	}
	n, usage, err := p.runChannelWindows(ctx, windows, to)
	if err == nil {
		if removeErr := os.Remove(path); removeErr != nil && !errors.Is(removeErr, os.ErrNotExist) {
			return n, usage, fmt.Errorf("clearing pending digest window: %w", removeErr)
		}
	}
	return n, usage, err
}
func earliestPending(w digestWindow) float64 {
	from := w.To
	for _, c := range w.Channels {
		if c.From < from {
			from = c.From
		}
	}
	return from
}
