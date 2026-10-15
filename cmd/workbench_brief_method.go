package cmd

import (
	"fmt"
	"strings"
	"unicode/utf8"

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
// a pointer to the file, the broken-file line, and the Checks: line when a
// check differs from the built-in default. "" when there is nothing to say.
// Pure.
func briefMethodSection(e workbenchmethod.Effective) string {
	checks := briefChecksLine(e)
	room := briefMethodChars
	if checks != "" {
		room -= utf8.RuneCountInString(checks) + 1
	}
	return joinBriefLines(briefFolderRules(e.File, room), checks)
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
