package devpack

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	"watchtower/internal/gitdir"
)

// ErrMalformedSettings means .claude/settings.local.json exists but is not
// a JSON object whose hooks and hooks.<event> of every event we own an entry
// in (ownedHookSpecs) have the documented types.
// The file is then never written (PROJ-04): the owner fixes it, not us.
var ErrMalformedSettings = errors.New("malformed .claude/settings.local.json")

// ErrSymlinkOutsideFolder means a file the installer writes in the workbench
// folder is a symlink whose target lies outside that folder (a link to
// ~/.claude/settings.json would make our hooks global). Install and removal
// refuse it before any write (PROJ-04, owner decision 2026-10-14, ask #109):
// the owner replaces the link with a regular file or points it inside the
// folder. The Desktop matches "outside the workbench folder" in the CLI's
// message (WorkbenchesViewModel.createInstallNote); keep it in every such
// message (TestInstallErrorTextsTheDesktopMatches).
var ErrSymlinkOutsideFolder = errors.New("symlink leads outside the workbench folder")

// What an OutsideFolderError left in place outside the folder.
const (
	leftoverHooks = "hooks"
	leftoverSkill = "skill"
)

// OutsideFolderError is an ErrSymlinkOutsideFolder refusal, naming the link
// in the folder and Outside, the path outside it the write or removal would
// have reached — where, on a removal, Watchtower's hooks or skill stay for
// the owner to remove by hand (Hint).
type OutsideFolderError struct {
	Link, Outside string
	leftover      string // leftoverHooks or leftoverSkill
	msg           string
}

func (e *OutsideFolderError) Error() string { return e.msg }
func (e *OutsideFolderError) Unwrap() error { return ErrSymlinkOutsideFolder }

// Hint tells the owner what a refused removal left outside the folder and
// what to remove by hand (ask #118).
func (e *OutsideFolderError) Hint() string {
	if e.leftover == leftoverSkill {
		return fmt.Sprintf("Watchtower's skill stays in %s — remove it by hand", e.Outside)
	}
	return fmt.Sprintf("Watchtower's hooks stay in %s — remove the entries marked watchtower by hand", e.Outside)
}

// OutsideFolderHints is the Hint of every OutsideFolderError in err (a
// joined error included) whose outside path exists, each once, in order.
func OutsideFolderHints(err error) []string {
	var hints []string
	var walk func(error)
	walk = func(err error) {
		if err == nil {
			return
		}
		if joined, ok := err.(interface{ Unwrap() []error }); ok {
			for _, e := range joined.Unwrap() {
				walk(e)
			}
			return
		}
		var oe *OutsideFolderError
		if !errors.As(err, &oe) {
			return
		}
		if _, statErr := os.Lstat(oe.Outside); statErr == nil && !slices.Contains(hints, oe.Hint()) {
			hints = append(hints, oe.Hint())
		}
	}
	walk(err)
	return hints
}

// WithoutHinted is err minus every OutsideFolderError OutsideFolderHints
// names (a joined error is filtered part by part), or nil when nothing else
// failed: a caller that shows the hints reports only the rest.
func WithoutHinted(err error) error {
	if err == nil {
		return nil
	}
	if joined, ok := err.(interface{ Unwrap() []error }); ok {
		var rest []error
		for _, e := range joined.Unwrap() {
			if r := WithoutHinted(e); r != nil {
				rest = append(rest, r)
			}
		}
		return errors.Join(rest...)
	}
	if len(OutsideFolderHints(err)) > 0 {
		return nil
	}
	return err
}

// hookSpec is one Claude Code hook event the workbench install owns an entry
// in: the event name, the command suffix that recognises our entry for a
// workbench (after the watchtower binary), and the entry's timeout.
// legacySubcommand is the suffix an install from before the Workbench rename
// wrote (spec 2026-10-02 §5.4): it is still recognised as ours, so an install
// replaces that entry in place and a removal takes it out. An empty one
// means the hook is newer than the rename and has no old spelling. async
// installs the entry as `"async": true`: Claude Code runs it in the
// background and never waits for it. matcher, when set, goes on the group a
// new entry is added in. replacesMarkerPrompt: the entry supersedes our
// `type: prompt` hook of the same event, recognised by its marker line
// (isOurMarkerPrompt) — an install drops that prompt, a removal takes it out
// too, and only the command entry counts as installed.
type hookSpec struct {
	event                string
	subcommand           string // e.g. "workbench brief --workbench"; the workbench id follows
	legacySubcommand     string // e.g. "project brief --project"
	flags                string // appended after the id, e.g. " --stop-hook"
	timeoutSec           int
	async                bool
	matcher              string
	replacesMarkerPrompt bool
}

