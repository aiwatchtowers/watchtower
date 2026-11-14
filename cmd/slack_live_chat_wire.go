package cmd

// TODO(#1764 task 3): interim file. internal/slacklive (task 2) was not
// merged yet, so classify is a stub and the Codex allow-list is one tool.
// Replace with the slacklive-backed version after merging task 2:
// classify = slacklive.Classify, tools = slacklive.ReadTools.

import (
	"context"
	"os"
	"os/exec"

	"watchtower/internal/ai"
	"watchtower/internal/chat"
	"watchtower/internal/codex"
	"watchtower/internal/db"
)

// codexSlackOverrides is the read-only allow-list of the Slack app id for a
// Codex chat run: only []string{"slack_read_channel"} are visible.
func codexSlackOverrides(connectorID string) []string {
	return codex.SlackReadOnlyOverrides(connectorID, []string{"slack_read_channel"})
}

// attachSlackLiveWatcher hooks the session's event stream: statuses on use
// and the one background probe. The probe child belongs to ctx, so it goes
// with the session.
func attachSlackLiveWatcher(ctx context.Context, out *chat.EventWriter, database *db.DB, provider string) {
	w := newSlackLiveWatcher(database, provider)
	w.classify = func(_, _ string, _, readOK bool) (string, string) {
		if readOK {
			return "ok", ""
		}
		return "unavailable", "read_failed"
	}
	w.startProbe = func(p string) { startSlackLiveProbe(ctx, p) }
	out.Observe = w.Observe
}

// startSlackLiveProbe runs `slack live probe --if-older 24h` for provider
// in the background; a start failure is only a missed refresh.
func startSlackLiveProbe(ctx context.Context, provider string) {
	exe, err := os.Executable()
	if err != nil {
		return
	}
	c := exec.CommandContext(ctx, exe, "slack", "live", "probe", "--provider", provider, "--if-older", "24h")
	reap := ai.ConfigureChild(c)
	if err := c.Start(); err != nil {
		reap()
		return
	}
	go func() {
		_ = c.Wait()
		reap()
	}()
}
