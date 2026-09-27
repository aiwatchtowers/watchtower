package chat

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"unicode/utf8"
)

// Attachment size limits (spec §7.1). Mirrored in Swift
// AttachmentValidator.imageLimit/pdfLimit/textLimit — change both sides together.
const (
	MaxImageBytes int64 = 5 << 20
	MaxPDFBytes   int64 = 32 << 20
	MaxTextBytes  int64 = 256 << 10
)

// MaxTurnAttachmentEncodedBytes caps the owner's files of one turn as they
// travel to the provider: images and PDFs base64-encoded (4/3 of their size),
// text inline. One API request cannot carry much more, so a set over the cap
// is rejected up front as attachment_unsupported instead of failing at the
// provider as a retryable internal error. Go-only (the Swift per-file limits
// cannot see the whole set); a single PDF over ~22 MB is over it on its own.
const MaxTurnAttachmentEncodedBytes int64 = 30 << 20

// AttachmentError is a per-file rejection. The session maps it to the
// protocol error code "attachment_unsupported" (not retryable).
type AttachmentError struct {
	Name   string
	Reason string
}

func (e *AttachmentError) Error() string {
	return fmt.Sprintf("attachment %q: %s", e.Name, e.Reason)
}

type attachmentKind int

const (
	kindText attachmentKind = iota
	kindImage
	kindPDF
)

type loadedAttachment struct {
	kind      attachmentKind
	mediaType string
	name      string
	data      []byte
}

var attachmentImageTypes = map[string]bool{
	"image/png": true, "image/jpeg": true, "image/gif": true, "image/webp": true,
}

var attachmentTextMimes = map[string]bool{
	"application/json": true, "application/yaml": true, "application/x-yaml": true,
	"application/xml": true, "application/toml": true,
}

func isTextMime(m string) bool {
	m = strings.ToLower(strings.TrimSpace(strings.Split(m, ";")[0]))
	return strings.HasPrefix(m, "text/") || attachmentTextMimes[m]
}

// classifyAttachment decides by content first: a sniffed image/PDF wins over
// whatever mime the caller declared; only non-binary content falls back to
// the declared mime to qualify as text.
func classifyAttachment(sniffed, declared string) (kind attachmentKind, mediaType string, limit int64, ok bool) {
	base := strings.TrimSpace(strings.Split(sniffed, ";")[0])
	switch {
	case attachmentImageTypes[base]:
		return kindImage, base, MaxImageBytes, true
	case base == "application/pdf":
		return kindPDF, base, MaxPDFBytes, true
	case isTextMime(declared):
		return kindText, declared, MaxTextBytes, true
	}
	return 0, "", 0, false
}

// loadAttachment validates and reads one file. textOnly rejects images/PDFs
// before their bytes are read (codex/ollama cannot take them).
//
// The path is resolved exactly once: O_NOFOLLOW refuses a symlink outright,
// and every check after the open (regular-file, sniff, size) runs against
// that same file descriptor rather than re-resolving the path — a file
// swapped or grown between separate stat/open/read calls cannot bypass the
// size limit this way. The read itself is capped at limit+1 bytes via
// io.LimitReader regardless of what stat reported, so a file that grows
// after the open is still never read past the limit.
func loadAttachment(a Attachment, textOnly bool) (loadedAttachment, error) {
	name := a.Name
	if name == "" {
		name = filepath.Base(a.Path)
	}
	reject := func(reason string) (loadedAttachment, error) {
		return loadedAttachment{}, &AttachmentError{Name: name, Reason: reason}
	}
	if !filepath.IsAbs(a.Path) {
		return reject("path is not absolute")
	}
	f, size, reason := openRegularNoFollow(a.Path)
	if reason != "" {
		return reject(reason)
	}
	defer func() { _ = f.Close() }()
	head, err := readHead(f)
	if err != nil {
		return reject(errUnreadable)
	}
	kind, media, limit, ok := classifyAttachment(http.DetectContentType(head), a.Mime)
	if !ok {
		return reject(fmt.Sprintf("unsupported file type %q (images, PDFs and text files only)", a.Mime))
	}
	if textOnly && kind != kindText {
		return reject("images and PDFs need the Claude provider")
	}
	if size > limit {
		return reject(fmt.Sprintf("file is %d bytes; the limit for this type is %d", size, limit))
	}
	data, reason := readCapped(f, limit)
	if reason != "" {
		return reject(reason)
	}
	if kind == kindText && !utf8.Valid(data) {
		return reject("text file is not UTF-8")
	}
	return loadedAttachment{kind: kind, mediaType: media, name: name, data: data}, nil
}