var (
	// sessionStartSpec: the brief. The timeout bounds it so a stuck DB can
	// never stall a Claude Code session start (`workbench brief` itself
	// always exits 0).
	sessionStartSpec = hookSpec{event: "SessionStart", subcommand: "workbench brief --workbench",
		legacySubcommand: "project brief --project", timeoutSec: 10}
	// stopSpec: the board drift check at the end of every agent turn
	// (PROJ-07). `workbench check --stop-hook` bounds its own git work well
	// under this timeout and always exits 0.
	stopSpec = hookSpec{event: "Stop", subcommand: "workbench check --workbench",
		legacySubcommand: "project check --project", flags: " --stop-hook", timeoutSec: 15}
	// coreStateHookSpecs: the session state the Desktop shows for an
	// embedded terminal (`workbench session-state` reads the event from its
	// input, so one command line serves every state hook). Async, so a
	// prompt or a tool call never waits for it; the Stop half lives in
	// stopSpec's command. These four gate the Stop's state write and the run
	// mark (HasCoreStateHooks), so a folder installed before SubagentStop
	// keeps its "waiting" until it is repaired.
	coreStateHookSpecs = []hookSpec{
		stateHookSpec("UserPromptSubmit"),
		stateHookSpec("Notification"),
		stateHookSpec("PostToolUse"),
		stateHookSpec("StopFailure"),
	}
	// stateHookSpecs: every state hook an install writes and a removal takes
	// out — the core four plus SubagentStop, which ends a subagent's or
	// teammate's turn and lowers the background count (board #411), and
	// SubagentStart, which opens one (board #543). The status needs all of
	// them (HasStateHooks).
	stateHookSpecs = append(coreStateHookSpecs, stateHookSpec("SubagentStop"), stateHookSpec("SubagentStart"))
	// askGuardSpec: the Stop command hook that sends a request the agent left
	// as plain text back to ask_owner unless the owner is there to answer it
	// (spec 2026-10-10-owner-asks-v2 Part 4, PROJ-13). It replaces the v1–v3
	// marker prompt hook (Part 4.8). `workbench ask-guard --stop` bounds its
	// model call at 20 s, well under this timeout, and always exits 0.
	askGuardSpec = hookSpec{event: "Stop", subcommand: "workbench ask-guard --workbench",
		flags: " --stop", timeoutSec: 30, replacesMarkerPrompt: true}
	// askToolBlockSpec: the PreToolUse hook denying AskUserQuestion, so a
	// question to the owner goes through ask_owner (§6.3). `workbench
	// ask-guard` bounds its own DB wait well under this timeout and always
	// exits 0.
	askToolBlockSpec = hookSpec{event: "PreToolUse", subcommand: "workbench ask-guard --workbench",
		flags: " --pre-tool-use", timeoutSec: 5, matcher: "AskUserQuestion"}
	// ownedHookSpecs is every event the workbench install owns an entry in.
	ownedHookSpecs = append([]hookSpec{sessionStartSpec, stopSpec, askGuardSpec, askToolBlockSpec}, stateHookSpecs...)
)

// askGuardMarkerTemplate opens the Stop prompt hook an install from before
// the command hook wrote (v1–v3; testdata/askguard_prompt_v{1,2,3}.md keep
// the texts as the upgrade's fixtures): what recognises that prompt as ours.
const askGuardMarkerTemplate = "[watchtower-workbench ask-guard <N>]"

// AskGuardClassifier is the Stop ask guard's v4 classifier text (spec
// 2026-10-10-owner-asks-v2 Part 4.4), the system prompt of the command
// hook's light-tier model call; testdata/askguard_classifier_v4.golden pins
// it. PROJ-13 pins the text, so it is deliberately not an owner-editable
// prompt in the prompt store.
//
//go:embed askguard_classifier.md
var AskGuardClassifier string

// askGuardMarker is the first line of workbenchID's old ask guard prompt:
// what recognises the prompt hook as ours, whatever else its text says.
func askGuardMarker(workbenchID int64) string {
	return strings.Replace(askGuardMarkerTemplate, "<N>", strconv.FormatInt(workbenchID, 10), 1)
}

func stateHookSpec(event string) hookSpec {
	return hookSpec{event: event, subcommand: "workbench session-state --workbench", timeoutSec: 5, async: true}
}

// command is the hook's command line for bin and workbenchID. Claude Code
// runs it through a shell, so a binary path with spaces (the CLI store sits
// under "Application Support") is single-quoted.
func (h hookSpec) command(bin string, workbenchID int64) string {
	return shellQuote(bin) + h.suffix(workbenchID)
}

func (h hookSpec) suffix(workbenchID int64) string {
	return " " + h.subcommand + " " + strconv.FormatInt(workbenchID, 10) + h.flags
}

// legacySuffix is "" for a hook with no pre-rename spelling, which no
// command matches.
func (h hookSpec) legacySuffix(workbenchID int64) string {
	if h.legacySubcommand == "" {
		return ""
	}
	return " " + h.legacySubcommand + " " + strconv.FormatInt(workbenchID, 10) + h.flags
}

func settingsLocalPath(dir string) string {
	return filepath.Join(dir, ".claude", "settings.local.json")
}

// InstallSessionStartHook adds or repairs one SessionStart command hook for
// workbenchID, running command, in dir's .claude/settings.local.json. An
// existing entry is recognised by looksLikeOurHook — a stale entry from a
// different watchtower binary path is updated in place (a bin change is an
// update, not a second entry: I2/PROJ-04), and an exact match is a no-op.
// Every other key, event and hook is preserved; the group omits a matcher so
// it fires on startup, resume, clear and compact alike.
func InstallSessionStartHook(dir, command string, workbenchID int64) (bool, error) {
	return installHook(dir, sessionStartSpec, command, workbenchID)
}

// InstallStopHook is InstallSessionStartHook for the Stop hook that runs the
// board drift check (PROJ-07), under the same PROJ-04 rules.
func InstallStopHook(dir, command string, workbenchID int64) (bool, error) {
	return installHook(dir, stopSpec, command, workbenchID)
}

// InstallStateHooks installs the session state hooks (stateHookSpecs) for
// workbenchID running bin, one entry per event, under the PROJ-04 rules;
// changed is true when any was added or repaired. A malformed file is
// reported once and none is attempted.
func InstallStateHooks(dir, bin string, workbenchID int64) (bool, error) {
	changed := false
	for _, spec := range stateHookSpecs {
		c, err := installHook(dir, spec, spec.command(bin, workbenchID), workbenchID)
		if err != nil {
			return changed, err
		}
		changed = changed || c
	}
	return changed, nil
}

