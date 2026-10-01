package confluenceedit

import (
	"errors"
	"fmt"
	"strings"
)

var (
	errSpansBlocks = errors.New("old text spans more than one block, or quotes list/table/heading syntax; replace text within one paragraph, list item, table cell, heading or code block (or use replace_section)")
	// errBoundaryInText refuses a LayoutBoundary in an edit's new text.
	errBoundaryInText = errors.New(LayoutBoundary + " marks the edge of a page layout, not text: a section ends at the first one after its heading; leave it, and the text past it, out of new_body (change that text with replace_text or under its own heading)")
)

// hit is one occurrence of old text: range r of slot s's text.
type hit struct {
	s slot
	r span
}

// replaceText rewrites the one unit whose text holds old (spec §3). The
// match is on whitespace/NBSP/quote-normalised text and must be unique and
// inside a single unit.
func (a *applier) replaceText(old, repl string) (Change, error) {
	key := matchKey(old)
	if key == "" {
		return Change{}, fmt.Errorf("%w: old text is empty; quote the text to replace", errEmpty)
	}
	if strings.Contains(old, LayoutBoundary) {
		return Change{}, errSpansBlocks
	}
	h, err := a.findOne(key, old)
	if err != nil {
		return Change{}, err
	}
	u := h.s.u
	if err := checkRewritable(u, repl); err != nil {
		return Change{}, err
	}
	if !a.roundTrips(u) {
		return Change{}, errors.New("this passage contains characters that read as formatting (e.g. `**`, `_`, `[..](..)`); edit that passage in Confluence")
	}
	repl = cleanModelText(repl)
	before := u.text
	after := before[:h.r.start] + repl + before[h.r.end:]
	if after == before {
		return Change{}, errors.New("edit changes nothing: new text equals the text it replaces")
	}
	marks, removed, err := a.remark(u, h.r, repl)
	if err != nil {
		return Change{}, err
	}
	u.text, u.marks = after, marks
	return Change{Kind: KindReplaceText, Locator: locator(h.s.heading), Before: before, After: after, Removed: removed}, nil
}

// checkRewritable refuses a unit a rewrite from text would damage, and new
// text its context cannot hold.
func checkRewritable(u *unit, repl string) error {
	if u.other {
		return errors.New("this text holds markup the editor cannot keep (an HTML comment or stray tag); edit it in Confluence instead")
	}
	if u.kind == unitInline && u.ctx != ctxPara && strings.Contains(repl, "\n") {
		return errors.New("a heading or table cell cannot hold a line break; keep new text on one line")
	}
	return nil
}

func (a *applier) findOne(key, old string) (hit, error) {
	var hits []hit
	for _, s := range a.slots() {
		for _, r := range findAll(s.u.text, key) {
			hits = append(hits, hit{s: s, r: r})
		}
	}
	switch len(hits) {
	case 1:
		return hits[0], nil
	case 0:
		return hit{}, a.notFound(old)
	}
	return hit{}, fmt.Errorf("old text is ambiguous (%d matches); quote more surrounding words so it matches exactly once", len(hits))
}

// notFound tells text that crosses blocks (or quotes list/table/heading
// syntax) from text that is not on the page at all.
func (a *applier) notFound(old string) error {
	var parts []string
	for _, bl := range expand(a.d.blocks) {
		if bl.kind == blockMarker {
			parts = append(parts, a.orig.markers[bl.marker-1].token())
		}
		for _, u := range bl.editUnits() {
			parts = append(parts, u.text)
		}
	}
	flat := matchKey(strings.Join(parts, " "))
	if k := matchKey(stripStructure(old)); k != "" && strings.Contains(flat, k) {
		return errSpansBlocks
	}
	return errors.New("old text not found; quote it exactly as the page text shows it (whitespace may differ)")
}

