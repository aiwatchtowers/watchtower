package cmd

import (
	"unicode"
	"unicode/utf8"
)

// maxTerminalNameRunes caps a phone-supplied string printed during
// `hub pair`, ellipsis included.
const maxTerminalNameRunes = 64

// sanitizeForTerminal makes a phone-supplied string (its name, a refusal
// reason) safe to print in the owner's terminal during `hub pair` (go-hub
// plan 2 Task 6, Review Focus 4). It drops:
//   - every control rune (C0, DEL, C1 — CSI U+009B and OSC U+009D among
//     them), so an escape sequence loses its ESC and prints as plain text;
//   - every format rune (Unicode Cf: the bidi controls, zero-width
//     characters, U+FEFF, U+00AD, the tag characters) and the line and
//     paragraph separators U+2028/U+2029;
//   - every byte that is not valid UTF-8, since a raw 0x9B byte is CSI to an
//     8-bit terminal.
//
// It keeps at most two combining marks (Mn) after a base rune, so a Zalgo
// name cannot paint over the lines around it, and cuts the result to
// maxTerminalNameRunes runes, the last one "…", when it is longer.
func sanitizeForTerminal(s string) string {
	kept := make([]rune, 0, min(len(s), maxTerminalNameRunes+1))
	marks := 0
	for i := 0; i < len(s) && len(kept) <= maxTerminalNameRunes; {
		r, size := utf8.DecodeRuneInString(s[i:])
		i += size
		switch {
		case r == utf8.RuneError && size <= 1,
			unicode.IsControl(r), unicode.Is(unicode.Cf, r),
			r == ' ', r == ' ':
			continue
		case unicode.Is(unicode.Mn, r):
			if marks == 2 {
				continue
			}
			marks++
		default:
			marks = 0
		}
		kept = append(kept, r)
	}
	if len(kept) > maxTerminalNameRunes {
		kept = append(kept[:maxTerminalNameRunes-1], '…')
	}
	return string(kept)
}