// InstallAskGuardHooks installs the ask guard for workbenchID under the
// PROJ-04 rules: the Stop command hook, which replaces every Stop prompt
// hook carrying workbenchID's marker (v1–v3 or an owner's edit), and the
// PreToolUse command hook denying AskUserQuestion, both running bin. A
// malformed file is reported once and neither is attempted.
func InstallAskGuardHooks(dir, bin string, workbenchID int64) (bool, error) {
	guarded, err := installHook(dir, askGuardSpec, askGuardSpec.command(bin, workbenchID), workbenchID)
	if err != nil {
		return guarded, err
	}
	blocked, err := installHook(dir, askToolBlockSpec, askToolBlockSpec.command(bin, workbenchID), workbenchID)
	return guarded || blocked, err
}

// installHook sets spec's entry for workbenchID to command, replacing the
// marker prompt it supersedes (hookSpec.replacesMarkerPrompt): the prompt
// entry goes and its keys other than type, prompt and command (the owner's timeout
// among them) are carried onto our command entry. A command entry already
// there keeps the keys it holds — the in-place rule of upsertOurHook; a
// fresh one takes the prompt's over its defaults (PROJ-04).
func installHook(dir string, spec hookSpec, command string, workbenchID int64) (bool, error) {
	file := settingsLocalPath(dir)
	target, err := resolveSymlinkInside(file, dir)
	if err != nil {
		return false, err
	}
	settings, mode, _, err := readSettings(file)
	if err != nil {
		return false, err
	}
	hooks, groups, err := eventGroupsOf(settings, file, spec.event)
	if err != nil {
		return false, err
	}
	var carried map[string]any
	dropped := false
	if spec.replacesMarkerPrompt {
		isMarker := func(h any) bool { return isOurMarkerPrompt(h, workbenchID) }
		carried = carriedKeys(groups, isMarker)
		groups, dropped = withoutHooks(groups, isMarker)
	}
	held := anyHook(groups, func(h any) bool { return isOurHook(h, spec, workbenchID) })
	updated, changed := upsertOurHook(groups, spec, workbenchID, command)
	updated = withKeysOnOurHook(updated, spec, workbenchID, carried, !held)
	changed = changed || dropped
	if !changed {
		return false, nil
	}
	hooks[spec.event] = updated
	settings["hooks"] = hooks
	return true, writeSettings(target, settings, mode)
}

// RemoveSessionStartHook removes every hook object recognised as ours for
// workbenchID (looksLikeOurHook), regardless of which watchtower binary wrote
// it. A group left with no hooks is dropped, then an empty SessionStart, an
// empty hooks object, and — when nothing at all is left — the file itself
// (a symlinked file keeps its link, its target emptied to {}).
// Anything else in the file stays.
func RemoveSessionStartHook(dir string, workbenchID int64) (bool, error) {
	return removeHook(dir, sessionStartSpec, workbenchID)
}

// RemoveStopHook is RemoveSessionStartHook for the Stop hook (PROJ-02/04).
func RemoveStopHook(dir string, workbenchID int64) (bool, error) {
	return removeHook(dir, stopSpec, workbenchID)
}

// RemoveStateHooks removes every session state hook of workbenchID
// (PROJ-02/04); the owner's own entries under those events stay.
func RemoveStateHooks(dir string, workbenchID int64) (bool, error) {
	changed := false
	for _, spec := range stateHookSpecs {
		c, err := removeHook(dir, spec, workbenchID)
		if err != nil {
			return changed, err
		}
		changed = changed || c
	}
	return changed, nil
}

// RemoveAskGuardHooks removes both ask guard entries of workbenchID and any
// leftover marker prompt of it (PROJ-02/04); the owner's own Stop and
// PreToolUse entries stay.
func RemoveAskGuardHooks(dir string, workbenchID int64) (bool, error) {
	guarded, err := removeHook(dir, askGuardSpec, workbenchID)
	if err != nil {
		return guarded, err
	}
	blocked, err := removeHook(dir, askToolBlockSpec, workbenchID)
	return guarded || blocked, err
}

func removeHook(dir string, spec hookSpec, workbenchID int64) (bool, error) {
	file := settingsLocalPath(dir)
	settings, mode, existed, err := readSettings(file)
	if err != nil || !existed {
		return false, err
	}
	target, err := resolveSymlinkInside(file, dir)
	if err != nil {
		return false, err
	}
	hooks, groups, err := eventGroupsOf(settings, file, spec.event)
	if err != nil {
		return false, err
	}
	kept, changed := withoutHooks(groups, func(h any) bool {
		return isOurHook(h, spec, workbenchID) || spec.replacesMarkerPrompt && isOurMarkerPrompt(h, workbenchID)
	})
	if !changed {
		return false, nil
	}
	pruneEmpty(settings, hooks, spec.event, kept)
	// A symlinked file (dotfiles-managed) is never removed: that would drop
	// the link and leave our hook in its target. Its target gets {} instead.
	if len(settings) == 0 && target == file {
		if err := os.Remove(file); err != nil {
			return false, fmt.Errorf("removing %s: %w", file, err)
		}
		return true, nil
	}
	return true, writeSettings(target, settings, mode)
}

// HasSessionStartHook reports whether a hook recognised as ours for
// workbenchID (looksLikeOurHook) is installed in dir's
// .claude/settings.local.json.
func HasSessionStartHook(dir string, workbenchID int64) (bool, error) {
	return hasHook(dir, sessionStartSpec, workbenchID)
}

// HasStopHook is HasSessionStartHook for the Stop hook.
func HasStopHook(dir string, workbenchID int64) (bool, error) {
	return hasHook(dir, stopSpec, workbenchID)
}

// HasStateHooks reports whether every session state hook of workbenchID is
// installed; one missing is false.
func HasStateHooks(dir string, workbenchID int64) (bool, error) {
	return hasHooks(dir, stateHookSpecs, workbenchID)
}

