package confluenceedit

import "strings"

// Text renders the editable text (spec §3): blocks separated by a blank
// line; headings as "#".."######"; lists as "-" / "N." items indented two
// spaces per nesting level (an item's line break or extra paragraph
// continues on the next line, aligned under its text); a plain table as a
// markdown pipe table (first row, then a "---" separator); a code macro as
// a fenced block tagged with its language; inline **bold**, _italic_,
// ~~strike~~, `code`, [text](href), and "\n" for a line break inside a
// paragraph. Everything else is a ⟦k:label⟧ marker. Empty blocks (an empty
// paragraph Confluence uses as spacing) are omitted.
//
// Text is not escaped: a literal "*" or "_" in the page is shown as is.
func (d *Doc) Text() string {
	parts := make([]string, 0, len(d.blocks))
	for _, bl := range d.blocks {
		if s := d.blockText(bl); s != "" {
			parts = append(parts, s)
		}
	}
	return strings.Join(parts, "\n\n")
}

func (d *Doc) blockText(bl *block) string {
	switch bl.kind {
	case blockHeading:
		if t := unitText(bl.unit); t != "" {
			return strings.Repeat("#", bl.level) + " " + t
		}
		return ""
	case blockCode:
		return codeFence(bl.lang, unitText(bl.unit))
	case blockList:
		return listText(bl.items)
	case blockTable:
		return tableText(bl.rows)
	case blockMarker:
		return d.markers[bl.marker-1].token()
	default:
		return unitText(bl.unit)
	}
}

// unitText is a unit's current editable text ("" for a nil unit — a
// self-closed element with nothing to edit).
func unitText(u *unit) string {
	if u == nil {
		return ""
	}
	return u.text
}

// longestRun is the length of the longest run of c in s.
func longestRun(s string, c byte) int {
	best, cur := 0, 0
	for i := 0; i < len(s); i++ {
		if s[i] == c {
			cur++
			best = max(best, cur)
		} else {
			cur = 0
		}
	}
	return best
}

// codeFence fences body with more backticks than any run inside it.
func codeFence(lang, body string) string {
	fence := strings.Repeat("`", max(3, longestRun(body, '`')+1))
	return fence + lang + "\n" + body + "\n" + fence
}

func listText(items []listItem) string {
	var lines []string
	for _, it := range items {
		indent := strings.Repeat("  ", it.depth)
		cont := "\n" + indent + strings.Repeat(" ", len(it.bullet)+1)
		var paras []string
		for _, u := range it.paras {
			if u.text != "" {
				paras = append(paras, strings.ReplaceAll(u.text, "\n", cont))
			}
		}
		line := indent + it.bullet
		if len(paras) > 0 {
			line += " " + strings.Join(paras, cont)
		}
		lines = append(lines, line)
	}
	return strings.Join(lines, "\n")
}

func tableText(rows [][]*unit) string {
	lines := make([]string, 0, len(rows)+1)
	for i, row := range rows {
		cells := make([]string, len(row))
		for j, u := range row {
			cells[j] = unitText(u)
		}
		lines = append(lines, "| "+strings.Join(cells, " | ")+" |")
		if i == 0 {
			lines = append(lines, "|"+strings.Repeat(" --- |", len(row)))
		}
	}
	return strings.Join(lines, "\n")
}
