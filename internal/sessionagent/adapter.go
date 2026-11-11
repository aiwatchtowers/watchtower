// Package sessionagent is the Workbench session adapter, the session-side
// twin of the provider registry (spec 2026-11-05-llm-transport-independence
// §3.5): one Adapter per agent kind (Claude Code, Codex) owns that agent's
// hook install rows, payload quirks, transcript files, probe and pull
// signals and its capabilities. Consumers ask the adapter or its Caps, never
// the kind (LLMTRANSPORT-01).
package sessionagent

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	"watchtower/internal/agentkind"
	"watchtower/internal/claudesession"
	"watchtower/internal/db"
	"watchtower/internal/sessionfeed"
)

// Kind is an agent kind as terminal_sessions.kind stores it. The kind
// itself stays defined in internal/agentkind, which db, sessionfeed and
// terminal import below this package.
type Kind = agentkind.Kind

// Adapter is one Workbench agent kind.
type Adapter interface {
	// Kind is the agent kind the adapter serves.
	Kind() Kind
	// HookSpecs is the agent's workbench hook install rows, in their fixed
	// order (devpack writes them).
	HookSpecs() []HookSpec
	// Normalize decodes one hook input of the agent: empty input is io.EOF
	// (a manual run with stdin closed), input that is no JSON object an
	// error; what the agent's payload cannot mean the shared way is
	// dropped.
	Normalize(raw []byte) (Event, error)
	// Home is the agent's home directory among homes, under which its
	// transcripts live.
	Home(homes Homes) string
	// Transcript is the session's transcript files: the title reader and
	// the analytics importer's file.
	Transcript(row Row) Transcript
	// Conversations lists the session's conversations in ledger order whose
	// transcripts exist: the sessionfeed parser's input.
	Conversations(ctx context.Context, d *db.DB, rowID int64, folder, storedPath string, dirs sessionfeed.Dirs) ([]sessionfeed.Conversation, error)
	// SessionModel returns the most recent actual model from this session's main transcript.
	SessionModel(context.Context, *db.DB, *db.TerminalSession, Homes) (string, error)
	// Probe is the verdict on a session whose background count went stale:
	// one of the Probe* outcomes, with the raw status it was read from.
	Probe(row Row, procs claudesession.ProcInfo, now time.Time) (outcome, raw string, err error)
	// Watch is the agent's pull signals, ok false when the agent reports
	// every turn end through its hooks.
	Watch() (Puller, bool)
	// Caps is the agent's capability row.
	Caps() Caps
	// WireAgent is the agent's raw value on the phone's wire (the Kit's
	// TerminalSessionState agent).
	WireAgent() string
	// ComposerNewline is the agent's own composer key that inserts a line
	// break instead of submitting, nil when it has none beyond the ones
	// every agent knows (sessionhost.Profile.Newline).
	ComposerNewline() []byte
	// LaunchCommand is the login shell's command for one start of the
	// agent (sessionstart.Launch; the Desktop's TerminalLaunch.make).
	LaunchCommand(s Start) LaunchCommand
	// NotFoundReason is the phone's action reason for a start whose binary
	// is missing (the Kit's ActionReason raw value).
	NotFoundReason() string
	// NotFoundMessage is that start's line (the Desktop's
	// TerminalLaunch.exitMessage for exit 127).
	NotFoundMessage() string
	// StoresTranscriptPath reports that the row keeps the transcript path
	// the agent's SessionStart reported (agent_transcript_path), which
	// LoadSession reads.
	StoresTranscriptPath() bool
}

// Row is what an adapter reads of a terminal session.
type Row struct {
	// SessionID is the agent's own session id (claude_session_id).
	SessionID string
	// TranscriptPath is the path the agent's SessionStart hook reported
	// (agent_transcript_path); "" when none.
	TranscriptPath string
	// Home is the agent's home directory (Adapter.Home).
	Home string
}

// Homes resolves each agent's home directory, through the caller's test
// seams; only the adapter's own is called, so no agent reads another's.
type Homes struct {
	Claude func() string // ~/.claude, never $CLAUDE_CONFIG_DIR
	Codex  func() string // $CODEX_HOME when absolute, else ~/.codex
}

// Transcript is one session's transcript.
type Transcript interface {
	// OwnerText returns the owner's typed text, oldest first, joined by
	// newlines and capped at capChars runes; terminal.ErrNoTranscript when
	// the agent has not written one (yet).
	OwnerText(capChars int) (string, error)
	// ImportFile is the file the analytics importer reads, ok false when
	// there is none. Codex's follows AGENTLOG-04 (no symlinks below its
	// roots); Claude's is unused by the importer, which lists Claude
	// transcripts by folder (agentfiles.ListTranscripts).
	ImportFile() (path string, ok bool)
	// Open opens a file ImportFile returned, decompressed when compressed
	// is true (in memory only, AGENTLOG-05).
	Open(path string) (rc io.ReadCloser, compressed bool, err error)
}

// Puller reads an agent's pull signals from its transcript (spec §3.5).
type Puller interface {
	// Locate finds the session's transcript under home: the stored path
	// when it is still the session's, else a lookup by session id.
	Locate(home, sessionID, storedPath string) (string, bool)
	// LastTurn reads how the transcript's last turn ended.
	LastTurn(path string) (sessionfeed.CodexTurn, error)
	// Event is the pull event a turn reads as, ok false for a turn that
	// neither failed nor was interrupted.
	Event(sessionID string, turn sessionfeed.CodexTurn) (Event, bool)
	// HomeOf is the agent's home in a launch environment.
	HomeOf(env []string) string
}