// HasCoreStateHooks reports whether every core state hook of workbenchID
// (coreStateHookSpecs) is installed; one missing is false. It reads only the
// core events: a malformed entry in another event we own (an owner's
// hooks.SubagentStop) is refused by install and status but never costs the
// Stop its "waiting" (board #411).
func HasCoreStateHooks(dir string, workbenchID int64) (bool, error) {
	file := settingsLocalPath(dir)
	settings, _, existed, err := readSettings(file)
	if err != nil || !existed {
		return false, err
	}
	for _, spec := range coreStateHookSpecs {
		_, groups, err := rawEventGroups(settings, file, spec.event)
		if err != nil || !hasOurHook(groups, spec, workbenchID) {
			return false, err
		}
	}
	return true, nil
}

func hasHooks(dir string, specs []hookSpec, workbenchID int64) (bool, error) {
	for _, spec := range specs {
		ok, err := hasHook(dir, spec, workbenchID)
		if err != nil || !ok {
			return false, err
		}
	}
	return true, nil
}

// HasAskGuardHook reports whether workbenchID's Stop command hook is
// installed; a leftover marker prompt alone does not count, so the folder
// is offered Repair.
func HasAskGuardHook(dir string, workbenchID int64) (bool, error) {
	return hasHook(dir, askGuardSpec, workbenchID)
}

// HasAskToolBlockHook reports whether workbenchID's PreToolUse block of
// AskUserQuestion is installed.
func HasAskToolBlockHook(dir string, workbenchID int64) (bool, error) {
	return hasHook(dir, askToolBlockSpec, workbenchID)
}

func hasHook(dir string, spec hookSpec, workbenchID int64) (bool, error) {
	file := settingsLocalPath(dir)
	settings, _, existed, err := readSettings(file)
	if err != nil || !existed {
		return false, err
	}
	_, groups, err := eventGroupsOf(settings, file, spec.event)
	if err != nil {
		return false, err
	}
	return hasOurHook(groups, spec, workbenchID), nil
}

// readSettings decodes file as one JSON object. A missing or whitespace-only
// file is an empty object; numbers stay json.Number so the owner's literals
// ("1.50") are written back as they were.
func readSettings(file string) (map[string]any, os.FileMode, bool, error) {
	b, err := os.ReadFile(file)
	if errors.Is(err, os.ErrNotExist) {
		return map[string]any{}, 0o644, false, nil
	}
	if err != nil {
		return nil, 0, false, fmt.Errorf("reading %s: %w", file, err)
	}
	info, err := os.Stat(file)
	if err != nil {
		return nil, 0, false, fmt.Errorf("inspecting %s: %w", file, err)
	}
	if len(bytes.TrimSpace(b)) == 0 {
		return map[string]any{}, info.Mode().Perm(), true, nil
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, 0, false, fmt.Errorf("%w: %s: %v", ErrMalformedSettings, file, err)
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return nil, 0, false, fmt.Errorf("%w: %s: trailing data after the top-level object", ErrMalformedSettings, file)
	}
	obj, ok := v.(map[string]any)
	if !ok {
		return nil, 0, false, fmt.Errorf("%w: %s: the top level is not an object", ErrMalformedSettings, file)
	}
	return obj, info.Mode().Perm(), true, nil
}

// eventGroupsOf returns the hooks object (a fresh one when absent, not yet
// attached) and its groups for event, refusing a shape it does not know. The
// whole file counts as malformed when any event we own an entry in has the
// wrong shape, so a file one install step refuses is refused — and left
// byte-identical — by every step (PROJ-04).
func eventGroupsOf(settings map[string]any, file, event string) (map[string]any, []any, error) {
	for _, spec := range ownedHookSpecs {
		if _, _, err := rawEventGroups(settings, file, spec.event); err != nil {
			return nil, nil, err
		}
	}
	return rawEventGroups(settings, file, event)
}

func rawEventGroups(settings map[string]any, file, event string) (map[string]any, []any, error) {
	hooks := map[string]any{}
	if raw, ok := settings["hooks"]; ok {
		m, isObj := raw.(map[string]any)
		if !isObj {
			return nil, nil, fmt.Errorf("%w: %s: \"hooks\" is not an object", ErrMalformedSettings, file)
		}
		hooks = m
	}
	raw, ok := hooks[event]
	if !ok {
		return hooks, nil, nil
	}
	groups, isArr := raw.([]any)
	if !isArr {
		return nil, nil, fmt.Errorf("%w: %s: \"hooks.%s\" is not an array", ErrMalformedSettings, file, event)
	}
	return hooks, groups, nil
}

// groupHooks unpacks one hook group; ok is false for any group whose
// shape is not {"hooks": [...]} — such a group is never ours and is kept.
func groupHooks(g any) (map[string]any, []any, bool) {
	m, ok := g.(map[string]any)
	if !ok {
		return nil, nil, false
	}
	hs, ok := m["hooks"].([]any)
	return m, hs, ok
}

// looksLikeOurHook reports whether cmd is spec's hook command for
// workbenchID, recognised independent of which watchtower binary wrote it
// (I2/PROJ-04): a stale entry installed from the CLI-store path and a fresh
// one installed from PATH must both be recognised as ours, or an install
// from a second binary duplicates the hook and a delete orphans the first
// entry. After stripping an optional single-quoted binary token
// (hookSpec.command's only quoting style — see unquoteShellSingle), the
// command must end in exactly spec's suffix — e.g.
// " workbench brief --workbench <workbenchID>", or its pre-rename form
// " project brief --project <workbenchID>" (looksLikeLegacyHook) — and the
// binary's basename must be "watchtower".
func looksLikeOurHook(cmd string, spec hookSpec, workbenchID int64) bool {
	return endsInOurCommand(cmd, spec.suffix(workbenchID)) || looksLikeLegacyHook(cmd, spec, workbenchID)
}

