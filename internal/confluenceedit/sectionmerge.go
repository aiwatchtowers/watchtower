package confluenceedit

import (
	"fmt"
	"sort"
	"strings"
)

// Ruling R11: a replace_section re-renders only what it changed.
//
// The new body's blocks are matched, in order, against the section's
// ORIGINAL blocks by editable text (an LCS over block texts; kind is not
// compared, so a paragraph reading "# x" matches the heading the body's
// "# x" parses as). A matched block is kept: it re-emits its original
// bytes, so formatting the editable text cannot express (a centred
// paragraph, a table's layout, a code macro's title, ...) survives. An
// original block whose text reads back as several blocks is kept when a
// run of new blocks joins to it (see mergeGap). A new block whose text
// equals an unmatched original's elsewhere in the section was moved: it
// re-emits that original's bytes at its new place (findMoves, ruling R13).
// Otherwise each new block
// is either derived from the next unmatched original block of the same
// kind — rendered from markdown, allowed only when that original is
// faithfully representable (checkDerivable) — or new, and every original
// block left over is deleted, which the text diff shows. Since the text
// cannot say which original a changed block was edited from, a deleted
// original that markdown cannot carry faithfully is allowed only when no
// changed block of its kind is anywhere in the section (checkLossy, ruling
// R14). An original block with no editable text (an empty spacing
// paragraph) is never deleted: nothing in the text could have asked for
// that.

// sectionOp is one step of a section merge, in body order.
type sectionOp struct {
	orig  *block // the original block kept, replaced or deleted (nil: new)
	body  *block // the body block (orig itself when kept; nil: deleted)
	moved bool   // orig is kept but moved here (its old place is deleted)
}

// moves pairs a new block with an unmatched original of exactly its text
// elsewhere in the section: the block was moved, not changed, so it keeps
// its original bytes (ruling R13).
type moves struct {
	to   map[*block]*block // body block -> the original it re-emits
	away map[*block]bool   // originals moved elsewhere
}

// findMoves pairs, in body order, each body block the match left over with
// the first unmatched original of the same non-empty text.
func findMoves(base, body []*block, baseText, bodyText []string, matched [][2]int) moves {
	mv := moves{to: map[*block]*block{}, away: map[*block]bool{}}
	usedBase, usedBody := map[int]bool{}, map[int]bool{}
	for _, m := range matched {
		usedBase[m[0]], usedBody[m[1]] = true, true
	}
	for j, t := range bodyText {
		if usedBody[j] || t == "" {
			continue
		}
		for i, o := range base {
			if !usedBase[i] && baseText[i] == t {
				usedBase[i] = true
				mv.to[body[j]], mv.away[o] = o, true
				break
			}
		}
	}
	return mv
}

// mergeSection matches body against the section's original blocks and
// returns the merge, or an error naming a block the edit would change but
// markdown cannot carry faithfully.
func (a *applier) mergeSection(base, body []*block) ([]sectionOp, error) {
	baseText := make([]string, len(base))
	for i, bl := range base {
		baseText[i] = a.d.blockText(bl)
	}
	bodyText := make([]string, len(body))
	for i, bl := range body {
		bodyText[i] = a.d.blockText(bl)
	}
	var ops []sectionOp
	bi, ni := 0, 0
	matched := matchBlocks(baseText, bodyText)
	mv := findMoves(base, body, baseText, bodyText, matched)
	for _, m := range matched {
		gap, err := a.mergeGap(base[bi:m[0]], body[ni:m[1]], baseText[bi:m[0]], bodyText[ni:m[1]], mv)
		if err != nil {
			return nil, err
		}
		ops = append(ops, gap...)
		ops = append(ops, sectionOp{orig: base[m[0]], body: base[m[0]]})
		bi, ni = m[0]+1, m[1]+1
	}
	gap, err := a.mergeGap(base[bi:], body[ni:], baseText[bi:], bodyText[ni:], mv)
	if err != nil {
		return nil, err
	}
	ops = append(ops, gap...)
	return ops, a.checkLossy(ops)
}

