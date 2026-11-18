package sources

import (
	"context"
	"errors"
	"fmt"
	"time"

	"watchtower/internal/agentkind"
	"watchtower/internal/chatengine"
	"watchtower/internal/db"
	"watchtower/internal/hub/actions/handlers"
	"watchtower/internal/hub/platform"
	"watchtower/internal/hub/slices"
	"watchtower/internal/hub/state"
	"watchtower/internal/policy"
)

// Runner is a background loop of a source: the runtime starts Run in its own
// goroutine and cancels it with the hub.
type Runner interface {
	Run(ctx context.Context) error
}

// Config is everything All needs to build the hub's sources. DB, Store,
// Watches, Sealer, Mode and AssetDir are required; the rest has the defaults
// its source documents (Now nil = time.Now, Live nil = nothing live, Away nil
// = always away, Active nil = always, Location nil = time.Local).
type Config struct {
	DB      *db.DB
	Store   *state.Store
	Watches handlers.ChatWatches
	Sealer  LocalSealer
	// Mode is the MobileSync scope: "allowed" or "workbench_only".
	Mode string
	// AssetDir stages the sealed segments.json files of meeting_transcript
	// (only used in "allowed" mode); it must be a dedicated directory, the first
	// call sweeps its *.asset files.
	AssetDir string

	Home         string
	DefaultAgent func() agentkind.Kind
	Live         func() Liveness
	Away         platform.Away
	// View (nil = none) is the Desktop's view: the sessions in its Undo
	// batch, which are neither published nor alerted, and the background
	// counts it shows over (TerminalSessionOptions.View).
	View         func() (hidden map[int64]bool, displayOver map[int64]ShownOver)
	Active       func() bool
	OnChatChange func()
	// OnReportChange and OnGitChange (nil = none) are the report runner's
	// and the git refresher's OnChange.
	OnReportChange func()
	OnGitChange    func()
	// ReportFetch and GitFetch (nil = the in-process reads) are test seams.
	ReportFetch ReportFetch
	GitFetch    GitFetch
	// RunnerGap (0 = the standard 5 s) is a test seam: the report runner's
	// and the git refresher's minimum gap between two passes.
	RunnerGap time.Duration
	Now       func() time.Time
	Location  *time.Location

	// ChatWatches (nil = a new registry, returned in Set.ChatWatches) is
	// what the chat handlers write and the chat sources publish; ChatEngine
	// (nil = chat off: the chat sources publish nothing) is the daemon's
	// chat engine they read; ChatModels (nil = RegistryChatModels) is the
	// composer's model list; ChatRouting (nil = no `routing` on chat_list)
	// reads the routing pill's catalog.
	ChatWatches *ChatWatches
	ChatEngine  ChatReader
	ChatModels  func() []ChatModel
	ChatRouting func(context.Context) *chatengine.RoutingCatalog
}

// Set is the hub's sources and what the runtime must start and tell.
type Set struct {
	// Sources are the slices to publish (hub.Options.Sources returns them);
	// the hub adds device_grant and heartbeat itself.
	Sources []slices.Source
	// Runners must each be started with Run in a goroutine of the hub's
	// lifetime: the session chat, the session report and the git refresher.
	// None in the set when the mode keeps no workbench source.
	Runners []Runner
	// Report, Git, Chat and Timeline are the pieces the runtime wires to the
	// handlers and to session-state changes (SessionStateChanged on Report
	// and Git, Observe on Timeline); nil when not built.
	Report   *SessionReportRunner
	Git      *GitRefresher
	Chat     *SessionChatSource
	Timeline *TimelineSource
	// Sessions is the terminal_session source: the handlers' SessionWindows
	// (what the phone may ask a chat or a report of).
	Sessions *TerminalSessionSource
	// Staged is the meeting_transcript source's staged-asset reset (nil
	// unless the mode publishes transcripts).
	Staged StagedAssets
	// ChatWatches is the AI chat's request registry the handlers write
	// (nil unless the mode publishes the chat).
	ChatWatches *ChatWatches
}

// StagedAssets forgets what a source staged after the runtime removed its
// files (an iCloud account change): its next Items stages anew.
type StagedAssets interface{ ForgetStaged() }

// WorkbenchOnlyKinds is what All publishes under MobileSync =
// workbench_only, in AllKinds order; the hub adds its own heartbeat and
// device_grant.
var WorkbenchOnlyKinds = []slices.Kind{
	"workbench", "workbench_target", "workbench_comment", "terminal_session", "owner_ask", "session_report",
	"session_timeline", slices.KindAskAlert, "permission_request", slices.KindSessionChat,
}

// ChangeTables maps each watchtower.db table a database-backed source reads
// to the kinds it feeds (the hub's data_version watch, spec §9). The
// runner-fed kinds (session_chat, session_report), the sidecar-backed
// recording_job and the request-fed chat_page and chat_search (built once
// per request) are not here: their own loops and nudges publish them. No
// chat_* table is here either (unified chat §6.4): every chat write goes
// through the daemon's engine, whose OnChange publishes chat_list and
// chat_feed; agent_actions stays, as a tool's proposal is written by the
// session's MCP process, not the engine. spec_reviews feeds every kind whose
// read hides the author loop's asks (askVisible) or reads the loop round
// (db.SpecLoopRoundSQL): a queue or a reveal writes only that table (#1945).
var ChangeTables = map[string][]slices.Kind{
	"projects":                 {"workbench"},
	"automations":              {"workbench"},
	"automation_runs":          {"workbench"},
	"targets":                  {"workbench", "workbench_target", "session_timeline", "calendar_event"},
	"target_status_history":    {"workbench_target", "session_timeline"},
	"workbench_board_columns":  {"workbench_target"},
	"terminal_session_targets": {"workbench_target", "session_timeline"},
	"project_comments":         {"workbench_target", "workbench_comment"},
	"terminal_sessions":        {"workbench", "workbench_target", "terminal_session", "session_timeline", "permission_request"},
	"owner_asks":               {"workbench", "workbench_target", "terminal_session", "session_timeline", "owner_ask", slices.KindAskAlert},
	"spec_reviews":             {"workbench", "workbench_target", "terminal_session", "session_timeline", "owner_ask", slices.KindAskAlert},
	"permission_requests":      {"permission_request", slices.KindAskAlert},
	"calendar_events":          {"calendar_event"},
	"meeting_prep_cache":       {"calendar_event"},
	"meeting_transcripts":      {"calendar_event", "meeting_transcript"},
	"meeting_recaps":           {"meeting_transcript"},
	"agent_actions":            {slices.KindChatList, slices.KindChatFeed},
}