// looksLikeLegacyHook is looksLikeOurHook for the pre-rename command only.
func looksLikeLegacyHook(cmd string, spec hookSpec, workbenchID int64) bool {
	return endsInOurCommand(cmd, spec.legacySuffix(workbenchID))
}

func endsInOurCommand(cmd, suffix string) bool {
	if suffix == "" {
		return false
	}
	bin, ok := strings.CutSuffix(cmd, suffix)
	if !ok || bin == "" {
		return false
	}
	return filepath.Base(unquoteShellSingle(bin)) == "watchtower"
}

// unquoteShellSingle reverses shellQuote's single-quoting ('a b' -> a b,
// '\” unescaped back to '). A token shellQuote left bare, because it held
// no unsafe character, is returned unchanged.
func unquoteShellSingle(s string) string {
	if len(s) < 2 || s[0] != '\'' || s[len(s)-1] != '\'' {
		return s
	}
	return strings.ReplaceAll(s[1:len(s)-1], `'\''`, "'")
}

func isOurHook(h any, spec hookSpec, workbenchID int64) bool {
	cmd, ok := hookCommand(h)
	return ok && looksLikeOurHook(cmd, spec, workbenchID)
}

// isOurMarkerPrompt reports whether h is the old Stop prompt hook of
// workbenchID: a prompt whose first line is exactly its marker, whatever the
// rest says (v1–v3, or an owner's edit — ours all the same, PROJ-04).
func isOurMarkerPrompt(h any, workbenchID int64) bool {
	text, ok := hookString(h, "prompt")
	return ok && opensWithLine(text, askGuardMarker(workbenchID))
}

// opensWithLine reports whether text's first line (a trailing "\r"
// ignored) is exactly line.
func opensWithLine(text, line string) bool {
	first, _, _ := strings.Cut(text, "\n")
	return trimCR(first) == line
}

func isLegacyHook(h any, spec hookSpec, workbenchID int64) bool {
	cmd, ok := hookCommand(h)
	return ok && looksLikeLegacyHook(cmd, spec, workbenchID)
}

// hookCommand is a hook object's command string.
func hookCommand(h any) (string, bool) {
	return hookString(h, "command")
}

// hookString is a hook object's string field key.
func hookString(h any, key string) (string, bool) {
	m, ok := h.(map[string]any)
	if !ok {
		return "", false
	}
	v, ok := m[key].(string)
	return v, ok
}

// hasOurHook counts our entry only in a group whose matcher is spec's: in
// another group it is not the hook we install (one under matcher "" would
// fire for every tool), and an install repairs it.
func hasOurHook(groups []any, spec hookSpec, workbenchID int64) bool {
	for _, g := range groups {
		m, hs, ok := groupHooks(g)
		if ok && inOurGroup(m, spec) && slices.ContainsFunc(hs, func(h any) bool { return isOurHook(h, spec, workbenchID) }) {
			return true
		}
	}
	return false
}

// inOurGroup reports whether group m is where spec's entry belongs: any
// group for a spec without a matcher, otherwise a group whose matcher is
// exactly spec's.
func inOurGroup(m map[string]any, spec hookSpec) bool {
	return spec.matcher == "" || m["matcher"] == spec.matcher
}

func anyHook(groups []any, match func(h any) bool) bool {
	for _, g := range groups {
		_, hs, ok := groupHooks(g)
		if ok && slices.ContainsFunc(hs, match) {
			return true
		}
	}
	return false
}

// HasLegacyHooks reports whether either of our hooks for workbenchID in dir's
// .claude/settings.local.json still runs the pre-rename command (`project
// brief --project N`, `project check --project N`): the folder was set up
// before the Workbench rename and not resynced since.
func HasLegacyHooks(dir string, workbenchID int64) (bool, error) {
	file := settingsLocalPath(dir)
	settings, _, existed, err := readSettings(file)
	if err != nil || !existed {
		return false, err
	}
	for _, spec := range []hookSpec{sessionStartSpec, stopSpec} {
		_, groups, err := eventGroupsOf(settings, file, spec.event)
		if err != nil {
			return false, err
		}
		if anyHook(groups, func(h any) bool { return isLegacyHook(h, spec, workbenchID) }) {
			return true, nil
		}
	}
	return false, nil
}

// legacyPermissionPrefix starts every Claude Code permission rule naming a
// tool of the pre-rename MCP server.
const legacyPermissionPrefix = "mcp__" + LegacyMCPServerName

// LegacyPermissionRules counts the `permissions.allow` rules in dir's
// .claude/settings.local.json — that file only; .claude/settings.json and the
// global settings are not read — that name the pre-rename MCP server
// (`mcp__watchtower-project` or `mcp__watchtower-project__<tool>`). They are
// the owner's: a resync only reports them (spec 2026-10-02 A6). A missing
// file counts 0; a file that cannot be read or parsed is an error.
func LegacyPermissionRules(dir string) (int, error) {
	settings, _, _, err := readSettings(settingsLocalPath(dir))
	if err != nil {
		return 0, err
	}
	perms, _ := settings["permissions"].(map[string]any)
	allow, _ := perms["allow"].([]any)
	n := 0
	for _, r := range allow {
		rule, _ := r.(string)
		if rule == legacyPermissionPrefix || strings.HasPrefix(rule, legacyPermissionPrefix+"__") {
			n++
		}
	}
	return n, nil
}

