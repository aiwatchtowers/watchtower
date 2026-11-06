package inboxfolders

import (
	"strings"
	"unicode"
	"unicode/utf8"
)

// The menu's limits: a folder sits at most MaxDepth levels below the root,
// the owner has at most MaxOwnerFolders folders, a title is at most
// MaxTitleRunes characters after trimming.
const (
	MaxDepth        = 3
	MaxOwnerFolders = 100
	MaxTitleRunes   = 60
)

// cleanTitle trims a title and checks it: 1..MaxTitleRunes runes, on one
// line (no control or format character, no line or paragraph separator).
func cleanTitle(raw string) (string, error) {
	title := strings.TrimSpace(raw)
	n := utf8.RuneCountInString(title)
	if n == 0 || n > MaxTitleRunes || !utf8.ValidString(title) {
		return "", ErrBadTitle
	}
	if strings.IndexFunc(title, notOnOneLine) >= 0 {
		return "", ErrBadTitle
	}
	return title, nil
}

// checkIcon accepts "" (the kind's default) or a name on the allowlist.
func checkIcon(icon string) error {
	if icon == "" || allowedIcons[icon] {
		return nil
	}
	return refuse(ErrUnknownIcon, "unknown icon %q", icon)
}

// zeroWidthJoiner (U+200D, Cf) joins emoji such as a family into one
// picture, so a title may hold it.
const zeroWidthJoiner = '\u200D'

// notOnOneLine is a rune a title may not hold: a control (Cc, a newline
// included), a format character (Cf, such as U+202E, which reorders what
// the menu shows; the zero-width joiner excepted) or a line/paragraph
// separator (Zl, Zp).
func notOnOneLine(r rune) bool {
	return r != zeroWidthJoiner && unicode.In(r, unicode.Cc, unicode.Cf, unicode.Zl, unicode.Zp)
}
