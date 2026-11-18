package devpack

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
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
// what Claude Code adds by itself: our hooks — any watchtower binary,
// current or pre-rename spelling (looksLikeOurHook), and the old marker
// prompt — and a permissions object with only allow and deny rule lists
// (the cleanup allow rule and Claude Code's "don't ask again" rules; owner
// ruling on #1878). Any other key, hook, hook field or permission setting,
// or JSON that does not parse, is the owner's: false.
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

// ourHookFields are the fields an install writes on a hook entry (and
// carries from the old prompt hook): anything else is the owner's.
var ourHookFields = []string{"type", "command", "timeout", "async", "prompt"}

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
				if !isOurEntry(h, event, workbenchID) {
					return false
				}
			}
		}
	}
	return true
}

func isOurEntry(h any, event string, workbenchID int64) bool {
	m, ok := h.(map[string]any)
	if !ok {
		return false
	}
	for key := range m {
		if !slices.Contains(ourHookFields, key) {
			return false
		}
	}
	if event == askGuardSpec.event && isOurMarkerPrompt(h, workbenchID) {
		return true
	}
	for _, spec := range ownedHookSpecs {
		if spec.event == event && isOurHook(h, spec, workbenchID) {
			return true
		}
	}
	return false
}