// upsertOurHook returns groups with our hook for workbenchID set to command.
// The first entry recognised by isOurHook is kept and, if it differs,
// updated in place with its other keys kept; any further one (there should
// never be more than one, but a hand-edited file could hold a leftover) is
// dropped as a duplicate. An entry of ours in a group with another matcher than spec's
// is dropped too, so it is re-added in a group of its own. Absent any
// match, a new group is appended, carrying spec's matcher. changed is false
// only when exactly one matching entry already held command.
func upsertOurHook(groups []any, spec hookSpec, workbenchID int64, command string) ([]any, bool) {
	found := false
	changed := false
	out := make([]any, 0, len(groups))
	for _, g := range groups {
		m, hs, ok := groupHooks(g)
		if !ok {
			out = append(out, g)
			continue
		}
		rest := make([]any, 0, len(hs))
		groupChanged := false
		for _, h := range hs {
			if !isOurHook(h, spec, workbenchID) {
				rest = append(rest, h)
				continue
			}
			if found || !inOurGroup(m, spec) {
				groupChanged = true // a duplicate stale entry, or one in the wrong group: drop it
				continue
			}
			found = true
			hm, _ := h.(map[string]any)
			if cur, _ := hm["command"].(string); cur == command {
				rest = append(rest, h)
				continue
			}
			groupChanged = true
			rest = append(rest, withOurCommand(hm, command))
		}
		if !groupChanged {
			out = append(out, g)
			continue
		}
		changed = true
		if len(rest) == 0 {
			continue
		}
		out = append(out, groupWithHooks(m, rest))
	}
	if !found {
		out = append(out, newOurHookGroup(spec, command))
		changed = true
	}
	return out, changed
}

// withOurCommand returns a copy of our entry hm with command set; its other
// keys are kept.
func withOurCommand(hm map[string]any, command string) map[string]any {
	cp := make(map[string]any, len(hm))
	for k, v := range hm {
		cp[k] = v
	}
	cp["command"] = command
	return cp
}

// carriedKeys collects the keys, other than the ones our entry owns (type,
// prompt, command), of every hook match picks (the first such hook wins a
// key), nil when none holds any.
func carriedKeys(groups []any, match func(h any) bool) map[string]any {
	var keys map[string]any
	for _, g := range groups {
		_, hs, ok := groupHooks(g)
		if !ok {
			continue
		}
		for _, h := range hs {
			hm, ok := h.(map[string]any)
			if !ok || !match(h) {
				continue
			}
			for k, v := range hm {
				if _, seen := keys[k]; seen || k == "type" || k == "prompt" || k == "command" {
					continue
				}
				if keys == nil {
					keys = map[string]any{}
				}
				keys[k] = v
			}
		}
	}
	return keys
}

// withKeysOnOurHook returns groups with keys set on our hook for workbenchID:
// with override every key, else only those it does not hold yet.
func withKeysOnOurHook(groups []any, spec hookSpec, workbenchID int64, keys map[string]any, override bool) []any {
	if len(keys) == 0 {
		return groups
	}
	out := slices.Clone(groups)
	for i, g := range out {
		m, hs, ok := groupHooks(g)
		j := slices.IndexFunc(hs, func(h any) bool { return isOurHook(h, spec, workbenchID) })
		if !ok || j < 0 {
			continue
		}
		hm, _ := hs[j].(map[string]any)
		cp := maps.Clone(hm)
		for k, v := range keys {
			if _, held := cp[k]; override || !held {
				cp[k] = v
			}
		}
		rest := slices.Clone(hs)
		rest[j] = cp
		out[i] = groupWithHooks(m, rest)
	}
	return out
}

// newOurHookGroup builds a fresh group holding only our hook running
// command, carrying spec's matcher when it has one.
func newOurHookGroup(spec hookSpec, command string) map[string]any {
	h := map[string]any{"type": "command", "command": command, "timeout": spec.timeoutSec}
	if spec.async {
		h["async"] = true
	}
	g := map[string]any{"hooks": []any{h}}
	if spec.matcher != "" {
		g["matcher"] = spec.matcher
	}
	return g
}

// groupWithHooks returns a copy of group m with its hooks replaced by rest;
// the group's other keys (its matcher among them) are kept.
func groupWithHooks(m map[string]any, rest []any) map[string]any {
	cp := make(map[string]any, len(m))
	for k, v := range m {
		cp[k] = v
	}
	cp["hooks"] = rest
	return cp
}

// withoutHooks filters the hook objects match picks (ours) out of every
// group. A group that still holds an owner hook survives (copied, so the
// input is untouched); a group that held only ours is dropped.
func withoutHooks(groups []any, match func(h any) bool) ([]any, bool) {
	kept := make([]any, 0, len(groups))
	changed := false
	for _, g := range groups {
		m, hs, ok := groupHooks(g)
		if !ok {
			kept = append(kept, g)
			continue
		}
		rest := slices.DeleteFunc(slices.Clone(hs), match)
		if len(rest) == len(hs) {
			kept = append(kept, g)
			continue
		}
		changed = true
		if len(rest) == 0 {
			continue
		}
		kept = append(kept, groupWithHooks(m, rest))
	}
	return kept, changed
}

// pruneEmpty writes kept back as hooks.<event>, dropping each level that
// became empty.
func pruneEmpty(settings, hooks map[string]any, event string, kept []any) {
	if len(kept) == 0 {
		delete(hooks, event)
	} else {
		hooks[event] = kept
	}
	if len(hooks) == 0 {
		delete(settings, "hooks")
	} else {
		settings["hooks"] = hooks
	}
}

// writeSettings replaces file atomically, keeping its mode. Keys come out
// sorted (encoding/json), HTML characters unescaped, two-space indented. file
// is already resolved past a symlink (resolveSymlinkInside), so a link
// (e.g. dotfiles-managed) keeps pointing at the target the write lands on.
func writeSettings(file string, settings map[string]any, mode os.FileMode) error {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(settings); err != nil {
		return fmt.Errorf("encoding %s: %w", file, err)
	}
	return atomicWriteFile(file, buf.Bytes(), mode)
}

