package sessionagent

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"watchtower/internal/agentkind"
	"watchtower/internal/claudesession"
	"watchtower/internal/db"
	"watchtower/internal/sessionfeed"
	"watchtower/internal/terminal"
)

// claudeAdapter is Claude Code: hooks installed into the folder's
// .claude/settings.local.json, transcripts under ~/.claude/projects, the
// session registry under ~/.claude/sessions.
type claudeAdapter struct{}

func (claudeAdapter) Kind() Kind { return agentkind.Claude }

// claudeStateHook is a session-state hook row: async, so a prompt or a tool
// call never waits for it.
func claudeStateHook(event string) HookSpec {
	return HookSpec{Event: event, Subcommand: "workbench session-state --workbench", TimeoutSec: 5, Async: true}
}

// claudeHookSpecs is every hook event the workbench install owns an entry
// in (devpack's ownedHookSpecs reads its rows by event and subcommand).
var claudeHookSpecs = []HookSpec{
	// The brief. The timeout bounds it so a stuck DB can never stall a
	// Claude Code session start (`workbench brief` itself always exits 0).
	{Event: "SessionStart", Subcommand: "workbench brief --workbench",
		LegacySubcommand: "project brief --project", TimeoutSec: 10},
	// The board drift check at the end of every agent turn (PROJ-07).
	// `workbench check --stop-hook` bounds its own git work well under this
	// timeout and always exits 0.
	{Event: "Stop", Subcommand: "workbench check --workbench",
		LegacySubcommand: "project check --project", Flags: " --stop-hook", TimeoutSec: 15},
	// The Stop command hook that sends a request the agent left as plain
	// text back to ask_owner unless the owner is there to answer it (spec
	// 2026-10-10-owner-asks-v2 Part 4, PROJ-13). It replaces the v1–v3 marker
	// prompt hook (Part 4.8). `workbench ask-guard --stop` bounds its model
	// call at 20 s, well under this timeout, and always exits 0.
	{Event: "Stop", Subcommand: "workbench ask-guard --workbench",
		Flags: " --stop", TimeoutSec: 30, ReplacesMarkerPrompt: true},
	// The PreToolUse hook denying AskUserQuestion, so a question to the
	// owner goes through ask_owner (§6.3). `workbench ask-guard` bounds its
	// own DB wait well under this timeout and always exits 0.
	{Event: "PreToolUse", Subcommand: "workbench ask-guard --workbench",
		Flags: " --pre-tool-use", TimeoutSec: 5, Matcher: "AskUserQuestion"},
	// The synchronous PermissionRequest hook that holds a permission dialog
	// open for an answer from the phone (#517). 86400 s holds past the 600 s
	// default (probe on Claude Code 2.1.302).
	{Event: "PermissionRequest", Subcommand: "workbench permission-wait --workbench",
		TimeoutSec: 86400, Matcher: "*"},
	// The session state the Desktop shows for an embedded terminal
	// (`workbench session-state` reads the event from its input, so one
	// command line serves every state hook).
	claudeStateHook("UserPromptSubmit"),
	claudeStateHook("Notification"),
	claudeStateHook("PostToolUse"),
	claudeStateHook("StopFailure"),
	claudeStateHook("SubagentStop"),
	claudeStateHook("SubagentStart"),
}

func (claudeAdapter) HookSpecs() []HookSpec { return append([]HookSpec(nil), claudeHookSpecs...) }

func (claudeAdapter) Normalize(raw []byte) (Event, error) { return decodeEvent(raw) }

func (claudeAdapter) Home(h Homes) string { return h.Claude() }

func (claudeAdapter) Transcript(row Row) Transcript { return claudeTranscript{row: row} }

func (claudeAdapter) Conversations(ctx context.Context, d *db.DB, rowID int64, folder, storedPath string, dirs sessionfeed.Dirs) ([]sessionfeed.Conversation, error) {
	return sessionfeed.SessionConversations(ctx, d, rowID, false, folder, storedPath, dirs)
}

