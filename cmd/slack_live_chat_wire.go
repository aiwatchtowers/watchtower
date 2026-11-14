package cmd

import (
	"context"
	"os"
	"os/exec"

	"watchtower/internal/ai"
	"watchtower/internal/chat"
	"watchtower/internal/codex"
	"watchtower/internal/db"
	"watchtower/internal/slacklive"
)

// codexSlackOverrides is the read-only allow-list of the Slack app id for a
// Codex chat run (only slacklive.ReadTools visible, the owner's config.toml
// cannot widen it). An error means no apps for the session.
func codexSlackOverrides(connectorID string) ([]string, error) {
	return codex.ReadOnlyAppOverrides(codex.OwnerHome(), connectorID, slacklive.ReadTools)
}

// attachSlackLiveWatcher hooks the session's event stream: statuses on use
// and the one background probe. The probe child belongs to ctx, so it goes
// with the session.
func attachSlackLiveWatcher(ctx context.Context, out *chat.EventWriter, database *db.DB, provider string) (wait func()) {
	w := newSlackLiveWatcher(database, provider)
	w.classify = slacklive.Classify
	w.startProbe = func(p string) { startSlackLiveProbe(ctx, p) }
	out.Observe = w.Observe
	return w.Wait
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
