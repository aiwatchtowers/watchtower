package cmd

import (
	"fmt"
	"os"
	"strings"
	"unicode/utf8"

	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// briefColumnsChars caps the Board columns section (spec 2026-10-16 §5): a
// longer definition becomes one line pointing at workbench_info.
const briefColumnsChars = 1000

// briefColumnsSection is the brief's Board columns section: one line per
// status with defined columns ("<label>: <title> — <description> | …") and
// the Turned off line for the hidden statuses with what to do instead. ""
// when the board defines no columns and hides nothing (PROJ-19), so the brief
// stays as it was. Over briefColumnsChars the columns become one line; the
// Turned off line always stays. Pure.
func briefColumnsSection(c db.BoardColumns) string {
	var off string
	if len(c.Hidden) > 0 {
		parts := make([]string, 0, len(c.Hidden))
		for _, s := range c.Hidden {
			parts = append(parts, fmt.Sprintf("%s (%s)", s, tools.HiddenStatusHints[s]))
		}
		off = "Turned off: " + strings.Join(parts, "; ") + "."
	}
	if len(c.Columns) == 0 {
		return off
	}
	lines := []string{"Board columns (the owner's; move a card with update_target column when its description fits):"}
	for _, s := range db.BoardStatusOrder {
		var cols []string
		for _, col := range c.Columns {
			if col.Status != s {
				continue
			}
			if col.Description == "" {
				cols = append(cols, col.Title)
			} else {
				cols = append(cols, col.Title+" — "+col.Description)
			}
		}
		if len(cols) > 0 {
			lines = append(lines, "- "+db.BoardStatusLabels[s]+": "+strings.Join(cols, " | "))
		}
	}
	section := joinBriefLines(strings.Join(lines, "\n"), off)
	if utf8.RuneCountInString(section) > briefColumnsChars {
		return joinBriefLines(fmt.Sprintf("Board columns: %d columns defined — read them with workbench_info before you move a card.",
			len(c.Columns)), off)
	}
	return section
}

// briefColumnsFor reads workbenchID's column definition for the brief; an
// unreadable one is a line saying so, never a failed brief.
func briefColumnsFor(database *db.DB, workbenchID int64) string {
	c, err := database.GetBoardColumns(workbenchID)
	if err != nil {
		fmt.Fprintf(os.Stderr, "watchtower: workbench %d brief: board columns: %v\n", workbenchID, err)
		return "Board columns: could not be read (" + briefClip(err.Error(), briefLineChars) + ")"
	}
	return briefColumnsSection(c)
}