// resolveSymlink returns the path an atomic write to file should target:
// file itself when it is not a symlink (or does not exist yet), or the
// symlink's resolved target when it is — so replacing the target's content
// never replaces the link itself. A dangling symlink is an error: the file
// is left untouched by the caller, since resolution fails before any write.
func resolveSymlink(file string) (string, error) {
	info, err := os.Lstat(file)
	if errors.Is(err, os.ErrNotExist) {
		return file, nil
	}
	if err != nil {
		return "", fmt.Errorf("inspecting %s: %w", file, err)
	}
	if info.Mode()&os.ModeSymlink == 0 {
		return file, nil
	}
	target, err := filepath.EvalSymlinks(file)
	if err != nil {
		return "", fmt.Errorf("%s is a symlink to a missing file: %w", file, err)
	}
	return target, nil
}

// resolveSymlinkInside is resolveSymlink for a file of the workbench folder
// root: a symlink whose resolved target lies outside root is refused with
// ErrSymlinkOutsideFolder, naming the link, its target and the fix first (the
// Desktop shows the start of the CLI's stderr), so the caller writes nothing
// anywhere. The same holds for a directory between root and file (.claude,
// .codex) that is a symlink leaving root. A link that stays inside root is
// followed as before.
func resolveSymlinkInside(file, root string) (string, error) {
	realRoot, err := dirInside(filepath.Dir(file), file, root, leftoverHooks)
	if err != nil {
		return "", err
	}
	target, err := resolveSymlink(file)
	if err != nil || target == file {
		return target, err
	}
	if outsideRoot(realRoot, target) {
		return "", &OutsideFolderError{Link: file, Outside: target, leftover: leftoverHooks,
			msg: fmt.Sprintf("%s links to %s, outside the workbench folder: replace the link with a regular file, or point it at a file inside the folder (%v)",
				file, target, ErrSymlinkOutsideFolder)}
	}
	return target, nil
}

// dirInside refuses with an OutsideFolderError (ErrSymlinkOutsideFolder)
// when the nearest existing directory at or above start, below root,
// resolves outside root — a write or removal of path (start or below it)
// would land there (a .claude, .claude/skills or skill directory linked
// elsewhere). leftover names what path holds. It returns root resolved.
func dirInside(start, path, root, leftover string) (string, error) {
	realRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return "", fmt.Errorf("resolving %s: %w", root, err)
	}
	// The nearest existing directory decides where a write lands; one not
	// yet created is made under it.
	for dir := start; dir != filepath.Clean(root) && dir != filepath.Dir(dir); dir = filepath.Dir(dir) {
		if _, err := os.Lstat(dir); errors.Is(err, os.ErrNotExist) {
			continue
		} else if err != nil {
			return "", fmt.Errorf("inspecting %s: %w", dir, err)
		}
		realDir, err := filepath.EvalSymlinks(dir)
		if err != nil {
			return "", fmt.Errorf("resolving %s: %w", dir, err)
		}
		if outsideRoot(realRoot, realDir) {
			rel, _ := filepath.Rel(dir, path)
			return "", &OutsideFolderError{Link: dir, Outside: filepath.Join(realDir, rel), leftover: leftover,
				msg: fmt.Sprintf("%s links to %s, outside the workbench folder: replace the link with a regular directory, or point it at one inside the folder (%v)",
					dir, realDir, ErrSymlinkOutsideFolder)}
		}
		break
	}
	return realRoot, nil
}

// outsideRoot reports whether the resolved path target lies outside the
// resolved directory realRoot.
func outsideRoot(realRoot, target string) bool {
	rel, err := filepath.Rel(realRoot, target)
	return err != nil || !filepath.IsLocal(rel)
}

// atomicWriteFile replaces path with data via a temp file in the same
// directory, fsynced then renamed into place, with mode applied before the
// rename. path is assumed already resolved past any symlink (resolveSymlink),
// so a symlinked settings or exclude file keeps pointing at its target
// instead of being replaced by a plain file.
func atomicWriteFile(path string, data []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("creating %s: %w", dir, err)
	}
	tmp, err := os.CreateTemp(dir, "."+filepath.Base(path)+".*")
	if err != nil {
		return fmt.Errorf("creating a temp file in %s: %w", dir, err)
	}
	defer func() { _ = os.Remove(tmp.Name()) }() // no-op once renamed
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("writing %s: %w", tmp.Name(), err)
	}
	if err := tmp.Chmod(mode); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("setting the mode of %s: %w", tmp.Name(), err)
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("syncing %s: %w", tmp.Name(), err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("closing %s: %w", tmp.Name(), err)
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		return fmt.Errorf("replacing %s: %w", path, err)
	}
	return nil
}

// filePerm returns path's current permission bits (following a symlink, so
// a symlinked file's own mode is read), or def when path does not exist yet.
func filePerm(path string, def os.FileMode) os.FileMode {
	info, err := os.Stat(path)
	if err != nil {
		return def
	}
	return info.Mode().Perm()
}

// --- git exclude ---

// Our exclude lines live between these markers so removal can never take a
// line the owner wrote themselves, even an identical one. The markers keep
// their pre-rename text (spec 2026-10-02 A5): changing them would orphan the
// block every connected folder already has.
const (
	excludeBegin = "# >>> watchtower-project: managed by `watchtower integrate --project`"
	excludeEnd   = "# <<< watchtower-project"
)

// EnsureGitExclude makes lines (relative to dir) ignored through the
// info/exclude git reads for dir's work tree. Outside a work tree it does
// nothing. A pattern already present — ours or the owner's — is skipped.
func EnsureGitExclude(dir string, lines []string) ([]string, error) {
	loc, ok, err := locateGitExclude(dir)
	if err != nil || !ok {
		return nil, err
	}
	doc, err := readExclude(loc.file)
	if err != nil {
		return nil, err
	}
	var added []string
	for _, l := range lines {
		p := loc.anchor(l)
		if doc.has(p) {
			continue
		}
		doc.block = append(doc.block, p)
		added = append(added, p)
	}
	if len(added) == 0 {
		return nil, nil
	}
	return added, writeExclude(loc.file, doc)
}