// checkLossy is ruling R14, the section-wide invariant. The merge leaves
// every original block kept (matched or moved: its bytes are emitted),
// derived (a changed block rendered from it, already checked by
// checkDerivable) or deleted. Which original a changed block was edited
// from cannot be known from the text, so an original markdown cannot carry
// faithfully may be deleted only when no changed block (derived or new) of
// its kind is anywhere in the section — otherwise the edit may be that
// block's rewrite with its formatting silently dropped, however the blocks
// were paired or reordered. A deletion with no such block is unambiguous,
// and the diff shows it.
func (a *applier) checkLossy(ops []sectionOp) error {
	changed := map[blockKind]bool{}
	moved := map[*block]bool{} // a moved block's old place is a deletion op too
	for _, op := range ops {
		if op.body != nil && op.body != op.orig {
			changed[op.body.kind] = true
		}
		if op.moved {
			moved[op.orig] = true
		}
	}
	for _, op := range ops {
		if op.orig == nil || op.body != nil || moved[op.orig] || !changed[op.orig.kind] {
			continue
		}
		if err := a.lossy(op.orig, a.d.blockText(op.orig)); err != nil {
			return err
		}
	}
	return nil
}

// lossy refuses, with the R11 message naming o, an original block markdown
// cannot carry faithfully: its text reads back as other or several blocks,
// or re-rendering it would lose markup, attributes or parameters. A marker
// block (removed only as a reported marker) and a block with no editable
// text (never deleted) are not lossy here.
func (a *applier) lossy(o *block, text string) error {
	if o.kind == blockMarker || text == "" {
		return nil
	}
	if err := a.checkParsable(o, text); err != nil {
		return err
	}
	return a.checkDerivable(o, text)
}

// mergeGap merges the unmatched original and new blocks between two
// matches. An original block whose text reads back as several blocks (a
// paragraph with a blank line from two <br/>s) is kept when a run of new
// blocks joins to exactly its text, splitting the gap around it. Only a
// text holding a blank line can read back as several blocks.
func (a *applier) mergeGap(orig, body []*block, origText, bodyText []string, mv moves) ([]sectionOp, error) {
	for i, t := range origText {
		if !strings.Contains(t, "\n\n") || mv.away[orig[i]] {
			continue
		}
		if q, k := findRun(bodyText, t); k > 0 && !anyMoved(body[q:q+k], mv) {
			left, err := a.mergeGap(orig[:i], body[:q], origText[:i], bodyText[:q], mv)
			if err != nil {
				return nil, err
			}
			right, err := a.mergeGap(orig[i+1:], body[q+k:], origText[i+1:], bodyText[q+k:], mv)
			if err != nil {
				return nil, err
			}
			return append(append(left, sectionOp{orig: orig[i], body: orig[i]}), right...), nil
		}
	}
	return a.pairGap(orig, body, origText, mv)
}

func anyMoved(body []*block, mv moves) bool {
	for _, n := range body {
		if mv.to[n] != nil {
			return true
		}
	}
	return false
}

// findRun finds k >= 2 consecutive texts starting at q that join to t.
func findRun(texts []string, t string) (q, k int) {
	for q = range texts {
		joined := texts[q]
		for k = 2; q+k <= len(texts) && len(joined) < len(t); k++ {
			joined += "\n\n" + texts[q+k-1]
			if joined == t {
				return q, k
			}
		}
	}
	return 0, 0
}

// pairGap re-emits each moved block, derives each other new block from the
// next unmatched original block of its kind, or adds it as new; the
// originals left over (and those moved elsewhere) are deleted.
func (a *applier) pairGap(allOrig, body []*block, allText []string, mv moves) ([]sectionOp, error) {
	var ops []sectionOp
	var orig, fresh []*block
	var origText []string
	for i, o := range allOrig {
		if mv.away[o] {
			ops = append(ops, sectionOp{orig: o})
			continue
		}
		orig, origText = append(orig, o), append(origText, allText[i])
	}
	for _, n := range body {
		if mv.to[n] == nil {
			fresh = append(fresh, n)
		}
	}
	if len(fresh) > 0 {
		for i, o := range orig {
			if err := a.checkParsable(o, origText[i]); err != nil {
				return nil, err
			}
		}
	}
	p := 0
	for _, n := range body {
		if o := mv.to[n]; o != nil {
			ops = append(ops, sectionOp{orig: o, body: o, moved: true})
			continue
		}
		j := nextDerivable(orig, origText, p, n.kind)
		if j < 0 {
			ops = append(ops, sectionOp{body: n})
			continue
		}
		if err := a.checkDerivable(orig[j], origText[j]); err != nil {
			return nil, err
		}
		ops = append(ops, dropOrKeep(orig[p:j], origText[p:j])...)
		ops = append(ops, sectionOp{orig: orig[j], body: n})
		p = j + 1
	}
	return append(ops, dropOrKeep(orig[p:], origText[p:])...), nil
}

