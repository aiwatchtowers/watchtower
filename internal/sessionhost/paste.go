package sessionhost

import (
	"strings"
	"unicode"
)

var (
	pasteStart = []byte{0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E} // ESC[200~
	pasteEnd   = []byte{0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E} // ESC[201~
)

// PasteText cleans a line for one bracketed paste — the cleaning of
// WorkbenchCommentPrompt.terminalPayload, pinned on both sides by
// testdata/paste_cases.json. Every control scalar (Unicode Cc and Cf, and the
// newline scalars) is dropped, ESC included, so the text can never carry the
// ESC[201~ that would end the paste early nor a key that submits.
// keepLineBreaks keeps line breaks as LF (CRLF is one break) and tabs;
// keepFormat keeps format scalars (Cf: an emoji sequence's zero-width
// joiner, say), none of which can end the paste.
func PasteText(line string, keepLineBreaks, keepFormat bool) string {
	if keepLineBreaks {
		line = strings.ReplaceAll(line, "\r\n", "\n")
	}
	var sb strings.Builder
	sb.Grow(len(line))
	for _, r := range line {
		switch {
		case keepLineBreaks && isNewlineScalar(r):
			sb.WriteByte('\n')
		case !isControlScalar(r),
			keepLineBreaks && r == '\t',
			keepFormat && unicode.Is(unicode.Cf, r):
			sb.WriteRune(r)
		}
	}
	return sb.String()
}

// PastePayload wraps text, already cleaned by PasteText, in the bracketed
// paste brackets: ESC[200~ text ESC[201~.
func PastePayload(text string) []byte {
	out := make([]byte, 0, len(pasteStart)+len(text)+len(pasteEnd))
	out = append(out, pasteStart...)
	out = append(out, text...)
	return append(out, pasteEnd...)
}

// isNewlineScalar is Foundation's CharacterSet.newlines: U+000A–U+000D,
// U+0085, U+2028, U+2029.
func isNewlineScalar(r rune) bool {
	return r >= 0x0A && r <= 0x0D || r == 0x85 || r == 0x2028 || r == 0x2029
}

// isControlScalar is Foundation's CharacterSet.controlCharacters (Cc and Cf)
// joined with its newlines, as WorkbenchCommentPrompt.isControl.
func isControlScalar(r rune) bool {
	return unicode.Is(unicode.Cc, r) || unicode.Is(unicode.Cf, r) || isNewlineScalar(r)
}
