package cmd

import (
	"strings"
	"sync"
	"time"

	"watchtower/internal/chat"
	"watchtower/internal/codex"
	"watchtower/internal/db"
)

// Live Slack in the AI chat (#1764): which providers may promise the owner's
// Slack connector, the status the chat itself writes when it uses one, and
// the background probe the first local Slack tool starts.

const slackLiveProbeAge = 24 * time.Hour

// newestSlackLive is the newest slack_live_status row of provider
// (ListSlackLiveStatus is newest first).
func newestSlackLive(rows []db.SlackLiveStatus, provider string) (db.SlackLiveStatus, bool) {
	for _, r := range rows {
		if r.Provider == provider {
			return r, true
		}
	}
	return db.SlackLiveStatus{}, false
}

// claudeSlackLive: the claude.ai connector loads by itself, so a Claude chat
// with connectors on may use it unless the owner switched Slack off or the
// newest probe is a known failure; no row yet is allowed (the first call
// writes the status).
func claudeSlackLive(rows []db.SlackLiveStatus, connectorsOn, slackDisabled bool) bool {
	if !connectorsOn || slackDisabled {
		return false
	}
	r, ok := newestSlackLive(rows, "claude")
	return !ok || r.Status == "ok"
}

// codexSlackConnector is the Slack app id a Codex chat may use, "" = apps
// stay off: the owner is signed in with ChatGPT and the newest Codex probe
// is ok with a known connector id.
func codexSlackConnector(rows []db.SlackLiveStatus, codexHome string) string {
	if !codex.ChatGPTLogin(codexHome) {
		return ""
	}
	r, ok := newestSlackLive(rows, "codex")
	if !ok || r.Status != "ok" {
		return ""
	}
	return r.ConnectorID
}

// slackLiveWatcher observes the chat's events: it writes the provider's
// status when a Slack connector tool ends, and starts one background probe
// the first time the session touches a local Slack tool. Never blocks a turn.
type slackLiveWatcher struct {
	database *db.DB
	now      func() time.Time
	// classify is slacklive.Classify; startProbe launches the detached
	// `slack live probe` for a provider.
	classify   func(provider, text string, connected, readOK bool) (status, class string)
	startProbe func(provider string)

	mu       sync.Mutex
	provider string
	calls    map[string]string // tool id → tool name
	probed   bool
}

func newSlackLiveWatcher(database *db.DB, provider string) *slackLiveWatcher {
	return &slackLiveWatcher{database: database, provider: provider, now: time.Now, calls: map[string]string{}}
}

// isSlackConnectorTool: a tool of the owner's Slack connector — display name
// "<server>:slack_…" (claude) — as opposed to the local `list_slack_channels`.
func isSlackConnectorTool(name string) bool {
	tool := name
	if j := strings.LastIndex(name, ":"); j >= 0 {
		tool = name[j+1:]
	}
	if j := strings.LastIndex(tool, "__"); j >= 0 {
		tool = tool[j+2:]
	}
	return strings.HasPrefix(tool, "slack_") && strings.Contains(strings.ToLower(name), "slack")
}

func isLocalSlackTool(name string) bool {
	return name == "list_messages" || name == "list_slack_channels"
}

// Observe is chat.EventWriter.Observe.
func (w *slackLiveWatcher) Observe(e chat.Event) {
	w.mu.Lock()
	defer w.mu.Unlock()
	switch e.Type {
	case chat.EventSessionReady:
		if e.Provider != "" {
			w.provider = e.Provider
		}
	case chat.EventToolStart:
		w.calls[e.ID] = e.Name
		if isLocalSlackTool(e.Name) && !w.probed {
			w.probed = true
			w.maybeProbe()
		}
	case chat.EventToolEnd:
		name := w.calls[e.ID]
		delete(w.calls, e.ID)
		if isSlackConnectorTool(name) {
			w.writeStatus(e)
		}
	}
}

func (w *slackLiveWatcher) maybeProbe() {
	if w.startProbe == nil || w.database == nil {
		return
	}
	rows, err := w.database.ListSlackLiveStatus()
	if err != nil {
		return
	}
	if r, ok := newestSlackLive(rows, w.provider); ok && w.now().Sub(r.CheckedAt) < slackLiveProbeAge {
		return
	}
	w.startProbe(w.provider)
}

// writeStatus records the outcome of one connector call on the provider's
// newest row's key (so a probe's connector id stays with it).
func (w *slackLiveWatcher) writeStatus(e chat.Event) {
	if w.database == nil || w.classify == nil || e.OK == nil {
		return
	}
	ok := *e.OK
	status, class := w.classify(w.provider, e.Summary, true, ok) // the tool ran, so the connector is present
	row := db.SlackLiveStatus{Provider: w.provider, Status: status, ErrorClass: class, CheckedAt: w.now()}
	if rows, err := w.database.ListSlackLiveStatus(); err == nil {
		if r, found := newestSlackLive(rows, w.provider); found {
			row.TeamID = r.TeamID
		}
	}
	_ = w.database.UpsertSlackLiveStatus(row)
}