const errUnreadable = "file not found or unreadable"

// openRegularNoFollow opens path once with O_NOFOLLOW and checks, on that
// descriptor, that it is a regular file. A non-empty reason means rejected
// (and nothing is left open).
func openRegularNoFollow(path string) (*os.File, int64, string) {
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, 0, errUnreadable
	}
	info, err := f.Stat()
	if err != nil {
		_ = f.Close()
		return nil, 0, errUnreadable
	}
	if !info.Mode().IsRegular() {
		_ = f.Close()
		return nil, 0, "not a regular file"
	}
	return f, info.Size(), ""
}

// readHead reads up to the first 512 bytes (the content-sniffing window).
func readHead(f *os.File) ([]byte, error) {
	head := make([]byte, 512)
	n, err := io.ReadFull(f, head)
	if err != nil && !errors.Is(err, io.ErrUnexpectedEOF) && !errors.Is(err, io.EOF) {
		return nil, err
	}
	return head[:n], nil
}

// readCapped rewinds f and reads it whole, never past limit+1 bytes, so a
// file that grew after the size check is still rejected.
func readCapped(f *os.File, limit int64) ([]byte, string) {
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		return nil, errUnreadable
	}
	data, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil {
		return nil, errUnreadable
	}
	if int64(len(data)) > limit {
		return nil, fmt.Sprintf("file grew past the %d-byte limit for this type while it was being read", limit)
	}
	return data, ""
}

type attBase64Source struct {
	Type      string `json:"type"`
	MediaType string `json:"media_type"`
	Data      string `json:"data"`
}

type attMediaBlock struct {
	Type   string          `json:"type"`
	Source attBase64Source `json:"source"`
}

type attTextBlock struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

func attachmentHeaderName(name string) string {
	return strings.NewReplacer(`"`, "'", "\n", " ", "\r", " ", "<", "(", ">", ")").Replace(name)
}

// fileCloseTagRe matches a literal closing tag that a text attachment's own
// content could contain: any case, and optional whitespace after "<", after
// "/", and before ">" (so "</ file>", "</FILE >" and "< /file>" all count —
// not just the byte-exact "</file>").
var fileCloseTagRe = regexp.MustCompile(`(?i)<\s*/\s*file\s*>`)

// breakFileCloseTags defuses a literal "</file>" inside attachment content
// by splitting it with a zero-width space: without this, a text file could
// close its own <file> wrapper early and inject text that reads as if it
// came from the owner, past the file boundary (M5).
func breakFileCloseTags(content string) string {
	return fileCloseTagRe.ReplaceAllString(content, "<\u200b/file>")
}

func inlineFile(name, content string) string {
	return fmt.Sprintf("<file name=\"%s\">\n%s\n</file>", attachmentHeaderName(name), breakFileCloseTags(content))
}

// encodedSize is the attachment's size in the request: base64 for images and
// PDFs, the raw text for text files.
func (l loadedAttachment) encodedSize() int64 {
	if l.kind == kindText {
		return int64(len(l.data))
	}
	return int64(base64.StdEncoding.EncodedLen(len(l.data)))
}

func (l loadedAttachment) block() (json.RawMessage, error) {
	var v any
	switch l.kind {
	case kindImage:
		v = attMediaBlock{Type: "image", Source: attBase64Source{Type: "base64", MediaType: l.mediaType, Data: base64.StdEncoding.EncodeToString(l.data)}}
	case kindPDF:
		v = attMediaBlock{Type: "document", Source: attBase64Source{Type: "base64", MediaType: "application/pdf", Data: base64.StdEncoding.EncodeToString(l.data)}}
	default:
		v = attTextBlock{Type: "text", Text: inlineFile(l.name, string(l.data))}
	}
	b, err := json.Marshal(v)
	if err != nil {
		return nil, fmt.Errorf("encoding attachment %q: %w", l.name, err)
	}
	return b, nil
}

