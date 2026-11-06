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

// cleanTitle trims a title and checks it: 1..MaxTitleRunes runes, no
// control characters (a newline included).
func cleanTitle(raw string) (string, error) {
	title := strings.TrimSpace(raw)
	n := utf8.RuneCountInString(title)
	if n == 0 || n > MaxTitleRunes || !utf8.ValidString(title) {
		return "", ErrBadTitle
	}
	if strings.IndexFunc(title, unicode.IsControl) >= 0 {
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
