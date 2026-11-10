package sessionagent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"time"

	"watchtower/internal/agentkind"
	"watchtower/internal/claudesession"
	"watchtower/internal/db"
	"watchtower/internal/rollout"
	"watchtower/internal/sessionfeed"
	"watchtower/internal/terminal"
)

// codexAdapter is Codex CLI: hooks passed as launch flags (the same lines
// in every folder), rollouts under $CODEX_HOME/sessions, no StopFailure or
// Notification event, so a failed or interrupted turn is pulled from the
// rollout (spec 2026-11-05 §3.5, board #959).
type codexAdapter struct{}

func (codexAdapter) Kind() Kind { return agentkind.Codex }

// codexHookSpecs is spec 2026-10-12 §4.3's hook table, in its fixed order:
// the command suffix after the quoted watchtower binary. No suffix names a
// workbench: one trusted hash per event and group then covers every folder,
// and the hook finds its row through WATCHTOWER_TERMINAL_SESSION_ID. Event,
// Group and a handler's place in its group make codex's trust key, so they
// stay stable.
var codexHookSpecs = []HookSpec{
	{Event: "SessionStart", Subcommand: "workbench brief --agent codex", TimeoutSec: 10},
	{Event: "UserPromptSubmit", Subcommand: "workbench session-state --agent codex", TimeoutSec: 5},
	{Event: "PermissionRequest", Subcommand: "workbench session-state --agent codex", TimeoutSec: 5},
	{Event: "PostToolUse", Subcommand: "workbench session-state --agent codex", TimeoutSec: 5},
	{Event: "SubagentStart", Subcommand: "workbench session-state --agent codex", TimeoutSec: 5},
	{Event: "SubagentStop", Subcommand: "workbench session-state --agent codex", TimeoutSec: 5},
	// Interrupt (the owner's Esc) ends the turn with no Stop: board #959.
	{Event: "Interrupt", Subcommand: "workbench session-state --agent codex", TimeoutSec: 5},
	{Event: "PreToolUse", Matcher: "request_user_input", Subcommand: "workbench ask-guard --agent codex --pre-tool-use", TimeoutSec: 5},
	{Event: "Stop", Subcommand: "workbench check --agent codex --stop-hook", TimeoutSec: 15},
	{Event: "Stop", Subcommand: "workbench ask-guard --agent codex --stop", TimeoutSec: 30, Group: 1},
}

func (codexAdapter) HookSpecs() []HookSpec { return append([]HookSpec(nil), codexHookSpecs...) }

// Normalize drops what a Codex payload cannot mean the Claude Code way: the
// Claude-only fields, and a SubagentStart's transcript_path, which names the
// child's rollout, not the session's (capture note, answer 1).
func (codexAdapter) Normalize(raw []byte) (Event, error) {
	ev, err := decodeEvent(raw)
	if err != nil {
		return Event{}, err
	}
	ev.BackgroundTasks = BackgroundTasks{}
	ev.NotificationType = ""
	ev.Error = nil
	if ev.Event == "SubagentStart" {
		ev.TranscriptPath = ""
	}
	return ev, nil
}

func (codexAdapter) Home(h Homes) string { return h.Codex() }

func (codexAdapter) Transcript(row Row) Transcript { return codexTranscript{row: row} }

func (codexAdapter) Conversations(ctx context.Context, d *db.DB, rowID int64, folder, storedPath string, dirs sessionfeed.Dirs) ([]sessionfeed.Conversation, error) {
	return sessionfeed.SessionConversations(ctx, d, rowID, true, folder, storedPath, dirs)
}

// Probe is a codex row's verdict from its rollout's subagent lifecycle (S6;
// Codex keeps no session registry): busy while a subagent still runs, idle
// when every one the rollout knows has finished, and unknown — which ends
// the count, as before this read existed (spec 2026-10-12 §6.3) — when there
// is no rollout, it cannot be read, or a subagent's status is unknown.
func (codexAdapter) Probe(row Row, _ claudesession.ProcInfo, now time.Time) (outcome, raw string, err error) {
	path, ok := sessionfeed.LocateCodex(row.Home, row.SessionID, row.TranscriptPath)
	if !ok {
		return ProbeUnknown, "", nil
	}
	live, err := sessionfeed.LiveOf(sessionfeed.Conversation{Path: path, AgentSessionID: row.SessionID, Codex: true}, false, now)
	if err != nil || live.AgentsState != "known" {
		return ProbeUnknown, "", nil //nolint:nilerr // an unreadable rollout is an unknown verdict, which ends the count
	}
	outcome = ProbeIdle
	for _, a := range live.Agents {
		switch a.Ref.Status {
		case sessionfeed.StatusRunning:
			return ProbeBusy, "", nil
		case sessionfeed.StatusFinished:
		default:
			outcome = ProbeUnknown
		}
	}
	return outcome, "", nil
}

func (codexAdapter) Watch() (Puller, bool) { return codexPuller{}, true }