// All assembles the sources of a MobileSync scope (MDM POLICY-03, spec §9):
//   - workbench_only: the workbench family (workbench, workbench_target,
//     workbench_comment), terminal sessions, the timeline, asks, permission
//     requests, alerts, the session chat and the report;
//   - allowed: those plus calendar events, meeting transcripts, recording
//     jobs and the AI chat (chat_list, chat_feed, chat_page, chat_search:
//     company data, so never under workbench_only);
//   - any other mode (off, unknown): nothing; unknown modes fail closed on
//     purpose, so a mistyped policy never widens what the phone sees.
//
// The hub's own device_grant and heartbeat are not in the set.
func All(c Config) (*Set, error) {
	switch {
	case c.DB == nil:
		return nil, errors.New("hub slices: sources need the database")
	case c.Store == nil:
		return nil, errors.New("hub slices: sources need the hub state")
	case c.Sealer == nil:
		return nil, errors.New("hub slices: sources need a sealer")
	}
	set := &Set{}
	switch c.Mode {
	case policy.MobileAllowed, policy.MobileWorkbenchOnly:
	default:
		return set, nil
	}
	now := c.Now
	if now == nil {
		now = time.Now
	}

	git := NewGitRefresher(c.DB, GitRefresherOptions{Active: c.Active, Now: now, OnChange: c.OnGitChange, Fetch: c.GitFetch, MinimumGap: c.RunnerGap})
	var report *SessionReportRunner
	sessions := TerminalSessions(c.DB, TerminalSessionOptions{
		Liveness: c.Live,
		ReportSummary: func(workbenchID, sessionID int64) (ReportSummary, bool) {
			if report == nil {
				return ReportSummary{}, false
			}
			return report.Summary(workbenchID, sessionID)
		},
		Now:  now,
		View: c.View,
	})
	report, err := SessionReport(c.DB, SessionReportOptions{Sessions: sessions, Store: c.Store, Sealer: c.Sealer, Active: c.Active, Now: now, OnChange: c.OnReportChange, Fetch: c.ReportFetch, MinimumGap: c.RunnerGap})
	if err != nil {
		return nil, err
	}
	timeline, err := SessionTimeline(c.DB, TimelineOptions{
		Sessions: sessions, Store: c.Store, Sealer: c.Sealer, Reports: report.Reports, Now: now,
	})
	if err != nil {
		return nil, err
	}
	chat := SessionChat(c.Watches, c.DB, SessionChatOptions{Liveness: c.Live, Active: c.Active, OnChange: c.OnChatChange, Now: now})

	set.Report, set.Git, set.Chat, set.Timeline, set.Sessions = report, git, chat, timeline, sessions
	set.Runners = []Runner{chat, report, git}
	set.Sources = []slices.Source{
		Workbench(c.DB, WorkbenchOptions{Home: c.Home, GitStatus: git.Status, Sessions: sessions, DefaultAgent: c.DefaultAgent, Now: now}),
		WorkbenchTargets(c.DB, now),
		WorkbenchComments(c.DB, now),
		sessions,
		timeline,
		OwnerAsk(c.DB, now),
		PermissionRequest(c.DB, c.Live, now),
		WorkAlert(WorkAlertConfig{DB: c.DB, Store: c.Store, Away: c.Away, Live: c.Live, View: c.View, Now: now}),
		chat,
		report.Source(),
	}

	if c.Mode == policy.MobileAllowed {
		cal := CalendarOptions{Now: now, Location: c.Location}
		if c.AssetDir == "" {
			return nil, errors.New("hub slices: meeting_transcript needs an asset directory")
		}
		transcripts, err := MeetingTranscript(c.DB, TranscriptOptions{CalendarOptions: cal, AssetDir: c.AssetDir, Store: c.Store})
		if err != nil {
			return nil, err
		}
		jobs, err := RecordingJob(c.Store, now)
		if err != nil {
			return nil, fmt.Errorf("hub slices: %w", err)
		}
		set.Sources = append(set.Sources, CalendarEvent(c.DB, cal), transcripts, jobs)
		if st, ok := transcripts.(StagedAssets); ok {
			set.Staged = st
		}
		watches := c.ChatWatches
		if watches == nil {
			watches = NewChatWatches()
		}
		feed := ChatFeedOptions{Watches: watches, Grant: c.Store.AnyChatPhone, Now: now}
		set.ChatWatches = watches
		set.Sources = append(set.Sources,
			ChatList(c.ChatEngine, ChatListOptions{Grant: c.Store.AnyChatPhone, Models: c.ChatModels, Routing: c.ChatRouting}),
			ChatFeed(c.ChatEngine, feed), ChatPage(c.ChatEngine, feed), ChatSearch(c.ChatEngine, feed))
	}
	return set, nil
}