// dropOrKeep deletes original blocks the new body left out — except one
// with no editable text, which the model never saw and so is kept.
func dropOrKeep(orig []*block, text []string) []sectionOp {
	ops := make([]sectionOp, len(orig))
	for i, o := range orig {
		ops[i] = sectionOp{orig: o}
		if text[i] == "" {
			ops[i].body = o
		}
	}
	return ops
}

// nextDerivable is the index of the first original block at or after p of
// the given kind that a new block can derive from, or -1.
func nextDerivable(orig []*block, text []string, p int, kind blockKind) int {
	for j := p; j < len(orig); j++ {
		if orig[j].kind == kind && kind != blockMarker && text[j] != "" {
			return j
		}
	}
	return -1
}

// checkParsable refuses an edit near an original block whose editable text
// does not read back, through the markdown parser, as one block of its own
// kind with the same text: such a block, once changed, would silently
// change kind (a paragraph reading "# x" would become a heading).
func (a *applier) checkParsable(o *block, text string) error {
	if text == "" || o.kind == blockMarker {
		return nil
	}
	p := &mdParser{a: a, lines: strings.Split(text, "\n")}
	for p.i < len(p.lines) {
		p.block()
	}
	if len(p.blocks) == 1 && p.blocks[0].kind == o.kind && a.d.blockText(p.blocks[0]) == text {
		return nil
	}
	return a.refuseBlock(o, text, "its text reads as different markdown structure")
}

// checkDerivable refuses to re-render an original block from markdown when
// that would lose something the editable text cannot show.
func (a *applier) checkDerivable(o *block, text string) error {
	for _, u := range o.editUnits() {
		if u.other {
			return a.refuseBlock(o, text, "an HTML comment or stray tag")
		}
		if !a.roundTrips(u) {
			return a.refuseBlock(o, text, "characters that read as formatting")
		}
	}
	if why := unfaithful(a.d.src[o.start:o.end], o); why != "" {
		return a.refuseBlock(o, text, why)
	}
	return nil
}

func (a *applier) refuseBlock(o *block, text, why string) error {
	return fmt.Errorf("the section's %s %s cannot be rewritten without losing formatting (%s); keep that block exactly as it is in new_body, or edit it in Confluence",
		blockKindName(o.kind), snippet(text), why)
}

func blockKindName(k blockKind) string {
	switch k {
	case blockHeading:
		return "heading"
	case blockList:
		return "list"
	case blockTable:
		return "table"
	case blockCode:
		return "code block"
	case blockMarker:
		return "element"
	case blockParagraph:
	}
	return "paragraph"
}

// snippet quotes the first line of text, at most 40 runes.
func snippet(text string) string {
	line, _, _ := strings.Cut(text, "\n")
	if r := []rune(line); len(r) > 40 {
		line = string(r[:39]) + "…"
	}
	return fmt.Sprintf("%q", line)
}

// sectionOut is a section region's new bytes: the region's source with
// every original block kept (and its later-edited units rewritten),
// replaced, deleted or preceded by new blocks — every other byte (the
// whitespace between blocks included) as it was.
func (a *applier) sectionOut(s *section) (string, error) {
	src := a.d.src
	anchor := s.region.start + len(src[s.region.start:s.region.end]) - len(strings.TrimLeft(src[s.region.start:s.region.end], " \t\r\n"))
	var ps []splice
	for _, op := range s.ops {
		switch {
		case op.moved:
			ps = append(ps, splice{span{anchor, anchor}, a.keptBytes(op.orig)})
		case op.orig == nil:
			ps = append(ps, splice{span{anchor, anchor}, a.blockXHTML(op.body, s.links)})
		case op.body == op.orig:
			ps = append(ps, a.unitSplices(op.orig)...)
			anchor = op.orig.end
		case op.body == nil:
			ps = append(ps, splice{span{op.orig.start, wsEnd(src, op.orig.end, s.region.end)}, ""})
		default:
			ps = append(ps, splice{span{op.orig.start, op.orig.end}, a.blockXHTML(op.body, s.links)})
			anchor = op.orig.end
		}
	}
	// An insertion goes before whatever else starts at its anchor.
	sort.SliceStable(ps, func(i, j int) bool {
		if ps[i].start != ps[j].start {
			return ps[i].start < ps[j].start
		}
		return ps[i].start == ps[i].end && ps[j].start != ps[j].end
	})
	var b strings.Builder
	cur := s.region.start
	for _, p := range ps {
		if p.start < cur {
			return "", fmt.Errorf("overlapping section rewrites at byte %d", p.start)
		}
		b.WriteString(src[cur:p.start])
		b.WriteString(p.out)
		cur = p.end
	}
	b.WriteString(src[cur:s.region.end])
	return b.String(), nil
}