// RemoveGitExclude removes lines' anchored patterns from our marked block.
// Lines outside the block are the owner's and are never touched.
func RemoveGitExclude(dir string, lines []string) error {
	loc, ok, err := locateGitExclude(dir)
	if err != nil || !ok {
		return err
	}
	doc, err := readExclude(loc.file)
	if err != nil {
		return err
	}
	drop := make(map[string]bool, len(lines))
	for _, l := range lines {
		drop[loc.anchor(l)] = true
	}
	kept := slices.DeleteFunc(slices.Clone(doc.block), func(p string) bool { return drop[trimCR(p)] })
	if len(kept) == len(doc.block) {
		return nil
	}
	doc.block = kept
	return writeExclude(loc.file, doc)
}

// excludeLoc is the info/exclude file git reads for a work tree, plus the
// project folder's path relative to that work tree's top.
type excludeLoc struct {
	file, rel string
}

// anchor turns a dir-relative line into a pattern anchored at the work
// tree's top. Glob characters in the path are escaped, so a folder named
// "acme [beta]" matches literally; a trailing "/" (directory) is kept.
func (l excludeLoc) anchor(line string) string {
	p := path.Join("/", filepath.ToSlash(l.rel), line)
	if strings.HasSuffix(line, "/") {
		p += "/"
	}
	return escapeGitignore(p)
}

func escapeGitignore(p string) string {
	var b strings.Builder
	for _, r := range p {
		if strings.ContainsRune(`\*?[`, r) {
			b.WriteByte('\\')
		}
		b.WriteRune(r)
	}
	return b.String()
}

// locateGitExclude walks up from dir to the first .git (a directory, or a
// linked worktree's "gitdir:" file) and resolves the common dir's
// info/exclude. ok is false when dir is not inside a work tree.
func locateGitExclude(dir string) (excludeLoc, bool, error) {
	abs, err := filepath.Abs(dir)
	if err != nil {
		return excludeLoc{}, false, fmt.Errorf("resolving %s: %w", dir, err)
	}
	root, gitDir, found, err := gitdir.FindWorkTree(abs)
	if err != nil || !found {
		return excludeLoc{}, false, err
	}
	common, err := commonGitDir(gitDir)
	if err != nil {
		return excludeLoc{}, false, err
	}
	rel, err := filepath.Rel(root, abs)
	if err != nil {
		return excludeLoc{}, false, fmt.Errorf("relating %s to %s: %w", abs, root, err)
	}
	return excludeLoc{file: filepath.Join(common, "info", "exclude"), rel: rel}, true, nil
}

// commonGitDir follows a linked worktree's commondir file; a main work
// tree's git dir is its own common dir.
func commonGitDir(gitDir string) (string, error) {
	b, err := os.ReadFile(filepath.Join(gitDir, "commondir"))
	if errors.Is(err, os.ErrNotExist) {
		return gitDir, nil
	}
	if err != nil {
		return "", fmt.Errorf("reading %s/commondir: %w", gitDir, err)
	}
	common := strings.TrimSpace(string(b))
	if !filepath.IsAbs(common) {
		common = filepath.Join(gitDir, common)
	}
	return filepath.Clean(common), nil
}

// excludeDoc is an exclude file split into the owner's lines and ours.
type excludeDoc struct {
	outside, block []string
}

func (d excludeDoc) has(p string) bool {
	eq := func(l string) bool { return trimCR(l) == p }
	return slices.ContainsFunc(d.outside, eq) || slices.ContainsFunc(d.block, eq)
}

// trimCR drops a trailing '\r' so a CRLF-authored line compares equal to its
// LF-only counterpart. Lines are otherwise stored and rewritten verbatim —
// this only affects comparisons, never what gets written back.
func trimCR(s string) string {
	return strings.TrimSuffix(s, "\r")
}

func readExclude(file string) (excludeDoc, error) {
	b, err := os.ReadFile(file)
	if errors.Is(err, os.ErrNotExist) {
		return excludeDoc{}, nil
	}
	if err != nil {
		return excludeDoc{}, fmt.Errorf("reading %s: %w", file, err)
	}
	var d excludeDoc
	inBlock := false
	for _, l := range splitLines(string(b)) {
		switch {
		case trimCR(l) == excludeBegin:
			inBlock = true
		case trimCR(l) == excludeEnd:
			inBlock = false
		case inBlock:
			d.block = append(d.block, l)
		default:
			d.outside = append(d.outside, l)
		}
	}
	return d, nil
}

// writeExclude writes the owner's lines first, verbatim and in order, then
// our block — or no block at all once it is empty. Like writeSettings, a
// symlinked exclude file is written through to its target, atomically, and
// its existing permission bits (or 0o644 for a brand-new file) are kept. It
// is not held to the folder (resolveSymlinkInside): info/exclude lives in the
// git dir, often outside the folder anyway, and only our marked block of
// ignore lines is ever written there.
func writeExclude(file string, d excludeDoc) error {
	out := slices.Clone(d.outside)
	if len(d.block) > 0 {
		out = append(out, excludeBegin)
		out = append(out, d.block...)
		out = append(out, excludeEnd)
	}
	content := ""
	if len(out) > 0 {
		content = strings.Join(out, "\n") + "\n"
	}
	target, err := resolveSymlink(file)
	if err != nil {
		return err
	}
	return atomicWriteFile(target, []byte(content), filePerm(file, 0o644))
}

func splitLines(s string) []string {
	if s == "" {
		return nil
	}
	return strings.Split(strings.TrimSuffix(s, "\n"), "\n")
}
