package devpack

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
)

// ErrMalformedSettings means .claude/settings.local.json exists but is not
// a JSON object whose hooks and hooks.<event> of every event we own an entry
// in (ownedHookSpecs) have the documented types.
// The file is then never written (PROJ-04): the owner fixes it, not us.
var ErrMalformedSettings = errors.New("malformed .claude/settings.local.json")

// hookSpec is one Claude Code hook event the workbench install owns an entry
// in: the event name, the command suffix that recognises our entry for a
// workbench (after the watchtower binary), and the entry's timeout.
// legacySubcommand is the suffix an install from before the Workbench rename
// wrote (spec 2026-10-02 §5.4): it is still recognised as ours, so an install
// replaces that entry in place and a removal takes it out. An empty one
// means the hook is newer than the rename and has no old spelling. async
// installs the entry as `"async": true`: Claude Code runs it in the
// background and never waits for it. matcher, when set, goes on the group a
// new entry is added in. prompt makes the entry a `type: prompt` hook: its
// text is askGuardPrompt and it is recognised by that text's marker line,
// not by a command suffix (subcommand and flags are then unused).
type hookSpec struct {
	event            string
	subcommand       string // e.g. "workbench brief --workbench"; the workbench id follows
	legacySubcommand string // e.g. "project brief --project"
	flags            string // appended after the id, e.g. " --stop-hook"
	timeoutSec       int
	async            bool
	matcher          string
	prompt           bool
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
	// stateHookSpecs: the session state the Desktop shows for an embedded
	// terminal (`workbench session-state` reads the event from its input, so
	// one command line serves all four). Async, so a prompt or a tool call
	// never waits for it; the Stop half lives in stopSpec's command.
	stateHookSpecs = []hookSpec{
		stateHookSpec("UserPromptSubmit"),
		stateHookSpec("Notification"),
		stateHookSpec("PostToolUse"),
		stateHookSpec("StopFailure"),
	}
	// askGuardSpec: the Stop prompt hook that sends a request the agent left
	// as plain text back to ask_owner (spec 2026-10-03 §6.2, PROJ-13). Claude
	// Code's model judges it; the prompt passes a continued turn.
	askGuardSpec = hookSpec{event: "Stop", prompt: true, timeoutSec: 30}
	// askToolBlockSpec: the PreToolUse hook denying AskUserQuestion, so a
	// question to the owner goes through ask_owner (§6.3). `workbench
	// ask-guard` bounds its own DB wait well under this timeout and always
	// exits 0.
	askToolBlockSpec = hookSpec{event: "PreToolUse", subcommand: "workbench ask-guard --workbench",
		flags: " --pre-tool-use", timeoutSec: 5, matcher: "AskUserQuestion"}
	// ownedHookSpecs is every event the workbench install owns an entry in.
	ownedHookSpecs = append([]hookSpec{sessionStartSpec, stopSpec, askGuardSpec, askToolBlockSpec}, stateHookSpecs...)
)

// askGuardPromptText is the ask guard's prompt as the spec pins it, opened
// by askGuardMarkerTemplate.
//
//go:embed askguard_prompt.md
var askGuardPromptText string

const askGuardMarkerTemplate = "[watchtower-workbench ask-guard <N>]"

// askGuardMarker is the first line of workbenchID's ask guard prompt: what
// recognises the prompt hook as ours, whatever else its text says.
func askGuardMarker(workbenchID int64) string {
	return strings.Replace(askGuardMarkerTemplate, "<N>", strconv.FormatInt(workbenchID, 10), 1)
}