// remark computes the unit's marks after replacing range r of its text
// with repl, and the markers the replacement removed. A marker token must
// lie wholly inside or wholly outside r.
func (a *applier) remark(u *unit, r span, repl string) ([]mark, []string, error) {
	if u.kind == unitCode {
		return nil, nil, nil // code is verbatim: nothing in it is a marker
	}
	delta := len(repl) - (r.end - r.start)
	var head, tail []mark
	inSpan := map[int]bool{}
	for _, m := range u.marks {
		end := m.at + len(a.orig.markers[m.k-1].token())
		switch {
		case end <= r.start:
			head = append(head, m)
		case m.at >= r.end:
			tail = append(tail, mark{at: m.at + delta, k: m.k})
		case m.at >= r.start && end <= r.end:
			inSpan[m.k] = true
		default:
			return nil, nil, fmt.Errorf("old text cuts through the marker %s; include the whole token or none of it", a.orig.markers[m.k-1].token())
		}
	}
	lits := literalView(u.text, u.marks, a.orig.markers)
	added, err := a.classify(repl, classifyCtx{inSpan: inSpan, present: a.present(), literal: lits})
	if err != nil {
		return nil, nil, err
	}
	if err := a.checkInline(added); err != nil {
		return nil, nil, err
	}
	now := map[int]bool{}
	for i := range added {
		now[added[i].k] = true
		added[i].at += r.start
	}
	marks := append(append(head, added...), tail...)
	return marks, a.removedTokens(inSpan, now), nil
}

// checkInline refuses a block marker (a table, a macro, an image ... that
// stood as a block of its own) placed inside inline text.
func (a *applier) checkInline(marks []mark) error {
	for _, m := range marks {
		if a.isBlock[m.k] {
			return fmt.Errorf("marker %s is a block element; it can only stand on a line of its own in a replace_section body", a.orig.markers[m.k-1].token())
		}
	}
	return nil
}

// replaceSection replaces the body of the one heading matching heading
// with new markdown, keeping the heading (spec §3).
func (a *applier) replaceSection(heading, body string) (Change, error) {
	key := matchKey(strings.TrimLeft(strings.TrimSpace(heading), "#"))
	if key == "" {
		return Change{}, fmt.Errorf("%w: heading is empty; name the section's heading", errEmpty)
	}
	i, err := a.findHeading(key)
	if err != nil {
		return Change{}, err
	}
	hb := a.d.blocks[i]
	region, err := a.d.sectionRegion(i)
	if err != nil {
		return Change{}, err
	}
	if err := a.checkNotNesting(region); err != nil {
		return Change{}, err
	}
	content := a.regionBlocks(hb, region)
	before := a.blocksText(content)
	had := blockMarks(content)
	newBody, err := a.parseBody(body, classifyCtx{inSpan: had, present: a.present(), literal: blocksLiteral(content, a.orig.markers)})
	if err != nil {
		return Change{}, err
	}
	after := a.blocksText(newBody)
	if after == before {
		return Change{}, errors.New("edit changes nothing: new body equals the section's current body")
	}
	if err := a.checkNoSpill(i, region, content, newBody); err != nil {
		return Change{}, err
	}
	ops, err := a.mergeSection(a.baseBlocks(region), newBody)
	if err != nil {
		return Change{}, err
	}
	links := blocksLinks(content)
	a.kill(region)
	hb.section = &section{region: region, body: opsBody(ops), ops: ops, index: a.index, links: links}
	return Change{
		Kind: KindReplaceSection, Locator: unitText(hb.unit), Before: before, After: after,
		Removed: a.removedTokens(had, blockMarks(hb.section.body)),
	}, nil
}

// checkNoSpill refuses a new body that repeats a block lying past the end
// of the section's region but before the next heading of the same or a
// higher level: the text past a layout edge, which reads as more of the
// section to a model that overlooks the LayoutBoundary line. Writing it
// would copy that block into the section while the original stays where it
// is. A text the section itself also holds is the section's own.
func (a *applier) checkNoSpill(hi int, region span, content, body []*block) error {
	own := map[string]bool{}
	for _, bl := range content {
		own[a.d.blockText(bl)] = true
	}
	past := map[string]bool{}
	for _, bl := range expand(a.d.blocks[hi+1:]) {
		if bl.kind == blockHeading && unitText(bl.unit) != "" && bl.level <= a.d.blocks[hi].level && bl.start >= region.end {
			break
		}
		if bl.start >= region.end {
			past[a.d.blockText(bl)] = true
		}
	}
	for _, bl := range body {
		if t := a.d.blockText(bl); t != "" && past[t] && !own[t] {
			return fmt.Errorf("new_body repeats %s, which is not in this section: the section ends at the %s line after its heading; leave that text out of new_body (change it with replace_text or under its own heading)", snippet(t), LayoutBoundary)
		}
	}
	return nil
}