// Probe is Claude Code's session registry verdict on the conversation, with
// the entry's raw status ("" when there is no live entry). row.Home is
// ~/.claude only, never $CLAUDE_CONFIG_DIR: the transcript readers' dual
// path rule.
func (claudeAdapter) Probe(row Row, procs claudesession.ProcInfo, _ time.Time) (outcome, raw string, err error) {
	if row.Home == "" {
		return "", "", errors.New("claude config dir unknown: no home dir")
	}
	entry, found, err := claudesession.FindSessionWith(row.Home, row.SessionID, procs)
	if err != nil {
		return "", "", fmt.Errorf("reading the claude session registry: %w", err)
	}
	if !found {
		return ProbeGone, "", nil
	}
	// A process table that cannot answer (a ps timeout or failed fork) is
	// ok: false, never gone: ending a live count cannot be undone.
	alive, err := claudesession.AliveWith(entry, procs)
	if err != nil {
		return "", "", fmt.Errorf("checking claude process %d: %w", entry.PID, err)
	}
	if !alive {
		return ProbeGone, "", nil
	}
	switch entry.Status {
	case ProbeBusy, ProbeWaiting, ProbeIdle, ProbeShell:
		return entry.Status, entry.Status, nil
	}
	return ProbeUnknown, entry.Status, nil
}

// Watch: Claude Code reports a failed turn through StopFailure and an
// interrupt through Stop, so nothing is pulled.
func (claudeAdapter) Watch() (Puller, bool) { return nil, false }

func (claudeAdapter) Caps() Caps {
	return Caps{
		StateEvents: []string{"SessionStart", "UserPromptSubmit", "Notification", "PermissionRequest",
			"PostToolUse", "StopFailure", "SubagentStart", "SubagentStop", "Stop"},
		FailureSignal: SignalHook, InterruptSignal: SignalHook,
		IdleSignal: true, PermissionWait: true, MidturnInput: true, PhoneInput: true, Elicitation: true,
		RegistryProbe: true, SubagentFeed: true, Analytics: true, BackgroundTasks: true,
		AppSessionID: true, AnalyticsContext: true,
	}
}

func (claudeAdapter) WireAgent() string { return "claude_code" }

func (claudeAdapter) ComposerNewline() []byte { return nil }

// LaunchCommand: `exec claude` with the app's id, `--resume` for a resume.
// A first prompt travels in FirstPromptEnv: /bin/sh reads it whatever the
// login shell, and `env -u` keeps it out of everything Claude Code runs.
// claude is found on the login shell's PATH, so it always runs.
func (claudeAdapter) LaunchCommand(s Start) LaunchCommand {
	switch {
	case s.Resume:
		return LaunchCommand{Command: "exec claude --resume " + s.SessionID, Runs: true}
	case s.Prompt == nil:
		return LaunchCommand{Command: "exec claude --session-id " + s.SessionID, Runs: true}
	}
	return LaunchCommand{
		Command: "exec /bin/sh -c 'exec env -u " + FirstPromptEnv + " claude --session-id " + s.SessionID +
			` "$` + FirstPromptEnv + `"'`,
		Prompt: new(positionalPrompt(*s.Prompt)),
		Runs:   true,
	}
}

func (claudeAdapter) NotFoundReason() string { return "claude_not_found" }

// NotFoundMessage: `exec claude` found no claude on the login shell's PATH.
func (claudeAdapter) NotFoundMessage() string {
	return "Claude Code was not found on your login-shell PATH. Install it, or add it to PATH, then Restart."
}

// StoresTranscriptPath: Claude readers find a transcript by session id.
func (claudeAdapter) StoresTranscriptPath() bool { return false }

// positionalPrompt gives a prompt starting with "-" a leading space, so
// claude never reads it as a flag (its usage documents no `--`).
func positionalPrompt(p string) string {
	if strings.HasPrefix(p, "-") {
		return " " + p
	}
	return p
}

// claudeTranscript is a Claude Code transcript (projects/*/<id>.jsonl).
type claudeTranscript struct{ row Row }

func (t claudeTranscript) OwnerText(capChars int) (string, error) {
	tr, err := terminal.OpenClaudeTranscript(t.row.Home, t.row.SessionID)
	if err != nil {
		return "", err
	}
	return tr.OwnerText(capChars)
}

func (t claudeTranscript) ImportFile() (string, bool) {
	path, err := terminal.FindTranscript(t.row.Home, t.row.SessionID)
	return path, err == nil
}

func (claudeTranscript) Open(path string) (io.ReadCloser, bool, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, false, err
	}
	return f, false, nil
}
