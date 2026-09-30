package confluenceedit

import (
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

// Storage XHTML for edited content. Text is HTML-escaped; a marker is put
// back as its original bytes; a link whose href the replaced content
// already carried reuses that link's original start tag.

var (
	textEscaper = strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;")
	attrEscaper = strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&quot;")
)

// unitXHTML is the storage for a unit's content span.
func (a *applier) unitXHTML(u *unit, links map[string]string) string {
	if u.kind == unitCode {
		return cdata(u.text)
	}
	return a.inlineXHTML(u.text, u.marks, links)
}

// cdata wraps s in CDATA, splitting every "]]>" across two sections (the
// same split confluence.SplitCDATA reads back as one body).
func cdata(s string) string {
	return "<![CDATA[" + strings.ReplaceAll(s, "]]>", "]]]]><![CDATA[>") + "]]>"
}

func codeMacro(lang, body string) string {
	var b strings.Builder
	b.WriteString(`<ac:structured-macro ac:name="code" ac:schema-version="1">`)
	if lang != "" {
		b.WriteString(`<ac:parameter ac:name="language">` + textEscaper.Replace(lang) + `</ac:parameter>`)
	}
	b.WriteString(`<ac:plain-text-body>` + cdata(body) + `</ac:plain-text-body></ac:structured-macro>`)
	return b.String()
}

func (a *applier) blockXHTML(bl *block, links map[string]string) string {
	switch bl.kind {
	case blockHeading:
		tag := "h" + strconv.Itoa(bl.level)
		return "<" + tag + ">" + a.unitXHTML(bl.unit, links) + "</" + tag + ">"
	case blockCode:
		return codeMacro(bl.lang, bl.unit.text)
	case blockMarker:
		return a.orig.markers[bl.marker-1].Raw
	case blockList:
		var b strings.Builder
		for i := 0; i < len(bl.items); {
			var s string
			s, i = a.listXHTML(bl.items, i, links)
			b.WriteString(s)
		}
		return b.String()
	case blockTable:
		return a.tableXHTML(bl, links)
	case blockParagraph:
	}
	return "<p>" + a.unitXHTML(bl.unit, links) + "</p>"
}

// listXHTML emits the list starting at items[i]: consecutive items at its
// depth with the same kind of bullet, each followed by its deeper items as
// nested lists. It returns the index after the list.
func (a *applier) listXHTML(items []listItem, i int, links map[string]string) (string, int) {
	depth, ordered := items[i].depth, items[i].bullet != "-"
	var b strings.Builder
	b.WriteString(listOpen(items[i]))
	for i < len(items) && items[i].depth == depth && (items[i].bullet != "-") == ordered {
		b.WriteString("<li>")
		for _, u := range items[i].paras {
			b.WriteString(a.unitXHTML(u, links))
		}
		i++
		for i < len(items) && items[i].depth > depth {
			var s string
			s, i = a.listXHTML(items, i, links)
			b.WriteString(s)
		}
		b.WriteString("</li>")
	}
	if ordered {
		b.WriteString("</ol>")
	} else {
		b.WriteString("</ul>")
	}
	return b.String(), i
}

func listOpen(first listItem) string {
	if first.bullet == "-" {
		return "<ul>"
	}
	if n := strings.TrimSuffix(first.bullet, "."); n != "1" {
		return `<ol start="` + n + `">`
	}
	return "<ol>"
}

func (a *applier) tableXHTML(bl *block, links map[string]string) string {
	var b strings.Builder
	b.WriteString("<table><tbody>")
	for i, row := range bl.rows {
		tag := "td"
		if i == 0 && bl.header {
			tag = "th"
		}
		b.WriteString("<tr>")
		for _, u := range row {
			b.WriteString("<" + tag + ">" + a.unitXHTML(u, links) + "</" + tag + ">")
		}
		b.WriteString("</tr>")
	}
	b.WriteString("</tbody></table>")
	return b.String()
}

// inlineXHTML converts one unit's editable text: every real marker becomes
// a NUL-delimited hole (NUL never occurs in unit text), each line is
// trimmed and parsed, and lines are joined by <br/>.
func (a *applier) inlineXHTML(text string, marks []mark, links map[string]string) string {
	var holed strings.Builder
	prev := 0
	for _, m := range marks {
		holed.WriteString(text[prev:m.at])
		holed.WriteString("\x00" + strconv.Itoa(m.k) + "\x00")
		prev = m.at + len(a.orig.markers[m.k-1].token())
	}
	holed.WriteString(text[prev:])
	lines := strings.Split(holed.String(), "\n")
	for i, l := range lines {
		p := &inlineParser{a: a, links: links, failedLink: map[int]bool{}}
		lines[i] = p.parse(strings.Trim(l, " \t"), 0, 0)
	}
	return strings.Join(lines, "<br/>")
}

// maxInlineDepth bounds emphasis/link nesting; deeper delimiters are text.
const maxInlineDepth = 32

// inlineParser is a tolerant parser of the inline subset: **bold**,
// _italic_, ~~strike~~, `code`, [text](href) and marker holes. An opening
// delimiter with no valid closer is literal text, so page text with a
// stray "*" or "_" survives a rewrite of the paragraph it sits in.
type inlineParser struct {
	a          *applier
	links      map[string]string
	failedLink map[int]bool // line offsets of "](" whose link failed to parse
}

// frame is one nesting level: s is a slice of the line starting at base.
type frame struct {
	s        string
	depth    int
	base     int
	noCloser map[string]bool // delimiters with no closer left in s
	noCode   map[int]bool    // backtick run lengths with no closing run left
	noMid    bool            // no "](" left in s
	nextMid  int             // the first "](" after lastOpen (valid when > lastOpen)
	lastOpen int
}

var delimTags = map[string]string{"**": "strong", "~~": "s", "_": "em"}

func (p *inlineParser) parse(s string, depth, base int) string {
	f := &frame{s: s, depth: depth, base: base, noCloser: map[string]bool{}, noCode: map[int]bool{}}
	var b strings.Builder
	for i := 0; i < len(s); {
		out, next := p.token(f, i)
		b.WriteString(out)
		i = next
	}
	return b.String()
}

// token converts the construct starting at f.s[i] and returns the index
// after it.
func (p *inlineParser) token(f *frame, i int) (string, int) {
	s := f.s
	switch {
	case s[i] == 0:
		return p.hole(s, i)
	case s[i] == '`':
		return p.codeSpan(f, i)
	case s[i] == '[' && f.depth < maxInlineDepth:
		if out, next, ok := p.link(f, i); ok {
			return out, next
		}
	case f.depth < maxInlineDepth:
		if d := delimAt(s, i); d != "" {
			if out, next, ok := p.emphasis(f, i, d); ok {
				return out, next
			}
			return textEscaper.Replace(d), i + len(d)
		}
	}
	_, w := utf8.DecodeRuneInString(s[i:])
	return textEscaper.Replace(s[i : i+w]), i + w
}

func delimAt(s string, i int) string {
	for _, d := range []string{"**", "~~", "_"} {
		if strings.HasPrefix(s[i:], d) {
			return d
		}
	}
	return ""
}

// hole emits a marker's original bytes.
func (p *inlineParser) hole(s string, i int) (string, int) {
	j := strings.IndexByte(s[i+1:], 0)
	if j < 0 {
		return "", len(s) // unreachable: holes are written in pairs
	}
	k, _ := strconv.Atoi(s[i+1 : i+1+j])
	return p.a.orig.markers[k-1].Raw, i + j + 2
}

// codeSpan: a run of n backticks up to the next run of exactly n; the
// content is verbatim (one padding space each side stripped, CommonMark).
func (p *inlineParser) codeSpan(f *frame, i int) (string, int) {
	s := f.s
	n := len(s[i:]) - len(strings.TrimLeft(s[i:], "`"))
	fence := s[i : i+n]
	for j := i + n; j < len(s) && !f.noCode[n]; {
		k := strings.Index(s[j:], fence)
		if k < 0 {
			break
		}
		k += j
		run := len(s[k:]) - len(strings.TrimLeft(s[k:], "`"))
		if run == n {
			return "<code>" + p.codeText(unpad(s[i+n:k])) + "</code>", k + n
		}
		j = k + run
	}
	f.noCode[n] = true
	return fence, i + n
}

func unpad(c string) string {
	if len(c) >= 2 && c[0] == ' ' && c[len(c)-1] == ' ' && strings.Trim(c, " ") != "" {
		return c[1 : len(c)-1]
	}
	return c
}

// codeText escapes code-span content, putting marker holes back as-is.
func (p *inlineParser) codeText(c string) string {
	var b strings.Builder
	for i := 0; i < len(c); {
		if c[i] == 0 {
			out, next := p.hole(c, i)
			b.WriteString(out)
			i = next
			continue
		}
		j := strings.IndexByte(c[i:], 0)
		if j < 0 {
			j = len(c) - i
		}
		b.WriteString(textEscaper.Replace(c[i : i+j]))
		i += j
	}
	return b.String()
}

// emphasis parses delimiter d opening at s[i]. The opener must be followed
// by a non-space; the closer preceded by one; "_" additionally may not
// touch a letter or digit on its outer side (snake_case stays text).
func (p *inlineParser) emphasis(f *frame, i int, d string) (string, int, bool) {
	s := f.s
	if f.noCloser[d] || !opens(s, i, d) {
		return "", 0, false
	}
	for j := i + len(d) + 1; j <= len(s)-len(d); j++ {
		if strings.HasPrefix(s[j:], d) && closes(s, j, d) {
			inner := p.parse(s[i+len(d):j], f.depth+1, f.base+i+len(d))
			tag := delimTags[d]
			return "<" + tag + ">" + inner + "</" + tag + ">", j + len(d), true
		}
	}
	f.noCloser[d] = true // no closer after i means none after any later opener
	return "", 0, false
}

func opens(s string, i int, d string) bool {
	next, _ := utf8.DecodeRuneInString(s[i+len(d):])
	if i+len(d) >= len(s) || unicode.IsSpace(next) {
		return false
	}
	if d == "_" && i > 0 {
		prev, _ := utf8.DecodeLastRuneInString(s[:i])
		return !isWordRune(prev)
	}
	return true
}

func closes(s string, j int, d string) bool {
	prev, _ := utf8.DecodeLastRuneInString(s[:j])
	if unicode.IsSpace(prev) {
		return false
	}
	if d == "_" && j+1 < len(s) {
		next, _ := utf8.DecodeRuneInString(s[j+1:])
		return !isWordRune(next)
	}
	return true
}

func isWordRune(r rune) bool { return unicode.IsLetter(r) || unicode.IsDigit(r) }

// link parses [text](href): text up to the first "](", href up to the ")"
// that balances its parentheses. An empty href is not a link.
func (p *inlineParser) link(f *frame, i int) (string, int, bool) {
	s := f.s
	mid, ok := f.midAfter(i)
	if !ok {
		return "", 0, false
	}
	if p.failedLink[f.base+mid] {
		return "", 0, false
	}
	end := hrefEnd(s, mid+2)
	if end < 0 || end == mid+2 || strings.IndexByte(s[mid+2:end], 0) >= 0 {
		p.failedLink[f.base+mid] = true
		return "", 0, false
	}
	href := s[mid+2 : end]
	tag, ok := p.links[href]
	if !ok {
		tag = `<a href="` + attrEscaper.Replace(href) + `">`
	}
	return tag + p.parse(s[i+1:mid], f.depth+1, f.base+i+1) + "</a>", end + 1, true
}

// midAfter finds the first "](" after s[i]. Every "[" before a known "]("
// shares it, so the scan runs once per "](" rather than once per "[".
func (f *frame) midAfter(i int) (int, bool) {
	if f.noMid {
		return 0, false
	}
	if f.nextMid > i {
		return f.nextMid, true
	}
	rel := strings.Index(f.s[i+1:], "](")
	if rel < 0 {
		f.noMid = true // none after i means none after any later "["
		return 0, false
	}
	f.nextMid = i + 1 + rel
	return f.nextMid, true
}

// maxHref bounds the scan for an href's closing ")", so a line of
// unbalanced "[a](" stays linear.
const maxHref = 4096

// hrefEnd is the index of the ")" closing an href starting at s[from], or
// -1.
func hrefEnd(s string, from int) int {
	depth := 0
	for j := from; j < len(s) && j-from <= maxHref; j++ {
		switch s[j] {
		case '(':
			depth++
		case ')':
			if depth == 0 {
				return j
			}
			depth--
		}
	}
	return -1
}