func (codexAdapter) Caps() Caps {
	return Caps{
		StateEvents: []string{"SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse",
			"SubagentStart", "SubagentStop", "Interrupt", "Stop"},
		FailureSignal: SignalPull, InterruptSignal: SignalPull,
		// G7's spikes on codex 0.159.2 (2026-11-05): a line pasted with its
		// Return mid-turn goes into the running turn, but an MCP elicitation
		// fires no hook, so no line is sent while it works; its
		// PermissionRequest hook hides the terminal prompt while it holds,
		// so it does not wait for the phone (owner decision); no idle event.
		MidturnInput: true, PhoneInput: true,
		RegistryProbe: true, CompressedTranscript: true, SubagentFeed: true, Analytics: true,
		LaunchHooks: true,
	}
}

func (codexAdapter) WireAgent() string { return "codex_cli" }

// codexLoginCommand is the login shell's command for Codex: /bin/sh reads
// the script from LaunchScriptEnv, so only /bin/sh ever parses values.
const codexLoginCommand = `exec /bin/sh -c 'eval "$` + LaunchScriptEnv + `"'`

// LaunchCommand runs codex as `workbench launch-args` resolved it
// (s.Binary); with none there is no binary and the start exits 127 ("Codex
// was not found"). The script is `<binary> <launch-args…> [resume '<id>']
// [-- "$PROMPT"]`, every value single-quoted, with path_prepend ahead of
// PATH; nothing but `--` and the prompt follows `resume <id>` (a `-c` after
// the subcommand would replace every root `-c`). The prompt is read after
// `--`, so one starting with "-" is no flag.
func (codexAdapter) LaunchCommand(s Start) LaunchCommand {
	var prompt *string
	if !s.Resume {
		prompt = s.Prompt
	}
	if s.Binary == nil {
		return LaunchCommand{Command: "exit 127", Prompt: prompt}
	}
	words := []string{"exec", "env", "-u", FirstPromptEnv, "-u", LaunchScriptEnv, shellQuote(s.Binary.Binary)}
	for _, a := range s.Binary.Args {
		words = append(words, shellQuote(a))
	}
	if s.Resume {
		words = append(words, "resume", shellQuote(s.SessionID))
	}
	if prompt != nil {
		words = append(words, "--", `"$`+FirstPromptEnv+`"`)
	}
	path := ""
	if s.Binary.PathPrepend != "" {
		path = "PATH=" + shellQuote(s.Binary.PathPrepend) + `:"$PATH" `
	}
	return LaunchCommand{
		Command: codexLoginCommand,
		Env:     []string{LaunchScriptEnv + "=" + path + strings.Join(words, " ")},
		Prompt:  prompt,
		Runs:    true,
	}
}

func (codexAdapter) NotFoundReason() string { return "codex_not_found" }

// NotFoundMessage: launch-args found no codex binary.
func (codexAdapter) NotFoundMessage() string {
	return "Codex was not found. Install it, or set codex_path in Watchtower's config, then try again."
}

// StoresTranscriptPath: the rollout path Codex's SessionStart reported, so
// its readers need not walk the sessions tree.
func (codexAdapter) StoresTranscriptPath() bool { return true }

// ComposerNewline: Ctrl+J (LF) inserts a line break; CR submits a bracketed
// paste, multi-line too, as one prompt.
func (codexAdapter) ComposerNewline() []byte { return []byte{0x0A} }

// codexPuller reads a codex rollout's last turn (G5's watch and the app's
// bridge probe).
type codexPuller struct{}

func (codexPuller) Locate(home, sessionID, storedPath string) (string, bool) {
	return sessionfeed.LocateCodex(home, sessionID, storedPath)
}

func (codexPuller) LastTurn(path string) (sessionfeed.CodexTurn, error) {
	return sessionfeed.CodexLastTurn(path)
}

// Event is a failed turn's StopFailure-equivalent event (its
// codex_error_info as the error) or an aborted turn's Interrupt.
func (codexPuller) Event(sessionID string, turn sessionfeed.CodexTurn) (Event, bool) {
	switch {
	case turn.Failed:
		e, _ := json.Marshal(turn.Error) // a string always marshals
		return Event{Event: "StopFailure", SessionID: sessionID, Error: e}, true
	case turn.Aborted:
		return Event{Event: "Interrupt", SessionID: sessionID}, true
	}
	return Event{}, false
}

// HomeOf is the launch's Codex home: CODEX_HOME from its environment when
// absolute (Codex's own rule), else ~/.codex.
func (codexPuller) HomeOf(env []string) string {
	for i := len(env) - 1; i >= 0; i-- {
		if v, ok := strings.CutPrefix(env[i], "CODEX_HOME="); ok {
			if filepath.IsAbs(v) {
				return v
			}
			break
		}
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".codex")
}

// codexTranscript is a codex session's rollout.
type codexTranscript struct{ row Row }

func (t codexTranscript) OwnerText(capChars int) (string, error) {
	tr, err := terminal.OpenCodexRollout(t.row.Home, t.row.SessionID, t.row.TranscriptPath)
	if err != nil {
		return "", err
	}
	return tr.OwnerText(capChars)
}

