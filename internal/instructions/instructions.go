// Package instructions holds the owner-written agent instructions: the limits,
// the session-brief slot and the target procedure text.
package instructions

import (
	"fmt"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"watchtower/internal/db"
)

const (
	// MaxRunes bounds one instruction text.
	MaxRunes = 1000
	// MaxSuggestionRunes bounds one mined suggestion line.
	MaxSuggestionRunes = 200
)

const (
	sessionHeader   = "Owner's instructions (follow in every turn):"
	workbenchHeader = "For this workbench:"
	procedurePtr    = "Target procedure: update_target returns it when a target goes in_progress."
	procedureHead   = "Owner's target procedure — follow it for #"
)

// SlotMaxRunes bounds BriefSlot's output for maximal texts (all ASCII
// constants, so bytes equal runes): the most the brief's cap can grow by.
const SlotMaxRunes = len(sessionHeader) + 1 + MaxRunes + 1 +
	len(workbenchHeader) + 1 + MaxRunes + 1 + len(procedurePtr)

// ErrTooLong reports an instruction text over MaxRunes.
var ErrTooLong = fmt.Errorf("instruction text is over the limit of %d characters", MaxRunes)

// Texts are the global and the workbench instruction texts.
type Texts struct{ Global, Workbench db.OwnerInstructions }

// Load reads the global texts and those of workbench workbenchID.
func Load(d *db.DB, workbenchID int64) (Texts, error) {
	g, err := d.GetOwnerInstructions()
	if err != nil {
		return Texts{}, err
	}
	w, err := d.GetWorkbenchInstructions(workbenchID)
	if err != nil {
		return Texts{}, err
	}
	return Texts{Global: g, Workbench: w}, nil
}

// Validate refuses a text over MaxRunes (surrounding space not counted).
func Validate(body string) error {
	if utf8.RuneCountInString(strings.TrimSpace(body)) > MaxRunes {
		return ErrTooLong
	}
	return nil
}

// BriefSlot renders the session-brief block: the session instructions, then a
// pointer to the target procedure when one exists. "" when there is nothing.
func BriefSlot(t Texts) string {
	g, w := strings.TrimSpace(t.Global.Session), strings.TrimSpace(t.Workbench.Session)
	var parts []string
	if g != "" || w != "" {
		parts = append(parts, sessionHeader)
		if g != "" {
			parts = append(parts, g)
		}
		if w != "" {
			parts = append(parts, workbenchHeader, w)
		}
	}
	if strings.TrimSpace(t.Global.Procedure) != "" || strings.TrimSpace(t.Workbench.Procedure) != "" {
		parts = append(parts, procedurePtr)
	}
	return strings.Join(parts, "\n")
}

// Procedure renders the target procedure for target targetID; "" when both
// procedure texts are empty.
func Procedure(t Texts, targetID int64) string {
	return ProcedureFor(t, strconv.FormatInt(targetID, 10))
}

// ProcedureFor renders the target procedure with idLabel after the "#" of its
// header (a target id, or "N" in the preview); "" when both texts are empty.
func ProcedureFor(t Texts, idLabel string) string {
	g, w := strings.TrimSpace(t.Global.Procedure), strings.TrimSpace(t.Workbench.Procedure)
	if g == "" && w == "" {
		return ""
	}
	parts := []string{procedureHead + idLabel + ":"}
	if g != "" {
		parts = append(parts, g)
	}
	if w != "" {
		parts = append(parts, workbenchHeader, w)
	}
	return strings.Join(parts, "\n")
}

// AppendLine adds line to existing on a new line; ErrTooLong when the result
// would pass MaxRunes.
func AppendLine(existing, line string) (string, error) {
	out := line
	if existing != "" {
		out = existing + "\n" + line
	}
	if err := Validate(out); err != nil {
		return "", fmt.Errorf("appending a line: %w", err)
	}
	return out, nil
}

// Fingerprint lower-cases s, keeps letters and digits, turns every other run
// into one space and trims.
func Fingerprint(s string) string {
	var b strings.Builder
	space := false
	for _, r := range strings.ToLower(s) {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			if space && b.Len() > 0 {
				b.WriteByte(' ')
			}
			space = false
			b.WriteRune(r)
		} else {
			space = true
		}
	}
	return b.String()
}
