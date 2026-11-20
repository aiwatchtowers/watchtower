package devpack

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
)

// The session cleanup's W10 (#1878, ask #1573) lets a git-ignored file of a
// worktree go only when a removal loses nothing of it. These two judges tell
// the workbench install's own files from the owner's: by the same decisions
// the install makes (DEV-04's un-edited skill copy, PROJ-04's "ours" hook
// and allow rule), never by a name alone, and whichever watchtower binary or
// pack version wrote them.

// workbenchSkillByName is the skill of one of the folders a workbench install writes or
// once wrote, by exact name.
func workbenchSkillByName(name string) (Skill, bool) {
	switch name {
	case WorkbenchSkillName:
		return workbenchSkill(), true
	case FlowSkillName:
		return flowSkill(), true
	case LegacySkillName:
		return legacySkill(), true
	}
	return Skill{}, false
}

// IsWorkbenchSkillName reports whether name is one of the skill folders the
// workbench install writes or once wrote.
func IsWorkbenchSkillName(name string) bool {
	_, ok := workbenchSkillByName(name)
	return ok
}

// WorkbenchSkillCopyUnedited reports whether skillDir, a folder named after
// one of the workbench skills, holds nothing but an un-edited copy we
// shipped: its SKILL.md is one the install would update or leave
// (planFor: unchanged, or the digest our sidecar recorded — any pack version
// or overlay), and the folder has no file besides SKILL.md and the sidecar.
// An edited, foreign or extra file, a symlink or a subfolder makes it false.
func WorkbenchSkillCopyUnedited(skillDir string) (bool, error) {
	s, ok := workbenchSkillByName(filepath.Base(skillDir))
	if !ok {
		return false, nil
	}
	entries, err := os.ReadDir(skillDir)
	if err != nil {
		return false, fmt.Errorf("reading %s: %w", skillDir, err)
	}
	for _, e := range entries {
		if !e.Type().IsRegular() || (e.Name() != "SKILL.md" && e.Name() != shippedDigestFile) {
			return false, nil
		}
	}
	file := filepath.Join(skillDir, "SKILL.md")
	if !slices.ContainsFunc(entries, func(e os.DirEntry) bool { return e.Name() == "SKILL.md" }) {
		return false, nil
	}
	state, err := planFor(file, s)
	if err != nil {
		return false, err
	}
	return state == StateUnchanged || state == StateUpdated, nil
}

// SettingsOnlyOurs reports whether file (a .claude/settings.local.json)
// holds nothing but what the workbench install writes for workbenchID and
// what Claude Code adds by itself: our hook entries, judged exactly
// (onlyOurHooks: any watchtower binary path, nothing else on the command
// line, the install's matcher, timeout and async), and a permissions object
// with only allow and deny rule lists (the cleanup allow rule and Claude
// Code's "don't ask again" rules; owner ruling on #1878). Any other key,
// hook, hook field or permission setting, or JSON that does not parse, is
// the owner's: false.
func SettingsOnlyOurs(file string, workbenchID int64) (bool, error) {
	settings, _, existed, err := readSettings(file)
	switch {
	case errors.Is(err, ErrMalformedSettings):
		return false, nil
	case err != nil:
		return false, err
	case !existed:
		return false, nil
	}
	for key, v := range settings {
		switch key {
		case "hooks":
			if !onlyOurHooks(v, workbenchID) {
				return false, nil
			}
		case "permissions":
			if !onlyRuleLists(v) {
				return false, nil
			}
		default:
			return false, nil
		}
	}
	return true, nil
}

func onlyRuleLists(v any) bool {
	perms, ok := v.(map[string]any)
	if !ok {
		return false
	}
	for key, rules := range perms {
		list, ok := rules.([]any)
		if !ok || (key != "allow" && key != "deny") {
			return false
		}
		for _, r := range list {
			if _, ok := r.(string); !ok {
				return false
			}
		}
	}
	return true
}

// onlyOurHooks reports whether every hook of every event is exactly an
// entry the install writes for workbenchID (exactHookEntry), in a group
// shaped as the install shapes it. Stricter than the install's own "ours"
// test (looksLikeOurHook), which dedupes loosely on purpose; that one is
// left as it is for installs.
func onlyOurHooks(v any, workbenchID int64) bool {
	events, ok := v.(map[string]any)
	if !ok {
		return false
	}
	for event, groups := range events {
		list, ok := groups.([]any)
		if !ok {
			return false
		}
		for _, g := range list {
			m, hooks, ok := groupHooks(g)
			if !ok {
				return false
			}
			for key := range m {
				if key != "hooks" && key != "matcher" {
					return false
				}
			}
			for _, h := range hooks {
				if !slices.ContainsFunc(ownedHookSpecs, func(spec hookSpec) bool {
					return spec.event == event && exactGroupMatcher(m, spec) && exactHookEntry(h, spec, workbenchID)
				}) {
					return false
				}
			}
		}
	}
	return true
}

// exactGroupMatcher: the group's matcher is what the install writes for
// spec — spec's matcher, or none.
func exactGroupMatcher(m map[string]any, spec hookSpec) bool {
	got, has := m["matcher"]
	if spec.matcher == "" {
		return !has || got == ""
	}
	return got == spec.matcher
}

// exactHookEntry: h is exactly newOurHookGroup's entry for spec — type
// command, the install's timeout and async, and a command that is one
// shell token naming a watchtower binary (any path, quoted as shellQuote
// quotes it) followed by spec's suffix for workbenchID (or its pre-rename
// spelling), nothing before or after. A prompt hook — the old ask guard,
// replaced by the command since 2026-10-11 — is not judged ours here.
func exactHookEntry(h any, spec hookSpec, workbenchID int64) bool {
	m, ok := h.(map[string]any)
	if !ok || m["type"] != "command" {
		return false
	}
	for key := range m {
		if key != "type" && key != "command" && key != "timeout" && key != "async" {
			return false
		}
	}
	// readSettings decodes numbers as json.Number: a string "30" is not
	// the install's timeout, nor "true" its async.
	if t, ok := m["timeout"].(json.Number); !ok || t.String() != strconv.Itoa(spec.timeoutSec) {
		return false
	}
	if a, has := m["async"]; spec.async != has {
		return false
	} else if b, isBool := a.(bool); has && (!isBool || !b) {
		return false
	}
	cmd, ok := m["command"].(string)
	if !ok {
		return false
	}
	for _, suffix := range []string{spec.suffix(workbenchID), spec.legacySuffix(workbenchID)} {
		if suffix == "" {
			continue
		}
		token, ok := strings.CutSuffix(cmd, suffix)
		if !ok || token == "" {
			continue
		}
		bin := unquoteShellSingle(token)
		if shellQuote(bin) == token && filepath.Base(bin) == "watchtower" {
			return true
		}
	}
	return false
}
