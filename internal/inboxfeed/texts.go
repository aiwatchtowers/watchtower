package inboxfeed

import (
	"bytes"
	"strings"

	"github.com/rivo/uniseg"
	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/ast"
	"github.com/yuin/goldmark/extension"
	extast "github.com/yuin/goldmark/extension/ast"
	"github.com/yuin/goldmark/text"
	"github.com/yuin/goldmark/util"
)

// PreviewLimit is the most characters a card's preview holds, "…" included
// (InboxCardTexts.previewLimit).
const PreviewLimit = 140

// TooLargeSentence is the body of a card whose block document is past
// MaxBlocksBytes: it is sent as a notice card.
const TooLargeSentence = "This card is too large to show here. Open it on your Mac."

// builtinNames are the built-ins' names by id as a failed move names them
// (BuiltinUpgradeNotice.names; Go builtin.Entry.Name, and the watch
// recipes' move).
var builtinNames = map[string]string{
	"morning-brief":    "Morning brief",
	"track-my-threads": "Track my threads",
	"idea-finder":      "Idea finder",
	"reactions":        "Reactions",
	"custom-tracks":    "your watched tracks",
}

// noticeTitle is a failed move's title: "Couldn't move Idea finder to
// Automations" (the id itself for a built-in the table does not know).
func noticeTitle(builtinID string) string {
	name, ok := builtinNames[builtinID]
	if !ok {
		name = builtinID
	}
	return "Couldn't move " + name + " to Automations"
}

// cardTitle is an artifact's list title: its own, else its automation's
// name.
func cardTitle(o output) string {
	if o.Title == "" {
		return o.Name
	}
	return o.Title
}

// sourceLine is an artifact's source: its automation's name. The Mac's
// InboxCardTexts.sourceLine appends " · 10:00" (today), " · Oct 18" or, on
// a living card, " · Updated 10 min ago"; that time is the screen models'
// (from Card.Stamp in the client's zone), so the feed sends the source only.
func sourceLine(o output) string { return o.Name }

// priority is high, medium or low; anything else reads as medium
// (InboxCardSubject.priority).
func priority(raw string) string {
	switch raw {
	case "high", "medium", "low":
		return raw
	}
	return "medium"
}

// previewMarkdown parses a body as the chat's MarkdownDocument does
// (CommonMark with the GFM tables, strikethrough, task lists and autolinks).
var previewMarkdown = goldmark.New(goldmark.WithExtensions(
	extension.Table, extension.Strikethrough, extension.TaskList, extension.Linkify))

// Preview is a body as one line of plain text (InboxCardTexts.preview): the
// markdown parsed, its blocks' text joined, whitespace runs made one space,
// and past PreviewLimit characters clipped with "…".
func Preview(markdown string) string {
	src := []byte(markdown)
	doc := previewMarkdown.Parser().Parse(text.NewReader(src))
	var parts []string
	for n := doc.FirstChild(); n != nil; n = n.NextSibling() {
		parts = append(parts, blockText(n, src))
	}
	words := strings.Join(strings.Fields(strings.Join(parts, " ")), " ")
	// Characters as Swift counts them: grapheme clusters, so an emoji
	// sequence counts once and is never cut.
	if uniseg.GraphemeClusterCount(words) <= PreviewLimit {
		return words
	}
	var b strings.Builder
	g := uniseg.NewGraphemes(words)
	for n := 0; n < PreviewLimit-1 && g.Next(); n++ {
		b.WriteString(g.Str())
	}
	return strings.TrimRight(b.String(), " \t") + "…"
}

// literalText is a text segment as the markdown means it: a backslash
// before ASCII punctuation escapes it, and an entity or numeric character
// reference is its character, resolved in one pass (so `\&amp;` stays
// "&amp;"), as cmark-gfm's text nodes hold them.
func literalText(raw []byte) string {
	var b strings.Builder
	for i := 0; i < len(raw); i++ {
		c := raw[i]
		switch {
		case c == '\\' && i+1 < len(raw) && isASCIIPunct(raw[i+1]):
			i++
			b.WriteByte(raw[i])
		case c == '&':
			end := bytes.IndexByte(raw[i:min(len(raw), i+40)], ';')
			if end > 1 {
				ref := raw[i : i+end+1]
				if resolved := util.ResolveEntityNames(util.ResolveNumericReferences(ref)); !bytes.Equal(resolved, ref) {
					b.Write(resolved)
					i += end
					continue
				}
			}
			b.WriteByte(c)
		default:
			b.WriteByte(c)
		}
	}
	return b.String()
}

// isASCIIPunct is CommonMark's ASCII punctuation, the characters a
// backslash escapes.
func isASCIIPunct(c byte) bool {
	return strings.IndexByte("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~", c) >= 0
}

// blockText is one block's plain text (InboxCardTexts.text(MarkdownBlock)).
func blockText(n ast.Node, src []byte) string {
	switch n := n.(type) {
	case *ast.Heading, *ast.Paragraph, *ast.TextBlock:
		return inlineText(n, src)
	case *ast.FencedCodeBlock, *ast.CodeBlock:
		var b strings.Builder
		lines := n.Lines()
		for i := range lines.Len() {
			seg := lines.At(i)
			b.Write(seg.Value(src))
		}
		return strings.TrimSuffix(b.String(), "\n")
	case *ast.HTMLBlock:
		var b strings.Builder
		lines := n.Lines()
		for i := range lines.Len() {
			seg := lines.At(i)
			b.Write(seg.Value(src))
		}
		if n.HasClosure() {
			b.Write(n.ClosureLine.Value(src))
		}
		return b.String()
	case *ast.List, *ast.ListItem, *ast.Blockquote:
		var parts []string
		for c := n.FirstChild(); c != nil; c = c.NextSibling() {
			parts = append(parts, blockText(c, src))
		}
		return strings.Join(parts, " ")
	case *extast.Table:
		var cells []string
		for row := n.FirstChild(); row != nil; row = row.NextSibling() {
			for cell := row.FirstChild(); cell != nil; cell = cell.NextSibling() {
				cells = append(cells, inlineText(cell, src))
			}
		}
		return strings.Join(cells, " ")
	}
	return ""
}

// inlineText is the plain text of n's inline children
// (InboxCardTexts.text([MarkdownInline])): text and code as is, emphasis,
// links and images by their children, every line break a space.
func inlineText(n ast.Node, src []byte) string {
	var b strings.Builder
	for c := n.FirstChild(); c != nil; c = c.NextSibling() {
		switch c := c.(type) {
		case *ast.Text:
			b.WriteString(literalText(c.Segment.Value(src)))
			if c.SoftLineBreak() || c.HardLineBreak() {
				b.WriteByte(' ')
			}
		case *ast.String:
			b.Write(c.Value)
		case *ast.CodeSpan:
			for t := c.FirstChild(); t != nil; t = t.NextSibling() {
				if s, ok := t.(*ast.Text); ok {
					b.Write(s.Segment.Value(src))
				}
			}
		case *ast.AutoLink:
			b.Write(c.Label(src))
		case *ast.RawHTML:
			for i := range c.Segments.Len() {
				seg := c.Segments.At(i)
				b.Write(seg.Value(src))
			}
		case *extast.TaskCheckBox:
			// A task item's box is no text.
		default:
			b.WriteString(inlineText(c, src))
		}
	}
	return b.String()
}
