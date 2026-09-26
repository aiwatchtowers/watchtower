package kb

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strings"
	"time"
	"unicode"
)

// ChunkChars is the chunk budget in runes (~512 tokens, Onyx's chunk size).
const ChunkChars = 2000

// Section is one citable unit of a document (a message, a comment, an utterance).
type Section struct {
	Text   string
	Anchor string // source-native locator of this section (message ts, comment id, start_sec)
}

// Doc is one rendered document. ID is its ref.
type Doc struct {
	ID       string
	Source   string
	Title    string
	Meta     string
	Link     string
	Time     time.Time
	Anchor   map[string]string
	Sections []Section
}

// Chunk is a packed run of sections; Anchor is its first section's anchor.
type Chunk struct {
	Idx    int
	Body   string
	Anchor string
}

// BuildChunks packs sections into chunks of at most ChunkChars runes, never
// overlapping. A section longer than the budget is split at the last
// whitespace before the limit (hard split when there is none).
func BuildChunks(sections []Section) []Chunk {
	var chunks []Chunk
	var cur []rune
	curAnchor := ""
	flush := func() {
		body := strings.TrimSpace(string(cur))
		if body != "" {
			chunks = append(chunks, Chunk{Idx: len(chunks), Body: body, Anchor: curAnchor})
		}
		cur, curAnchor = nil, ""
	}
	for _, s := range sections {
		text := []rune(strings.TrimSpace(s.Text))
		if len(text) == 0 {
			continue
		}
		for len(text) > ChunkChars {
			flush()
			cut := splitPoint(text)
			cur, curAnchor = text[:cut], s.Anchor
			flush()
			text = []rune(strings.TrimLeftFunc(string(text[cut:]), unicode.IsSpace))
		}
		if len(text) == 0 {
			continue
		}
		sep := 0
		if len(cur) > 0 {
			sep = 1
		}
		if len(cur)+sep+len(text) > ChunkChars {
			flush()
			sep = 0
		}
		if sep == 1 {
			cur = append(cur, '\n')
		}
		if len(cur) == 0 {
			curAnchor = s.Anchor
		}
		cur = append(cur, text...)
	}
	flush()
	return chunks
}

// splitPoint returns the cut index for an over-budget rune slice: just after
// the last whitespace within the budget, or the budget itself.
func splitPoint(text []rune) int {
	for i := ChunkChars; i > ChunkChars/2; i-- {
		if unicode.IsSpace(text[i-1]) {
			return i
		}
	}
	return ChunkChars
}

// contentHash fingerprints everything written for a document, so an unchanged
// render skips the write (Onyx's gate 2).
func contentHash(d *Doc, chunks []Chunk) string {
	h := sha256.New()
	anchor, _ := json.Marshal(d.Anchor)
	for _, part := range []string{d.Source, d.Title, d.Meta, d.Link, string(anchor), d.Time.UTC().Format(time.RFC3339)} {
		h.Write([]byte(part))
		h.Write([]byte{0})
	}
	for _, c := range chunks {
		h.Write([]byte(c.Body))
		h.Write([]byte{0})
		h.Write([]byte(c.Anchor))
		h.Write([]byte{0})
	}
	return hex.EncodeToString(h.Sum(nil))
}
