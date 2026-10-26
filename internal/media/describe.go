// Package media turns images and web links found in synced content into
// knowledge: a stored description or summary the search index renders.
package media

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"regexp"
	"slices"
	"strings"
	"unicode"
	"unicode/utf8"

	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// ErrBadOutput marks a model reply that is not the prompt's JSON shape: a
// failed attempt, not a description.
var ErrBadOutput = errors.New("media: the model's reply is not the expected JSON")

// Caps on what is stored, in runes, applied after control characters are
// stripped; and on the page text sent to the model.
const (
	maxTitleRunes       = 120
	maxDescriptionRunes = 4000
	maxImageTextRunes   = 4000
	maxSummaryRunes     = 1200
	maxPageTextRunes    = 20000
	maxKeys             = 50
	maxKeyRunes         = 200
)

// keyShape is what a kept key looks like: a Jira-style issue key or an
// http(s) URL.
var keyShape = regexp.MustCompile(`^(?:[A-Z][A-Z0-9]+-\d+|https?://\S+)$`)

// describeUserMessage is the whole text sent with an image: no channel,
// page or sender name, so nothing ties the bytes to another context.
const describeUserMessage = "Describe the attached image. Reply with the JSON object only."

// Description is an image's stored description. Text is the image's own
// words, verbatim; Keys are issue keys and URLs that occur in Text.
type Description struct {
	Title, Body, Text string
	Keys              []string
}

// Summary is a fetched page's stored summary.
type Summary struct {
	Title, Body string
}

// DescribeImage describes the image at path (one of the media types the
// model takes) with the media.describe prompt. The reply is third-party
// data: it is parsed, cleaned and capped, never acted on.
func DescribeImage(ctx context.Context, g digest.ImageGenerator, store *prompts.Store, path, mediaType string) (Description, *digest.Usage, error) {
	system := resolvePrompt(store, prompts.MediaDescribe)
	raw, usage, err := g.GenerateWithImage(digest.WithSource(ctx, prompts.MediaDescribe), system, describeUserMessage, path, mediaType)
	if err != nil {
		return Description{}, usage, err
	}
	var reply struct {
		Title       string   `json:"title"`
		Description string   `json:"description"`
		Text        string   `json:"text"`
		Keys        []string `json:"keys"`
	}
	if err := decodeStrict(raw, &reply); err != nil {
		return Description{}, usage, err
	}
	d := Description{
		Title: capRunes(cleanLine(reply.Title), maxTitleRunes),
		Body:  capRunes(cleanText(reply.Description), maxDescriptionRunes),
		Text:  capRunes(cleanText(reply.Text), maxImageTextRunes),
	}
	if d.Body == "" {
		return Description{}, usage, fmt.Errorf("%w: empty description", ErrBadOutput)
	}
	for _, k := range reply.Keys {
		if len(d.Keys) == maxKeys {
			break
		}
		k = cleanLine(k)
		if keyShape.MatchString(k) && utf8.RuneCountInString(k) <= maxKeyRunes &&
			strings.Contains(d.Text, k) && !slices.Contains(d.Keys, k) {
			d.Keys = append(d.Keys, k)
		}
	}
	return d, usage, nil
}

// SummarizeLink summarizes a fetched public page with the
// media.summarize_link prompt (light tier). title is the page's own title,
// the fallback when the reply names none; text is capped before sending.
func SummarizeLink(ctx context.Context, g digest.Generator, store *prompts.Store, url, title, text string) (Summary, *digest.Usage, error) {
	system := resolvePrompt(store, prompts.MediaSummarizeLink)
	pageTitle := capRunes(cleanLine(title), maxTitleRunes)
	user := "Page address: " + cleanLine(url) + "\nPage title: " + pageTitle +
		"\n\n=== PAGE TEXT ===\n" + capRunes(cleanText(text), maxPageTextRunes)
	raw, usage, _, err := g.Generate(digest.WithSource(ctx, prompts.MediaSummarizeLink), system, user, "")
	if err != nil {
		return Summary{}, usage, err
	}
	var reply struct {
		Title   string `json:"title"`
		Summary string `json:"summary"`
	}
	if err := decodeStrict(raw, &reply); err != nil {
		return Summary{}, usage, err
	}
	s := Summary{
		Title: capRunes(cleanLine(reply.Title), maxTitleRunes),
		Body:  capRunes(cleanText(reply.Summary), maxSummaryRunes),
	}
	if s.Body == "" {
		return Summary{}, usage, fmt.Errorf("%w: empty summary", ErrBadOutput)
	}
	if s.Title == "" {
		s.Title = pageTitle
	}
	return s, usage, nil
}

func resolvePrompt(store *prompts.Store, id string) string {
	tmpl, _, err := prompts.Resolve(store, id, "")
	if err != nil {
		slog.Warn("media: using the built-in prompt", "id", id, "err", err)
	}
	return tmpl
}

// decodeStrict decodes the reply's JSON object into v: anything after the
// object is an error (ErrBadOutput); extra fields are ignored.
func decodeStrict(raw string, v any) error {
	js, err := prompts.ExtractJSONObject(raw)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrBadOutput, err)
	}
	dec := json.NewDecoder(bytes.NewReader([]byte(js)))
	if err := dec.Decode(v); err != nil {
		return fmt.Errorf("%w: %v", ErrBadOutput, err)
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return fmt.Errorf("%w: data after the JSON object", ErrBadOutput)
	}
	return nil
}

// cleanText drops control characters (newlines and tabs kept), the
// bidirectional-override marks and the zero-width characters that can
// disguise text, and trims.
func cleanText(s string) string {
	return strings.TrimSpace(strings.Map(func(r rune) rune {
		if r == '\n' || r == '\t' {
			return r
		}
		if unicode.IsControl(r) || isBidiControl(r) || isZeroWidth(r) || r == utf8.RuneError {
			return -1
		}
		return r
	}, s))
}

// cleanLine is cleanText on one line: newlines and tabs become spaces and
// runs of spaces collapse.
func cleanLine(s string) string {
	return strings.Join(strings.Fields(cleanText(s)), " ")
}

func isZeroWidth(r rune) bool {
	return (r >= 0x200b && r <= 0x200d) || r == 0x2060 || r == 0xfeff
}

func isBidiControl(r rune) bool {
	return (r >= 0x202a && r <= 0x202e) || (r >= 0x2066 && r <= 0x2069) || r == 0x200e || r == 0x200f || r == 0x061c
}

// capRunes cuts s to at most n runes, on a rune boundary.
func capRunes(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n])
}
