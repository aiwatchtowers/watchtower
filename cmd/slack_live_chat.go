package cmd

import (
	"slices"
	"strings"
	"sync"
	"time"

	"watchtower/internal/chat"
	"watchtower/internal/codex"
	"watchtower/internal/db"
	"watchtower/internal/slacklive"
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

	mu     sync.Mutex
	wg     sync.WaitGroup
	closed bool
	// Test seams: beforeWrite runs in the status goroutine ahead of the
	// write, afterWrite once it is done.
	beforeWrite, afterWrite func(chat.Event)
	provider                string
	calls                   map[string]string // tool id → tool name
	probed                  bool
}

func newSlackLiveWatcher(database *db.DB, provider string) *slackLiveWatcher {
	return &slackLiveWatcher{database: database, provider: provider, now: time.Now, calls: map[string]string{}}
}

// isSlackConnectorTool: a read tool of the owner's Slack connector as the
// chat names its steps (displayToolName): Claude "claude_ai_Slack:<name>",
// Codex "codex_apps:slack.<name>" (an mcp_tool_call item of server
// codex_apps, tool "slack.<name>"), with <name> in slacklive.ReadTools. The
// local `list_slack_channels` never matches.
func isSlackConnectorTool(name string) bool {
	var tool string
	switch {
	case strings.HasPrefix(name, "claude_ai_Slack:"):
		tool = strings.TrimPrefix(name, "claude_ai_Slack:")
	case strings.HasPrefix(name, "codex_apps:slack."):
		tool = strings.TrimPrefix(name, "codex_apps:slack.")
	default:
		return false
	}
	return slices.Contains(slacklive.ReadTools, tool)
}

// isLocalSlackTool matches by bare tool name, so a Watchtower server under
// another key ("watchtower-app:list_messages") still counts.
func isLocalSlackTool(name string) bool {
	if j := strings.LastIndex(name, ":"); j >= 0 {
		name = name[j+1:]
	}
	return name == "list_messages" || name == "list_slack_channels"
}

// Observe is chat.EventWriter.Observe, called under the writer's mutex: it
// only bookkeeps, and hands the database work to a goroutine (Wait reaps).
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
			provider := w.provider
			w.run(func() { w.maybeProbe(provider) })
		}
	case chat.EventToolEnd:
		name := w.calls[e.ID]
		delete(w.calls, e.ID)
		if isSlackConnectorTool(name) {
			provider, at := w.provider, w.now() // the event's time, not the write's
			w.run(func() { w.writeStatus(provider, e, at) })
		}
	}
}

// run starts fn in a goroutine Wait will join.
// Called with mu held; after Wait it schedules nothing.
func (w *slackLiveWatcher) run(fn func()) {
	if w.closed {
		return
	}
	w.wg.Add(1)
	go func() {
		defer w.wg.Done()
		fn()
	}()
}

// Wait joins the watcher's goroutines (session end, tests).
// After it returns the watcher schedules nothing more (no database use once
// the session closes it).
func (w *slackLiveWatcher) Wait() {
	w.mu.Lock()
	w.closed = true
	w.mu.Unlock()
	w.wg.Wait()
}

func (w *slackLiveWatcher) maybeProbe(provider string) {
	if w.startProbe == nil || w.database == nil {
		return
	}
	rows, err := w.database.ListSlackLiveStatus()
	if err != nil {
		return
	}
	if r, ok := newestSlackLive(rows, provider); ok && w.now().Sub(r.CheckedAt) < slackLiveProbeAge {
		return
	}
	w.startProbe(provider)
}

// writeStatus records the outcome of one connector call on the provider's
// newest row's key (so a probe's connector id stays with it).
func (w *slackLiveWatcher) writeStatus(provider string, e chat.Event, at time.Time) {
	if w.beforeWrite != nil {
		w.beforeWrite(e)
	}
	if w.afterWrite != nil {
		defer w.afterWrite(e)
	}
	if w.database == nil || w.classify == nil || e.OK == nil {
		return
	}
	ok := *e.OK
	status, class := w.classify(provider, e.Summary, true, ok) // the tool ran, so the connector is present
	row := db.SlackLiveStatus{Provider: provider, Status: status, ErrorClass: class, CheckedAt: at}
	if rows, err := w.database.ListSlackLiveStatus(); err == nil {
		if r, found := newestSlackLive(rows, provider); found {
			row.TeamID = r.TeamID
		}
	}
	_ = w.database.UpsertSlackLiveStatus(row)
}