// HookSpec is one hook handler an agent's workbench install owns. For a
// folder install the command line is <bin> Subcommand <workbench id> Flags;
// for launch hooks (Caps.LaunchHooks) it is <bin> Subcommand.
type HookSpec struct {
	Event string
	// Matcher goes on the group the entry is added in; "" for none.
	Matcher string
	// Subcommand follows the quoted watchtower binary.
	Subcommand string
	// LegacySubcommand is the suffix an install from before the Workbench
	// rename wrote (spec 2026-10-02 §5.4); "" when the hook is newer.
	LegacySubcommand string
	// Flags is appended after the workbench id of a folder install.
	Flags      string
	TimeoutSec int
	// Group is the index of the matcher group within Event for launch
	// hooks (codex's trust key); folder installs leave it 0.
	Group int
	// Async installs the entry as `"async": true`.
	Async bool
	// ReplacesMarkerPrompt: the entry supersedes our `type: prompt` hook of
	// the same event, recognised by its marker line.
	ReplacesMarkerPrompt bool
}

// Probe outcomes. busy and waiting leave the row alone; shell ends the
// subagent count and keeps the background shells (board #1712); idle,
// unknown and gone end every count.
const (
	ProbeBusy    = "busy"    // the agents still work
	ProbeWaiting = "waiting" // a prompt or a held message
	ProbeIdle    = "idle"
	ProbeShell   = "shell"   // only background shells run: the subagents are over, the shells are not
	ProbeUnknown = "unknown" // no status, or one this version does not know
	ProbeGone    = "gone"    // no registry entry, or its process is dead or its pid reused
)

// adapterList is every session adapter: one per agentkind registry entry
// (checkAdapters at start, TestSessionAgent_AdaptersMatchAgentKindRegistry).
var adapterList = []Adapter{claudeAdapter{}, codexAdapter{}}

// adapters is adapterList by kind; ordered is it in agentkind's order. A
// mismatch with agentkind's registry panics at start, naming what is
// missing, so it never surfaces later in a surprising place.
var adapters, ordered = func() (map[Kind]Adapter, []Adapter) {
	if err := checkAdapters(agentkind.All(), adapterList); err != nil {
		panic("sessionagent: " + err.Error())
	}
	byKind := make(map[Kind]Adapter, len(adapterList))
	for _, a := range adapterList {
		byKind[a.Kind()] = a
	}
	out := make([]Adapter, 0, len(adapterList))
	for _, k := range agentkind.All() {
		out = append(out, byKind[k])
	}
	return byKind, out
}()

// checkAdapters reports every registered kind without an adapter, every
// adapter of no registered kind and every kind served twice.
func checkAdapters(kinds []Kind, list []Adapter) error {
	registered := map[Kind]bool{}
	for _, k := range kinds {
		registered[k] = true
	}
	served := map[Kind]bool{}
	var problems []string
	for _, a := range list {
		k := a.Kind()
		switch {
		case served[k]:
			problems = append(problems, fmt.Sprintf("two session adapters for agent kind %q", k))
		case !registered[k]:
			problems = append(problems, fmt.Sprintf("session adapter %q serves no registered agent kind (add it to agentkind's registry)", k))
		}
		served[k] = true
	}
	for _, k := range kinds {
		if !served[k] {
			problems = append(problems, fmt.Sprintf("agent kind %q has no session adapter (add one to sessionagent's adapterList)", k))
		}
	}
	if len(problems) > 0 {
		return errors.New(strings.Join(problems, "; "))
	}
	return nil
}

// For is the adapter of kind k; false for a value that is no agent kind
// (`shell` included).
func For(k Kind) (Adapter, bool) {
	a, ok := adapters[k]
	return a, ok
}

// MustFor is the adapter of agent kind k, only for a caller that names a
// kind constant: a kind with no adapter is a programming error, which
// checkAdapters already refuses at start, and panics with its name. A kind
// read at runtime goes through For or Of and refuses with
// agentkind.Unsupported.
func MustFor(k Kind) Adapter {
	a, ok := For(k)
	if !ok {
		panic("sessionagent: no session adapter for agent kind " + string(k))
	}
	return a
}

// Of is the adapter of the stored kind s (terminal_sessions.kind).
func Of(s string) (Adapter, bool) { return For(Kind(s)) }

// PullerOf is the pull signal reader of the stored kind s
// (Adapter.Watch); false for an agent whose hooks report every turn end,
// or no agent.
func PullerOf(s string) (Puller, bool) {
	a, ok := Of(s)
	if !ok {
		return nil, false
	}
	return a.Watch()
}

// RolloutWatchKinds is every stored kind whose turn ends are pulled from
// its transcript (Caps.RolloutWatch): the rows a not-watched mark may land
// on (db.SetAgentWatchIssue).
func RolloutWatchKinds() []string {
	var kinds []string
	for _, a := range All() {
		if a.Caps().RolloutWatch() {
			kinds = append(kinds, string(a.Kind()))
		}
	}
	return kinds
}

// All is every adapter, in agentkind's registry order.
func All() []Adapter { return append([]Adapter(nil), ordered...) }