// keptBytes is a moved block's original bytes, with its units a later edit
// changed rewritten in place.
func (a *applier) keptBytes(bl *block) string {
	src := a.d.src
	var b strings.Builder
	cur := bl.start
	for _, p := range a.unitSplices(bl) {
		b.WriteString(src[cur:p.start])
		b.WriteString(p.out)
		cur = p.end
	}
	b.WriteString(src[cur:bl.end])
	return b.String()
}

// unitSplices rewrites a kept block's units that a later edit changed.
func (a *applier) unitSplices(bl *block) []splice {
	var ps []splice
	for _, u := range bl.editUnits() {
		if o := a.origOf[u]; o != nil && unitChanged(o, u) {
			ps = append(ps, splice{span{u.start, u.end}, a.unitXHTML(u, u.links)})
		}
	}
	return ps
}

// wsEnd extends a deleted block over the whitespace after it, so deleting
// blocks does not leave blank lines behind.
func wsEnd(src string, end, limit int) int {
	for end < limit && strings.IndexByte(" \t\r\n", src[end]) >= 0 {
		end++
	}
	return end
}

// maxLCSCells bounds the matching table; past it the unmatched middle is
// matched greedily.
const maxLCSCells = 4 << 20

// matchBlocks returns the (base, body) index pairs of equal non-empty
// texts, in order: common prefix and suffix first, then an LCS of the
// middle (or a greedy forward match when the middle is too large).
func matchBlocks(base, body []string) [][2]int {
	var pre [][2]int
	i, j := 0, 0
	for ; i < len(base) && j < len(body) && base[i] != "" && base[i] == body[j]; i, j = i+1, j+1 {
		pre = append(pre, [2]int{i, j})
	}
	be, ne := len(base), len(body)
	var suf [][2]int
	for be > i && ne > j && base[be-1] != "" && base[be-1] == body[ne-1] {
		be, ne = be-1, ne-1
		suf = append([][2]int{{be, ne}}, suf...)
	}
	mid := middleMatch(base[i:be], body[j:ne])
	for k := range mid {
		mid[k][0] += i
		mid[k][1] += j
	}
	return append(append(pre, mid...), suf...)
}

func middleMatch(base, body []string) [][2]int {
	if len(base)*len(body) > maxLCSCells {
		return greedyMatch(base, body)
	}
	return lcs(base, body)
}

func greedyMatch(base, body []string) [][2]int {
	var out [][2]int
	i := 0
	for j, t := range body {
		for k := i; k < len(base); k++ {
			if base[k] != "" && base[k] == t {
				out = append(out, [2]int{k, j})
				i = k + 1
				break
			}
		}
	}
	return out
}

func lcs(base, body []string) [][2]int {
	n, m := len(base), len(body)
	dp := make([][]int32, n+1)
	for x := range dp {
		dp[x] = make([]int32, m+1)
	}
	for x := n - 1; x >= 0; x-- {
		for y := m - 1; y >= 0; y-- {
			if base[x] != "" && base[x] == body[y] {
				dp[x][y] = dp[x+1][y+1] + 1
			} else {
				dp[x][y] = max(dp[x+1][y], dp[x][y+1])
			}
		}
	}
	var out [][2]int
	for x, y := 0, 0; x < n && y < m; {
		switch {
		case base[x] != "" && base[x] == body[y]:
			out = append(out, [2]int{x, y})
			x, y = x+1, y+1
		case dp[x+1][y] >= dp[x][y+1]:
			x++
		default:
			y++
		}
	}
	return out
}
