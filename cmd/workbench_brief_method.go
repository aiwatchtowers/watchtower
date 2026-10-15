package cmd

import (
	"fmt"
	"strings"
	"unicode/utf8"

	"watchtower/internal/devpack"
	"watchtower/internal/workbenchmethod"
)

// The brief's folder rules slot (spec 2026-10-15 §6). Its room is set aside
// next to the board rules, before the board is fitted, so the board never
// cuts it; at most briefMethodChars runes, which keeps the 4000-rune cap and
// the board's share workable.
const (
	briefMethodChars       = 1400
	briefFolderRulesInline = 1200
	briefFolderRulesTitle  = "Folder rules (.watchtower/workflow.md — the owner's rules for this folder; they win over the watchtower-flow preset):"
)

// briefMethodSection is the slot for e: the workflow.md body inline (at
// most briefFolderRulesInline runes, when it fits beside the other lines) or
// a pointer to the file, the broken-file line, the Checks: line when a check
// differs from the built-in default, and mismatch (briefPresetMismatch).
// "" when there is nothing to say. Pure.
func briefMethodSection(e workbenchmethod.Effective, mismatch string) string {
	tail := joinBriefLines(briefChecksLine(e), mismatch)
	room := briefMethodChars
	if tail != "" {
		room -= utf8.RuneCountInString(tail) + 1
	}
	return joinBriefLines(briefFolderRules(e.File, room), tail)
}

// briefPresetMismatch is the brief's line when the effective preset is not
// what the workbench folder holds (spec §6), so a changed preset: line or
// setting is never silent; "" when they agree, when the folder has no core
// skill, or when its core is an owner-edited single file (which carries its
// own methodology).
func briefPresetMismatch(e workbenchmethod.Effective, folder string, workbenchID int64) string {
	l := devpack.FolderMethodologyLayout(folder)
	switch {
	case !l.Core || l.SingleFile:
		return ""
	case e.Preset == workbenchmethod.PresetNone && l.Flow:
		return fmt.Sprintf("Methodology preset: none is set, but %s is still installed — run 'watchtower workbench resync %d'.",
			devpack.FlowSkillName, workbenchID)
	case e.Preset == workbenchmethod.PresetFlow && !l.Flow:
		return fmt.Sprintf("Methodology preset: %s is set, but it is not installed — run 'watchtower workbench resync %d'.",
			devpack.FlowSkillName, workbenchID)
	}
	return ""
}

// briefRulesFor is the fixed board rules for preset: without a methodology
// preset (none) the sentence keeps the status, ask_owner and plain-text
// question clauses and drops the review step and the comment convention,
// which belong to watchtower-flow (spec 2026-10-15 F15).
func briefRulesFor(preset string) []string {
	if preset == workbenchmethod.PresetNone {
		return briefRulesNoPreset
	}
	return briefRules
}

// joinBriefLines joins the non-empty lines.
func joinBriefLines(lines ...string) string {
	kept := make([]string, 0, len(lines))
	for _, l := range lines {
		if l != "" {
			kept = append(kept, l)
		}
	}
	return strings.Join(kept, "\n")
}

// briefFolderRules is f's part of the slot within room runes.
func briefFolderRules(f workbenchmethod.File, room int) string {
	switch {
	case !f.Present:
		return ""
	case f.Err != nil:
		return briefClip("Folder rules: "+workbenchmethod.FileRel+" was ignored: "+f.Err.Error()+". Built-in defaults apply.", briefLineChars)
	case f.Body == "":
		return ""
	}
	inline := briefFolderRulesTitle + "\n" + f.Body
	if !f.Truncated && f.BodyChars <= briefFolderRulesInline && utf8.RuneCountInString(inline) <= room {
		return inline
	}
	cut := ""
	if f.Truncated {
		cut = ", cut at 64 KiB"
	}
	return fmt.Sprintf("Folder rules: %s (%d chars%s) — read it before you start working.", workbenchmethod.FileRel, f.BodyChars, cut)
}

// briefChecksLine names each end-of-turn check that is not at its built-in
// default, with where its value comes from, so the core skill's conditional
// paragraphs resolve; "" when both are at their defaults.
func briefChecksLine(e workbenchmethod.Effective) string {
	var parts []string
	if e.AskGuard != workbenchmethod.AskGuardStrict {
		parts = append(parts, fmt.Sprintf("ask guard %s (%s)", e.AskGuard, e.Sources.AskGuard.Label()))
	}
	if !e.FinishOn() {
		parts = append(parts, fmt.Sprintf("finish check off (%s)", e.Sources.FinishCheck.Label()))
	}
	if len(parts) == 0 {
		return ""
	}
	return "Checks: " + strings.Join(parts, ", ") + "."
}

// briefSessionRow is the Desktop terminal row the brief runs in, 0 outside
// one (an invalid variable is already reported by recordTerminalSessionID).
func briefSessionRow() int64 {
	id, ok, err := terminalSessionRowID()
	if err != nil || !ok {
		return 0
	}
	return id
}