// ImportFile finds the session's rollout under AGENTLOG-04 as amended in
// ask #507: the stored path, else home/sessions/<y>/<m>/<d>/rollout-*-<id>.jsonl,
// else (codex archived it) home/archived_sessions/rollout-*-<id>.jsonl. The
// file must lie under one of those roots with nothing below the root a
// symlink: each folder and the file itself are checked with Lstat. Whether
// the rollout ran in the workbench is the importer's decision (its
// session_meta cwd).
func (t codexTranscript) ImportFile() (string, bool) {
	return locateCodexRollout(t.roots(), t.row)
}

// roots are home's sessions and archived_sessions folders, each as given and
// resolved, so a symlinked CODEX_HOME still matches.
func (t codexTranscript) roots() []string {
	var roots []string
	if t.row.Home != "" {
		for _, dir := range []string{"sessions", "archived_sessions"} {
			raw := filepath.Join(t.row.Home, dir)
			roots = append(roots, raw)
			if r, err := filepath.EvalSymlinks(raw); err == nil && r != raw {
				roots = append(roots, r)
			}
		}
	}
	return roots
}

// childMetaBytes bounds the read of a candidate child's first line.
const childMetaBytes = 64 << 10

// ChildImportFile globs rollout-*-<childID>.jsonl under the dated sessions
// folders and the flat archived_sessions folder, keeps the matches with no
// symlink below their root, and returns the first whose first line
// (sessionfeed.CodexChildMeta, at most 64 KB of text, a compressed file
// decoded in memory) is childID's session_meta naming one of parents. A
// match that cannot be opened or read is returned as err when no other
// match is the child (the importer counts it failed, not missing).
func (t codexTranscript) ChildImportFile(childID string, parents []string) (string, bool, error) {
	if !codexIDRe.MatchString(childID) {
		return "", false, nil
	}
	var firstErr error
	for _, root := range t.roots() {
		matches, _ := filepath.Glob(rolloutPattern(root, "-"+childID+".jsonl"))
		sort.Strings(matches)
		for _, m := range matches {
			if !noSymlinkBelow(root, m) {
				continue
			}
			ok, err := childMetaMatches(m, childID, parents)
			if ok {
				return m, true, nil
			}
			if err != nil && firstErr == nil {
				firstErr = err
			}
		}
	}
	return "", false, firstErr
}

func childMetaMatches(path, childID string, parents []string) (bool, error) {
	rc, _, err := rollout.Open(path)
	if errors.Is(err, fs.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	defer rc.Close()
	buf := make([]byte, childMetaBytes)
	n, err := io.ReadFull(rc, buf)
	if err != nil && !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) {
		return false, err
	}
	first, _, ok := bytes.Cut(buf[:n], []byte{'\n'})
	if !ok {
		return false, nil
	}
	id, parent, ok := sessionfeed.CodexChildMeta(first)
	return ok && id == childID && parent != "" && slices.Contains(parents, parent), nil
}

// Open opens the rollout (rollout.Open: a zstd file is decompressed in
// memory only; nothing is written beside it, AGENTLOG-05).
func (codexTranscript) Open(path string) (io.ReadCloser, bool, error) { return rollout.Open(path) }

// codexIDRe is a codex session id (a UUID), the only shape put into a glob.
var codexIDRe = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

func locateCodexRollout(roots []string, row Row) (string, bool) {
	if !codexIDRe.MatchString(row.SessionID) {
		return "", false
	}
	suffix := "-" + row.SessionID + ".jsonl"
	if p := filepath.Clean(row.TranscriptPath); filepath.IsAbs(p) && strings.HasPrefix(filepath.Base(p), "rollout-") && strings.HasSuffix(p, suffix) {
		for _, root := range roots {
			if noSymlinkBelow(root, p) {
				return p, true
			}
		}
	}
	for _, root := range roots {
		matches, _ := filepath.Glob(rolloutPattern(root, suffix))
		sort.Strings(matches)
		for _, m := range matches {
			if noSymlinkBelow(root, m) {
				return m, true
			}
		}
	}
	return "", false
}

// rolloutPattern globs the rollouts named …<suffix> under root: dated
// folders under sessions, flat under archived_sessions.
func rolloutPattern(root, suffix string) string {
	if filepath.Base(root) == "archived_sessions" {
		return filepath.Join(root, "rollout-*"+suffix)
	}
	return filepath.Join(root, "*", "*", "*", "rollout-*"+suffix)
}

// noSymlinkBelow reports whether every path element of p below root (the
// file included) is a real directory or regular file, not a symlink.
func noSymlinkBelow(root, p string) bool {
	rel, err := filepath.Rel(root, p)
	if err != nil || rel == "." || strings.HasPrefix(rel, "..") {
		return false
	}
	cur := root
	parts := strings.Split(rel, string(filepath.Separator))
	for i, part := range parts {
		cur = filepath.Join(cur, part)
		fi, err := os.Lstat(cur)
		if err != nil || fi.Mode()&os.ModeSymlink != 0 {
			return false
		}
		if last := i == len(parts)-1; last != fi.Mode().IsRegular() || (!last && !fi.IsDir()) {
			return false
		}
	}
	return true
}
