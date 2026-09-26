package extract

import (
	"bytes"
	"errors"
	"io"
	"strings"
	"unicode/utf8"

	"golang.org/x/net/html"

	"watchtower/internal/extsync"
)

// utf8BOM is stripped from the start of text input.
var utf8BOM = []byte{0xEF, 0xBB, 0xBF}

// readUTF8 reads r (≤ MaxDownload) as UTF-8 text without a BOM, with LF
// line endings. Invalid UTF-8 is StatusFailed, input above MaxDownload
// StatusTooLarge.
func readUTF8(r io.Reader) (text, status string, err error) {
	b, err := readCapped(r)
	if errors.Is(err, errTooLarge) {
		return "", StatusTooLarge, nil
	}
	if err != nil {
		return "", "", err
	}
	b = bytes.TrimPrefix(b, utf8BOM)
	if !utf8.Valid(b) {
		return "", StatusFailed, nil
	}
	s := strings.ReplaceAll(string(b), "\r\n", "\n")
	return strings.ReplaceAll(s, "\r", "\n"), StatusOK, nil
}

// plainText is one section holding the whole text (text, markdown, csv,
// json, xml).
func plainText(r io.Reader) ([]extsync.Section, string, error) {
	text, status, err := readUTF8(r)
	if err != nil || status != StatusOK {
		return nil, status, err
	}
	return oneSection(strings.TrimSpace(text)), StatusOK, nil
}

func oneSection(text string) []extsync.Section {
	if text == "" {
		return nil
	}
	return []extsync.Section{{Text: text}}
}

// htmlText strips an HTML document to its text: tags dropped, block
// elements break lines, whitespace collapsed, <head>/<script>/<style>
// skipped.
func htmlText(r io.Reader) ([]extsync.Section, string, error) {
	text, status, err := readUTF8(r)
	if err != nil || status != StatusOK {
		return nil, status, err
	}
	return oneSection(stripHTML(text)), StatusOK, nil
}

// skippedElements carry no document text.
var skippedElements = map[string]bool{"head": true, "script": true, "style": true, "noscript": true, "template": true}

// blockElements end the current line.
var blockElements = map[string]bool{
	"p": true, "div": true, "br": true, "li": true, "tr": true, "table": true, "ul": true, "ol": true,
	"h1": true, "h2": true, "h3": true, "h4": true, "h5": true, "h6": true, "pre": true, "blockquote": true,
	"section": true, "article": true, "header": true, "footer": true, "hr": true, "dt": true, "dd": true,
	"title": true, "body": true, "main": true, "nav": true, "aside": true, "figcaption": true,
}

func stripHTML(doc string) string {
	z := html.NewTokenizer(strings.NewReader(doc))
	var lines []string
	var cur strings.Builder
	flush := func() {
		if line := strings.Join(strings.Fields(cur.String()), " "); line != "" {
			lines = append(lines, line)
		}
		cur.Reset()
	}
	skip := 0
	for {
		switch z.Next() {
		case html.ErrorToken:
			flush()
			return strings.Join(lines, "\n")
		case html.TextToken:
			if skip == 0 {
				cur.Write(z.Text())
			}
		case html.StartTagToken, html.SelfClosingTagToken, html.EndTagToken:
			skip = htmlTag(z, skip, flush)
		case html.CommentToken, html.DoctypeToken:
		}
	}
}

// htmlTag handles one tag token: it tracks skipped-element depth and ends
// the line at a block element, returning the new skip depth.
func htmlTag(z *html.Tokenizer, skip int, flush func()) int {
	tt := z.Token()
	name := tt.Data
	if skippedElements[name] {
		if tt.Type == html.StartTagToken {
			return skip + 1
		}
		if tt.Type == html.EndTagToken {
			return max(skip-1, 0)
		}
		return skip
	}
	if blockElements[name] {
		flush()
	}
	return skip
}
