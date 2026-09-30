// Package confluence converts Confluence storage-format XHTML (pages, blog
// posts, comments) into the sectioned plain text internal/extsync stores
// (spec docs/superpowers/specs/2026-09-26-confluence-knowledge-connector-design.md
// §7). This file has no dependency on the Confluence REST client — it is a
// pure text transform.
package confluence

import (
	stdhtml "html" // EscapeString only; golang.org/x/net/html owns the "html" name below.
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"

	"golang.org/x/net/html"
	"golang.org/x/net/html/atom"

	"watchtower/internal/extsync"
	"watchtower/internal/jira"
)

// MentionPrefix is the fixed prefix of a user-mention token. The full token
// is "@[~<accountId>]" (controller ruling R3) — never change this shape, the
// KB matches it at index time with the regexp `@\[~([^\]]+)\]` to resolve
// display names from ext_users.
const MentionPrefix = "@[~"

// truncatedMarker is the section appended when the body is cut at maxRunes.
const truncatedMarker = "[truncated]"

// wsRun matches a run of one or more whitespace characters (space, tab,
// newline, ...), collapsed to a single separator by normalizeWS/HeadingAnchor.
var wsRun = regexp.MustCompile(`\s+`)

// StorageToSections converts Confluence storage-format XHTML into sections
// split at h1-h3. User mentions become "@[~<accountId>]" tokens (resolved to
// names at index time from ext_users); returned userIDs lists them. jiraKeys
// lists issue keys from Jira macros and plain text (deduped, in order) — on
// the fallback path below, plain-text keys only (no ac:name="jira" macro
// parsing, since fallbackText renders no structure), so doc_links still picks
// up whatever keys the page's raw text names.
//
// ParseFragment's HTML5 algorithm tolerates arbitrarily malformed input (there
// is no equivalent of an XML well-formedness error) with one exception:
// golang.org/x/net/html caps its open-element stack at 512 nodes and returns
// an error past that depth (storage_depth_test.go). parseErr is non-nil only
// in that case; sections/jiraKeys still carry a best-effort tag-blind text
// strip (fallbackText) rather than an empty page, so a pathologically deep or
// malformed document is still searchable by its text and still links its
// Jira mentions — userIDs is always nil on this path, since a mention token
// only ever comes from an ac:link/ri:user element the fallback never parses.
// Callers should log a non-nil parseErr — there is no useful recovery action,
// since re-parsing the same input gives the same result.
func StorageToSections(xhtml string, maxRunes int) (sections []extsync.Section, userIDs []string, jiraKeys []string, parseErr error) {
	nodes, err := parseFragment(xhtml)
	if err != nil {
		text := fallbackText(xhtml)
		c := &converter{}
		c.scanJiraKeys(text)
		return capSections(oneSection(text), maxRunes), nil, c.jiraKeys, err
	}
	c := &converter{}
	nodes = flattenTransparent(nodes)
	sections = capSections(c.splitSections(nodes), maxRunes)
	return sections, c.userIDs, c.jiraKeys, nil
}

// oneSection wraps text as the one-section shape the rest of the pipeline
// expects ("" text = no section, matching capSections' input convention
// elsewhere in this file).
func oneSection(text string) []extsync.Section {
	if text == "" {
		return nil
	}
	return []extsync.Section{{Text: text}}
}

// fallbackSkipTags carry no document text in fallbackText, matching
// internal/extract's stripHTML — a raw <script>/<style> occasionally
// survives a paste into a Confluence page.
var fallbackSkipTags = map[string]bool{"script": true, "style": true}

// fallbackText renders xhtml's visible text with the raw tokenizer alone,
// ignoring all structure (headings, tables, macros): used only when
// parseFragment's tree builder gives up. It stays linear in len(xhtml) — no
// tree, no open-element stack — so a document that overflowed the tree
// builder's depth cap still costs no more than a normal scan.
func fallbackText(xhtml string) string {
	z := html.NewTokenizer(strings.NewReader(escapeCDATASections(xhtml)))
	var b strings.Builder
	skip := 0
	for {
		switch z.Next() {
		case html.ErrorToken:
			return normalizeWS(b.String())
		case html.TextToken:
			if skip == 0 {
				b.Write(z.Text())
				b.WriteByte(' ')
			}
		case html.StartTagToken, html.SelfClosingTagToken, html.EndTagToken:
			tok := z.Token()
			if !fallbackSkipTags[tok.Data] {
				continue
			}
			if tok.Type == html.StartTagToken {
				skip++
			} else if tok.Type == html.EndTagToken {
				skip = max(skip-1, 0)
			}
		case html.CommentToken, html.DoctypeToken:
		}
	}
}