// BuildContentBlocks turns the turn's attachments into Claude content blocks:
// images → "image", PDFs → "document", text-like → an inlined "text" block
// with a <file name="…"> header. The first bad file aborts with
// *AttachmentError, and so does the file that takes the set's encoded total
// past MaxTurnAttachmentEncodedBytes.
func BuildContentBlocks(atts []Attachment) ([]json.RawMessage, error) {
	blocks := make([]json.RawMessage, 0, len(atts))
	var total int64
	for _, a := range atts {
		l, err := loadAttachment(a, false)
		if err != nil {
			return nil, err
		}
		if total += l.encodedSize(); total > MaxTurnAttachmentEncodedBytes {
			return nil, &AttachmentError{Name: l.name, Reason: fmt.Sprintf(
				"the message's files come to %d MB encoded; one message carries at most %d MB — send fewer or smaller files",
				(total+(1<<20)-1)>>20, MaxTurnAttachmentEncodedBytes>>20)}
		}
		b, err := l.block()
		if err != nil {
			return nil, err
		}
		blocks = append(blocks, b)
	}
	return blocks, nil
}

// claudeUserContent: attachments first (the API's recommended order), then the
// text; an all-whitespace text is omitted (an empty text block is rejected).
// lead are already-built blocks placed before the attachments (the project
// files of a fresh session's first turn).
func claudeUserContent(lead []json.RawMessage, text string, atts []Attachment) ([]json.RawMessage, error) {
	own, err := BuildContentBlocks(atts)
	if err != nil {
		return nil, err
	}
	blocks := append(append(make([]json.RawMessage, 0, len(lead)+len(own)+1), lead...), own...)
	if strings.TrimSpace(text) != "" {
		b, err := json.Marshal(attTextBlock{Type: "text", Text: text})
		if err != nil {
			return nil, fmt.Errorf("encoding user text: %w", err)
		}
		blocks = append(blocks, b)
	}
	return blocks, nil
}

type claudeUserEnvelopeMessage struct {
	Role    string            `json:"role"`
	Content []json.RawMessage `json:"content"`
}

type claudeUserEnvelope struct {
	Type    string                    `json:"type"`
	Message claudeUserEnvelopeMessage `json:"message"`
}

// claudeUserMessageLine renders one stream-json stdin line (with trailing
// newline) for a user turn.
func claudeUserMessageLine(text string, atts []Attachment) ([]byte, error) {
	return claudeUserMessageLineWith(nil, text, atts)
}

// claudeUserMessageLineWith is claudeUserMessageLine with lead blocks first.
// The only place the Claude backend builds a user line.
func claudeUserMessageLineWith(lead []json.RawMessage, text string, atts []Attachment) ([]byte, error) {
	content, err := claudeUserContent(lead, text, atts)
	if err != nil {
		return nil, err
	}
	line, err := json.Marshal(claudeUserEnvelope{Type: "user", Message: claudeUserEnvelopeMessage{Role: "user", Content: content}})
	if err != nil {
		return nil, fmt.Errorf("encoding claude user message: %w", err)
	}
	return append(line, '\n'), nil
}

// InlineTextAttachments is the codex/ollama path: text-like files are inlined
// ahead of the user text; any image/PDF is an *AttachmentError before the call.
func InlineTextAttachments(text string, atts []Attachment) (string, error) {
	if len(atts) == 0 {
		return text, nil
	}
	parts := make([]string, 0, len(atts)+1)
	for _, a := range atts {
		l, err := loadAttachment(a, true)
		if err != nil {
			return "", err
		}
		parts = append(parts, inlineFile(l.name, string(l.data)))
	}
	parts = append(parts, text)
	return strings.Join(parts, "\n\n"), nil
}

// attachmentErrorEvent maps an *AttachmentError to the protocol error event.
func attachmentErrorEvent(turnID string, err error) (Event, bool) {
	var ae *AttachmentError
	if !errors.As(err, &ae) {
		return Event{}, false
	}
	return errorEvent(turnID, CodeAttachmentUnsupported, ae.Error(), false), true
}
