package asks

import (
	"fmt"
	"strings"
	"unicode"
)

// DeliveryLine is the one line the Desktop types into the ask's session,
// then submits with a Return of its own, after the owner answers (spec
// Part 5, PROJ-12) — the Go side of the Swift OwnerAskPrompt, pinned by
// testdata/lines.
func DeliveryLine(id int64, kind string, a Answer) string {
	line := fmt.Sprintf("Ask #%d answered (%s: %s) — read it with get_ask %d using the watchtower-workbench skill.",
		id, kind, short(kind, a), id)
	return OneLine(line)
}

func short(kind string, a Answer) string {
	switch {
	case kind == KindReview && a.Verdict == VerdictApproved:
		return "approved"
	case kind == KindReview && a.Verdict == VerdictChanges:
		return "changes requested"
	case kind == KindCheck:
		return checkCounts(a.Checklist)
	}
	return "answered"
}

// OneLine turns every control scalar and line break into a space, the
// WorkbenchCommentPrompt rule (Swift's controlCharacters plus newlines:
// Cc, Cf, Zl, Zp), so the typed line can neither submit early nor carry an
// escape sequence.
func OneLine(s string) string {
	return strings.Map(func(r rune) rune {
		if unicode.In(r, unicode.Cc, unicode.Cf, unicode.Zl, unicode.Zp) {
			return ' '
		}
		return r
	}, s)
}