// HeadingAnchor is Confluence Cloud's in-page anchor for a heading text: trim,
// collapse internal whitespace to "-", keep letters/digits (Unicode, so
// Cyrillic etc. survive) and -_. , drop every other character. This is an
// approximation of Confluence's own slug rule, pinned by TestHeadingAnchor —
// it is not guaranteed byte-identical to what Confluence itself generates.
func HeadingAnchor(heading string) string {
	dashed := wsRun.ReplaceAllString(strings.TrimSpace(heading), "-")
	var b strings.Builder
	for _, r := range dashed {
		if unicode.IsLetter(r) || unicode.IsDigit(r) || r == '-' || r == '_' || r == '.' {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// parseFragment parses xhtml as a body fragment: the returned nodes are the
// top-level siblings of the (virtual) body, in document order. CDATA
// sections are neutralized before ANY tokenizer pass runs over the document
// (normalizeSelfClosing included — it tokenizes too, and would hit the same
// bogus-comment misparse escapeCDATASections exists to avoid).
func parseFragment(xhtml string) ([]*html.Node, error) {
	safe := normalizeSelfClosing(escapeCDATASections(xhtml))
	return html.ParseFragment(strings.NewReader(safe), &html.Node{
		Type:     html.ElementNode,
		Data:     "body",
		DataAtom: atom.Body,
	})
}

// cdataStart/cdataEnd delimit a CDATA section (used by ac:plain-text-body/
// ac:plain-text-link-body for code/noformat/link-body content). XHTML forbids
// the literal sequence "]]>" inside CDATA content, so the first occurrence
// of cdataEnd after cdataStart reliably terminates the section — a lone
// "]]" not followed by '>' is ordinary content and is left alone.
const (
	cdataStart = "<![CDATA["
	cdataEnd   = "]]>"
)

// escapeCDATASections rewrites every "<![CDATA[...]]>" span in xhtml into
// its HTML-escaped text, in place of the CDATA syntax itself.
//
// HTML5 (which is what golang.org/x/net/html's tokenizer implements, not
// XML) has no CDATA section outside foreign SVG/MathML content: it treats
// "<![CDATA[" as the start of a "bogus comment" — and unlike a real
// comment, a bogus comment ends at the first '>', not at "]]>". A CDATA
// body containing '>' (any code sample using ->, >=, generics, HTML, shell
// redirects, ...) would otherwise be truncated right there, with the
// remainder — including the literal "]]>" — leaking into the document and
// getting re-tokenized as tag soup (verified: a literal <div> inside an
// unterminated code body was parsed as a real, nested <div> element).
// Escaping first means the tokenizer only ever sees plain, safe character
// data for that span; the parser unescapes it back to the exact original
// bytes when building the resulting TextNode, so the code body's content —
// including its internal whitespace — survives byte-for-byte.
func escapeCDATASections(xhtml string) string {
	var b strings.Builder
	SplitCDATA(xhtml, func(raw, body string, isCDATA bool) {
		if isCDATA {
			b.WriteString(stdhtml.EscapeString(body))
			return
		}
		b.WriteString(raw)
	})
	return b.String()
}

// SplitCDATA is the single place that finds CDATA sections in storage
// XHTML: it calls fn for each consecutive piece of xhtml, in order, with
// isCDATA telling a "<![CDATA[...]]>" section apart from the markup around
// it. raw is the piece's exact bytes (concatenating every raw reproduces
// xhtml byte for byte); body is the CDATA content without its delimiters
// (equal to raw for a non-CDATA piece). Empty non-CDATA pieces are skipped.
// An unterminated section (malformed input) runs to the end of xhtml, with
// no closing delimiter to strip. escapeCDATASections (the converter) and
// internal/confluenceedit (the byte-exact editor, which must tokenize the
// markup around a section without ever handing the section itself to the
// HTML5 tokenizer) both build on it, so the rule lives here once.
func SplitCDATA(xhtml string, fn func(raw, body string, isCDATA bool)) {
	rest := xhtml
	for rest != "" {
		i := strings.Index(rest, cdataStart)
		if i < 0 {
			fn(rest, rest, false)
			return
		}
		if i > 0 {
			fn(rest[:i], rest[:i], false)
		}
		body := rest[i+len(cdataStart):]
		j := strings.Index(body, cdataEnd)
		if j < 0 {
			// Unterminated CDATA: the remainder is the section's body, and
			// the loop stops rather than scanning forever.
			fn(rest[i:], body, true)
			return
		}
		end := i + len(cdataStart) + j + len(cdataEnd)
		fn(rest[i:end], body[:j], true)
		rest = rest[end:]
	}
}

// alwaysSelfClosingByName are non-namespaced tag names that real Confluence
// storage format also always self-closes with no children — unlike ac:*/
// ri:* below, these need listing by name since they carry no ':' to key on.
// "time" is the date lozenge (<time datetime="2026-09-01" />); it is not a
// void element in HTML5, so left alone it stays open and swallows whatever
// follows as its children (see normalizeSelfClosing's doc).
var alwaysSelfClosingByName = map[string]bool{"time": true}

// normalizeSelfClosing rewrites every self-closing tag whose name contains
// ':' (ac:*/ri:* — real Confluence storage format self-closes these
// everywhere: <ri:user .../>, <ac:structured-macro ac:name="toc" .../>, ...)
// or is listed in alwaysSelfClosingByName, into an explicit start+end tag
// pair before handing the document to html.ParseFragment.
//
// The HTML5 parsing algorithm ParseFragment implements has no concept of
// XML-style self-closing on a non-void custom element: a trailing "/>" on
// e.g. <ri:user .../> is silently ignored and the element is left OPEN, so
// every sibling that follows in the source (a heading, a paragraph, ...)
// becomes a descendant of that "self-closed" element instead of a sibling —
// for a macro that is dropped outright (like toc), this silently swallows
// the rest of the document; for <time />, it swallows the rest of its
// surrounding phrase and its datetime attribute is never read at all
// (renderTime never runs on a node that isn't the empty, attribute-bearing
// element the source actually wrote). Rewriting at the tokenizer level,
// before the tree builder ever runs, sidesteps that HTML5 rule entirely
// rather than working around its effects after the fact (e.g. with a
// regex, which cannot reliably tell a real tag from one that only looks
// like one inside a CDATA/comment/attribute value).
func normalizeSelfClosing(xhtml string) string {
	z := html.NewTokenizer(strings.NewReader(xhtml))
	var b strings.Builder
	for {
		tt := z.Next()
		if tt == html.ErrorToken {
			break // io.EOF (the normal end) or a tokenizer error; either way, stop.
		}
		tok := z.Token()
		if tt == html.SelfClosingTagToken && (strings.Contains(tok.Data, ":") || alwaysSelfClosingByName[tok.Data]) {
			start := tok
			start.Type = html.StartTagToken
			b.WriteString(start.String())
			b.WriteString(html.Token{Type: html.EndTagToken, Data: tok.Data}.String())
			continue
		}
		b.WriteString(tok.String())
	}
	return b.String()
}

// transparentContainers are Confluence Cloud layout wrappers with no text of
// their own: their content should be treated as if it sat directly at the
// level their parent occupies, so a heading inside a layout cell still
// starts a section. flattenTransparent recurses into them (arbitrarily
// nested layouts included) before splitSections ever looks for a heading.
var transparentContainers = map[string]bool{
	"ac:layout": true, "ac:layout-section": true, "ac:layout-cell": true,
}

func flattenTransparent(nodes []*html.Node) []*html.Node {
	var out []*html.Node
	for _, n := range nodes {
		if n.Type == html.ElementNode && transparentContainers[n.Data] {
			var children []*html.Node
			for ch := n.FirstChild; ch != nil; ch = ch.NextSibling {
				children = append(children, ch)
			}
			out = append(out, flattenTransparent(children)...)
			continue
		}
		out = append(out, n)
	}
	return out
}

// converter accumulates the side outputs (mentioned user ids, Jira issue
// keys) discovered while rendering one document.
type converter struct {
	userIDs  []string
	userSeen map[string]bool
	jiraKeys []string
	jiraSeen map[string]bool
}

func (c *converter) addUser(id string) {
	if id == "" {
		return
	}
	if c.userSeen == nil {
		c.userSeen = make(map[string]bool)
	}
	if c.userSeen[id] {
		return
	}
	c.userSeen[id] = true
	c.userIDs = append(c.userIDs, id)
}

func (c *converter) addJiraKey(key string) {
	if key == "" {
		return
	}
	if c.jiraSeen == nil {
		c.jiraSeen = make(map[string]bool)
	}
	if c.jiraSeen[key] {
		return
	}
	c.jiraSeen[key] = true
	c.jiraKeys = append(c.jiraKeys, key)
}

// scanJiraKeys records every plain-text Jira key found in text (reusing the
// key detector's regexp with no known-project filtering — storage.go has no
// DB access, so unlike jira.KeyDetector every syntactically valid key is
// collected).
func (c *converter) scanJiraKeys(text string) {
	for _, m := range jira.KeyRegexp.FindAllString(text, -1) {
		c.addJiraKey(m)
	}
}

// isHeading reports whether tag is a section-splitting heading (h1-h3 only;
// spec §7 — deeper headings render as ordinary block text).
func isHeading(tag string) bool {
	return tag == "h1" || tag == "h2" || tag == "h3"
}

// splitSections walks the top-level nodes once, starting a new section at
// every h1-h3 and rendering everything else into the current section's body.
func (c *converter) splitSections(nodes []*html.Node) []extsync.Section {
	var out []extsync.Section
	cur := extsync.Section{}
	var body []string

	flush := func() {
		if cur.Heading == "" && len(body) == 0 {
			return // an empty leading section (doc starts on a heading) is not emitted
		}
		cur.Text = strings.Join(append([]string{}, prependNonEmpty(cur.Heading, body)...), "\n")
		out = append(out, cur)
	}

	for _, n := range nodes {
		if n.Type != html.ElementNode {
			continue
		}
		if isHeading(n.Data) {
			flush()
			heading := c.inlineText(n)
			cur = extsync.Section{Heading: heading, Anchor: HeadingAnchor(heading)}
			body = nil
			continue
		}
		if text := c.renderBlock(n); text != "" {
			body = append(body, text)
		}
	}
	flush()
	return out
}

// prependNonEmpty puts heading as the first line ahead of body when it is
// non-empty ("heading text is the section's first line" — spec §7).
func prependNonEmpty(heading string, body []string) []string {
	if heading == "" {
		return body
	}
	return append([]string{heading}, body...)
}

// renderBlock renders one top-level-shaped node into its section text (zero,
// one or several lines). Dispatch table by tag, so each branch stays small.
func (c *converter) renderBlock(n *html.Node) string {
	switch n.Data {
	case "p", "h4", "h5", "h6":
		return c.inlineText(n)
	case "table":
		return c.renderTable(n)
	case "ul", "ol":
		return strings.Join(c.renderListItems(n, 0), "\n")
	case "ac:structured-macro":
		return c.renderMacro(n)
	case "ac:task-list":
		return c.renderTaskList(n)
	case "time":
		return c.renderTime(n)
	case "ac:image":
		return "" // images are dropped (spec §7)
	case "script", "style":
		return "" // never page content; not worth indexing even if present
	default:
		return c.renderChildren(n)
	}
}

// renderTime renders a date lozenge's datetime attribute ("2026-09-01"),
// falling back to any child text on the rare node that carries no attribute
// (never written by Confluence itself, but not worth an empty string over).
func (c *converter) renderTime(n *html.Node) string {
	if dt := attrValue(n, "datetime"); dt != "" {
		return dt
	}
	return c.inlineText(n)
}

// renderTaskList renders an ac:task-list's ac:task children as "- " lines,
// each carrying only its ac:task-body text — the ac:task-id/ac:task-uuid/
// ac:task-status identifiers are Confluence bookkeeping, not page content,
// so they are read (task-status, to prefix a completed task) but never
// rendered verbatim.
func (c *converter) renderTaskList(n *html.Node) string {
	var lines []string
	for ch := n.FirstChild; ch != nil; ch = ch.NextSibling {
		if ch.Type == html.ElementNode && ch.Data == "ac:task" {
			lines = append(lines, c.renderTask(ch))
		}
	}
	return strings.Join(lines, "\n")
}

func (c *converter) renderTask(task *html.Node) string {
	status, body := "", ""
	for ch := task.FirstChild; ch != nil; ch = ch.NextSibling {
		if ch.Type != html.ElementNode {
			continue
		}
		switch ch.Data {
		case "ac:task-status":
			status = normalizeWS(c.inlineChildren(ch))
		case "ac:task-body":
			body = c.inlineText(ch)
		}
	}
	if status == "complete" {
		return "- [x] " + body
	}
	return "- " + body
}

// renderChildren treats an unrecognized element as a transparent container
// and renders each child block in turn, joined by newlines.
func (c *converter) renderChildren(n *html.Node) string {
	var lines []string
	for ch := n.FirstChild; ch != nil; ch = ch.NextSibling {
		switch ch.Type {
		case html.TextNode:
			if t := normalizeWS(ch.Data); t != "" {
				c.scanJiraKeys(t)
				lines = append(lines, t)
			}
		case html.ElementNode:
			if t := c.renderBlock(ch); t != "" {
				lines = append(lines, t)
			}
		default:
			// Comments, doctypes, etc. carry no renderable text.
		}
	}
	return strings.Join(lines, "\n")
}

// normalizeWS collapses any run of whitespace to a single space and trims
// the ends (spec §7: "whitespace normalized").
func normalizeWS(s string) string {
	return strings.TrimSpace(wsRun.ReplaceAllString(s, " "))
}

// inlineText renders n's children as one normalized line of text, scanning
// the result for plain-text Jira keys. Used for headings, paragraphs, table
// cells, list items and macro parameters.
func (c *converter) inlineText(n *html.Node) string {
	text := normalizeWS(c.inlineChildren(n))
	c.scanJiraKeys(text)
	return text
}

// inlineChildren concatenates the rendered inline content of n's children
// with no normalization (callers normalize once, at the top of the phrase).
func (c *converter) inlineChildren(n *html.Node) string {
	var b strings.Builder
	for ch := n.FirstChild; ch != nil; ch = ch.NextSibling {
		switch ch.Type {
		case html.TextNode:
			b.WriteString(ch.Data)
		case html.ElementNode:
			b.WriteString(c.inlineElement(ch))
		default:
			// Comments, doctypes, etc. carry no renderable text.
		}
	}
	return b.String()
}

// inlineElement dispatches the inline-context elements that need special
// handling; anything else is a transparent formatting wrapper (strong, em,
// a, span, code, ...) whose children are rendered as more inline content.
func (c *converter) inlineElement(n *html.Node) string {
	switch n.Data {
	case "br":
		return " "
	case "p", "li", "div":
		// A block-level element appearing in an inline context (a table
		// cell wrapping its text in <p>, a list nested for cell content,
		// ...) needs an explicit separator around it, or two adjacent ones
		// (<p>A</p><p>B</p>, or two <li> siblings) fuse into "AB" with no
		// space at all; normalizeWS collapses the extra spacing back down.
		return " " + c.inlineChildren(n) + " "
	case "ac:link":
		return c.renderLink(n)
	case "ac:structured-macro":
		return c.renderMacro(n)
	case "time":
		return c.renderTime(n)
	case "ac:image":
		return ""
	case "script", "style":
		return "" // never page content; not worth indexing even if present
	default:
		return c.inlineChildren(n)
	}
}

// renderLink renders an ac:link: a user mention (ri:user/ri:account-id) wins
// unconditionally (a mention chip never carries a link body in practice);
// otherwise an explicit link body (ac:plain-text-link-body/ac:link-body) —
// what the page actually shows as the link's visible text, for a page link,
// a URL link (ri:url), or anything else — wins over a page's bare
// ri:content-title, which is only a fallback for a page link with no body.
func (c *converter) renderLink(n *html.Node) string {
	if user := firstChildByTag(n, "ri:user"); user != nil {
		if id := attrValue(user, "ri:account-id"); id != "" {
			c.addUser(id)
			return MentionPrefix + id + "]"
		}
	}
	if body := c.linkBodyText(n); body != "" {
		return body
	}
	if page := firstChildByTag(n, "ri:page"); page != nil {
		return attrValue(page, "ri:content-title")
	}
	return ""
}

// linkBodyText returns an ac:link's ac:plain-text-link-body/ac:link-body
// content, or "" when neither is present.
func (c *converter) linkBodyText(n *html.Node) string {
	if b := firstChildByTag(n, "ac:plain-text-link-body"); b != nil {
		return normalizeWS(plainText(b))
	}
	if b := firstChildByTag(n, "ac:link-body"); b != nil {
		return c.inlineText(b)
	}
	return ""
}

// renderTable renders every row (inside thead/tbody/tfoot or bare) as one
// line, cells joined by " | " (spec §7: header row + rows kept).
func (c *converter) renderTable(n *html.Node) string {
	var rows []string
	c.collectTableRows(n, &rows)
	return strings.Join(rows, "\n")
}

func (c *converter) collectTableRows(n *html.Node, rows *[]string) {
	for ch := n.FirstChild; ch != nil; ch = ch.NextSibling {
		if ch.Type != html.ElementNode {
			continue
		}
		switch ch.Data {
		case "tr":
			*rows = append(*rows, c.renderTableRow(ch))
		case "thead", "tbody", "tfoot":
			c.collectTableRows(ch, rows)
		}
	}
}

func (c *converter) renderTableRow(tr *html.Node) string {
	var cells []string
	for ch := tr.FirstChild; ch != nil; ch = ch.NextSibling {
		if ch.Type == html.ElementNode && (ch.Data == "td" || ch.Data == "th") {
			cells = append(cells, c.inlineText(ch))
		}
	}
	return strings.Join(cells, " | ")
}

// renderListItems renders a ul/ol's own <li> children as "- " lines indented
// two spaces per level; a nested ul/ol inside an <li> recurses at level+1.
func (c *converter) renderListItems(list *html.Node, level int) []string {
	var lines []string
	indent := strings.Repeat("  ", level)
	for li := list.FirstChild; li != nil; li = li.NextSibling {
		if li.Type != html.ElementNode || li.Data != "li" {
			continue
		}
		text, nested := c.splitListItem(li)
		lines = append(lines, indent+"- "+text)
		for _, n := range nested {
			lines = append(lines, c.renderListItems(n, level+1)...)
		}
	}
	return lines
}

// splitListItem separates an <li>'s own inline text from any nested ul/ol
// (which the caller renders as separate, deeper lines).
func (c *converter) splitListItem(li *html.Node) (text string, nested []*html.Node) {
	var b strings.Builder
	for ch := li.FirstChild; ch != nil; ch = ch.NextSibling {
		if ch.Type == html.ElementNode && (ch.Data == "ul" || ch.Data == "ol") {
			nested = append(nested, ch)
			continue
		}
		switch ch.Type {
		case html.TextNode:
			b.WriteString(ch.Data)
		case html.ElementNode:
			b.WriteString(c.inlineElement(ch))
		default:
			// Comments, doctypes, etc. carry no renderable text.
		}
	}
	text = normalizeWS(b.String())
	c.scanJiraKeys(text)
	return text, nested
}

// macroBodyNames render their ac:rich-text-body / ac:plain-text-body as
// ordinary content: expand/panel/info/note/tip/warning/excerpt (spec §7).
var macroBodyNames = map[string]bool{
	"expand": true, "panel": true, "info": true, "note": true,
	"tip": true, "warning": true, "excerpt": true,
}

// macroDroppedNames are structural macros with no useful body text.
var macroDroppedNames = map[string]bool{
	"toc": true, "children": true, "attachments": true, "gallery": true,
}

// renderMacro dispatches an ac:structured-macro by its ac:name attribute.
func (c *converter) renderMacro(n *html.Node) string {
	name := attrValue(n, "ac:name")
	switch {
	case name == "code" || name == "noformat":
		return c.renderCodeMacro(n)
	case name == "jira":
		return c.renderJiraMacro(n)
	case macroDroppedNames[name]:
		return ""
	case macroBodyNames[name]:
		return c.renderMacroBody(n)
	default:
		// Unknown macro: default to rendering its body when it has one,
		// since dropping unrecognized content silently would make search
		// miss text the owner can see on the page.
		return c.renderMacroBody(n)
	}
}

// renderCodeMacro extracts a code/noformat macro's ac:plain-text-body
// verbatim (only the outer whitespace is trimmed — internal line breaks and
// indentation are the whole point of a code block, so they are kept, unlike
// the blanket normalizeWS rule applied everywhere else).
func (c *converter) renderCodeMacro(n *html.Node) string {
	body := firstChildByTag(n, "ac:plain-text-body")
	if body == nil {
		return ""
	}
	text := strings.TrimSpace(plainText(body))
	c.scanJiraKeys(text)
	return text
}

// renderJiraMacro reads the macro's ac:parameter[name=key] value, records it
// as a Jira key and renders it as the macro's own text.
func (c *converter) renderJiraMacro(n *html.Node) string {
	for ch := n.FirstChild; ch != nil; ch = ch.NextSibling {
		if ch.Type == html.ElementNode && ch.Data == "ac:parameter" && attrValue(ch, "ac:name") == "key" {
			key := normalizeWS(c.inlineChildren(ch))
			c.addJiraKey(key)
			return key
		}
	}
	return ""
}

// renderMacroBody renders an ac:rich-text-body (as ordinary nested blocks),
// an ac:plain-text-body (verbatim text), or — for a macro with neither, like
// the status lozenge, which carries only ac:parameter children — its
// ac:parameter[ac:name="title"] value (e.g. "DONE"/"BLOCKED").
func (c *converter) renderMacroBody(n *html.Node) string {
	if body := firstChildByTag(n, "ac:rich-text-body"); body != nil {
		return c.renderChildren(body)
	}
	if body := firstChildByTag(n, "ac:plain-text-body"); body != nil {
		return normalizeWS(plainText(body))
	}
	return c.macroTitleParameter(n)
}

// macroTitleParameter returns a macro's ac:parameter[ac:name="title"] text,
// or "" when it has none.
func (c *converter) macroTitleParameter(n *html.Node) string {
	for ch := n.FirstChild; ch != nil; ch = ch.NextSibling {
		if ch.Type == html.ElementNode && ch.Data == "ac:parameter" && attrValue(ch, "ac:name") == "title" {
			return c.inlineText(ch)
		}
	}
	return ""
}

// attrValue returns n's attribute value for key, or "" when absent. Element
// and attribute names arrive lowercased from the html package; attribute
// VALUES keep their original case.
func attrValue(n *html.Node, key string) string {
	for _, a := range n.Attr {
		if a.Key == key {
			return a.Val
		}
	}
	return ""
}

// firstChildByTag returns n's first direct child element named tag, or nil.
func firstChildByTag(n *html.Node, tag string) *html.Node {
	for ch := n.FirstChild; ch != nil; ch = ch.NextSibling {
		if ch.Type == html.ElementNode && ch.Data == tag {
			return ch
		}
	}
	return nil
}

// plainText concatenates n's direct TextNode children's raw data. Used for
// ac:plain-text-body/ac:plain-text-link-body, whose content is CDATA in a
// real Confluence export: escapeCDATASections has already unwrapped that
// CDATA into ordinary text before the document was ever parsed, so by the
// time this runs it is indistinguishable from plain text, and no
// CDATA-specific handling is needed here. A CommentNode child (a real HTML
// comment the body happens to contain, not CDATA) is deliberately skipped —
// a comment is not page content.
func plainText(n *html.Node) string {
	var b strings.Builder
	for ch := n.FirstChild; ch != nil; ch = ch.NextSibling {
		if ch.Type == html.TextNode {
			b.WriteString(ch.Data)
		}
	}
	return b.String()
}

// capSections enforces the maxRunes budget over the sections' Text fields
// (spec §7: "body capped ... a truncation marker section is appended when
// cut"). Whole sections are kept while they fit; the section that would
// overflow is cut to the remaining budget (dropped outright if no budget is
// left), then a trailing {Text: "[truncated]"} marker section is appended.
func capSections(sections []extsync.Section, maxRunes int) []extsync.Section {
	if maxRunes <= 0 {
		return sections
	}
	total := 0
	for i, s := range sections {
		n := utf8.RuneCountInString(s.Text)
		if total+n <= maxRunes {
			total += n
			continue
		}
		out := append([]extsync.Section{}, sections[:i]...)
		if cut := truncateRunes(s.Text, maxRunes-total); cut != "" {
			kept := s
			kept.Text = cut
			out = append(out, kept)
		}
		out = append(out, extsync.Section{Text: truncatedMarker})
		return out
	}
	return sections
}

// truncateRunes returns s cut to at most n runes ("" when n <= 0).
func truncateRunes(s string, n int) string {
	if n <= 0 {
		return ""
	}
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n])
}
