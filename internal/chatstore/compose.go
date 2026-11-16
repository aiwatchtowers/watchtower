package chatstore

import (
	"strconv"
	"strings"
	"unicode"

	"github.com/rivo/uniseg"

	"watchtower/internal/skills"
)

// Mention is one entity the owner picked with `@` (Swift MentionCandidate):
// stored as `<kind>:<id> "<label>"` on the REFERENCED line.
type Mention struct {
	Kind  string `json:"kind"`
	ID    string `json:"id"`
	Label string `json:"label"`
}

// Quote is one passage of an answer in the reply batch (Swift
// ChatQuoteDraft): the quoted text and the owner's optional comment on it.
// MessageID names the answer it was taken from; the composed text does not
// carry it.
type Quote struct {
	MessageID int64  `json:"message_id"`
	Text      string `json:"text"`
	Comment   string `json:"comment,omitempty"`
}

// Compose is what the composer adds around the typed text: a `/` skill, the
// `@` mentions and the quote batch (Swift ChatTurnComposer + ChatQuoteReply).
type Compose struct {
	Skill    string    `json:"skill,omitempty"`
	Mentions []Mention `json:"mentions"`
	Quotes   []Quote   `json:"quotes"`
}

// mentionKinds is Swift MentionCandidate.Kind.
var mentionKinds = map[string]bool{"person": true, "channel": true, "jira": true, "linear": true, "target": true, "track": true}

// Valid reports whether c is a composition the Mac's composer can make: a
// valid skill name, known mention kinds with an id, and non-blank quotes.
func (c *Compose) Valid() bool {
	if c == nil {
		return true
	}
	if c.Skill != "" && !skills.ValidName(c.Skill) {
		return false
	}
	for _, m := range c.Mentions {
		if !mentionKinds[m.Kind] || m.ID == "" {
			return false
		}
	}
	for _, q := range c.Quotes {
		if swiftTrim(q.Text) == "" {
			return false
		}
	}
	return true
}

// empty: c adds nothing to the typed text.
func (c *Compose) empty() bool {
	return c == nil || (c.Skill == "" && len(c.Mentions) == 0 && len(c.Quotes) == 0)
}

// ComposeOwnerText is the stored (and sent) owner text of a send: the quote
// batch with the typed text as its note (ChatQuoteReply.compose ?? typed),
// then the skill line and the REFERENCED line around it
// (ChatTurnComposer.compose). The shared fixture
// internal/chatengine/testdata/compose_cases.json pins it to the Swift twin.
func ComposeOwnerText(text string, c Compose) string {
	return composeTurn(quotedText(text, c.Quotes), c.Skill, c.Mentions)
}

// QuoteBatchHeader is ChatQuoteReply.batchHeader.
const QuoteBatchHeader = "About these parts of your answers:"

// quotedText is ChatQuoteReply.compose(quotes:typed:) ?? typed.
func quotedText(typed string, quotes []Quote) string {
	items := make([]batchItem, len(quotes))
	for i, q := range quotes {
		items[i] = batchItem{quote: q.Text, comment: q.Comment}
	}
	if s, ok := commentBatch(QuoteBatchHeader, items, "", typed); ok {
		return s
	}
	return typed
}

// composeTurn is ChatTurnComposer.compose(text:skill:mentions:).
func composeTurn(text, skill string, mentions []Mention) string {
	var parts []string
	if skill != "" {
		parts = append(parts, skillLinePrefix+skill+skillLineSuffix)
	}
	if body := escapedBody(swiftTrim(text), skill != "", len(mentions) > 0); body != "" {
		parts = append(parts, body)
	}
	if len(mentions) > 0 {
		refs := make([]string, len(mentions))
		for i, m := range mentions {
			refs[i] = m.Kind + ":" + m.ID + ` "` + escapeLabel(sanitizeLabel(m.Label)) + `"`
		}
		parts = append(parts, referencedPrefix+strings.Join(refs, "; "))
	}
	return strings.Join(parts, "\n\n")
}

// sanitizeLabel is MentionCandidate.sanitized: a label is one line.
func sanitizeLabel(s string) string {
	return strings.NewReplacer("\r\n", " ", "\n", " ", "\r", " ").Replace(s)
}

// escapeLabel is ChatTurnComposer.escape.
func escapeLabel(s string) string {
	return strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(s)
}

// CommentItem is one artifact comment for ComposeArtifactComments.
type CommentItem struct {
	Quote, Heading, Body string
}

// ComposeArtifactComments is ArtifactCommentMessage.compose: the one owner
// message "Send N comments" sends, the comments in the given order; "" when
// there are none.
func ComposeArtifactComments(title, key string, version int, comments []CommentItem) string {
	if len(comments) == 0 {
		return ""
	}
	name := title
	if swiftTrim(title) == "" {
		name = key
	}
	items := make([]batchItem, len(comments))
	for i, c := range comments {
		items[i] = batchItem{quote: c.Quote, heading: c.Heading, comment: c.Body}
	}
	s, _ := commentBatch(`Comments on the artifact "`+name+`" (key="`+key+`", version `+strconv.Itoa(version)+`):`, items,
		"Please reply with a new version of this artifact under the same key that addresses these comments.", "")
	return s
}

type batchItem struct {
	quote, heading, comment string
}

// commentBatch is CommentBatchComposer.compose: header, the numbered items
// and closing (only with items), then the trimmed note, joined by blank
// lines; false when nothing is left.
func commentBatch(header string, items []batchItem, closing, note string) (string, bool) {
	var blocks []string
	if len(items) > 0 {
		if header != "" {
			blocks = append(blocks, header)
		}
		for i, it := range items {
			place := "On this passage:"
			if it.heading != "" {
				place = `Under "` + it.heading + `":`
			}
			lines := []string{strconv.Itoa(i+1) + ". " + place, blockquote(it.quote)}
			if c := swiftTrim(it.comment); c != "" {
				lines = append(lines, c)
			}
			blocks = append(blocks, strings.Join(lines, "\n"))
		}
		if closing != "" {
			blocks = append(blocks, closing)
		}
	}
	if n := swiftTrim(note); n != "" {
		blocks = append(blocks, n)
	}
	if len(blocks) == 0 {
		return "", false
	}
	return strings.Join(blocks, "\n\n"), true
}

// blockquote is CommentBatchComposer.blockquote: the trimmed text, each line
// (split on the "\n" character; "\r\n" is one other character) without its
// trailing whitespace and prefixed "> ", a blank line kept as ">".
func blockquote(text string) string {
	lines := splitNewlineChars(swiftTrim(text))
	for i, l := range lines {
		kept := strings.TrimRightFunc(l, unicode.IsSpace)
		if kept == "" {
			lines[i] = ">"
		} else {
			lines[i] = "> " + kept
		}
	}
	return strings.Join(lines, "\n")
}

// splitNewlineChars splits s on every "\n" character as Swift counts them
// (a "\r\n" grapheme is not one), keeping empty pieces.
func splitNewlineChars(s string) []string {
	var out []string
	start := 0
	g := uniseg.NewGraphemes(s)
	for g.Next() {
		if g.Str() == "\n" {
			from, to := g.Positions()
			out = append(out, s[start:from])
			start = to
		}
	}
	return append(out, s[start:])
}