// askGuardPrompt is the Stop prompt hook's text for workbenchID: the
// embedded prompt with its marker's <N> substituted. Claude Code puts the
// hook input where it says $ARGUMENTS.
func askGuardPrompt(workbenchID int64) string {
	body, ok := strings.CutPrefix(strings.TrimSuffix(askGuardPromptText, "\n"), askGuardMarkerTemplate)
	if !ok {
		// An embed without its marker is a build-time defect.
		panic("devpack: askguard_prompt.md must open with " + askGuardMarkerTemplate)
	}
	return askGuardMarker(workbenchID) + body
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

// hookType is the entry's "type", which is also the key holding what
// installHook sets: "command", or "prompt" for a prompt hook's text.
func (h hookSpec) hookType() string {
	if h.prompt {
		return "prompt"
	}
	return "command"
}

func settingsLocalPath(dir string) string {
	return filepath.Join(dir, ".claude", "settings.local.json")
}

// InstallSessionStartHook adds or repairs one SessionStart command hook for
// projectID, running command, in dir's .claude/settings.local.json. An
// existing entry is recognised by looksLikeOurHook — a stale entry from a
// different watchtower binary path is updated in place (a bin change is an
// update, not a second entry: I2/PROJ-04), and an exact match is a no-op.
// Every other key, event and hook is preserved; the group omits a matcher so
// it fires on startup, resume, clear and compact alike.
func InstallSessionStartHook(dir, command string, projectID int64) (bool, error) {
	return installHook(dir, sessionStartSpec, command, projectID)
}

// InstallStopHook is InstallSessionStartHook for the Stop hook that runs the
// board drift check (PROJ-07), under the same PROJ-04 rules.
func InstallStopHook(dir, command string, projectID int64) (bool, error) {
	return installHook(dir, stopSpec, command, projectID)
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
// PROJ-04 rules: the Stop prompt hook (askGuardPrompt) and the PreToolUse
// command hook denying AskUserQuestion, running bin. An entry of ours whose
// text the owner edited is set back in place, its other keys kept. A
// malformed file is reported once and neither is attempted.
func InstallAskGuardHooks(dir, bin string, workbenchID int64) (bool, error) {
	guarded, err := installHook(dir, askGuardSpec, askGuardPrompt(workbenchID), workbenchID)
	if err != nil {
		return guarded, err
	}
	blocked, err := installHook(dir, askToolBlockSpec, askToolBlockSpec.command(bin, workbenchID), workbenchID)
	return guarded || blocked, err
}

// installHook sets spec's entry for projectID to value: the command, or a
// prompt hook's text (hookSpec.hookType).
func installHook(dir string, spec hookSpec, value string, projectID int64) (bool, error) {
	file := settingsLocalPath(dir)
	settings, mode, _, err := readSettings(file)
	if err != nil {
		return false, err
	}
	hooks, groups, err := eventGroupsOf(settings, file, spec.event)
	if err != nil {
		return false, err
	}
	updated, changed := upsertOurHook(groups, spec, projectID, value)
	if !changed {
		return false, nil
	}
	hooks[spec.event] = updated
	settings["hooks"] = hooks
	return true, writeSettings(file, settings, mode)
}

// RemoveSessionStartHook removes every hook object recognised as ours for
// projectID (looksLikeOurHook), regardless of which watchtower binary wrote
// it. A group left with no hooks is dropped, then an empty SessionStart, an
// empty hooks object, and — when nothing at all is left — the file itself
// (a symlinked file keeps its link, its target emptied to {}).
// Anything else in the file stays.
func RemoveSessionStartHook(dir string, projectID int64) (bool, error) {
	return removeHook(dir, sessionStartSpec, projectID)
}

// RemoveStopHook is RemoveSessionStartHook for the Stop hook (PROJ-02/04).
func RemoveStopHook(dir string, projectID int64) (bool, error) {
	return removeHook(dir, stopSpec, projectID)
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

// RemoveAskGuardHooks removes both ask guard entries of workbenchID
// (PROJ-02/04); the owner's own Stop and PreToolUse entries stay.
func RemoveAskGuardHooks(dir string, workbenchID int64) (bool, error) {
	guarded, err := removeHook(dir, askGuardSpec, workbenchID)
	if err != nil {
		return guarded, err
	}
	blocked, err := removeHook(dir, askToolBlockSpec, workbenchID)
	return guarded || blocked, err
}

func removeHook(dir string, spec hookSpec, projectID int64) (bool, error) {
	file := settingsLocalPath(dir)
	settings, mode, existed, err := readSettings(file)
	if err != nil || !existed {
		return false, err
	}
	hooks, groups, err := eventGroupsOf(settings, file, spec.event)
	if err != nil {
		return false, err
	}
	kept, changed := withoutOurHook(groups, spec, projectID)
	if !changed {
		return false, nil
	}
	pruneEmpty(settings, hooks, spec.event, kept)
	// A symlinked file (dotfiles-managed) is never removed: that would drop
	// the link and leave our hook in its target. Its target gets {} instead.
	target, err := resolveSymlink(file)
	if err != nil {
		return false, err
	}
	if len(settings) == 0 && target == file {
		if err := os.Remove(file); err != nil {
			return false, fmt.Errorf("removing %s: %w", file, err)
		}
		return true, nil
	}
	return true, writeSettings(file, settings, mode)
}

// HasSessionStartHook reports whether a hook recognised as ours for
// projectID (looksLikeOurHook) is installed in dir's
// .claude/settings.local.json.
func HasSessionStartHook(dir string, projectID int64) (bool, error) {
	return hasHook(dir, sessionStartSpec, projectID)
}

// HasStopHook is HasSessionStartHook for the Stop hook.
func HasStopHook(dir string, projectID int64) (bool, error) {
	return hasHook(dir, stopSpec, projectID)
}

// HasStateHooks reports whether every session state hook of workbenchID is
// installed; one missing is false.
func HasStateHooks(dir string, workbenchID int64) (bool, error) {
	for _, spec := range stateHookSpecs {
		ok, err := hasHook(dir, spec, workbenchID)
		if err != nil || !ok {
			return false, err
		}
	}
	return true, nil
}

// HasAskGuardHook reports whether workbenchID's Stop prompt hook is
// installed.
func HasAskGuardHook(dir string, workbenchID int64) (bool, error) {
	return hasHook(dir, askGuardSpec, workbenchID)
}

// HasAskToolBlockHook reports whether workbenchID's PreToolUse block of
// AskUserQuestion is installed.
func HasAskToolBlockHook(dir string, workbenchID int64) (bool, error) {
	return hasHook(dir, askToolBlockSpec, workbenchID)
}

func hasHook(dir string, spec hookSpec, projectID int64) (bool, error) {
	file := settingsLocalPath(dir)
	settings, _, existed, err := readSettings(file)
	if err != nil || !existed {
		return false, err
	}
	_, groups, err := eventGroupsOf(settings, file, spec.event)
	if err != nil {
		return false, err
	}
	return hasOurHook(groups, spec, projectID), nil
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
// projectID, recognised independent of which watchtower binary wrote it
// (I2/PROJ-04): a stale entry installed from the CLI-store path and a fresh
// one installed from PATH must both be recognised as ours, or an install
// from a second binary duplicates the hook and a delete orphans the first
// entry. After stripping an optional single-quoted binary token
// (hookSpec.command's only quoting style — see unquoteShellSingle), the
// command must end in exactly spec's suffix — e.g.
// " workbench brief --workbench <projectID>", or its pre-rename form
// " project brief --project <projectID>" (looksLikeLegacyHook) — and the
// binary's basename must be "watchtower".
func looksLikeOurHook(cmd string, spec hookSpec, projectID int64) bool {
	return endsInOurCommand(cmd, spec.suffix(projectID)) || looksLikeLegacyHook(cmd, spec, projectID)
}

// looksLikeLegacyHook is looksLikeOurHook for the pre-rename command only.
func looksLikeLegacyHook(cmd string, spec hookSpec, projectID int64) bool {
	return endsInOurCommand(cmd, spec.legacySuffix(projectID))
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

func isOurHook(h any, spec hookSpec, projectID int64) bool {
	if spec.prompt {
		text, ok := hookString(h, "prompt")
		return ok && opensWithLine(text, askGuardMarker(projectID))
	}
	cmd, ok := hookCommand(h)
	return ok && looksLikeOurHook(cmd, spec, projectID)
}

// opensWithLine reports whether text's first line (a trailing "\r"
// ignored) is exactly line.
func opensWithLine(text, line string) bool {
	first, _, _ := strings.Cut(text, "\n")
	return trimCR(first) == line
}

func isLegacyHook(h any, spec hookSpec, projectID int64) bool {
	cmd, ok := hookCommand(h)
	return ok && looksLikeLegacyHook(cmd, spec, projectID)
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
func hasOurHook(groups []any, spec hookSpec, projectID int64) bool {
	for _, g := range groups {
		m, hs, ok := groupHooks(g)
		if ok && inOurGroup(m, spec) && slices.ContainsFunc(hs, func(h any) bool { return isOurHook(h, spec, projectID) }) {
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

// upsertOurHook returns groups with our hook for projectID set to value
// (its command, or a prompt hook's type and text). The first entry
// recognised by isOurHook is kept and, if it differs, updated in place with
// its other keys kept; any further one (there should never be more than
// one, but a hand-edited file could hold a leftover) is dropped as a
// duplicate. An entry of ours in a group with another matcher than spec's
// is dropped too, so it is re-added in a group of its own. Absent any
// match, a new group is appended, carrying spec's matcher. changed is false
// only when exactly one matching entry already held value.
func upsertOurHook(groups []any, spec hookSpec, projectID int64, value string) ([]any, bool) {
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
			if !isOurHook(h, spec, projectID) {
				rest = append(rest, h)
				continue
			}
			if found || !inOurGroup(m, spec) {
				groupChanged = true // a duplicate stale entry, or one in the wrong group: drop it
				continue
			}
			found = true
			hm, _ := h.(map[string]any)
			if hasValue(hm, spec, value) {
				rest = append(rest, h)
				continue
			}
			groupChanged = true
			cp := make(map[string]any, len(hm))
			for k, v := range hm {
				cp[k] = v
			}
			cp[spec.hookType()] = value
			if spec.prompt {
				cp["type"] = spec.hookType()
			}
			rest = append(rest, cp)
		}
		if !groupChanged {
			out = append(out, g)
			continue
		}
		changed = true
		if len(rest) == 0 {
			continue
		}
		cp := make(map[string]any, len(m))
		for k, v := range m {
			cp[k] = v
		}
		cp["hooks"] = rest
		out = append(out, cp)
	}
	if !found {
		h := map[string]any{"type": spec.hookType(), spec.hookType(): value, "timeout": spec.timeoutSec}
		if spec.async {
			h["async"] = true
		}
		g := map[string]any{"hooks": []any{h}}
		if spec.matcher != "" {
			g["matcher"] = spec.matcher
		}
		out = append(out, g)
		changed = true
	}
	return out, changed
}

// hasValue: our entry hm already holds value — and, for a prompt hook, is
// still of type prompt (an owner-retyped entry is set back).
func hasValue(hm map[string]any, spec hookSpec, value string) bool {
	if cur, _ := hm[spec.hookType()].(string); cur != value {
		return false
	}
	return !spec.prompt || hm["type"] == spec.hookType()
}

// withoutOurHook filters our hook objects (isOurHook, by projectID) out of
// every group. A group that still holds an owner hook survives (copied, so
// the input is untouched); a group that held only ours is dropped.
func withoutOurHook(groups []any, spec hookSpec, projectID int64) ([]any, bool) {
	kept := make([]any, 0, len(groups))
	changed := false
	for _, g := range groups {
		m, hs, ok := groupHooks(g)
		if !ok {
			kept = append(kept, g)
			continue
		}
		rest := slices.DeleteFunc(slices.Clone(hs), func(h any) bool { return isOurHook(h, spec, projectID) })
		if len(rest) == len(hs) {
			kept = append(kept, g)
			continue
		}
		changed = true
		if len(rest) == 0 {
			continue
		}
		cp := make(map[string]any, len(m))
		for k, v := range m {
			cp[k] = v
		}
		cp["hooks"] = rest
		kept = append(kept, cp)
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
// sorted (encoding/json), HTML characters unescaped, two-space indented. When
// file is a symlink (e.g. dotfiles-managed), the write lands on its resolved
// target so the link itself survives.
func writeSettings(file string, settings map[string]any, mode os.FileMode) error {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(settings); err != nil {
		return fmt.Errorf("encoding %s: %w", file, err)
	}
	target, err := resolveSymlink(file)
	if err != nil {
		return err
	}
	return atomicWriteFile(target, buf.Bytes(), mode)
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
	for cur := abs; ; cur = filepath.Dir(cur) {
		gitDir, found, err := gitDirAt(cur)
		if err != nil {
			return excludeLoc{}, false, err
		}
		if found {
			common, err := commonGitDir(gitDir)
			if err != nil {
				return excludeLoc{}, false, err
			}
			rel, err := filepath.Rel(cur, abs)
			if err != nil {
				return excludeLoc{}, false, fmt.Errorf("relating %s to %s: %w", abs, cur, err)
			}
			return excludeLoc{file: filepath.Join(common, "info", "exclude"), rel: rel}, true, nil
		}
		if filepath.Dir(cur) == cur {
			return excludeLoc{}, false, nil
		}
	}
}

func gitDirAt(dir string) (string, bool, error) {
	p := filepath.Join(dir, ".git")
	info, err := os.Stat(p)
	if errors.Is(err, os.ErrNotExist) {
		return "", false, nil
	}
	if err != nil {
		return "", false, fmt.Errorf("inspecting %s: %w", p, err)
	}
	if info.IsDir() {
		return p, true, nil
	}
	b, err := os.ReadFile(p)
	if err != nil {
		return "", false, fmt.Errorf("reading %s: %w", p, err)
	}
	target, ok := strings.CutPrefix(strings.TrimSpace(string(b)), "gitdir:")
	if !ok {
		return "", false, fmt.Errorf("%s is neither a git directory nor a gitdir file", p)
	}
	target = strings.TrimSpace(target)
	if !filepath.IsAbs(target) {
		target = filepath.Join(dir, target)
	}
	return target, true, nil
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
// its existing permission bits (or 0o644 for a brand-new file) are kept.
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