// baseBlocks are the ORIGINAL blocks of a section region (dead or alive,
// with their current unit text): what a new body is merged against, since
// only they have bytes to keep.
func (a *applier) baseBlocks(region span) []*block {
	var out []*block
	for _, bl := range a.d.blocks {
		if bl.start >= region.start && bl.end <= region.end {
			out = append(out, bl)
		}
	}
	return out
}

// checkNotNesting refuses a section that encloses a section an earlier
// edit replaced: the two rewrites would claim the same bytes.
func (a *applier) checkNotNesting(region span) error {
	for _, bl := range a.d.blocks {
		if !bl.dead && bl.section != nil && bl.start >= region.start && bl.end <= region.end {
			return fmt.Errorf("this section contains the section replaced by edits[%d]; put both changes into one replace_section", bl.section.index)
		}
	}
	return nil
}

func opsBody(ops []sectionOp) []*block {
	var out []*block
	for _, op := range ops {
		if op.body != nil {
			out = append(out, op.body)
		}
	}
	return out
}

// regionBlocks is a section's current body: the body an earlier
// replace_section wrote, or else the live blocks inside its region (with
// the bodies of nested rewritten sections).
func (a *applier) regionBlocks(hb *block, region span) []*block {
	if hb.section != nil {
		return hb.section.body
	}
	var in []*block
	for _, bl := range a.d.blocks {
		if bl.start >= region.start && bl.end <= region.end {
			in = append(in, bl)
		}
	}
	return expand(in)
}

// kill marks every block inside region dead; a nested section rewritten
// earlier is subsumed with its heading.
func (a *applier) kill(region span) {
	for _, bl := range a.d.blocks {
		if bl.start >= region.start && bl.end <= region.end {
			bl.dead = true
			bl.section = nil
		}
	}
}

func (a *applier) findHeading(key string) (int, error) {
	match := func(strict bool) []int {
		var out []int
		for i, bl := range a.d.blocks {
			if !bl.dead && bl.kind == blockHeading && headingMatches(unitText(bl.unit), key, strict) {
				out = append(out, i)
			}
		}
		return out
	}
	found := match(true)
	if len(found) == 0 {
		found = match(false)
	}
	switch len(found) {
	case 1:
		return found[0], nil
	case 0:
		return 0, a.headingNotFound(key)
	}
	return 0, fmt.Errorf("heading is ambiguous (%d headings match); use replace_text for changes under it", len(found))
}

func headingMatches(text, key string, strict bool) bool {
	if text == "" {
		return false
	}
	if strict {
		return matchKey(text) == key
	}
	return strings.EqualFold(matchKey(stripEmphasis.Replace(text)), stripEmphasis.Replace(key))
}

// headingNotFound points at the earlier replace_section when the heading
// is in its new body or was one of the headings its region replaced.
func (a *applier) headingNotFound(key string) error {
	for _, bl := range a.d.blocks {
		if bl.dead || bl.section == nil {
			continue
		}
		if a.sectionHasHeading(bl.section, key) {
			return fmt.Errorf("heading is inside the section replaced by edits[%d]; put this change into that edit's new_body", bl.section.index)
		}
	}
	return errors.New("heading not found; name a heading exactly as the page text shows it, without the leading #")
}

func (a *applier) sectionHasHeading(s *section, key string) bool {
	for _, b := range s.body {
		if b.kind == blockHeading && headingMatches(unitText(b.unit), key, false) {
			return true
		}
	}
	for _, b := range a.d.blocks {
		if b.dead && b.kind == blockHeading && b.start >= s.region.start && b.end <= s.region.end &&
			headingMatches(unitText(b.unit), key, false) {
			return true
		}
	}
	return false
}
