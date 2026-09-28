# Chat Redesign — Phase 3: Files & Artifacts (Tasks 20–23)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Attachments (images/PDFs/text) travel from the composer to Claude as native content blocks, and the assistant's drafts/documents/tables become versioned artifacts in a side panel whose actions only open or copy.

**Architecture:** Go reads attachment files named in the `turn` command (stdin, never argv) and turns them into Claude content blocks (`internal/chat/attachments.go`); Swift validates, copies and records files (`ChatAttachmentStore`, `chat_attachments`). Artifacts are parsed from assistant text by a pure streaming-aware Swift parser (`ArtifactParser`), versioned in `chat_artifacts`, and acted on through pure URL/pasteboard builders (`ArtifactActions`) so CHAT-05 is structurally true. The Go prompt contract (`ArtifactsContract()`) and the Swift parser share one example fixture.

**Tech Stack:** Go 1.25 (`net/http.DetectContentType`, `encoding/base64`, `//go:embed`), SwiftUI macOS 14 (`.inspector`, `.dropDestination`, `NSOpenPanel`/`NSSavePanel`), GRDB 7, CryptoKit.

**Spec:** `docs/superpowers/specs/2026-09-26-chat-redesign-design.md` — §7 (files & artifacts), §4.1.5 (artifacts contract), §5 (`attachment_unsupported`), §9 CHAT-04/05. Master plan: `docs/superpowers/plans/2026-09-26-chat-redesign.md` (Global Constraints and binding interfaces apply to every task here).

## Global Constraints (restated from the master plan — binding)

- Everything in the repo in English. Go inner loop `go test ./internal/<pkg>` (no `-count=1`); Swift inner loop `make test-swift FILTER=<TestClass>`; never delete `WatchtowerDesktop/.build`.
- Attachments: images png/jpeg/gif/webp ≤ 5 MB; PDF ≤ 32 MB; text-like ≤ 256 KB; stored under `Config.WorkspaceDir()/chat_files/…` (Swift: `Constants.activeWorkspaceDir()` + `/chat_files`) mode 0600.
- System prompt, user text and attachment paths never on argv (CHAT-04).
- Artifact fence: `:::artifact key="…" kind="…" title="…" [meta attrs]` … `:::`; kinds `document|table|email|slack|event|code`. Artifact actions only open/copy (CHAT-05).
- Error code for a rejected attachment is exactly `attachment_unsupported`, `retryable: false`.
- Guard tests: Swift `testChat05…` for CHAT-05.
- No model names hardcoded in Swift. No TCC-prompting APIs: the general pasteboard is read only inside a user-initiated paste (`paste(_:)`), never polled; files come from `NSOpenPanel`/drag & drop/`NSSavePanel` (user-chosen, no TCC).

## Review Focus owned by this phase

- **#4 (master plan):** `:::artifact` inside a ``` / ~~~ fenced code block is not an artifact; an unterminated artifact at turn end is kept as complete content; Cyrillic and `\"`-escaped attribute values parse. → Task 22 Step 1 tests `testArtifactInsideBacktickFenceIsNotAnArtifact`, `testTildeAndLongerFencesAreRespected`, `testFinalUnterminatedBlockIsKeptComplete`, `testCyrillicTitleAndEscapedQuotes`.
- A file whose declared mime lies (a PNG named `.txt`, a zip named `.png`): both sides classify by magic bytes, not by the declared type. → Task 20 `TestBuildContentBlocks_SniffBeatsDeclaredMime`, Task 21 `testMagicBytesBeatExtension`.
- A draft email longer than a URL can carry: the body is copied to the clipboard and compose opens without it, never silently truncated. → Task 22 `testGmailOverCapCopiesBodyAndOpensWithoutIt`.

## Decisions made in this phase file (binding for Tasks 20–23)

1. **Storage layout:** `chat_files/conversations/<conversation id>/<uuid>.<ext>` and `chat_files/projects/<project id>/<uuid>.<ext>`. Deleting a conversation/project removes its whole directory post-commit.
2. **sha256 dedupe is storage dedupe:** re-attaching an identical file in the same conversation reuses the stored file but always inserts a NEW `chat_attachments` row (so linking it to a later message never steals the row of an earlier one). A stored file is removed only when no row references its path.
3. **Classification by magic bytes on both sides.** Images/PDF are detected from content (Go `http.DetectContentType`, Swift signature check with the same signatures); text-like is decided by the declared mime (Go) / extension list (Swift) plus a UTF-8 check. Limits are mirrored constants pinned by a test on each side.
4. **Artifact versions:** persistence happens once per finished turn (`final: true` parse). Saving key K from message M when K's latest version was produced by the same M and is not an edit overwrites that version in place (idempotent re-persist; the later of two same-key blocks in one message wins); otherwise a new version is inserted. An edit always inserts a new version with `edited = 1`.
5. **Slack artifact meta:** `channel` (the channel id exactly as a tool returned it, namespaced OK), optional `thread_ts`, or `permalink`. `#name` channels are not resolved (copy only). `ArtifactActions.slackTarget(meta:links:)` takes an extra defaulted `links: SlackLinkResolver? = nil` (so `.slackTarget(meta:)` stays callable).
6. **`ArtifactAction` is a value** (`.open(URL)`, `.copyThenOpen(text:url:)`, `.copy(String)`); only the App-side `ArtifactActionPerformer` touches `NSPasteboard`/`NSWorkspace`, and only for URLs `AllowedURLSchemes.permits`.

---

### Task 20: Go attachments → Claude content blocks

**Files:**
- Modify (replace the Task 7 stub wholesale): `internal/chat/attachments.go`
- Modify: `internal/chat/claude_backend.go` (content assembly in `Turn`)
- Modify: `internal/chat/turn_backend.go` (codex/ollama text inlining in `Turn`)
- Modify: `internal/chat/session.go` (map `*AttachmentError` → `attachment_unsupported`)
- Test: `internal/chat/attachments_test.go`, `internal/chat/session_attachments_test.go`

**Interfaces:**
- Consumes (Task 2/7/8): `type Attachment struct{ Path, Mime, Name string }` with JSON tags `path`/`mime`/`name`; `type Command struct{ Type, TurnID, Text string; Attachments []Attachment; Replay bool }`; `type Event struct{ …; Code, Message string; Retryable bool }`; `type Backend interface{ Start(ctx) (string, error); Turn(ctx, Command, func(Event)) error; Cancel() error; Close() error }`; `NewSession(b Backend, w *EventWriter) *Session`, `(*Session).Run(ctx, io.Reader) error`; `NewEventWriter(io.Writer) *EventWriter`.
- Produces:
  - `const MaxImageBytes int64 = 5 << 20`, `MaxPDFBytes int64 = 32 << 20`, `MaxTextBytes int64 = 256 << 10`
  - `type AttachmentError struct{ Name, Reason string }` (`Error() string`)
  - `func BuildContentBlocks(atts []Attachment) ([]json.RawMessage, error)` — never returns a nil slice on success
  - `func InlineTextAttachments(text string, atts []Attachment) (string, error)` — codex/ollama path
  - unexported `claudeUserMessageLine(text string, atts []Attachment) ([]byte, error)` (one stdin JSONL line incl. `\n`), `attachmentErrorEvent(turnID string, err error) (Event, bool)`

- [ ] **Step 1: Write the failing attachment tests**

Create `internal/chat/attachments_test.go`:

```go
package chat

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

var (
	fixturePNG  = []byte("\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR")
	fixturePDF  = []byte("%PDF-1.4\n%fake body\n")
	fixtureWEBP = []byte("RIFF\x00\x00\x00\x00WEBPVP8 ")
	fixtureZIP  = []byte("PK\x03\x04rest-of-zip")
)

func writeAttachmentFixture(t *testing.T, name string, data []byte) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), name)
	require.NoError(t, os.WriteFile(p, data, 0o600))
	return p
}

type attBlockView struct {
	Type   string `json:"type"`
	Text   string `json:"text"`
	Source struct {
		Type      string `json:"type"`
		MediaType string `json:"media_type"`
		Data      string `json:"data"`
	} `json:"source"`
}

func decodeAttBlocks(t *testing.T, raw []json.RawMessage) []attBlockView {
	t.Helper()
	out := make([]attBlockView, 0, len(raw))
	for _, r := range raw {
		var b attBlockView
		require.NoError(t, json.Unmarshal(r, &b))
		out = append(out, b)
	}
	return out
}

func requireAttachmentError(t *testing.T, err error, name string) *AttachmentError {
	t.Helper()
	var ae *AttachmentError
	require.True(t, errors.As(err, &ae), "want *AttachmentError, got %v", err)
	assert.Equal(t, name, ae.Name)
	assert.NotEmpty(t, ae.Reason)
	return ae
}

func TestBuildContentBlocks_ImageBecomesBase64ImageBlock(t *testing.T) {
	p := writeAttachmentFixture(t, "shot.png", fixturePNG)
	blocks, err := BuildContentBlocks([]Attachment{{Path: p, Mime: "image/png", Name: "shot.png"}})
	require.NoError(t, err)
	got := decodeAttBlocks(t, blocks)
	require.Len(t, got, 1)
	assert.Equal(t, "image", got[0].Type)
	assert.Equal(t, "base64", got[0].Source.Type)
	assert.Equal(t, "image/png", got[0].Source.MediaType)
	assert.Equal(t, base64.StdEncoding.EncodeToString(fixturePNG), got[0].Source.Data)
}

func TestBuildContentBlocks_WebPIsAnImage(t *testing.T) {
	p := writeAttachmentFixture(t, "a.webp", fixtureWEBP)
	blocks, err := BuildContentBlocks([]Attachment{{Path: p, Mime: "image/webp", Name: "a.webp"}})
	require.NoError(t, err)
	assert.Equal(t, "image/webp", decodeAttBlocks(t, blocks)[0].Source.MediaType)
}

func TestBuildContentBlocks_PDFBecomesDocumentBlock(t *testing.T) {
	p := writeAttachmentFixture(t, "spec.pdf", fixturePDF)
	blocks, err := BuildContentBlocks([]Attachment{{Path: p, Mime: "application/pdf", Name: "spec.pdf"}})
	require.NoError(t, err)
	got := decodeAttBlocks(t, blocks)
	require.Len(t, got, 1)
	assert.Equal(t, "document", got[0].Type)
	assert.Equal(t, "application/pdf", got[0].Source.MediaType)
	assert.Equal(t, base64.StdEncoding.EncodeToString(fixturePDF), got[0].Source.Data)
}

func TestBuildContentBlocks_TextInlinedWithFilenameHeader(t *testing.T) {
	p := writeAttachmentFixture(t, "notes.md", []byte("# План\n- ship"))
	blocks, err := BuildContentBlocks([]Attachment{{Path: p, Mime: "text/markdown", Name: `my "notes".md`}})
	require.NoError(t, err)
	got := decodeAttBlocks(t, blocks)
	require.Len(t, got, 1)
	assert.Equal(t, "text", got[0].Type)
	// A quote in the name cannot break the header attribute.
	assert.Equal(t, "<file name=\"my 'notes'.md\">\n# План\n- ship\n</file>", got[0].Text)
}

func TestBuildContentBlocks_SniffBeatsDeclaredMime(t *testing.T) {
	p := writeAttachmentFixture(t, "actually-png.txt", fixturePNG)
	blocks, err := BuildContentBlocks([]Attachment{{Path: p, Mime: "text/plain", Name: "actually-png.txt"}})
	require.NoError(t, err)
	assert.Equal(t, "image", decodeAttBlocks(t, blocks)[0].Type)

	zip := writeAttachmentFixture(t, "fake.png", fixtureZIP)
	_, err = BuildContentBlocks([]Attachment{{Path: zip, Mime: "image/png", Name: "fake.png"}})
	requireAttachmentError(t, err, "fake.png")
}

func TestBuildContentBlocks_Rejections(t *testing.T) {
	bigPNG := writeAttachmentFixture(t, "big.png", fixturePNG)
	require.NoError(t, os.Truncate(bigPNG, MaxImageBytes+1))
	bigText := writeAttachmentFixture(t, "big.log", []byte("x"))
	require.NoError(t, os.Truncate(bigText, MaxTextBytes+1))
	binaryText := writeAttachmentFixture(t, "bin.txt", []byte{0xff, 0xfe, 0x00, 0x81})
	zip := writeAttachmentFixture(t, "a.zip", fixtureZIP)
	dir := t.TempDir()
	link := filepath.Join(t.TempDir(), "link.png")
	require.NoError(t, os.Symlink(writeAttachmentFixture(t, "real.png", fixturePNG), link))

	cases := []struct {
		name string
		att  Attachment
	}{
		{"big.png", Attachment{Path: bigPNG, Mime: "image/png", Name: "big.png"}},
		{"big.log", Attachment{Path: bigText, Mime: "text/plain", Name: "big.log"}},
		{"bin.txt", Attachment{Path: binaryText, Mime: "text/plain", Name: "bin.txt"}},
		{"a.zip", Attachment{Path: zip, Mime: "application/zip", Name: "a.zip"}},
		{"rel.png", Attachment{Path: "relative/rel.png", Mime: "image/png", Name: "rel.png"}},
		{"gone.png", Attachment{Path: filepath.Join(dir, "gone.png"), Mime: "image/png", Name: "gone.png"}},
		{"dir", Attachment{Path: dir, Mime: "text/plain", Name: "dir"}},
		{"link.png", Attachment{Path: link, Mime: "image/png", Name: "link.png"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			blocks, err := BuildContentBlocks([]Attachment{tc.att})
			assert.Nil(t, blocks)
			requireAttachmentError(t, err, tc.name)
		})
	}
}

func TestBuildContentBlocks_NameFallsBackToBase(t *testing.T) {
	zip := writeAttachmentFixture(t, "a.zip", fixtureZIP)
	_, err := BuildContentBlocks([]Attachment{{Path: zip, Mime: "application/zip"}})
	requireAttachmentError(t, err, "a.zip")
}

func TestBuildContentBlocks_NoAttachmentsIsEmptyNotNil(t *testing.T) {
	blocks, err := BuildContentBlocks(nil)
	require.NoError(t, err)
	require.NotNil(t, blocks)
	assert.Empty(t, blocks)
}

func TestClaudeUserMessageLine_TextOnly(t *testing.T) {
	line, err := claudeUserMessageLine("hi", nil)
	require.NoError(t, err)
	assert.Equal(t, `{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}`+"\n", string(line))
}

func TestClaudeUserMessageLine_AttachmentsBeforeTextAndEmptyTextOmitted(t *testing.T) {
	p := writeAttachmentFixture(t, "shot.png", fixturePNG)
	line, err := claudeUserMessageLine("what is on it?", []Attachment{{Path: p, Mime: "image/png", Name: "shot.png"}})
	require.NoError(t, err)
	var env struct {
		Type    string `json:"type"`
		Message struct {
			Role    string            `json:"role"`
			Content []json.RawMessage `json:"content"`
		} `json:"message"`
	}
	require.NoError(t, json.Unmarshal(line, &env))
	got := decodeAttBlocks(t, env.Message.Content)
	require.Len(t, got, 2)
	assert.Equal(t, "image", got[0].Type)
	assert.Equal(t, "text", got[1].Type)

	line, err = claudeUserMessageLine("  ", []Attachment{{Path: p, Mime: "image/png", Name: "shot.png"}})
	require.NoError(t, err)
	require.NoError(t, json.Unmarshal(line, &env))
	assert.Len(t, env.Message.Content, 1, "an empty text block would be rejected by the API")
}

func TestInlineTextAttachments_TextInlinedBeforeUserText(t *testing.T) {
	p := writeAttachmentFixture(t, "a.csv", []byte("a,b\n1,2"))
	got, err := InlineTextAttachments("sum column b", []Attachment{{Path: p, Mime: "text/csv", Name: "a.csv"}})
	require.NoError(t, err)
	assert.Equal(t, "<file name=\"a.csv\">\na,b\n1,2\n</file>\n\nsum column b", got)
}

func TestInlineTextAttachments_BinaryRejectedBeforeRead(t *testing.T) {
	p := writeAttachmentFixture(t, "shot.png", fixturePNG)
	_, err := InlineTextAttachments("look", []Attachment{{Path: p, Mime: "image/png", Name: "shot.png"}})
	ae := requireAttachmentError(t, err, "shot.png")
	assert.Contains(t, ae.Reason, "Claude")
}

func TestInlineTextAttachments_NoAttachmentsIsIdentity(t *testing.T) {
	got, err := InlineTextAttachments("plain", nil)
	require.NoError(t, err)
	assert.Equal(t, "plain", got)
}

// Mirrored in Swift AttachmentValidator.imageLimit/pdfLimit/textLimit
// (AttachmentValidatorTests.testLimitsMirrorGo) — change both sides together.
func TestAttachmentLimits_MirrorSwift(t *testing.T) {
	assert.Equal(t, int64(5*1024*1024), MaxImageBytes)
	assert.Equal(t, int64(32*1024*1024), MaxPDFBytes)
	assert.Equal(t, int64(256*1024), MaxTextBytes)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/chat -run 'TestBuildContentBlocks|TestClaudeUserMessageLine|TestInlineTextAttachments|TestAttachmentLimits'`
Expected: FAIL — compile errors (`undefined: MaxImageBytes`, `claudeUserMessageLine`, `InlineTextAttachments`, or the Task 7 stub returning an error for every attachment).

- [ ] **Step 3: Replace `internal/chat/attachments.go` with the real implementation**

(If Task 7's stub already declared `AttachmentError`, this file keeps the same name and fields — replace the whole file.)

```go
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
	"strings"
	"unicode/utf8"
)

// Attachment size limits (spec §7.1). Mirrored in Swift
// AttachmentValidator.imageLimit/pdfLimit/textLimit — change both sides together.
const (
	MaxImageBytes int64 = 5 << 20
	MaxPDFBytes   int64 = 32 << 20
	MaxTextBytes  int64 = 256 << 10
)

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

func readHead(path string, n int) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer func() { _ = f.Close() }()
	buf := make([]byte, n)
	read, err := io.ReadFull(f, buf)
	if err != nil && !errors.Is(err, io.ErrUnexpectedEOF) && !errors.Is(err, io.EOF) {
		return nil, err
	}
	return buf[:read], nil
}

// loadAttachment validates and reads one file. textOnly rejects images/PDFs
// before their bytes are read (codex/ollama cannot take them).
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
	info, err := os.Lstat(a.Path)
	if err != nil {
		return reject("file not found or unreadable")
	}
	if !info.Mode().IsRegular() {
		return reject("not a regular file")
	}
	head, err := readHead(a.Path, 512)
	if err != nil {
		return reject("file not found or unreadable")
	}
	kind, media, limit, ok := classifyAttachment(http.DetectContentType(head), a.Mime)
	if !ok {
		return reject(fmt.Sprintf("unsupported file type %q (images, PDFs and text files only)", a.Mime))
	}
	if textOnly && kind != kindText {
		return reject("images and PDFs need the Claude provider")
	}
	if info.Size() > limit {
		return reject(fmt.Sprintf("file is %d bytes; the limit for this type is %d", info.Size(), limit))
	}
	data, err := os.ReadFile(a.Path)
	if err != nil {
		return reject("file not found or unreadable")
	}
	if int64(len(data)) > limit {
		return reject(fmt.Sprintf("file is %d bytes; the limit for this type is %d", len(data), limit))
	}
	if kind == kindText && !utf8.Valid(data) {
		return reject("text file is not UTF-8")
	}
	return loadedAttachment{kind: kind, mediaType: media, name: name, data: data}, nil
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

func inlineFile(name, content string) string {
	return fmt.Sprintf("<file name=\"%s\">\n%s\n</file>", attachmentHeaderName(name), content)
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
// with a <file name="…"> header. The first bad file aborts with *AttachmentError.
func BuildContentBlocks(atts []Attachment) ([]json.RawMessage, error) {
	blocks := make([]json.RawMessage, 0, len(atts))
	for _, a := range atts {
		l, err := loadAttachment(a, false)
		if err != nil {
			return nil, err
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
func claudeUserContent(text string, atts []Attachment) ([]json.RawMessage, error) {
	blocks, err := BuildContentBlocks(atts)
	if err != nil {
		return nil, err
	}
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
// newline) for a user turn. The only place the Claude backend builds it.
func claudeUserMessageLine(text string, atts []Attachment) ([]byte, error) {
	content, err := claudeUserContent(text, atts)
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
	return Event{Type: "error", TurnID: turnID, Code: "attachment_unsupported", Message: ae.Error(), Retryable: false}, true
}
```

- [ ] **Step 4: Run the attachment tests**

Run: `go test ./internal/chat -run 'TestBuildContentBlocks|TestClaudeUserMessageLine|TestInlineTextAttachments|TestAttachmentLimits'`
Expected: PASS.

- [ ] **Step 5: Write the failing session-mapping test**

Create `internal/chat/session_attachments_test.go`:

```go
package chat

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

type attachmentFailBackend struct{}

func (attachmentFailBackend) Start(context.Context) (string, error) { return "s1", nil }
func (attachmentFailBackend) Turn(context.Context, Command, func(Event)) error {
	return &AttachmentError{Name: "x.zip", Reason: `unsupported file type "application/zip"`}
}
func (attachmentFailBackend) Cancel() error { return nil }
func (attachmentFailBackend) Close() error  { return nil }

func TestSession_AttachmentErrorMapsToAttachmentUnsupported(t *testing.T) {
	var out bytes.Buffer
	s := NewSession(attachmentFailBackend{}, NewEventWriter(&out))
	in := strings.NewReader(`{"type":"turn","turn_id":"t1","text":"hi","attachments":[{"path":"/x.zip","mime":"application/zip","name":"x.zip"}]}` + "\n")
	// Run's return at stdin EOF is Task 7's contract; only the emitted events matter here.
	_ = s.Run(context.Background(), in)

	var errs []Event
	for _, line := range strings.Split(strings.TrimSpace(out.String()), "\n") {
		var e Event
		require.NoError(t, json.Unmarshal([]byte(line), &e), line)
		if e.Type == "error" {
			errs = append(errs, e)
		}
	}
	require.Len(t, errs, 1)
	assert.Equal(t, "t1", errs[0].TurnID)
	assert.Equal(t, "attachment_unsupported", errs[0].Code)
	assert.False(t, errs[0].Retryable)
	assert.Contains(t, errs[0].Message, "x.zip")
}
```

- [ ] **Step 6: Run to verify it fails**

Run: `go test ./internal/chat -run TestSession_AttachmentErrorMapsToAttachmentUnsupported`
Expected: FAIL — the error event carries `internal` (Task 7's generic mapping), not `attachment_unsupported`.

- [ ] **Step 7: Wire the mapping and both backends**

In `internal/chat/session.go`, find the single place where an error returned by `Backend.Turn` becomes an `error` event (the branch that emits `Code: "internal"`). Put this check first:

```go
if ev, ok := attachmentErrorEvent(cmd.TurnID, err); ok {
	s.emit(ev)
} else {
	// existing mapping (ClassifyClaudeError / "internal") unchanged
}
```

(`s.emit` stands for whatever emit call that branch already uses — keep it; only the `attachmentErrorEvent` branch is new.)

In `internal/chat/claude_backend.go` `Turn`, delete the code that builds the user stdin line (including the Task 7 stub call) and write it with the new helper, before anything is written to the child's stdin — a rejected attachment must never reach the `claude` process:

```go
line, err := claudeUserMessageLine(text, cmd.Attachments) // text = cmd.Text, or the replay-prefixed text when cmd.Replay
if err != nil {
	return err // *AttachmentError → attachment_unsupported via the session
}
if _, err := b.stdin.Write(line); err != nil {
	return fmt.Errorf("writing turn to claude: %w", err)
}
```

(`b.stdin` is the backend's existing stdin writer field; keep the variable holding the replay-prefixed text that Task 7 already computes.)

In `internal/chat/turn_backend.go` `Turn`, replace the Task 7/8 blanket "any attachment → attachment_unsupported" check with inlining, placed before the replay prefix is added and before the provider call:

```go
text, err := InlineTextAttachments(cmd.Text, cmd.Attachments)
if err != nil {
	return err
}
// …continue with `text` where the code previously used cmd.Text…
```

- [ ] **Step 8: Run the package tests**

Run: `go test ./internal/chat`
Expected: PASS (new tests plus Task 7/8's session and backend tests; a Task 7 test that asserted "any attachment is rejected" must be updated to use a zip fixture — that behavior was the stub's).

- [ ] **Step 9: Lint**

Run: `make lint-diff`
Expected: no new issues.

- [ ] **Step 10: Commit**

```bash
git add internal/chat/attachments.go internal/chat/attachments_test.go internal/chat/session_attachments_test.go internal/chat/session.go internal/chat/claude_backend.go internal/chat/turn_backend.go
git commit -m "feat(chat): attachments as Claude content blocks, text inlining for other providers

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 21: Swift attachments — validation, store, composer

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/ChatModels.swift` (append `ChatAttachment`, `ChatAttachmentOwner`)
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/AttachmentValidator.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ChatAttachmentQueries.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatAttachmentStore.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ComposerAttachments.swift`
- Create: `WatchtowerDesktop/Sources/Views/Chat/AttachmentChipsView.swift`, `WatchtowerDesktop/Sources/Views/Chat/PastedImage.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Chat/ChatInput.swift`, `WatchtowerDesktop/Sources/Views/Chat/ChatView.swift`, `WatchtowerDesktop/Sources/Views/Chat/MessageBubble.swift`, `WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift`, `WatchtowerDesktop/Sources/ViewModels/ChatHistoryViewModel.swift` (or the Task 15 type that now owns `deleteConversation(_:)`)
- Test: `WatchtowerDesktop/Tests/Core/AttachmentValidatorTests.swift`, `WatchtowerDesktop/Tests/Core/ChatAttachmentStoreTests.swift`, `WatchtowerDesktop/Tests/Core/ComposerAttachmentsTests.swift`, `WatchtowerDesktop/Tests/ChatInputAttachmentTests.swift`, `WatchtowerDesktop/Tests/PastedImageTests.swift`, `WatchtowerDesktop/Tests/ChatHistoryAttachmentCleanupTests.swift`

**Interfaces:**
- Consumes: `chat_attachments(id, conversation_id, project_id, message_id, name, mime, size, path, sha256, created_at)` (migration 00074, mirrored in `Tests/Support/TestDatabase.swift` by Task 10); `Constants.activeWorkspaceDir()`; Task 14 `ChatViewModel.send(text:attachments:mentions:)` and its `ChatTreeQueries.insertUser` write; Task 11 turn command carrying `{path, mime, name}` per attachment.
- Produces:
  - `package struct ChatAttachment` (fields `id, conversationID, projectID, messageID, name, mime, size, path, sha256, createdAt`)
  - `package enum ChatAttachmentOwner { case conversation(Int64), project(Int64) }`
  - `package enum AttachmentKind { case image(mime:), pdf, text(mime:) }` with `.mime`, `.fileExtension(fallbackName:)`; `package enum AttachmentRejection: Error { unsupportedType(fileName:), tooLarge(fileName:limit:), notUTF8(fileName:), unreadable(fileName:) }` with `.message`
  - `AttachmentValidator.validate(url:) -> Result<AttachmentKind, AttachmentRejection>`, `.validate(data:fileName:)`, limits `imageLimit/pdfLimit/textLimit`
  - `ChatAttachmentStore(db:rootDir:)`: `importFile(url:conversationID:)`, `importFile(url:projectID:)`, `importFile(url:owner:)`, `importData(_:name:owner:)`, `discard(_:)`, `directory(for:)`, `static removeFiles(for:rootDir:)`, `static defaultRootDir() -> URL?`
  - `ChatAttachmentQueries`: `insert`, `existingPath`, `link(_:attachmentIDs:messageID:)`, `fetchByMessages(_:messageIDs:) -> [Int64: [ChatAttachment]]`, `delete`, `referenceCount`
  - `ComposerAttachments` (`@MainActor @Observable`): `pending`, `errorMessage`, `add(urls:conversationID:)`, `addPastedImage(_:conversationID:)`, `remove(id:)`, `takeForSend()`
  - `ChatInput`/`ChatInputContent` defaulted params `attachments`, `attachmentError`, `onAttachFiles`, `onPasteImage`, `onRemoveAttachment`; `MessageBubble` defaulted `attachments`

- [ ] **Step 1: Verify the test DB carries the table**

Run: `grep -n "chat_attachments" WatchtowerDesktop/Tests/Support/TestDatabase.swift`
Expected: the `CREATE TABLE chat_attachments` block from Task 10. If absent, copy the `chat_attachments` DDL verbatim from `internal/db/migrations/00074_chat_core.sql` into the `schema` string there before continuing (Task 10 owns the mirror; this only closes a gap).

- [ ] **Step 2: Write the failing validator tests**

Create `WatchtowerDesktop/Tests/Core/AttachmentValidatorTests.swift`:

```swift
import XCTest
@testable import WatchtowerCore

final class AttachmentValidatorTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("att-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13])
    static let pdf = Data("%PDF-1.4\n%fake\n".utf8)
    static let webp = Data("RIFF\0\0\0\0WEBPVP8 ".utf8)
    static let zip = Data([0x50, 0x4B, 0x03, 0x04, 1, 2, 3])

    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func sparse(_ name: String, head: Data, size: Int64) throws -> URL {
        let url = try file(name, head)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
        return url
    }

    func testImagesPdfAndText() throws {
        XCTAssertEqual(try AttachmentValidator.validate(url: file("a.png", Self.png)).get(), .image(mime: "image/png"))
        XCTAssertEqual(try AttachmentValidator.validate(url: file("a.webp", Self.webp)).get(), .image(mime: "image/webp"))
        XCTAssertEqual(try AttachmentValidator.validate(url: file("a.pdf", Self.pdf)).get(), .pdf)
        XCTAssertEqual(try AttachmentValidator.validate(url: file("n.md", Data("# План".utf8))).get(), .text(mime: "text/markdown"))
        XCTAssertEqual(try AttachmentValidator.validate(url: file("main.go", Data("package main".utf8))).get(), .text(mime: "text/plain"))
    }

    func testMagicBytesBeatExtension() throws {
        XCTAssertEqual(try AttachmentValidator.validate(url: file("shot.txt", Self.png)).get(), .image(mime: "image/png"))
        XCTAssertEqual(AttachmentValidator.validate(url: try file("fake.png", Self.zip)),
                       .failure(.unsupportedType(fileName: "fake.png")))
    }

    func testRejections() throws {
        XCTAssertEqual(AttachmentValidator.validate(url: try file("a.zip", Self.zip)), .failure(.unsupportedType(fileName: "a.zip")))
        XCTAssertEqual(AttachmentValidator.validate(url: try sparse("big.png", head: Self.png, size: AttachmentValidator.imageLimit + 1)),
                       .failure(.tooLarge(fileName: "big.png", limit: AttachmentValidator.imageLimit)))
        XCTAssertEqual(AttachmentValidator.validate(url: try sparse("big.log", head: Data("x".utf8), size: AttachmentValidator.textLimit + 1)),
                       .failure(.tooLarge(fileName: "big.log", limit: AttachmentValidator.textLimit)))
        XCTAssertEqual(AttachmentValidator.validate(url: try file("bin.txt", Data([0xFF, 0xFE, 0x00, 0x81]))),
                       .failure(.notUTF8(fileName: "bin.txt")))
        XCTAssertEqual(AttachmentValidator.validate(url: dir.appendingPathComponent("gone.png")),
                       .failure(.unreadable(fileName: "gone.png")))
        XCTAssertEqual(AttachmentValidator.validate(url: dir), .failure(.unreadable(fileName: dir.lastPathComponent)))
    }

    func testValidateDataForPaste() {
        XCTAssertEqual(try AttachmentValidator.validate(data: Self.png, fileName: "Pasted image.png").get(), .image(mime: "image/png"))
        XCTAssertEqual(AttachmentValidator.validate(data: Self.zip, fileName: "x.bin"), .failure(.unsupportedType(fileName: "x.bin")))
    }

    func testRejectionMessagesNameTheFile() {
        XCTAssertTrue(AttachmentRejection.tooLarge(fileName: "big.png", limit: AttachmentValidator.imageLimit).message.contains("big.png"))
        XCTAssertTrue(AttachmentRejection.unsupportedType(fileName: "a.zip").message.contains("a.zip"))
    }

    /// Mirrors Go internal/chat MaxImageBytes/MaxPDFBytes/MaxTextBytes
    /// (TestAttachmentLimits_MirrorSwift) — change both sides together.
    func testLimitsMirrorGo() {
        XCTAssertEqual(AttachmentValidator.imageLimit, 5 * 1024 * 1024)
        XCTAssertEqual(AttachmentValidator.pdfLimit, 32 * 1024 * 1024)
        XCTAssertEqual(AttachmentValidator.textLimit, 256 * 1024)
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `make test-swift FILTER=AttachmentValidatorTests`
Expected: FAIL — `cannot find 'AttachmentValidator' in scope`.

- [ ] **Step 4: Implement the validator**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/AttachmentValidator.swift`:

```swift
import Foundation

package enum AttachmentKind: Equatable, Sendable {
    case image(mime: String)
    case pdf
    case text(mime: String)

    package var mime: String {
        switch self {
        case .image(let mime), .text(let mime): return mime
        case .pdf: return "application/pdf"
        }
    }

    /// Extension for the stored copy: canonical for binaries, the original
    /// (lowercased) for text so a `.go` stays recognisable.
    package func fileExtension(fallbackName: String) -> String {
        switch self {
        case .image(let mime):
            switch mime {
            case "image/jpeg": return "jpg"
            case "image/gif": return "gif"
            case "image/webp": return "webp"
            default: return "png"
            }
        case .pdf:
            return "pdf"
        case .text:
            let ext = (fallbackName as NSString).pathExtension.lowercased()
            return ext.isEmpty ? "txt" : ext
        }
    }
}

package enum AttachmentRejection: Error, Equatable, Sendable {
    case unsupportedType(fileName: String)
    case tooLarge(fileName: String, limit: Int64)
    case notUTF8(fileName: String)
    case unreadable(fileName: String)

    package var message: String {
        switch self {
        case .unsupportedType(let name):
            return "\(name): only images, PDFs and text files can be attached"
        case .tooLarge(let name, let limit):
            return "\(name) is larger than \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file))"
        case .notUTF8(let name):
            return "\(name) is not a UTF-8 text file"
        case .unreadable(let name):
            return "\(name) could not be read"
        }
    }
}

/// Composer-side twin of Go `internal/chat` attachment rules: binaries are
/// detected from magic bytes (the signatures Go's `http.DetectContentType`
/// uses), text by extension + UTF-8. Limits mirror Go `Max*Bytes`.
package enum AttachmentValidator {
    package static let imageLimit: Int64 = 5 * 1024 * 1024
    package static let pdfLimit: Int64 = 32 * 1024 * 1024
    package static let textLimit: Int64 = 256 * 1024

    package static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "json", "yaml", "yml", "log", "xml", "toml", "ini",
        "go", "swift", "py", "js", "ts", "tsx", "jsx", "java", "kt", "rb", "rs", "c", "h", "cpp",
        "hpp", "m", "cs", "php", "sh", "zsh", "bash", "sql", "html", "css", "scss",
    ]

    package static func validate(url: URL) -> Result<AttachmentKind, AttachmentRejection> {
        let name = url.lastPathComponent
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return .failure(.unreadable(fileName: name))
        }
        let head = (try? handle.read(upToCount: 16)) ?? Data()
        try? handle.close()
        guard let classified = classify(head: head, fileName: name) else {
            return .failure(.unsupportedType(fileName: name))
        }
        let (kind, limit) = classified
        guard Int64(size) <= limit else { return .failure(.tooLarge(fileName: name, limit: limit)) }
        if case .text = kind {
            guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable(fileName: name)) }
            guard String(data: data, encoding: .utf8) != nil else { return .failure(.notUTF8(fileName: name)) }
        }
        return .success(kind)
    }

    package static func validate(data: Data, fileName: String) -> Result<AttachmentKind, AttachmentRejection> {
        guard let classified = classify(head: data.prefix(16), fileName: fileName) else {
            return .failure(.unsupportedType(fileName: fileName))
        }
        let (kind, limit) = classified
        guard Int64(data.count) <= limit else { return .failure(.tooLarge(fileName: fileName, limit: limit)) }
        if case .text = kind, String(data: data, encoding: .utf8) == nil {
            return .failure(.notUTF8(fileName: fileName))
        }
        return .success(kind)
    }

    static func classify(head: Data, fileName: String) -> (AttachmentKind, Int64)? {
        let bytes = [UInt8](head)
        func starts(_ signature: [UInt8]) -> Bool {
            bytes.count >= signature.count && Array(bytes.prefix(signature.count)) == signature
        }
        if starts([0x89, 0x50, 0x4E, 0x47]) { return (.image(mime: "image/png"), imageLimit) }
        if starts([0xFF, 0xD8, 0xFF]) { return (.image(mime: "image/jpeg"), imageLimit) }
        if starts(Array("GIF8".utf8)) { return (.image(mime: "image/gif"), imageLimit) }
        if starts(Array("RIFF".utf8)), bytes.count >= 12, Array(bytes[8..<12]) == Array("WEBP".utf8) {
            return (.image(mime: "image/webp"), imageLimit)
        }
        if starts(Array("%PDF-".utf8)) { return (.pdf, pdfLimit) }
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard textExtensions.contains(ext) else { return nil }
        return (.text(mime: textMime(ext)), textLimit)
    }

    /// Every value here is accepted by Go `isTextMime`.
    static func textMime(_ ext: String) -> String {
        switch ext {
        case "md", "markdown": return "text/markdown"
        case "csv": return "text/csv"
        case "tsv": return "text/tab-separated-values"
        case "json": return "application/json"
        case "yaml", "yml": return "application/yaml"
        case "xml": return "application/xml"
        case "toml": return "application/toml"
        case "html": return "text/html"
        default: return "text/plain"
        }
    }
}
```

- [ ] **Step 5: Run the validator tests**

Run: `make test-swift FILTER=AttachmentValidatorTests`
Expected: PASS.

- [ ] **Step 6: Write the failing store/queries tests**

Create `WatchtowerDesktop/Tests/Core/ChatAttachmentStoreTests.swift`:

```swift
import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class ChatAttachmentStoreTests: XCTestCase {
    private var dbQueue: DatabaseQueue!
    private var root: URL!
    private var src: URL!
    private var store: ChatAttachmentStore!
    private var conversationID: Int64 = 0

    override func setUpWithError() throws {
        dbQueue = try TestDatabase.create()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("chatfiles-\(UUID().uuidString)")
        src = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        store = ChatAttachmentStore(db: dbQueue, rootDir: root)
        conversationID = try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO chat_conversations (title, created_at, updated_at) VALUES ('', 0, 0)")
            return db.lastInsertedRowID
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: src)
    }

    private func source(_ name: String, _ data: Data) throws -> URL {
        let url = src.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func insertUserMessage() throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO chat_messages (conversation_id, role, text, turn_id, created_at) VALUES (?, 'user', 'hi', '', 0)",
                arguments: [conversationID])
            return db.lastInsertedRowID
        }
    }

    func testImportCopiesFileWith0600UnderConversationDir() throws {
        let att = try store.importFile(url: source("shot.png", AttachmentValidatorTests.png), conversationID: conversationID)
        XCTAssertEqual(att.name, "shot.png")
        XCTAssertEqual(att.mime, "image/png")
        XCTAssertEqual(att.size, Int64(AttachmentValidatorTests.png.count))
        XCTAssertEqual(att.conversationID, conversationID)
        XCTAssertNil(att.projectID)
        XCTAssertNil(att.messageID)
        XCTAssertTrue(att.path.hasPrefix(root.appendingPathComponent("conversations/\(conversationID)").path))
        XCTAssertTrue(att.path.hasSuffix(".png"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: att.path)), AttachmentValidatorTests.png)
        let perms = try FileManager.default.attributesOfItem(atPath: att.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
    }

    func testSameFileTwiceSharesStorageButGetsTwoRows() throws {
        let url = try source("shot.png", AttachmentValidatorTests.png)
        let first = try store.importFile(url: url, conversationID: conversationID)
        let second = try store.importFile(url: url, conversationID: conversationID)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.path, second.path)
        let files = try FileManager.default.contentsOfDirectory(atPath: store.directory(for: .conversation(conversationID)).path)
        XCTAssertEqual(files.count, 1)

        try store.discard(first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path), "still referenced by the second row")
        try store.discard(second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testRejectedFileLeavesNoRowAndNoFile() throws {
        XCTAssertThrowsError(try store.importFile(url: source("a.zip", AttachmentValidatorTests.zip), conversationID: conversationID)) { error in
            XCTAssertEqual(error as? AttachmentRejection, .unsupportedType(fileName: "a.zip"))
        }
        let count = try dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chat_attachments") }
        XCTAssertEqual(count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testImportDataForPastedImage() throws {
        let att = try store.importData(AttachmentValidatorTests.png, name: "Pasted image.png", owner: .conversation(conversationID))
        XCTAssertEqual(att.name, "Pasted image.png")
        XCTAssertEqual(att.mime, "image/png")
    }

    func testProjectOwnerUsesProjectsDir() throws {
        let projectID = try dbQueue.write { db -> Int64 in
            try db.execute(sql: "INSERT INTO chat_projects (name, instructions, created_at, updated_at) VALUES ('P', '', 0, 0)")
            return db.lastInsertedRowID
        }
        let att = try store.importFile(url: source("n.md", Data("x".utf8)), projectID: projectID)
        XCTAssertEqual(att.projectID, projectID)
        XCTAssertNil(att.conversationID)
        XCTAssertTrue(att.path.hasPrefix(root.appendingPathComponent("projects/\(projectID)").path))
    }

    func testLinkAndFetchByMessages() throws {
        let att = try store.importFile(url: source("n.md", Data("x".utf8)), conversationID: conversationID)
        let messageID = try insertUserMessage()
        try dbQueue.write { try ChatAttachmentQueries.link($0, attachmentIDs: [att.id], messageID: messageID) }
        let byMessage = try dbQueue.read { try ChatAttachmentQueries.fetchByMessages($0, messageIDs: [messageID]) }
        XCTAssertEqual(byMessage[messageID]?.map(\.id), [att.id])
        XCTAssertEqual(try dbQueue.read { try ChatAttachmentQueries.fetchByMessages($0, messageIDs: []) }, [:])

        // Linking never steals a row that already belongs to a message.
        let other = try insertUserMessage()
        try dbQueue.write { try ChatAttachmentQueries.link($0, attachmentIDs: [att.id], messageID: other) }
        let again = try dbQueue.read { try ChatAttachmentQueries.fetchByMessages($0, messageIDs: [messageID, other]) }
        XCTAssertEqual(again[messageID]?.count, 1)
        XCTAssertNil(again[other])
    }

    func testRemoveFilesDeletesOwnerDirectory() throws {
        let att = try store.importFile(url: source("shot.png", AttachmentValidatorTests.png), conversationID: conversationID)
        ChatAttachmentStore.removeFiles(for: .conversation(conversationID), rootDir: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: att.path))
        // Missing directory is a no-op, not a crash.
        ChatAttachmentStore.removeFiles(for: .conversation(conversationID), rootDir: root)
    }
}
```

- [ ] **Step 7: Run to verify it fails**

Run: `make test-swift FILTER=ChatAttachmentStoreTests`
Expected: FAIL — `cannot find 'ChatAttachmentStore' in scope`.

- [ ] **Step 8: Add the model, queries and store**

First check `grep -n "struct ChatAttachment" WatchtowerDesktop/Sources/WatchtowerCore/Models/ChatModels.swift`. If Task 10 already declared it, make its fields/CodingKeys match the block below exactly; otherwise append to `ChatModels.swift`:

```swift
package enum ChatAttachmentOwner: Equatable, Hashable, Sendable {
    case conversation(Int64)
    case project(Int64)

    var directoryName: String {
        switch self {
        case .conversation(let id): return "conversations/\(id)"
        case .project(let id): return "projects/\(id)"
        }
    }
}

package struct ChatAttachment: FetchableRecord, Decodable, Identifiable, Equatable, Sendable {
    package let id: Int64
    package let conversationID: Int64?
    package let projectID: Int64?
    package let messageID: Int64?
    package let name: String
    package let mime: String
    package let size: Int64
    package let path: String
    package let sha256: String
    package let createdAt: Double

    package enum CodingKeys: String, CodingKey {
        case id, name, mime, size, path, sha256
        case conversationID = "conversation_id"
        case projectID = "project_id"
        case messageID = "message_id"
        case createdAt = "created_at"
    }
}
```

Create `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ChatAttachmentQueries.swift`:

```swift
import Foundation
import GRDB

package enum ChatAttachmentQueries {
    private static func ownerColumns(_ owner: ChatAttachmentOwner) -> (conversationID: Int64?, projectID: Int64?) {
        switch owner {
        case .conversation(let id): return (id, nil)
        case .project(let id): return (nil, id)
        }
    }

    package static func insert(
        _ db: Database, owner: ChatAttachmentOwner, name: String, mime: String,
        size: Int64, path: String, sha256: String
    ) throws -> ChatAttachment {
        let columns = ownerColumns(owner)
        try db.execute(sql: """
            INSERT INTO chat_attachments (conversation_id, project_id, name, mime, size, path, sha256, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [columns.conversationID, columns.projectID, name, mime, size, path, sha256,
                             Date().timeIntervalSince1970])
        guard let row = try ChatAttachment.fetchOne(
            db, sql: "SELECT * FROM chat_attachments WHERE id = ?", arguments: [db.lastInsertedRowID]) else {
            throw DatabaseError(message: "chat attachment missing right after insert")
        }
        return row
    }

    /// A stored file with this content for the same owner (storage dedupe).
    package static func existingPath(_ db: Database, owner: ChatAttachmentOwner, sha256: String) throws -> String? {
        switch owner {
        case .conversation(let id):
            return try String.fetchOne(db, sql: """
                SELECT path FROM chat_attachments WHERE conversation_id = ? AND sha256 = ? ORDER BY id LIMIT 1
                """, arguments: [id, sha256])
        case .project(let id):
            return try String.fetchOne(db, sql: """
                SELECT path FROM chat_attachments WHERE project_id = ? AND sha256 = ? ORDER BY id LIMIT 1
                """, arguments: [id, sha256])
        }
    }

    /// Links pending (message-less) rows to the message they were sent with.
    package static func link(_ db: Database, attachmentIDs: [Int64], messageID: Int64) throws {
        guard !attachmentIDs.isEmpty else { return }
        var arguments: StatementArguments = [messageID]
        arguments += StatementArguments(attachmentIDs)
        try db.execute(sql: """
            UPDATE chat_attachments SET message_id = ?
            WHERE id IN (\(databaseQuestionMarks(count: attachmentIDs.count))) AND message_id IS NULL
            """, arguments: arguments)
    }

    package static func fetchByMessages(_ db: Database, messageIDs: [Int64]) throws -> [Int64: [ChatAttachment]] {
        guard !messageIDs.isEmpty else { return [:] }
        let rows = try ChatAttachment.fetchAll(db, sql: """
            SELECT * FROM chat_attachments WHERE message_id IN (\(databaseQuestionMarks(count: messageIDs.count))) ORDER BY id
            """, arguments: StatementArguments(messageIDs))
        var out: [Int64: [ChatAttachment]] = [:]
        for row in rows {
            guard let messageID = row.messageID else { continue }
            out[messageID, default: []].append(row)
        }
        return out
    }

    package static func delete(_ db: Database, id: Int64) throws {
        try db.execute(sql: "DELETE FROM chat_attachments WHERE id = ?", arguments: [id])
    }

    package static func referenceCount(_ db: Database, path: String) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat_attachments WHERE path = ?", arguments: [path]) ?? 0
    }
}
```

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatAttachmentStore.swift`:

```swift
import CryptoKit
import Foundation
import GRDB

/// Copies owner-chosen files into `<workspace>/chat_files/<conversations|projects>/<id>/`
/// (0700 dirs, 0600 files) and records them in `chat_attachments`. Go reads
/// the stored path from the `turn` command's stdin (CHAT-04: never argv).
package final class ChatAttachmentStore {
    package let db: any DatabaseWriter
    package let rootDir: URL

    package init(db: any DatabaseWriter, rootDir: URL) {
        self.db = db
        self.rootDir = rootDir
    }

    /// `Constants.activeWorkspaceDir()/chat_files` — the Swift side of Go
    /// `Config.WorkspaceDir()/chat_files`. Nil without an active workspace.
    package static func defaultRootDir() -> URL? {
        Constants.activeWorkspaceDir().map {
            URL(fileURLWithPath: $0).appendingPathComponent("chat_files", isDirectory: true)
        }
    }

    package func directory(for owner: ChatAttachmentOwner) -> URL {
        rootDir.appendingPathComponent(owner.directoryName, isDirectory: true)
    }

    package func importFile(url: URL, conversationID: Int64) throws -> ChatAttachment {
        try importFile(url: url, owner: .conversation(conversationID))
    }

    package func importFile(url: URL, projectID: Int64) throws -> ChatAttachment {
        try importFile(url: url, owner: .project(projectID))
    }

    package func importFile(url: URL, owner: ChatAttachmentOwner) throws -> ChatAttachment {
        let kind = try AttachmentValidator.validate(url: url).get()
        let data = try Data(contentsOf: url)
        return try store(data: data, name: url.lastPathComponent, kind: kind, owner: owner)
    }

    package func importData(_ data: Data, name: String, owner: ChatAttachmentOwner) throws -> ChatAttachment {
        let kind = try AttachmentValidator.validate(data: data, fileName: name).get()
        return try store(data: data, name: name, kind: kind, owner: owner)
    }

    /// Removes a pending attachment's row, and its file once no row points at it.
    package func discard(_ attachment: ChatAttachment) throws {
        let stillReferenced = try db.write { db -> Bool in
            try ChatAttachmentQueries.delete(db, id: attachment.id)
            return try ChatAttachmentQueries.referenceCount(db, path: attachment.path) > 0
        }
        if !stillReferenced {
            // Best effort: a missing file is already the desired end state.
            try? FileManager.default.removeItem(atPath: attachment.path)
        }
    }

    /// Post-commit cleanup after a conversation/project delete (rows are gone
    /// by FK cascade). Best effort by spec §7.1; a missing dir is a no-op.
    package static func removeFiles(for owner: ChatAttachmentOwner, rootDir: URL) {
        try? FileManager.default.removeItem(at: rootDir.appendingPathComponent(owner.directoryName, isDirectory: true))
    }

    private func store(data: Data, name: String, kind: AttachmentKind, owner: ChatAttachmentOwner) throws -> ChatAttachment {
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let existing = try db.read { try ChatAttachmentQueries.existingPath($0, owner: owner, sha256: sha) }
        let reused = existing.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        let path = try reused ?? writeFile(data: data, ext: kind.fileExtension(fallbackName: name), owner: owner)
        do {
            return try db.write { db in
                try ChatAttachmentQueries.insert(db, owner: owner, name: name, mime: kind.mime,
                                                 size: Int64(data.count), path: path, sha256: sha)
            }
        } catch {
            if reused == nil { try? FileManager.default.removeItem(atPath: path) }
            throw error
        }
    }

    private func writeFile(data: Data, ext: String, owner: ChatAttachmentOwner) throws -> String {
        let dir = directory(for: owner)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent("\(UUID().uuidString.lowercased()).\(ext)")
        guard FileManager.default.createFile(atPath: file.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return file.path
    }
}
```

- [ ] **Step 9: Run the store tests**

Run: `make test-swift FILTER=ChatAttachmentStoreTests`
Expected: PASS.

- [ ] **Step 10: Write the failing composer-model tests**

Create `WatchtowerDesktop/Tests/Core/ComposerAttachmentsTests.swift`:

```swift
import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

@MainActor
final class ComposerAttachmentsTests: XCTestCase {
    private var dbQueue: DatabaseQueue!
    private var root: URL!
    private var src: URL!
    private var conversationID: Int64 = 0

    override func setUp() async throws {
        dbQueue = try TestDatabase.create()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cf-\(UUID().uuidString)")
        src = FileManager.default.temporaryDirectory.appendingPathComponent("cs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        conversationID = try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO chat_conversations (title, created_at, updated_at) VALUES ('', 0, 0)")
            return db.lastInsertedRowID
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: src)
    }

    private func source(_ name: String, _ data: Data) throws -> URL {
        let url = src.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testAddKeepsValidAndReportsRejected() throws {
        let model = ComposerAttachments(store: ChatAttachmentStore(db: dbQueue, rootDir: root))
        model.add(urls: [try source("a.png", AttachmentValidatorTests.png), try source("b.zip", AttachmentValidatorTests.zip)],
                  conversationID: conversationID)
        XCTAssertEqual(model.pending.map(\.name), ["a.png"])
        XCTAssertEqual(model.errorMessage, AttachmentRejection.unsupportedType(fileName: "b.zip").message)

        model.add(urls: [try source("c.md", Data("x".utf8))], conversationID: conversationID)
        XCTAssertNil(model.errorMessage, "a clean add clears the previous rejection")
    }

    func testRemoveDiscardsRowAndFile() throws {
        let model = ComposerAttachments(store: ChatAttachmentStore(db: dbQueue, rootDir: root))
        model.add(urls: [try source("a.png", AttachmentValidatorTests.png)], conversationID: conversationID)
        let path = try XCTUnwrap(model.pending.first?.path)
        model.remove(id: try XCTUnwrap(model.pending.first?.id))
        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testTakeForSendHandsOverAndClears() throws {
        let model = ComposerAttachments(store: ChatAttachmentStore(db: dbQueue, rootDir: root))
        model.addPastedImage(AttachmentValidatorTests.png, conversationID: conversationID)
        let taken = model.takeForSend()
        XCTAssertEqual(taken.map(\.name), ["Pasted image.png"])
        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    func testNoWorkspaceSaysSo() {
        let model = ComposerAttachments(store: nil)
        model.add(urls: [URL(fileURLWithPath: "/tmp/x.png")], conversationID: 1)
        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertEqual(model.errorMessage, "Attachments need an active workspace")
    }
}
```

- [ ] **Step 11: Run to verify it fails**

Run: `make test-swift FILTER=ComposerAttachmentsTests`
Expected: FAIL — `cannot find 'ComposerAttachments' in scope`.

- [ ] **Step 12: Implement the composer model**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ComposerAttachments.swift`:

```swift
import Foundation
import Observation

/// The composer's pending (not yet sent) attachments. Owned by ChatViewModel,
/// so pending files survive navigating away from the chat.
@MainActor @Observable
package final class ComposerAttachments {
    package private(set) var pending: [ChatAttachment] = []
    package private(set) var errorMessage: String?
    @ObservationIgnored private let store: ChatAttachmentStore?

    package init(store: ChatAttachmentStore?) {
        self.store = store
    }

    package func add(urls: [URL], conversationID: Int64) {
        guard let store else {
            errorMessage = "Attachments need an active workspace"
            return
        }
        var problems: [String] = []
        for url in urls {
            do {
                pending.append(try store.importFile(url: url, conversationID: conversationID))
            } catch let rejection as AttachmentRejection {
                problems.append(rejection.message)
            } catch {
                problems.append("\(url.lastPathComponent) could not be attached: \(error.localizedDescription)")
            }
        }
        errorMessage = problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    package func addPastedImage(_ png: Data, conversationID: Int64) {
        guard let store else {
            errorMessage = "Attachments need an active workspace"
            return
        }
        do {
            pending.append(try store.importData(png, name: "Pasted image.png", owner: .conversation(conversationID)))
            errorMessage = nil
        } catch let rejection as AttachmentRejection {
            errorMessage = rejection.message
        } catch {
            errorMessage = "The pasted image could not be attached: \(error.localizedDescription)"
        }
    }

    package func remove(id: Int64) {
        guard let item = pending.first(where: { $0.id == id }), let store else { return }
        do {
            try store.discard(item)
            pending.removeAll { $0.id == id }
        } catch {
            errorMessage = "\(item.name) could not be removed: \(error.localizedDescription)"
        }
    }

    /// Hands the pending set to `send` and clears the composer.
    package func takeForSend() -> [ChatAttachment] {
        let taken = pending
        pending = []
        errorMessage = nil
        return taken
    }
}
```

- [ ] **Step 13: Run the composer-model tests**

Run: `make test-swift FILTER=ComposerAttachmentsTests`
Expected: PASS.

- [ ] **Step 14: Write the failing App-side view/paste tests**

Create `WatchtowerDesktop/Tests/PastedImageTests.swift`:

```swift
import XCTest
import AppKit
@testable import WatchtowerDesktop

final class PastedImageTests: XCTestCase {
    private func privatePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("wt-test-\(UUID().uuidString)"))
    }

    private func onePixelImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        return image
    }

    func testImageOnlyPasteboardYieldsPNG() throws {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([onePixelImage()])
        let png = try XCTUnwrap(PastedImage.pngData(from: pasteboard))
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testTextWinsOverImage() {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([onePixelImage()])
        pasteboard.setString("hello", forType: .string)
        XCTAssertNil(PastedImage.pngData(from: pasteboard))
    }
}
```

Create `WatchtowerDesktop/Tests/ChatInputAttachmentTests.swift`:

```swift
import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
@testable import WatchtowerCore // memberwise init of the package struct ChatAttachment (TrayMenuViewTests precedent)

@MainActor
final class ChatInputAttachmentTests: XCTestCase {
    private func attachment(id: Int64, name: String, mime: String) -> ChatAttachment {
        ChatAttachment(id: id, conversationID: 1, projectID: nil, messageID: nil, name: name, mime: mime,
                       size: 1, path: "/tmp/\(name)", sha256: "x", createdAt: 0)
    }

    private func makeView(
        text: String = "", attachments: [ChatAttachment] = [], error: String? = nil,
        onSend: @escaping () -> Void = {}, onAttach: (([URL]) -> Void)? = { _ in },
        onRemove: ((Int64) -> Void)? = { _ in }
    ) -> ChatInputContent {
        var stored = text
        return ChatInputContent(
            text: Binding(get: { stored }, set: { stored = $0 }),
            isStreaming: false, onSend: onSend, onStop: nil,
            placeholder: "Ask…", dictationTargetID: nil, dictationCenter: nil,
            attachments: attachments, attachmentError: error,
            onAttachFiles: onAttach, onPasteImage: nil, onRemoveAttachment: onRemove)
    }

    func testChipsShowNamesAndRemoveCallsBack() throws {
        var removed: Int64?
        let view = makeView(attachments: [attachment(id: 7, name: "shot.png", mime: "image/png")],
                            onRemove: { removed = $0 })
        XCTAssertNoThrow(try view.inspect().find(text: "shot.png"))
        try view.inspect().find(ViewType.Button.self) { try $0.accessibilityLabel().string() == "Remove shot.png" }.tap()
        XCTAssertEqual(removed, 7)
    }

    func testSendEnabledWithAttachmentOnly() throws {
        var sent = 0
        let view = makeView(attachments: [attachment(id: 1, name: "a.pdf", mime: "application/pdf")], onSend: { sent += 1 })
        let send = try view.inspect().find(ViewType.Button.self) { try $0.accessibilityLabel().string() == "Send" }
        XCTAssertFalse(try send.isDisabled())
        try send.tap()
        XCTAssertEqual(sent, 1)
    }

    func testRejectionTextShown() throws {
        let view = makeView(error: "a.zip: only images, PDFs and text files can be attached")
        XCTAssertNoThrow(try view.inspect().find(text: "a.zip: only images, PDFs and text files can be attached"))
    }

    func testPaperclipOnlyWhenAttachingIsWired() throws {
        let with = makeView()
        XCTAssertNoThrow(try with.inspect().find(ViewType.Button.self) { try $0.accessibilityLabel().string() == "Attach files" })
        let without = makeView(onAttach: nil)
        XCTAssertThrowsError(try without.inspect().find(ViewType.Button.self) { try $0.accessibilityLabel().string() == "Attach files" })
    }
}
```

- [ ] **Step 15: Run to verify they fail**

Run: `make test-swift FILTER=PastedImageTests` then `make test-swift FILTER=ChatInputAttachmentTests`
Expected: FAIL — `cannot find 'PastedImage'`; `extra arguments 'attachments'…` in call to `ChatInputContent`.

- [ ] **Step 16: Implement paste detection, chips and the composer changes**

Create `WatchtowerDesktop/Sources/Views/Chat/PastedImage.swift`:

```swift
import AppKit

enum PastedImage {
    /// PNG bytes for an image-only pasteboard; nil when it carries text (text
    /// wins — a rich copy often has both) or no image. Called ONLY from the
    /// text view's `paste(_:)` — a user-initiated paste — never polled
    /// (No-TCC convention: programmatic pasteboard reads can prompt).
    static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if pasteboard.string(forType: .string) != nil { return nil }
        guard pasteboard.canReadObject(forClasses: [NSImage.self], options: nil),
              let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
```

Create `WatchtowerDesktop/Sources/Views/Chat/AttachmentChipsView.swift`:

```swift
import SwiftUI
import WatchtowerCore

struct AttachmentChipsView: View {
    let attachments: [ChatAttachment]
    var onRemove: ((Int64) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 4) {
                        Image(systemName: Self.icon(for: attachment.mime))
                        Text(attachment.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let onRemove {
                            Button {
                                onRemove(attachment.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(attachment.name)")
                            .help("Remove \(attachment.name)")
                        }
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }
        }
    }

    static func icon(for mime: String) -> String {
        if mime.hasPrefix("image/") { return "photo" }
        if mime == "application/pdf" { return "doc.richtext" }
        return "doc.text"
    }
}
```

In `WatchtowerDesktop/Sources/Views/Chat/ChatInput.swift`:

1. Add to BOTH `ChatInput` and `ChatInputContent` (defaulted, so every existing call site compiles unchanged), and forward them from `ChatInput.body` into `ChatInputContent(...)`:

```swift
    var attachments: [ChatAttachment] = []
    var attachmentError: String?
    var onAttachFiles: (([URL]) -> Void)?
    var onPasteImage: ((Data) -> Void)?
    var onRemoveAttachment: ((Int64) -> Void)?
```

(`ChatInputContent`'s memberwise init lists them after `dictationCenter`; add `import WatchtowerCore` at the top of the file.)

2. In `ChatInputContent.body`, wrap the existing `HStack(alignment: .bottom, spacing: 6) { … }` (and its two `.padding` modifiers) in a `VStack`, add a leading paperclip, pass the paste handler to `ExpandingTextInput`, label the send button, and accept drops:

```swift
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let attachmentError {
                Text(attachmentError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
            }
            if !attachments.isEmpty {
                AttachmentChipsView(attachments: attachments, onRemove: onRemoveAttachment)
                    .padding(.horizontal, 12)
            }
            HStack(alignment: .bottom, spacing: 6) {
                if onAttachFiles != nil {
                    Button(action: pickFiles) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Attach files")
                    .help("Attach images, PDFs or text files")
                    .padding(.bottom, 6)
                }
                // …existing ZStack { placeholder + ExpandingTextInput } with its modifiers, except:
                //    ExpandingTextInput(text: $text, height: $inputHeight, onPasteImage: onPasteImage) { … }
                // …existing DictationButton…
                // existing send/stop Button, with `.accessibilityLabel(isStreaming ? "Stop" : "Send")` added
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let onAttachFiles else { return false }
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            onAttachFiles(files)
            return true
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Attach images, PDFs or text files"
        panel.begin { response in
            guard response == .OK else { return }
            onAttachFiles?(panel.urls)
        }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }
```

3. Replace `ExpandingTextInput`'s scroll-view construction so paste can be intercepted. Add the property and the subclass, and change `makeNSView`/`updateNSView`:

```swift
private final class PastingTextView: NSTextView {
    var onPasteImage: ((Data) -> Void)?

    override func paste(_ sender: Any?) {
        if let onPasteImage, let png = PastedImage.pngData(from: .general) {
            onPasteImage(png)
            return
        }
        super.paste(sender)
    }
}
```

```swift
    var onPasteImage: ((Data) -> Void)?   // new stored property on ExpandingTextInput (before onSubmit)

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let contentSize = scrollView.contentSize
        let textView = PastingTextView(frame: NSRect(origin: .zero, size: contentSize))
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.onPasteImage = onPasteImage
        scrollView.documentView = textView
        // …the existing textView configuration (delegate, font, isRichText, …, drawsBackground)
        // …the existing scrollView configuration and frame-change observer, unchanged…
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? PastingTextView else { return }
        textView.onPasteImage = onPasteImage
        // …existing text sync + recalculateHeight, unchanged…
    }
```

(With the new stored property before `onSubmit`, the trailing-closure call `ExpandingTextInput(text:height:onPasteImage:) { … }` still binds `onSubmit`.)

In `WatchtowerDesktop/Sources/Views/Chat/MessageBubble.swift`, add `var attachments: [ChatAttachment] = []` and, in the `.user` case, show read-only chips above the bubble text: wrap the existing user `Text(message.text)…` chain in `VStack(alignment: .trailing, spacing: 4) { if !attachments.isEmpty { AttachmentChipsView(attachments: attachments, onRemove: nil) }; <existing Text chain> }`.

- [ ] **Step 17: Run the App-side tests**

Run: `make test-swift FILTER=PastedImageTests` then `make test-swift FILTER=ChatInput`
Expected: PASS for `PastedImageTests`, `ChatInputAttachmentTests` and the pre-existing `ChatInputViewTests` (no paperclip without `onAttachFiles`, so its first-button assertions are unchanged).

- [ ] **Step 18: Write the failing conversation-delete cleanup test**

Create `WatchtowerDesktop/Tests/ChatHistoryAttachmentCleanupTests.swift` (target the type that owns `deleteConversation(_:)` after Task 15 — `ChatHistoryViewModel` today; if Task 15 renamed it, use that name and its init):

```swift
import XCTest
import GRDB
import WatchtowerCore
@testable import WatchtowerDesktop

@MainActor
final class ChatHistoryAttachmentCleanupTests: XCTestCase {
    func testDeletingConversationRemovesItsFilesAfterCommit() throws {
        let (dbManager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let history = ChatHistoryViewModel(dbManager: dbManager, attachmentsRoot: root)
        let conversation = try XCTUnwrap(history.createConversation())
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).md")
        try Data("x".utf8).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }
        let att = try ChatAttachmentStore(db: dbManager.dbPool, rootDir: root).importFile(url: src, conversationID: conversation.id)

        history.deleteConversation(conversation.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: att.path))
        let rows = try dbManager.dbPool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chat_attachments") }
        XCTAssertEqual(rows, 0, "rows go by FK cascade")
    }
}
```

- [ ] **Step 19: Run to verify it fails**

Run: `make test-swift FILTER=ChatHistoryAttachmentCleanupTests`
Expected: FAIL — `extra argument 'attachmentsRoot' in call`.

- [ ] **Step 20: Wire the VM, the view and the delete hook**

`ChatHistoryViewModel` (or its Task 15 successor): add `private let attachmentsRoot: URL?`, an init parameter `attachmentsRoot: URL? = ChatAttachmentStore.defaultRootDir()`, and in `deleteConversation(_:)` after the successful `dbPool.write` (inside the `do`, after the write returns):

```swift
            if let attachmentsRoot {
                ChatAttachmentStore.removeFiles(for: .conversation(id), rootDir: attachmentsRoot)
            }
```

`ChatViewModel` (App, `Sources/ViewModels/ChatViewModel.swift`):

```swift
    let composerAttachments: ComposerAttachments
    private(set) var attachmentsByMessage: [Int64: [ChatAttachment]] = [:]
```

- Initialise in `init`: `composerAttachments = ComposerAttachments(store: ChatAttachmentStore.defaultRootDir().map { ChatAttachmentStore(db: dbManager.dbPool, rootDir: $0) })`.
- Add, reusing the conversation-creation code Task 14's `send` already runs for a new chat (extract it into this helper and call it from both):

```swift
    func attachFiles(_ urls: [URL]) {
        guard let conversationID = conversationIDCreatingIfNeeded() else { return }
        composerAttachments.add(urls: urls, conversationID: conversationID)
    }

    func attachPastedImage(_ png: Data) {
        guard let conversationID = conversationIDCreatingIfNeeded() else { return }
        composerAttachments.addPastedImage(png, conversationID: conversationID)
    }
```

- In `send(text:attachments:mentions:)`: callers pass `composerAttachments.takeForSend()`; the send guard accepts empty text when attachments are non-empty; inside the same `dbPool.write` that calls `ChatTreeQueries.insertUser(…)` add, right after it, `try ChatAttachmentQueries.link(db, attachmentIDs: attachments.map(\.id), messageID: userMessage.id)` (CHAT-01: linked in the same transaction that persists the owner's message); the `turn` command's attachments are `attachments.map { (path: $0.path, mime: $0.mime, name: $0.name) }` in whatever element type Task 11's turn command defines (`grep -n "attachments" WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatEvent.swift` — the Go side decodes `path`/`mime`/`name`).
- Where the VM loads the active path (Task 14's path reload), also set `attachmentsByMessage = try ChatAttachmentQueries.fetchByMessages(db, messageIDs: path.map(\.id))` in the same read.

`ChatView`: pass to the composer `attachments: vm.composerAttachments.pending, attachmentError: vm.composerAttachments.errorMessage, onAttachFiles: { vm.attachFiles($0) }, onPasteImage: { vm.attachPastedImage($0) }, onRemoveAttachment: { vm.composerAttachments.remove(id: $0) }`, and to each user `MessageBubble` `attachments: vm.attachmentsByMessage[message.id] ?? []`.

- [ ] **Step 21: Run the Task 21 suites**

Run: `make test-swift FILTER=Attachment` then `make test-swift FILTER=ChatViewModel`
Expected: PASS (all attachment suites; Task 14's ChatViewModel suites unaffected).

- [ ] **Step 22: Lint**

Run: `make lint-diff`
Expected: no new issues.

- [ ] **Step 23: Commit**

```bash
git add WatchtowerDesktop/Sources/WatchtowerCore/Models/ChatModels.swift \
  WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/AttachmentValidator.swift \
  WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatAttachmentStore.swift \
  WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ComposerAttachments.swift \
  WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ChatAttachmentQueries.swift \
  WatchtowerDesktop/Sources/Views/Chat/AttachmentChipsView.swift WatchtowerDesktop/Sources/Views/Chat/PastedImage.swift \
  WatchtowerDesktop/Sources/Views/Chat/ChatInput.swift WatchtowerDesktop/Sources/Views/Chat/ChatView.swift \
  WatchtowerDesktop/Sources/Views/Chat/MessageBubble.swift WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift \
  WatchtowerDesktop/Sources/ViewModels/ChatHistoryViewModel.swift \
  WatchtowerDesktop/Tests/Core/AttachmentValidatorTests.swift WatchtowerDesktop/Tests/Core/ChatAttachmentStoreTests.swift \
  WatchtowerDesktop/Tests/Core/ComposerAttachmentsTests.swift WatchtowerDesktop/Tests/ChatInputAttachmentTests.swift \
  WatchtowerDesktop/Tests/PastedImageTests.swift WatchtowerDesktop/Tests/ChatHistoryAttachmentCleanupTests.swift
git commit -m "feat(desktop): chat attachments — validation, 0600 store, paperclip/drop/paste

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 22: Artifact parser, store and actions

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ArtifactParser.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ArtifactActions.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/CSVTable.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/ChatModels.swift` (append `ChatArtifact`)
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ChatArtifactQueries.swift`
- Modify: `WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift` (persist artifacts when a turn finalises)
- Test: `WatchtowerDesktop/Tests/Core/ArtifactParserTests.swift`, `WatchtowerDesktop/Tests/Core/ChatArtifactQueriesTests.swift`, `WatchtowerDesktop/Tests/Core/ArtifactActionsTests.swift`, `WatchtowerDesktop/Tests/Core/CSVTableTests.swift`

**Interfaces:**
- Consumes: `chat_artifacts(id, conversation_id, message_id, artifact_key, version, kind, title, content, meta_json, edited, created_at)` UNIQUE(conversation_id, artifact_key, version) (migration 00074, mirrored in `TestDatabase.swift` by Task 10); `SlackLinkResolver`, `SlackDeepLink` (WatchtowerCore/Utilities/SlackDeepLink.swift); Task 14's final-assistant-persist write (`ChatTreeQueries.updateAssistant`).
- Produces:
  - `package struct ArtifactDraft { key, kind, title: String; meta: [String: String]; content: String; isComplete: Bool }`
  - `package struct ParsedMessage { enum Segment { case markdown(String), artifact(ArtifactDraft) }; segments: [Segment]; artifacts: [ArtifactDraft] }`
  - `ArtifactParser.parse(_ text: String, final: Bool) -> ParsedMessage`, `ArtifactParser.slug(_:) -> String`, `ArtifactParser.knownKinds`
  - `package struct ChatArtifact` (+ `meta`, `asDraft`)
  - `ChatArtifactQueries.saveVersion(_:conversationID:messageID:draft:edited:) -> ChatArtifact`, `latest(_:conversationID:key:)`, `versions(_:conversationID:key:)` (ascending), `persistArtifacts(_:conversationID:messageID:text:) -> [ChatArtifact]`, `versionsByMessage(_:messageIDs:) -> [Int64: [String: Int]]`
  - `package enum ArtifactAction { case open(URL), copyThenOpen(text: String, url: URL?), copy(String) }`, `package struct ArtifactMenuItem { title, systemImage, action }`
  - `ArtifactActions.gmailComposeURL(meta:body:)`, `.mailtoURL(meta:body:)`, `.calendarTemplateURL(meta:body:timeZone:)` → `ArtifactAction`; `.slackTarget(meta:links:) -> URL?`; `.kindActions(for:gmailConnected:slackLinks:timeZone:) -> [ArtifactMenuItem]`; `.exportFile(for:) -> (name: String, contents: String)`; `maxURLLength = 8000`
  - `CSVTable.parse(_:) -> [[String]]`

- [ ] **Step 1: Write the failing parser tests**

Create `WatchtowerDesktop/Tests/Core/ArtifactParserTests.swift`:

```swift
import XCTest
@testable import WatchtowerCore

final class ArtifactParserTests: XCTestCase {
    private func draft(
        _ key: String, _ kind: String, _ title: String, meta: [String: String] = [:],
        content: String, complete: Bool = true
    ) -> ArtifactDraft {
        ArtifactDraft(key: key, kind: kind, title: title, meta: meta, content: content, isComplete: complete)
    }

    func testPlainTextIsOneMarkdownSegment() {
        XCTAssertEqual(ArtifactParser.parse("Hello\n\nworld", final: true).segments, [.markdown("Hello\n\nworld")])
        XCTAssertEqual(ArtifactParser.parse("", final: true).segments, [])
    }

    func testCompleteArtifactSplitsSurroundingMarkdown() {
        let text = #"""
        Here it is:
        :::artifact key="q3" kind="document" title="Q3 plan"
        # Q3
        - ship
        :::
        Done.
        """#
        XCTAssertEqual(ArtifactParser.parse(text, final: true).segments, [
            .markdown("Here it is:"),
            .artifact(draft("q3", "document", "Q3 plan", content: "# Q3\n- ship")),
            .markdown("Done."),
        ])
    }

    func testArtifactInsideBacktickFenceIsNotAnArtifact() {
        let text = #"""
        Syntax:
        ```
        :::artifact key="x" kind="document" title="X"
        body
        :::
        ```
        """#
        let parsed = ArtifactParser.parse(text, final: true)
        XCTAssertEqual(parsed.artifacts, [])
        XCTAssertEqual(parsed.segments, [.markdown(text)])
    }

    func testTildeAndLongerFencesAreRespected() {
        let text = #"""
        ~~~
        :::artifact key="a" kind="document" title="A"
        :::
        ~~~
        ````markdown
        ```
        :::artifact key="b" kind="document" title="B"
        ```
        ````
        :::artifact key="real" kind="document" title="Real"
        yes
        :::
        """#
        XCTAssertEqual(ArtifactParser.parse(text, final: true).artifacts, [draft("real", "document", "Real", content: "yes")])
    }

    func testStreamingOpenBlockIsIncompleteDraft() {
        let text = "Intro\n:::artifact key=\"q3\" kind=\"document\" title=\"Q3\"\nline one\nline t"
        XCTAssertEqual(ArtifactParser.parse(text, final: false).segments, [
            .markdown("Intro"),
            .artifact(draft("q3", "document", "Q3", content: "line one\nline t", complete: false)),
        ])
    }

    func testStreamingOpenerWithNoBodyYet() {
        let text = "Intro\n:::artifact key=\"q3\" kind=\"document\" title=\"Q3\"\n"
        XCTAssertEqual(ArtifactParser.parse(text, final: false).segments, [
            .markdown("Intro"),
            .artifact(draft("q3", "document", "Q3", content: "", complete: false)),
        ])
    }

    func testFinalUnterminatedBlockIsKeptComplete() {
        let text = "Intro\n:::artifact key=\"q3\" kind=\"document\" title=\"Q3\"\nline one\nline t"
        XCTAssertEqual(ArtifactParser.parse(text, final: true).segments, [
            .markdown("Intro"),
            .artifact(draft("q3", "document", "Q3", content: "line one\nline t", complete: true)),
        ])
    }

    func testStreamingPartialOpenerIsHeldBack() {
        XCTAssertEqual(ArtifactParser.parse("Intro\n:::artifact key=\"q3\" kind=\"doc", final: false).segments, [.markdown("Intro")])
        XCTAssertEqual(ArtifactParser.parse("Intro\n:::arti", final: false).segments, [.markdown("Intro")])
        XCTAssertEqual(ArtifactParser.parse("Intro\n:::artifact key=\"q3\" kind=\"document\" title=\"Q3\"", final: false).segments,
                       [.markdown("Intro")], "an opener line is only trusted once its newline arrived")
    }

    func testFinalMalformedOpenerIsMarkdown() {
        let text = "Intro\n:::artifact key=\"q3\" kind=\"doc"
        XCTAssertEqual(ArtifactParser.parse(text, final: true).segments, [.markdown(text)])
    }

    func testCyrillicTitleAndEscapedQuotes() {
        let text = #"""
        :::artifact key="lyst" kind="email" title="Лист для \"Ані\"" to="anna@example.com" subject="Re: \"v2\" — наступні кроки"
        Привіт!
        :::
        """#
        XCTAssertEqual(ArtifactParser.parse(text, final: true).artifacts, [
            draft("lyst", "email", #"Лист для "Ані""#,
                  meta: ["to": "anna@example.com", "subject": #"Re: "v2" — наступні кроки"#],
                  content: "Привіт!"),
        ])
    }

    func testUnknownKindBecomesDocumentAndMissingKeyIsSlugged() {
        let text = ":::artifact kind=\"memo\" title=\"План на Q3 — draft!\"\nx\n:::"
        XCTAssertEqual(ArtifactParser.parse(text, final: true).artifacts,
                       [draft("план-на-q3-draft", "document", "План на Q3 — draft!", content: "x")])
        let bare = ":::artifact\nx\n:::"
        XCTAssertEqual(ArtifactParser.parse(bare, final: true).artifacts,
                       [draft("artifact", "document", "Untitled", content: "x")])
    }

    func testCloserInsideInnerCodeFenceDoesNotCloseDocument() {
        let text = #"""
        :::artifact key="doc" kind="document" title="Doc"
        Example:
        ```
        :::
        ```
        :::
        """#
        XCTAssertEqual(ArtifactParser.parse(text, final: true).artifacts,
                       [draft("doc", "document", "Doc", content: "Example:\n```\n:::\n```")])
    }

    func testCodeKindDoesNotTrackInnerFences() {
        let text = ":::artifact key=\"c\" kind=\"code\" title=\"C\" language=\"swift\"\nlet a = 1\n```\n:::"
        XCTAssertEqual(ArtifactParser.parse(text, final: true).artifacts,
                       [draft("c", "code", "C", meta: ["language": "swift"], content: "let a = 1\n```")])
    }

    func testTwoArtifactsAndSameKeyTwiceBothSurface() {
        let text = ":::artifact key=\"a\" kind=\"table\" title=\"A\"\nx,y\n:::\nmid\n:::artifact key=\"a\" kind=\"table\" title=\"A\"\nx,z\n:::"
        XCTAssertEqual(ArtifactParser.parse(text, final: true).segments, [
            .artifact(draft("a", "table", "A", content: "x,y")),
            .markdown("mid"),
            .artifact(draft("a", "table", "A", content: "x,z")),
        ])
    }

    func testCRLFLineEndings() {
        let text = "a\r\n:::artifact key=\"k\" kind=\"table\" title=\"T\"\r\nx,y\r\n:::\r\n"
        XCTAssertEqual(ArtifactParser.parse(text, final: true).segments, [
            .markdown("a"),
            .artifact(draft("k", "table", "T", content: "x,y")),
        ])
    }

    func testSlug() {
        XCTAssertEqual(ArtifactParser.slug("Q3 plan — draft!"), "q3-plan-draft")
        XCTAssertEqual(ArtifactParser.slug("План на Q3"), "план-на-q3")
        XCTAssertEqual(ArtifactParser.slug("!!!"), "artifact")
        XCTAssertEqual(ArtifactParser.slug(String(repeating: "a", count: 100)).count, 64)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test-swift FILTER=ArtifactParserTests`
Expected: FAIL — `cannot find 'ArtifactParser' in scope`.

- [ ] **Step 3: Implement the parser**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ArtifactParser.swift`:

```swift
import Foundation

package struct ArtifactDraft: Equatable, Sendable {
    package var key: String
    package var kind: String
    package var title: String
    package var meta: [String: String]
    package var content: String
    package var isComplete: Bool

    package init(key: String, kind: String, title: String, meta: [String: String], content: String, isComplete: Bool) {
        self.key = key
        self.kind = kind
        self.title = title
        self.meta = meta
        self.content = content
        self.isComplete = isComplete
    }
}

package struct ParsedMessage: Equatable, Sendable {
    package enum Segment: Equatable, Sendable {
        case markdown(String)
        case artifact(ArtifactDraft)
    }

    package var segments: [Segment]

    package var artifacts: [ArtifactDraft] {
        segments.compactMap { segment -> ArtifactDraft? in
            guard case .artifact(let draft) = segment else { return nil }
            return draft
        }
    }
}

/// Parses `:::artifact key="…" kind="…" title="…" [attrs]` … `:::` blocks out of
/// assistant text (the grammar taught by Go `chat.ArtifactsContract()`; shared
/// fixture `internal/chat/artifacts_examples.md`). Pure and streaming-aware:
/// `final: false` holds back a half-written opener line and reports an open
/// block as an incomplete draft; `final: true` keeps an unterminated block as
/// complete content. A fence inside a ``` / ~~~ code block is literal text.
package enum ArtifactParser {
    package static let knownKinds: Set<String> = ["document", "table", "email", "slack", "event", "code"]
    static let opener = ":::artifact"

    package static func parse(_ text: String, final: Bool) -> ParsedMessage {
        var machine = Machine(final: final)
        let lines = splitLines(text)
        for (index, entry) in lines.enumerated() {
            let trailingPartial = index == lines.count - 1 && !entry.terminated
            guard machine.consume(entry.line, isTrailingPartial: trailingPartial) else { break }
        }
        return machine.finish()
    }

    package static func slug(_ title: String) -> String {
        var out = ""
        var pendingDash = false
        for character in title.lowercased() {
            if character.isLetter || character.isNumber {
                if pendingDash && !out.isEmpty { out.append("-") }
                pendingDash = false
                out.append(character)
                if out.count >= 64 { break }
            } else {
                pendingDash = true
            }
        }
        return out.isEmpty ? "artifact" : out
    }

    static func splitLines(_ text: String) -> [(line: Substring, terminated: Bool)] {
        guard !text.isEmpty else { return [] }
        // "\r\n" is ONE Character in Swift, so both separators are listed.
        var parts = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
        let endsWithNewline = text.last == "\n" || text.last == "\r\n"
        if endsWithNewline { parts.removeLast() }
        return parts.enumerated().map { index, part in
            (part, endsWithNewline || index < parts.count - 1)
        }
    }

    static func isOpenerLine(_ trimmed: Substring) -> Bool {
        guard trimmed.hasPrefix(opener) else { return false }
        return trimmed.dropFirst(opener.count).first.map(\.isWhitespace) ?? true
    }

    static func isOpenerPrefix(_ trimmed: Substring) -> Bool {
        !trimmed.isEmpty && opener.hasPrefix(trimmed)
    }

    static func parseOpener(_ trimmed: Substring) -> ArtifactDraft? {
        guard var attributes = parseAttributes(trimmed.dropFirst(opener.count)) else { return nil }
        let rawKind = attributes.removeValue(forKey: "kind")?.lowercased() ?? ""
        let rawKey = attributes.removeValue(forKey: "key")?.trimmingCharacters(in: .whitespaces) ?? ""
        let rawTitle = attributes.removeValue(forKey: "title")?.trimmingCharacters(in: .whitespaces) ?? ""
        let key = rawKey.isEmpty ? slug(rawTitle) : rawKey
        let title = rawTitle.isEmpty ? (rawKey.isEmpty ? "Untitled" : rawKey) : rawTitle
        return ArtifactDraft(key: key, kind: knownKinds.contains(rawKind) ? rawKind : "document",
                             title: title, meta: attributes, content: "", isComplete: false)
    }

    /// `name="value"` pairs; `\"` and `\\` are escapes. Nil on any syntax error
    /// (including an unterminated quote).
    static func parseAttributes(_ source: Substring) -> [String: String]? {
        var result: [String: String] = [:]
        var index = source.startIndex
        func advance() { index = source.index(after: index) }
        while true {
            while index < source.endIndex, source[index].isWhitespace { advance() }
            if index == source.endIndex { return result }
            let nameStart = index
            while index < source.endIndex, source[index].isLetter || source[index].isNumber || source[index] == "_" || source[index] == "-" {
                advance()
            }
            let name = source[nameStart..<index].lowercased()
            guard !name.isEmpty, index < source.endIndex, source[index] == "=" else { return nil }
            advance()
            guard index < source.endIndex, source[index] == "\"" else { return nil }
            advance()
            var value = ""
            var closed = false
            while index < source.endIndex {
                let character = source[index]
                if character == "\\" {
                    let next = source.index(after: index)
                    if next < source.endIndex, source[next] == "\"" || source[next] == "\\" {
                        value.append(source[next])
                        index = source.index(after: next)
                        continue
                    }
                } else if character == "\"" {
                    closed = true
                    advance()
                    break
                }
                value.append(character)
                advance()
            }
            guard closed else { return nil }
            result[name] = value
        }
    }
}

private struct CodeFence {
    let marker: Character
    let length: Int

    static func opening(_ line: Substring) -> CodeFence? {
        let stripped = line.drop(while: { $0 == " " })
        guard line.count - stripped.count <= 3, let marker = stripped.first, marker == "`" || marker == "~" else { return nil }
        let run = stripped.prefix(while: { $0 == marker }).count
        guard run >= 3 else { return nil }
        if marker == "`", stripped.dropFirst(run).contains("`") { return nil }
        return CodeFence(marker: marker, length: run)
    }

    func isClosed(by line: Substring) -> Bool {
        let stripped = line.drop(while: { $0 == " " })
        guard line.count - stripped.count <= 3 else { return false }
        let run = stripped.prefix(while: { $0 == marker }).count
        return run >= length && stripped.dropFirst(run).allSatisfy(\.isWhitespace)
    }
}

private struct Machine {
    let final: Bool
    var segments: [ParsedMessage.Segment] = []
    var markdown: [Substring] = []
    var outerFence: CodeFence?
    var open: ArtifactDraft?
    var innerFence: CodeFence?
    var body: [Substring] = []

    init(final: Bool) { self.final = final }

    /// False = stop: the rest of a still-streaming text is held back.
    mutating func consume(_ line: Substring, isTrailingPartial: Bool) -> Bool {
        if open != nil {
            consumeArtifactLine(line)
            return true
        }
        if let fence = outerFence {
            if fence.isClosed(by: line) { outerFence = nil }
            markdown.append(line)
            return true
        }
        if let fence = CodeFence.opening(line) {
            outerFence = fence
            markdown.append(line)
            return true
        }
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        let candidate = ArtifactParser.isOpenerLine(trimmed)
        if isTrailingPartial, !final, candidate || ArtifactParser.isOpenerPrefix(trimmed) {
            return false
        }
        if candidate, let draft = ArtifactParser.parseOpener(trimmed) {
            flushMarkdown()
            open = draft
            innerFence = nil
            body = []
            return true
        }
        markdown.append(line)
        return true
    }

    private mutating func consumeArtifactLine(_ line: Substring) {
        guard var draft = open else { return }
        if innerFence == nil, line.trimmingCharacters(in: .whitespaces) == ":::" {
            draft.content = body.joined(separator: "\n")
            draft.isComplete = true
            segments.append(.artifact(draft))
            open = nil
            body = []
            return
        }
        if draft.kind != "code" {
            if let fence = innerFence {
                if fence.isClosed(by: line) { innerFence = nil }
            } else if let fence = CodeFence.opening(line) {
                innerFence = fence
            }
        }
        body.append(line)
    }

    private mutating func flushMarkdown() {
        let joined = markdown.joined(separator: "\n").trimmingCharacters(in: .newlines)
        if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.append(.markdown(joined))
        }
        markdown = []
    }

    mutating func finish() -> ParsedMessage {
        if var draft = open {
            draft.content = body.joined(separator: "\n")
            draft.isComplete = final
            segments.append(.artifact(draft))
            open = nil
        }
        flushMarkdown()
        return ParsedMessage(segments: segments)
    }
}
```

- [ ] **Step 4: Run the parser tests**

Run: `make test-swift FILTER=ArtifactParserTests`
Expected: PASS.

- [ ] **Step 5: Write the failing store tests**

Verify first: `grep -n "chat_artifacts" WatchtowerDesktop/Tests/Support/TestDatabase.swift` (Task 10 mirror; if absent, copy the DDL from `internal/db/migrations/00074_chat_core.sql`).

Create `WatchtowerDesktop/Tests/Core/ChatArtifactQueriesTests.swift`:

```swift
import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class ChatArtifactQueriesTests: XCTestCase {
    private var dbQueue: DatabaseQueue!
    private var conversationID: Int64 = 0

    override func setUpWithError() throws {
        dbQueue = try TestDatabase.create()
        conversationID = try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO chat_conversations (title, created_at, updated_at) VALUES ('', 0, 0)")
            return db.lastInsertedRowID
        }
    }

    private func insertAssistantMessage() throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO chat_messages (conversation_id, role, text, turn_id, created_at) VALUES (?, 'assistant', '', '', 0)",
                arguments: [conversationID])
            return db.lastInsertedRowID
        }
    }

    private func doc(_ content: String, key: String = "q3", meta: [String: String] = [:]) -> ArtifactDraft {
        ArtifactDraft(key: key, kind: "document", title: "Q3", meta: meta, content: content, isComplete: true)
    }

    private func save(_ draft: ArtifactDraft, message: Int64, edited: Bool = false) throws -> ChatArtifact {
        try dbQueue.write {
            try ChatArtifactQueries.saveVersion($0, conversationID: conversationID, messageID: message, draft: draft, edited: edited)
        }
    }

    func testFirstSaveIsVersionOneWithMeta() throws {
        let m1 = try insertAssistantMessage()
        let saved = try save(doc("a", meta: ["language": "go"]), message: m1)
        XCTAssertEqual(saved.version, 1)
        XCTAssertEqual(saved.meta, ["language": "go"])
        XCTAssertFalse(saved.edited)
        XCTAssertEqual(saved.asDraft, doc("a", meta: ["language": "go"]))
    }

    func testResaveFromSameMessageOverwritesInPlace() throws {
        let m1 = try insertAssistantMessage()
        _ = try save(doc("a"), message: m1)
        let again = try save(doc("b"), message: m1)
        XCTAssertEqual(again.version, 1)
        let all = try dbQueue.read { try ChatArtifactQueries.versions($0, conversationID: conversationID, key: "q3") }
        XCTAssertEqual(all.map(\.content), ["b"])
    }

    func testLaterMessageSameKeyIsNewVersion() throws {
        let m1 = try insertAssistantMessage()
        let m2 = try insertAssistantMessage()
        _ = try save(doc("a"), message: m1)
        _ = try save(doc("b"), message: m2)
        let latest = try dbQueue.read { try ChatArtifactQueries.latest($0, conversationID: conversationID, key: "q3") }
        XCTAssertEqual(latest?.version, 2)
        XCTAssertEqual(latest?.content, "b")
        let all = try dbQueue.read { try ChatArtifactQueries.versions($0, conversationID: conversationID, key: "q3") }
        XCTAssertEqual(all.map(\.version), [1, 2])
    }

    func testEditAlwaysInsertsEditedVersion() throws {
        let m1 = try insertAssistantMessage()
        _ = try save(doc("a"), message: m1)
        let edited = try save(doc("a, edited"), message: m1, edited: true)
        XCTAssertEqual(edited.version, 2)
        XCTAssertTrue(edited.edited)
        // A re-persist of the same message after an edit must not clobber the edit.
        let repersist = try save(doc("a"), message: m1)
        XCTAssertEqual(repersist.version, 3)
    }

    func testKeysVersionIndependently() throws {
        let m1 = try insertAssistantMessage()
        _ = try save(doc("a"), message: m1)
        XCTAssertEqual(try save(doc("x", key: "other"), message: m1).version, 1)
    }

    func testPersistArtifactsFromFinalText() throws {
        let m1 = try insertAssistantMessage()
        let text = "Intro\n:::artifact key=\"q3\" kind=\"document\" title=\"Q3\"\nbody\n:::\n:::artifact key=\"t\" kind=\"table\" title=\"T\"\na,b"
        let saved = try dbQueue.write {
            try ChatArtifactQueries.persistArtifacts($0, conversationID: conversationID, messageID: m1, text: text)
        }
        XCTAssertEqual(saved.map(\.artifactKey), ["q3", "t"])
        XCTAssertEqual(saved.last?.content, "a,b", "an unterminated block at turn end is kept")
        let byMessage = try dbQueue.read { try ChatArtifactQueries.versionsByMessage($0, messageIDs: [m1]) }
        XCTAssertEqual(byMessage[m1], ["q3": 1, "t": 1])
    }

    func testDeletingMessageCascades() throws {
        let m1 = try insertAssistantMessage()
        _ = try save(doc("a"), message: m1)
        try dbQueue.write { try $0.execute(sql: "DELETE FROM chat_messages WHERE id = ?", arguments: [m1]) }
        XCTAssertNil(try dbQueue.read { try ChatArtifactQueries.latest($0, conversationID: conversationID, key: "q3") })
    }
}
```

- [ ] **Step 6: Run to verify it fails**

Run: `make test-swift FILTER=ChatArtifactQueriesTests`
Expected: FAIL — `cannot find 'ChatArtifactQueries' in scope`.

- [ ] **Step 7: Add the model and queries**

First `grep -n "struct ChatArtifact" WatchtowerDesktop/Sources/WatchtowerCore/Models/ChatModels.swift`; if Task 10 declared it, align it with this block; otherwise append:

```swift
package struct ChatArtifact: FetchableRecord, Decodable, Identifiable, Equatable, Sendable {
    package let id: Int64
    package let conversationID: Int64
    package let messageID: Int64
    package let artifactKey: String
    package let version: Int
    package let kind: String
    package let title: String
    package let content: String
    package let metaJSON: String?
    package let edited: Bool
    package let createdAt: Double

    package enum CodingKeys: String, CodingKey {
        case id, version, kind, title, content, edited
        case conversationID = "conversation_id"
        case messageID = "message_id"
        case artifactKey = "artifact_key"
        case metaJSON = "meta_json"
        case createdAt = "created_at"
    }

    /// Meta attributes; an unreadable blob renders as no meta (display-only data).
    package var meta: [String: String] {
        guard let data = metaJSON?.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return decoded
    }

    package var asDraft: ArtifactDraft {
        ArtifactDraft(key: artifactKey, kind: kind, title: title, meta: meta, content: content, isComplete: true)
    }
}
```

Create `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ChatArtifactQueries.swift`:

```swift
import Foundation
import GRDB

package enum ChatArtifactQueries {
    /// Stores one version. Non-edit save from the message that produced the
    /// key's current latest (non-edited) version overwrites it in place —
    /// re-persisting a turn is idempotent and the last same-key block of one
    /// message wins. Everything else inserts `max(version) + 1`.
    @discardableResult
    package static func saveVersion(
        _ db: Database, conversationID: Int64, messageID: Int64, draft: ArtifactDraft, edited: Bool
    ) throws -> ChatArtifact {
        let metaJSON = try encodeMeta(draft.meta)
        if !edited, let latest = try latest(db, conversationID: conversationID, key: draft.key),
           latest.messageID == messageID, !latest.edited {
            try db.execute(sql: """
                UPDATE chat_artifacts SET kind = ?, title = ?, content = ?, meta_json = ? WHERE id = ?
                """, arguments: [draft.kind, draft.title, draft.content, metaJSON, latest.id])
            return try fetch(db, id: latest.id)
        }
        let maxVersion = try Int.fetchOne(db, sql: """
            SELECT MAX(version) FROM chat_artifacts WHERE conversation_id = ? AND artifact_key = ?
            """, arguments: [conversationID, draft.key]) ?? 0
        try db.execute(sql: """
            INSERT INTO chat_artifacts
                (conversation_id, message_id, artifact_key, version, kind, title, content, meta_json, edited, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [conversationID, messageID, draft.key, maxVersion + 1, draft.kind, draft.title,
                             draft.content, metaJSON, edited ? 1 : 0, Date().timeIntervalSince1970])
        return try fetch(db, id: db.lastInsertedRowID)
    }

    package static func latest(_ db: Database, conversationID: Int64, key: String) throws -> ChatArtifact? {
        try ChatArtifact.fetchOne(db, sql: """
            SELECT * FROM chat_artifacts WHERE conversation_id = ? AND artifact_key = ? ORDER BY version DESC LIMIT 1
            """, arguments: [conversationID, key])
    }

    package static func versions(_ db: Database, conversationID: Int64, key: String) throws -> [ChatArtifact] {
        try ChatArtifact.fetchAll(db, sql: """
            SELECT * FROM chat_artifacts WHERE conversation_id = ? AND artifact_key = ? ORDER BY version
            """, arguments: [conversationID, key])
    }

    /// Parses a finished assistant message (`final: true`) and stores every artifact.
    @discardableResult
    package static func persistArtifacts(
        _ db: Database, conversationID: Int64, messageID: Int64, text: String
    ) throws -> [ChatArtifact] {
        try ArtifactParser.parse(text, final: true).artifacts.map {
            try saveVersion(db, conversationID: conversationID, messageID: messageID, draft: $0, edited: false)
        }
    }

    /// message id → (artifact key → the non-edited version that message produced), for card badges.
    package static func versionsByMessage(_ db: Database, messageIDs: [Int64]) throws -> [Int64: [String: Int]] {
        guard !messageIDs.isEmpty else { return [:] }
        let rows = try Row.fetchAll(db, sql: """
            SELECT message_id, artifact_key, MAX(version) AS version FROM chat_artifacts
            WHERE message_id IN (\(databaseQuestionMarks(count: messageIDs.count))) AND edited = 0
            GROUP BY message_id, artifact_key
            """, arguments: StatementArguments(messageIDs))
        var out: [Int64: [String: Int]] = [:]
        for row in rows {
            let messageID: Int64 = row["message_id"]
            let key: String = row["artifact_key"]
            out[messageID, default: [:]][key] = row["version"]
        }
        return out
    }

    private static func fetch(_ db: Database, id: Int64) throws -> ChatArtifact {
        guard let artifact = try ChatArtifact.fetchOne(db, sql: "SELECT * FROM chat_artifacts WHERE id = ?", arguments: [id]) else {
            throw DatabaseError(message: "chat artifact \(id) missing right after write")
        }
        return artifact
    }

    private static func encodeMeta(_ meta: [String: String]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(meta), as: UTF8.self)
    }
}
```

- [ ] **Step 8: Run the store tests**

Run: `make test-swift FILTER=ChatArtifactQueriesTests`
Expected: PASS.

- [ ] **Step 9: Write the failing actions + CSV tests (includes the CHAT-05 guard)**

Create `WatchtowerDesktop/Tests/Core/ArtifactActionsTests.swift`:

```swift
import XCTest
@testable import WatchtowerCore

final class ArtifactActionsTests: XCTestCase {
    private func query(_ url: URL?) -> [String: String] {
        guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [:] }
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
    }

    private func openedURL(_ action: ArtifactAction) -> URL? {
        guard case .open(let url) = action else { return nil }
        return url
    }

    func testGmailComposeEncodesEverything() throws {
        let meta = ["to": "anna@example.com, bo@example.com", "cc": "legal@example.com", "subject": #"Re: "v2" & next"#]
        let body = "Привіт,\nsee a+b=c"
        let url = try XCTUnwrap(openedURL(ArtifactActions.gmailComposeURL(meta: meta, body: body)))
        XCTAssertTrue(url.absoluteString.hasPrefix("https://mail.google.com/mail/?view=cm&fs=1&"))
        let items = query(url)
        XCTAssertEqual(items["to"], "anna@example.com, bo@example.com")
        XCTAssertEqual(items["cc"], "legal@example.com")
        XCTAssertEqual(items["su"], #"Re: "v2" & next"#)
        XCTAssertEqual(items["body"], body)
        XCTAssertTrue(url.absoluteString.contains("a%2Bb%3Dc"), "a literal + must not turn into a space")
    }

    func testGmailOverCapCopiesBodyAndOpensWithoutIt() throws {
        let body = String(repeating: "x", count: ArtifactActions.maxURLLength)
        guard case .copyThenOpen(let text, let url) = ArtifactActions.gmailComposeURL(meta: ["subject": "Long"], body: body) else {
            return XCTFail("expected copyThenOpen")
        }
        XCTAssertEqual(text, body)
        let items = query(url)
        XCTAssertNil(items["body"])
        XCTAssertEqual(items["su"], "Long")
    }

    func testMailtoFallback() throws {
        let url = try XCTUnwrap(openedURL(ArtifactActions.mailtoURL(meta: ["to": "a@x.com; b@y.com", "subject": "Hi"], body: "Body")))
        XCTAssertEqual(url.scheme, "mailto")
        XCTAssertTrue(url.absoluteString.hasPrefix("mailto:a%40x.com,b%40y.com?"))
        XCTAssertEqual(query(url)["subject"], "Hi")
        XCTAssertEqual(query(url)["body"], "Body")
    }

    func testCalendarTemplateConvertsToUTC() throws {
        let meta = ["title": "Design review", "start": "2026-09-30T10:00:00+03:00", "end": "2026-09-30T11:30:00+03:00",
                    "attendees": "a@x.com, b@y.com", "location": "Room 4"]
        let url = try XCTUnwrap(openedURL(ArtifactActions.calendarTemplateURL(meta: meta, body: "Agenda")))
        XCTAssertTrue(url.absoluteString.hasPrefix("https://calendar.google.com/calendar/render?action=TEMPLATE&"))
        let items = query(url)
        XCTAssertEqual(items["text"], "Design review")
        XCTAssertEqual(items["dates"], "20260930T070000Z/20260930T083000Z")
        XCTAssertEqual(items["details"], "Agenda")
        XCTAssertEqual(items["location"], "Room 4")
        XCTAssertEqual(items["add"], "a@x.com,b@y.com")
    }

    func testCalendarLocalTimeAllDayAndMissingEnd() throws {
        let kyiv = try XCTUnwrap(TimeZone(secondsFromGMT: 3 * 3600))
        let local = try XCTUnwrap(openedURL(ArtifactActions.calendarTemplateURL(
            meta: ["title": "T", "start": "2026-09-30T10:00"], body: "", timeZone: kyiv)))
        XCTAssertEqual(query(local)["dates"], "20260930T070000Z/20260930T080000Z", "no end → one hour")
        let allDay = try XCTUnwrap(openedURL(ArtifactActions.calendarTemplateURL(
            meta: ["title": "T", "start": "2026-09-30"], body: "", timeZone: kyiv)))
        XCTAssertEqual(query(allDay)["dates"], "20260930/20261001")
        let undated = try XCTUnwrap(openedURL(ArtifactActions.calendarTemplateURL(meta: ["title": "T", "start": "soon"], body: "")))
        XCTAssertNil(query(undated)["dates"])
    }

    func testSlackTarget() {
        let links = SlackLinkResolver(teamIDByAccount: [1: "T1"], fallbackTeamID: "T0")
        XCTAssertEqual(ArtifactActions.slackTarget(meta: ["permalink": "https://acme.slack.com/archives/C1/p123"])?.absoluteString,
                       "https://acme.slack.com/archives/C1/p123")
        XCTAssertEqual(ArtifactActions.slackTarget(meta: ["permalink": "https://evil.example/x", "channel": "1:C0123"], links: links)?.absoluteString,
                       "slack://channel?team=T1&id=C0123", "a non-Slack permalink is ignored")
        XCTAssertEqual(ArtifactActions.slackTarget(meta: ["channel": "1:C0123", "thread_ts": "1727000000.000100"], links: links)?.absoluteString,
                       "slack://channel?team=T1&id=C0123&message=1727000000.000100")
        XCTAssertEqual(ArtifactActions.slackTarget(meta: ["channel": "1:C0123", "thread_ts": "1727000000.000100"])?.absoluteString,
                       "https://slack.com/archives/C0123/p1727000000000100")
        XCTAssertNil(ArtifactActions.slackTarget(meta: ["channel": "#general"]))
        XCTAssertNil(ArtifactActions.slackTarget(meta: [:]))
    }

    func testKindActions() {
        let email = ArtifactDraft(key: "e", kind: "email", title: "E", meta: ["to": "a@x.com"], content: "B", isComplete: true)
        XCTAssertEqual(ArtifactActions.kindActions(for: email, gmailConnected: true, slackLinks: nil).map(\.title),
                       ["Open in Gmail", "Open in Mail"])
        XCTAssertEqual(ArtifactActions.kindActions(for: email, gmailConnected: false, slackLinks: nil).map(\.title), ["Open in Mail"])
        let slack = ArtifactDraft(key: "s", kind: "slack", title: "S", meta: ["channel": "C1"], content: "hello", isComplete: true)
        XCTAssertEqual(ArtifactActions.kindActions(for: slack, gmailConnected: false, slackLinks: nil).map(\.action),
                       [.copyThenOpen(text: "hello", url: URL(string: "https://slack.com/app_redirect?channel=C1"))])
        let doc = ArtifactDraft(key: "d", kind: "document", title: "D", meta: [:], content: "x", isComplete: true)
        XCTAssertEqual(ArtifactActions.kindActions(for: doc, gmailConnected: true, slackLinks: nil), [])
    }

    func testExportFile() {
        func draft(_ kind: String, _ meta: [String: String] = [:]) -> ArtifactDraft {
            ArtifactDraft(key: "k", kind: kind, title: "Q3 План", meta: meta, content: "Body", isComplete: true)
        }
        XCTAssertEqual(ArtifactActions.exportFile(for: draft("document")).name, "q3-план.md")
        XCTAssertEqual(ArtifactActions.exportFile(for: draft("table")).name, "q3-план.csv")
        XCTAssertEqual(ArtifactActions.exportFile(for: draft("code", ["language": "python"])).name, "q3-план.py")
        XCTAssertEqual(ArtifactActions.exportFile(for: draft("code")).name, "q3-план.txt")
        let email = ArtifactActions.exportFile(for: draft("email", ["to": "a@x.com", "subject": "Hi"]))
        XCTAssertEqual(email.name, "q3-план.txt")
        XCTAssertEqual(email.contents, "To: a@x.com\nSubject: Hi\n\nBody")
    }

    /// CHAT-05 — artifacts never send: every action any artifact kind can
    /// produce is a copy or an open of a compose/deep-link URL; there is no
    /// action value that could perform a network or CLI write.
    func testChat05ArtifactActionsOnlyOpenOrCopy() {
        let rich: [String: String] = [
            "to": "a@x.com", "cc": "b@x.com", "subject": "S", "channel": "1:C1", "thread_ts": "1.2",
            "permalink": "https://acme.slack.com/archives/C1/p12", "start": "2026-09-30T10:00:00Z",
            "end": "2026-09-30T11:00:00Z", "attendees": "a@x.com", "location": "L", "language": "go",
        ]
        let links = SlackLinkResolver(teamIDByAccount: [1: "T1"], fallbackTeamID: "T0")
        for kind in ArtifactParser.knownKinds.sorted() {
            for body in ["short", String(repeating: "y", count: ArtifactActions.maxURLLength)] {
                let draft = ArtifactDraft(key: "k", kind: kind, title: "T", meta: rich, content: body, isComplete: true)
                for gmail in [true, false] {
                    for item in ArtifactActions.kindActions(for: draft, gmailConnected: gmail, slackLinks: links) {
                        switch item.action {
                        case .copy:
                            break
                        case .open(let url):
                            assertComposeOrDeepLink(url, kind: kind)
                        case .copyThenOpen(_, let url):
                            if let url { assertComposeOrDeepLink(url, kind: kind) }
                        }
                    }
                }
            }
        }
    }

    private func assertComposeOrDeepLink(_ url: URL, kind: String, file: StaticString = #filePath, line: UInt = #line) {
        switch url.scheme {
        case "mailto", "slack":
            return
        case "https":
            let host = url.host ?? ""
            let allowed = host == "mail.google.com" || host == "calendar.google.com" || host == "slack.com" || host.hasSuffix(".slack.com")
            XCTAssertTrue(allowed, "\(kind): unexpected host \(host)", file: file, line: line)
        default:
            XCTFail("\(kind): unexpected scheme in \(url)", file: file, line: line)
        }
    }
}
```

Create `WatchtowerDesktop/Tests/Core/CSVTableTests.swift`:

```swift
import XCTest
@testable import WatchtowerCore

final class CSVTableTests: XCTestCase {
    func testQuotedFieldsAndEscapedQuotes() {
        XCTAssertEqual(CSVTable.parse("a,b\n1,\"x, y\"\n2,\"he said \"\"hi\"\"\""),
                       [["a", "b"], ["1", "x, y"], ["2", "he said \"hi\""]])
    }

    func testTrailingNewlineAndCRLF() {
        XCTAssertEqual(CSVTable.parse("a,b\r\n1,2\r\n"), [["a", "b"], ["1", "2"]])
        XCTAssertEqual(CSVTable.parse(""), [])
    }

    func testNewlineInsideQuotes() {
        XCTAssertEqual(CSVTable.parse("h\n\"line1\nline2\""), [["h"], ["line1\nline2"]])
    }
}
```

- [ ] **Step 10: Run to verify they fail**

Run: `make test-swift FILTER=ArtifactActionsTests` then `make test-swift FILTER=CSVTableTests`
Expected: FAIL — `cannot find 'ArtifactActions'` / `'CSVTable'`.

- [ ] **Step 11: Implement actions and CSV**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ArtifactActions.swift`:

```swift
import Foundation

/// What an artifact button does. A value, not an effect: only the App-side
/// `ArtifactActionPerformer` turns it into a pasteboard write / URL open.
/// There is deliberately no case that sends anything (CHAT-05).
package enum ArtifactAction: Equatable, Sendable {
    case open(URL)
    case copyThenOpen(text: String, url: URL?)
    case copy(String)
}

package struct ArtifactMenuItem: Equatable, Sendable {
    package let title: String
    package let systemImage: String
    package let action: ArtifactAction
}

/// Pure builders: "open ready, never send" (spec §7.2).
package enum ArtifactActions {
    /// Browsers and Gmail start misbehaving past ~8k; above it the body goes
    /// to the clipboard and compose opens without it — never truncated.
    package static let maxURLLength = 8000

    /// RFC 3986 unreserved only. NOT `.alphanumerics` — that set contains
    /// Unicode letters, which would leave Cyrillic unencoded.
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    static func query(_ items: [(String, String?)]) -> String {
        items.compactMap { name, value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return "\(name)=\(encode(value))"
        }.joined(separator: "&")
    }

    static func addresses(_ raw: String?) -> [String] {
        (raw ?? "").split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
            .map(String.init).filter { !$0.isEmpty }
    }

    private static func withBody(head: String, separator: String, bodyParam: String, body: String) -> ArtifactAction {
        let full = body.isEmpty ? head : head + separator + bodyParam + "=" + encode(body)
        if full.count < maxURLLength, let url = URL(string: full) { return .open(url) }
        return .copyThenOpen(text: body, url: URL(string: head))
    }

    package static func gmailComposeURL(meta: [String: String], body: String) -> ArtifactAction {
        let params = query([("to", meta["to"]), ("cc", meta["cc"]), ("su", meta["subject"])])
        let head = "https://mail.google.com/mail/?view=cm&fs=1" + (params.isEmpty ? "" : "&" + params)
        return withBody(head: head, separator: "&", bodyParam: "body", body: body)
    }

    package static func mailtoURL(meta: [String: String], body: String) -> ArtifactAction {
        let to = addresses(meta["to"]).map(encode).joined(separator: ",")
        let params = query([("cc", meta["cc"]), ("subject", meta["subject"])])
        let head = "mailto:" + to + (params.isEmpty ? "" : "?" + params)
        return withBody(head: head, separator: params.isEmpty ? "?" : "&", bodyParam: "body", body: body)
    }

    /// `meta["title"]` is the event title; start/end are ISO 8601 (offset,
    /// `Z`, local `yyyy-MM-ddTHH:mm[:ss]` in `timeZone`, or a date for all-day;
    /// an all-day `end` is inclusive). No end → one hour.
    package static func calendarTemplateURL(meta: [String: String], body: String, timeZone: TimeZone = .current) -> ArtifactAction {
        let params = query([
            ("text", meta["title"]),
            ("dates", calendarDates(start: meta["start"], end: meta["end"], timeZone: timeZone)),
            ("location", meta["location"]),
            ("add", addresses(meta["attendees"]).joined(separator: ",")),
        ])
        let head = "https://calendar.google.com/calendar/render?action=TEMPLATE" + (params.isEmpty ? "" : "&" + params)
        return withBody(head: head, separator: "&", bodyParam: "details", body: body)
    }

    /// Permalink (Slack hosts / `slack:` only) wins; else the stored channel id
    /// (+ `thread_ts`) through the per-account resolver, or the web
    /// archives/app_redirect links when no resolver is at hand. `#name` → nil.
    package static func slackTarget(meta: [String: String], links: SlackLinkResolver? = nil) -> URL? {
        if let raw = meta["permalink"], let url = URL(string: raw.trimmingCharacters(in: .whitespaces)), isSlackURL(url) {
            return url
        }
        guard let channel = meta["channel"]?.trimmingCharacters(in: .whitespaces), !channel.isEmpty, !channel.hasPrefix("#") else {
            return nil
        }
        let ts = meta["thread_ts"].flatMap { $0.isEmpty ? nil : $0 }
        if let links { return links.channelURL(channel, messageTS: ts) }
        if let ts { return SlackDeepLink.archives(channelID: channel, messageTS: ts) }
        return SlackDeepLink.channelRedirect(channelID: channel)
    }

    package static func kindActions(
        for draft: ArtifactDraft, gmailConnected: Bool, slackLinks: SlackLinkResolver?, timeZone: TimeZone = .current
    ) -> [ArtifactMenuItem] {
        switch draft.kind {
        case "email":
            let mail = ArtifactMenuItem(title: "Open in Mail", systemImage: "envelope",
                                        action: mailtoURL(meta: draft.meta, body: draft.content))
            guard gmailConnected else { return [mail] }
            return [ArtifactMenuItem(title: "Open in Gmail", systemImage: "envelope.badge",
                                     action: gmailComposeURL(meta: draft.meta, body: draft.content)), mail]
        case "slack":
            return [ArtifactMenuItem(title: "Copy & open in Slack", systemImage: "number",
                                     action: .copyThenOpen(text: draft.content, url: slackTarget(meta: draft.meta, links: slackLinks)))]
        case "event":
            var meta = draft.meta
            meta["title"] = draft.title
            return [ArtifactMenuItem(title: "Open in Google Calendar", systemImage: "calendar.badge.plus",
                                     action: calendarTemplateURL(meta: meta, body: draft.content, timeZone: timeZone))]
        default:
            return []
        }
    }

    package static func exportFile(for draft: ArtifactDraft) -> (name: String, contents: String) {
        let base = ArtifactParser.slug(draft.title)
        switch draft.kind {
        case "table":
            return ("\(base).csv", draft.content)
        case "code":
            return ("\(base).\(codeExtension(draft.meta["language"]))", draft.content)
        case "email":
            return ("\(base).txt", header([("To", draft.meta["to"]), ("Cc", draft.meta["cc"]), ("Subject", draft.meta["subject"])]) + draft.content)
        case "event":
            return ("\(base).txt", header([("Title", draft.title), ("Start", draft.meta["start"]), ("End", draft.meta["end"]),
                                           ("Attendees", draft.meta["attendees"]), ("Location", draft.meta["location"])]) + draft.content)
        case "slack":
            return ("\(base).txt", draft.content)
        default:
            return ("\(base).md", draft.content)
        }
    }

    private static func header(_ fields: [(String, String?)]) -> String {
        let lines = fields.compactMap { name, value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return "\(name): \(value)"
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n\n"
    }

    private static func codeExtension(_ language: String?) -> String {
        switch language?.lowercased() {
        case "swift": return "swift"
        case "go": return "go"
        case "python", "py": return "py"
        case "javascript", "js": return "js"
        case "typescript", "ts": return "ts"
        case "sql": return "sql"
        case "bash", "sh", "shell", "zsh": return "sh"
        case "json": return "json"
        case "yaml", "yml": return "yaml"
        default: return "txt"
        }
    }

    static func isSlackURL(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "slack":
            return true
        case "https":
            guard let host = url.host?.lowercased() else { return false }
            return host == "slack.com" || host.hasSuffix(".slack.com")
        default:
            return false
        }
    }

    static func calendarDates(start: String?, end: String?, timeZone: TimeZone) -> String? {
        guard let start = start?.trimmingCharacters(in: .whitespaces), !start.isEmpty else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if let day = parseDay(start, timeZone: timeZone) {
            let lastDay = end.flatMap { parseDay($0, timeZone: timeZone) } ?? day
            guard let exclusiveEnd = calendar.date(byAdding: .day, value: 1, to: lastDay) else { return nil }
            return format(day, "yyyyMMdd", timeZone) + "/" + format(exclusiveEnd, "yyyyMMdd", timeZone)
        }
        guard let startDate = parseDateTime(start, timeZone: timeZone) else { return nil }
        let endDate = end.flatMap { parseDateTime($0, timeZone: timeZone) } ?? startDate.addingTimeInterval(3600)
        let utc = TimeZone(identifier: "UTC") ?? timeZone
        return format(startDate, "yyyyMMdd'T'HHmmss'Z'", utc) + "/" + format(endDate, "yyyyMMdd'T'HHmmss'Z'", utc)
    }

    private static func parseDay(_ value: String, timeZone: TimeZone) -> Date? {
        guard value.count == 10 else { return nil }
        return formatter("yyyy-MM-dd", timeZone).date(from: value)
    }

    private static func parseDateTime(_ value: String, timeZone: TimeZone) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            if let date = formatter(pattern, timeZone).date(from: value) { return date }
        }
        return nil
    }

    private static func formatter(_ pattern: String, _ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter
    }

    private static func format(_ date: Date, _ pattern: String, _ timeZone: TimeZone) -> String {
        formatter(pattern, timeZone).string(from: date)
    }
}
```

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/CSVTable.swift`:

```swift
import Foundation

/// Minimal RFC 4180 reader for `table` artifacts (quoted fields, `""`
/// escapes, embedded newlines, LF or CRLF).
package enum CSVTable {
    package static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if inQuotes {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 2
                        continue
                    }
                    inQuotes = false
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\n", "\r\n": row.append(field); rows.append(row); row = []; field = ""
                case "\r": break
                default: field.append(character)
                }
            }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
```

- [ ] **Step 12: Run the actions and CSV tests**

Run: `make test-swift FILTER=ArtifactActionsTests` then `make test-swift FILTER=CSVTableTests`
Expected: PASS (including `testChat05ArtifactActionsOnlyOpenOrCopy`).

- [ ] **Step 13: Persist artifacts when a turn finalises**

In `WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift`, find every write that stores the FINAL assistant text — the `turn_done` handler and the stop/crash `status = 'partial'` path (both call `ChatTreeQueries.updateAssistant(db, …)`). Inside the same `dbPool.write` closure, right after `updateAssistant`, add:

```swift
                try ChatArtifactQueries.persistArtifacts(db, conversationID: conversationID, messageID: assistantMessageID, text: finalText)
```

(`conversationID`, `assistantMessageID`, `finalText` are the values already passed to `updateAssistant` there.) Do not call it from the per-delta path: versions are written once per finished turn. The error path (`status = 'error'`) is skipped — an errored turn produces no artifacts.

- [ ] **Step 14: Run the Core + VM suites**

Run: `make test-swift FILTER=Artifact` then `make test-swift FILTER=ChatViewModel`
Expected: PASS.

- [ ] **Step 15: Lint**

Run: `make lint-diff`
Expected: no new issues (if SwiftLint flags `parseAttributes` complexity, split the quoted-value scan into `private static func scanQuoted(_:from:) -> (String, Substring.Index)?` rather than raising a threshold).

- [ ] **Step 16: Commit**

```bash
git add WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ArtifactParser.swift \
  WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ArtifactActions.swift \
  WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/CSVTable.swift \
  WatchtowerDesktop/Sources/WatchtowerCore/Models/ChatModels.swift \
  WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ChatArtifactQueries.swift \
  WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift \
  WatchtowerDesktop/Tests/Core/ArtifactParserTests.swift WatchtowerDesktop/Tests/Core/ChatArtifactQueriesTests.swift \
  WatchtowerDesktop/Tests/Core/ArtifactActionsTests.swift WatchtowerDesktop/Tests/Core/CSVTableTests.swift
git commit -m "feat(desktop): artifact parser, versioned store and open/copy-only actions (CHAT-05)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 23: Artifact UI + Go prompt contract

**Files:**
- Create: `internal/chat/artifacts_examples.md`
- Modify (replace wholesale; Task 5 created it): `internal/chat/artifacts_contract.go`
- Test: `internal/chat/artifacts_contract_test.go`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ArtifactPanelModel.swift`
- Create: `WatchtowerDesktop/Sources/Views/Chat/ArtifactCardView.swift`, `WatchtowerDesktop/Sources/Views/Chat/AssistantMessageBody.swift`, `WatchtowerDesktop/Sources/Views/Chat/ArtifactPanelView.swift`, `WatchtowerDesktop/Sources/Views/Chat/ArtifactActionPerformer.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Chat/MessageBubble.swift`, `WatchtowerDesktop/Sources/Views/Chat/ChatView.swift`, `WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift`
- Test: `WatchtowerDesktop/Tests/Core/ArtifactPanelModelTests.swift`, `WatchtowerDesktop/Tests/Core/ArtifactContractFixtureTests.swift`, `WatchtowerDesktop/Tests/Core/ArtifactChat05ScanTests.swift`, `WatchtowerDesktop/Tests/ArtifactActionPerformerTests.swift`, `WatchtowerDesktop/Tests/ArtifactCardViewTests.swift`

**Interfaces:**
- Consumes: Task 22 (`ArtifactParser`, `ArtifactDraft`, `ChatArtifact`, `ChatArtifactQueries`, `ArtifactActions`, `ArtifactAction`, `CSVTable`); Task 12 `MarkdownView(text:)`; `AllowedURLSchemes.permits(_:)` (App); `GoogleAccountQueries.hasConnectedGmailAccount(_:)`, `SlackLinkResolver.load(_:)`; Task 5 `func ArtifactsContract() string` and its prompt golden test.
- Produces:
  - Go: `ArtifactsContract()` final text (embeds `artifacts_examples.md`)
  - `ArtifactPanelModel` (`@MainActor @Observable`): `init(db:conversationID:key:)`, `versions`, `selectedVersion: Int?`, `liveDraft`, `displayed: ArtifactDraft?`, `selectedArtifact`, `isEditing`, `editText`, `errorMessage`, `reload()`, `applyStreaming(_:)`, `turnFinished()`, `beginEdit()`, `cancelEdit()`, `saveEdit()`, `static keyToAutoOpen(drafts:currentKey:dismissedKeys:) -> String?`
  - `ArtifactActionPerformer.perform(_:pasteboard:open:) -> ArtifactActionOutcome`; `ArtifactExporter.export(_:onError:)`
  - `ChatViewModel`: `artifactPanel`, `openArtifact(key:)`, `closeArtifactPanel()`, `artifactVersionsByMessage`, `gmailConnected`, `slackLinks`

- [ ] **Step 1: Write the failing Go contract tests**

Create `internal/chat/artifacts_examples.md` (the ONE example set: embedded into the prompt by Go, parsed by the Swift fixture test):

```text
:::artifact key="vendor-followup" kind="email" title="Follow-up: vendor contract" to="anna@example.com" cc="legal@example.com" subject="Contract \"v2\" — next steps"
Hi Anna,

Thanks for the call today. Legal has two comments on section 4; I will send the marked-up copy by Friday.

Best,
Alex
:::

:::artifact key="standup-note" kind="slack" title="Standup update" channel="1:C0123ABC" thread_ts="1727000000.000100"
Yesterday: closed PROJ-123. Today: payments rollout review. Blocked: none.
:::

:::artifact key="design-review" kind="event" title="Design review" start="2026-09-30T10:00:00+03:00" end="2026-09-30T11:00:00+03:00" attendees="anna@example.com, bohdan@example.com" location="Room 4"
Agenda: new chat layout, artifact panel, open questions.
:::
```

Create `internal/chat/artifacts_contract_test.go`:

```go
package chat

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestArtifactsContract_TeachesFenceKindsAndRules(t *testing.T) {
	c := ArtifactsContract()
	for _, want := range []string{
		`:::artifact key="`, "\n:::\n",
		"document", "table", "email", "slack", "event", "code",
		`to="`, `subject="`, `channel="`, `thread_ts="`, `permalink="`, `start="`, `attendees="`, `language="`,
		`\"`, "SAME key", "Never say or imply", "outside any ``` code block",
	} {
		assert.Contains(t, c, want)
	}
}

func TestArtifactsContract_EmbedsTheSharedExamples(t *testing.T) {
	c := ArtifactsContract()
	assert.Contains(t, c, strings.TrimSpace(artifactExamples))
	openers, closers := 0, 0
	for _, line := range strings.Split(artifactExamples, "\n") {
		if strings.HasPrefix(line, ":::artifact ") {
			openers++
		}
		if strings.TrimSpace(line) == ":::" {
			closers++
		}
	}
	assert.Equal(t, 3, openers)
	assert.Equal(t, 3, closers, "every example must be closed")
}

func TestArtifactsContract_StaysSmall(t *testing.T) {
	assert.Less(t, len(ArtifactsContract()), 4500, "the contract is one block of a 40k-char prompt budget")
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/chat -run TestArtifactsContract`
Expected: FAIL — `undefined: artifactExamples` (and Task 5's placeholder text lacks the rules).

- [ ] **Step 3: Write the contract**

Replace `internal/chat/artifacts_contract.go` entirely:

```go
package chat

import (
	_ "embed"
	"strings"
)

// artifactExamples is shared with the Swift parser's fixture test
// (ArtifactContractFixtureTests reads internal/chat/artifacts_examples.md):
// the grammar the prompt teaches is the grammar ArtifactParser accepts.
//
//go:embed artifacts_examples.md
var artifactExamples string

const artifactsContractIntro = `ARTIFACTS
When your answer contains something the owner will copy, send, or keep — a draft email or Slack message, a meeting invite, a document or plan longer than about 15 lines, a table, or a code snippet worth saving — put it in an artifact instead of the chat text. The app shows each artifact as a card and opens it in a side panel with Copy, Export and kind-specific buttons.

Syntax: an opening line, the content, and a closing line that is exactly ":::".
:::artifact key="<stable-id>" kind="<kind>" title="<short title>" [extra attributes]
<content>
:::
- The opening and closing lines stand on their own lines, outside any ` + "```" + ` code block.
- Attribute values are double-quoted; write a literal quote inside a value as \" . Titles may be in any language.
- key: a short lowercase id (letters, digits, dashes), unique within this conversation, e.g. key="q3-plan".

Kinds and their attributes:
- document — markdown content.
- table — CSV content; the first row is the header.
- code — raw code with no ` + "```" + ` fence inside; attribute language="go", "swift", "python", ….
- email — the body as plain text; attributes to="a@x.com, b@y.com", cc="…", subject="…".
- slack — the message in Slack formatting; attribute channel="<channel id exactly as a tool returned it>" plus thread_ts="<ts>" to reply in a thread, or permalink="<Slack permalink>".
- event — the description; attributes start="2026-09-30T10:00:00+03:00" and end="…" (ISO 8601 with offset), attendees="a@x.com, b@y.com", location="…"; the title attribute is the event title.`

const artifactsContractRules = `Rules:
- Keep the chat text around an artifact short: one line on what it is and anything the owner must check. Do not repeat the artifact's content in the chat text.
- To revise an artifact, emit it again in full with the SAME key; the app keeps the earlier versions. Use a new key only for a genuinely new artifact.
- Artifacts are drafts. You cannot send, post or schedule them — the owner reviews them and opens Gmail, Slack or Google Calendar from the panel. Never say or imply that an email, message or invite was sent, posted or scheduled.
- Short answers, lists and explanations stay in plain chat text: no artifact for fewer than about 15 lines unless it is a draft to send or a table.`

// ArtifactsContract is block 5 of the chat system prompt (spec §4.1.5, §7.2).
func ArtifactsContract() string {
	return artifactsContractIntro + "\n\nExamples:\n\n" + strings.TrimSpace(artifactExamples) + "\n\n" + artifactsContractRules
}
```

- [ ] **Step 4: Run the Go tests, refresh the prompt golden**

Run: `go test ./internal/chat -run TestArtifactsContract`
Expected: PASS.

Run: `go test ./internal/chat`
Expected: Task 5's system-prompt golden test FAILS only on the changed artifacts block. Regenerate it with that test's update flag (`grep -n 'flag.Bool("update"' internal/chat/*_test.go` names it; typically `go test ./internal/chat -run TestBuildSystemPrompt -update`), inspect the golden diff (only the ARTIFACTS block moved), then rerun `go test ./internal/chat` — PASS, including the `PromptBudgetChars` budget test.

- [ ] **Step 5: Write the failing Swift Core tests (panel model, shared fixture, CHAT-05 scan)**

Create `WatchtowerDesktop/Tests/Core/ArtifactContractFixtureTests.swift`:

```swift
import XCTest
@testable import WatchtowerCore

/// `internal/chat/artifacts_examples.md` is embedded verbatim in the Go
/// `ArtifactsContract()` prompt; the Swift parser must accept exactly what
/// the prompt teaches (dual path, pinned from both sides).
final class ArtifactContractFixtureTests: XCTestCase {
    private static func fixture() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/chat/artifacts_examples.md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testPromptExamplesParse() throws {
        let artifacts = ArtifactParser.parse(try Self.fixture(), final: true).artifacts
        XCTAssertEqual(artifacts.map(\.key), ["vendor-followup", "standup-note", "design-review"])
        XCTAssertEqual(artifacts.map(\.kind), ["email", "slack", "event"])
        XCTAssertTrue(artifacts.allSatisfy(\.isComplete))
        XCTAssertEqual(artifacts[0].meta["subject"], #"Contract "v2" — next steps"#)
        XCTAssertEqual(artifacts[1].meta["channel"], "1:C0123ABC")
        XCTAssertNotNil(ArtifactActions.slackTarget(meta: artifacts[1].meta))
        let actions = ArtifactActions.kindActions(for: artifacts[2], gmailConnected: false, slackLinks: nil)
        guard case .open(let url) = actions.first?.action else { return XCTFail("event must open a calendar URL") }
        XCTAssertTrue(url.absoluteString.contains("dates=20260930T070000Z%2F20260930T080000Z"))
    }
}
```

Create `WatchtowerDesktop/Tests/Core/ArtifactPanelModelTests.swift`:

```swift
import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

@MainActor
final class ArtifactPanelModelTests: XCTestCase {
    private var dbQueue: DatabaseQueue!
    private var conversationID: Int64 = 0
    private var m1: Int64 = 0
    private var m2: Int64 = 0

    override func setUp() async throws {
        dbQueue = try TestDatabase.create()
        (conversationID, m1, m2) = try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO chat_conversations (title, created_at, updated_at) VALUES ('', 0, 0)")
            let conversation = db.lastInsertedRowID
            var ids: [Int64] = []
            for _ in 0..<2 {
                try db.execute(sql: "INSERT INTO chat_messages (conversation_id, role, text, turn_id, created_at) VALUES (?, 'assistant', '', '', 0)",
                               arguments: [conversation])
                ids.append(db.lastInsertedRowID)
            }
            return (conversation, ids[0], ids[1])
        }
    }

    private func doc(_ content: String, complete: Bool = true) -> ArtifactDraft {
        ArtifactDraft(key: "q3", kind: "document", title: "Q3", meta: [:], content: content, isComplete: complete)
    }

    private func store(_ content: String, message: Int64) throws {
        _ = try dbQueue.write {
            try ChatArtifactQueries.saveVersion($0, conversationID: conversationID, messageID: message, draft: doc(content), edited: false)
        }
    }

    func testShowsLatestAndSwitchesVersions() throws {
        try store("v1", message: m1)
        try store("v2", message: m2)
        let model = ArtifactPanelModel(db: dbQueue, conversationID: conversationID, key: "q3")
        XCTAssertEqual(model.versions.map(\.version), [1, 2])
        XCTAssertEqual(model.displayed?.content, "v2")
        model.selectedVersion = 1
        XCTAssertEqual(model.displayed?.content, "v1")
    }

    func testLiveDraftWinsWhileStreamingThenStoredVersionAfter() throws {
        let model = ArtifactPanelModel(db: dbQueue, conversationID: conversationID, key: "q3")
        XCTAssertNil(model.displayed)
        model.applyStreaming([doc("partial", complete: false)])
        XCTAssertEqual(model.displayed?.content, "partial")
        model.applyStreaming([ArtifactDraft(key: "other", kind: "document", title: "O", meta: [:], content: "x", isComplete: false)])
        XCTAssertEqual(model.displayed?.content, "partial", "another key's draft does not touch this panel")
        try store("final", message: m1)
        model.turnFinished()
        XCTAssertNil(model.liveDraft)
        XCTAssertEqual(model.displayed?.content, "final")
    }

    func testEditSavesNewEditedVersion() throws {
        try store("v1", message: m1)
        let model = ArtifactPanelModel(db: dbQueue, conversationID: conversationID, key: "q3")
        model.beginEdit()
        XCTAssertTrue(model.isEditing)
        XCTAssertEqual(model.editText, "v1")
        model.editText = "v1 edited"
        model.saveEdit()
        XCTAssertFalse(model.isEditing)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.versions.map(\.version), [1, 2])
        XCTAssertEqual(model.versions.last?.edited, true)
        XCTAssertEqual(model.displayed?.content, "v1 edited")
    }

    func testUnchangedEditWritesNothingAndEditIsBlockedWhileWriting() throws {
        try store("v1", message: m1)
        let model = ArtifactPanelModel(db: dbQueue, conversationID: conversationID, key: "q3")
        model.beginEdit()
        model.saveEdit()
        XCTAssertEqual(model.versions.count, 1)
        model.applyStreaming([doc("streaming", complete: false)])
        model.beginEdit()
        XCTAssertFalse(model.isEditing)
    }

    func testFailedSaveKeepsEditorOpen() throws {
        try store("v1", message: m1)
        let model = ArtifactPanelModel(db: dbQueue, conversationID: conversationID, key: "q3")
        model.beginEdit()
        model.editText = "changed"
        try dbQueue.write { try $0.execute(sql: "DROP TABLE chat_artifacts") }
        model.saveEdit()
        XCTAssertTrue(model.isEditing, "UI state is cleared only after the write succeeds")
        XCTAssertEqual(model.editText, "changed")
        XCTAssertNotNil(model.errorMessage)
    }

    func testKeyToAutoOpen() {
        let writing = doc("x", complete: false)
        XCTAssertEqual(ArtifactPanelModel.keyToAutoOpen(drafts: [writing], currentKey: nil, dismissedKeys: []), "q3")
        XCTAssertNil(ArtifactPanelModel.keyToAutoOpen(drafts: [writing], currentKey: "q3", dismissedKeys: []))
        XCTAssertNil(ArtifactPanelModel.keyToAutoOpen(drafts: [writing], currentKey: nil, dismissedKeys: ["q3"]))
        XCTAssertNil(ArtifactPanelModel.keyToAutoOpen(drafts: [doc("x")], currentKey: nil, dismissedKeys: []))
    }
}
```

Create `WatchtowerDesktop/Tests/Core/ArtifactChat05ScanTests.swift`:

```swift
import XCTest

/// CHAT-05 — artifacts never send. Every source on the artifact path may only
/// build URLs, copy to the pasteboard, open URLs and write local chat rows;
/// none may reach a process, the CLI, the network or the provider session.
final class ArtifactChat05ScanTests: XCTestCase {
    func testChat05ArtifactSurfacesNeverWrite() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .appendingPathComponent("Sources")
        let files = [
            "WatchtowerCore/Services/Chat/ArtifactParser.swift",
            "WatchtowerCore/Services/Chat/ArtifactActions.swift",
            "WatchtowerCore/Services/Chat/ArtifactPanelModel.swift",
            "Views/Chat/ArtifactPanelView.swift",
            "Views/Chat/ArtifactCardView.swift",
            "Views/Chat/ArtifactActionPerformer.swift",
        ]
        let forbidden = ["Process(", "CLIRunner", "URLSession", "findCLIPath", "WatchtowerAIService", "ChatSessionPool"]
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for token in forbidden {
                XCTAssertFalse(text.contains(token), "\(file) must not reference \(token) (CHAT-05)")
            }
        }
    }
}
```

- [ ] **Step 6: Run to verify they fail**

Run: `make test-swift FILTER=ArtifactContractFixtureTests` (expected PASS already — the parser exists; it guards drift from now on), then `make test-swift FILTER=ArtifactPanelModelTests` and `make test-swift FILTER=ArtifactChat05ScanTests`
Expected: FAIL — `cannot find 'ArtifactPanelModel'`; the scan fails opening the not-yet-created view files.

- [ ] **Step 7: Implement the panel model**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ArtifactPanelModel.swift`:

```swift
import Foundation
import GRDB
import Observation

/// State of the artifact side panel for one (conversation, key). Owned by
/// ChatViewModel so the panel survives navigation like the turn itself.
@MainActor @Observable
package final class ArtifactPanelModel {
    package let conversationID: Int64
    package let key: String
    package private(set) var versions: [ChatArtifact] = []
    /// nil = follow the latest version (and a live draft while a turn writes this key).
    package var selectedVersion: Int?
    package private(set) var liveDraft: ArtifactDraft?
    package private(set) var isEditing = false
    package var editText = ""
    package private(set) var errorMessage: String?
    @ObservationIgnored private let db: any DatabaseWriter

    package init(db: any DatabaseWriter, conversationID: Int64, key: String) {
        self.db = db
        self.conversationID = conversationID
        self.key = key
        reload()
    }

    package func reload() {
        do {
            versions = try db.read { try ChatArtifactQueries.versions($0, conversationID: conversationID, key: key) }
            if let selected = selectedVersion, !versions.contains(where: { $0.version == selected }) {
                selectedVersion = nil
            }
            errorMessage = nil
        } catch {
            errorMessage = "Could not load the artifact: \(error.localizedDescription)"
        }
    }

    package var selectedArtifact: ChatArtifact? {
        guard let selectedVersion else { return versions.last }
        return versions.first { $0.version == selectedVersion }
    }

    package var displayed: ArtifactDraft? {
        if selectedVersion == nil, let liveDraft { return liveDraft }
        return selectedArtifact?.asDraft
    }

    /// Feed with the streaming message's drafts (`parse(…, final: false).artifacts`).
    package func applyStreaming(_ drafts: [ArtifactDraft]) {
        guard let draft = drafts.last(where: { $0.key == key }) else { return }
        liveDraft = draft
    }

    /// The turn ended and its artifacts are persisted: drop the draft, show the stored version.
    package func turnFinished() {
        liveDraft = nil
        reload()
    }

    package func beginEdit() {
        guard liveDraft == nil, let displayed else { return }
        editText = displayed.content
        isEditing = true
    }

    package func cancelEdit() {
        isEditing = false
        editText = ""
    }

    package func saveEdit() {
        guard isEditing, let base = selectedArtifact else { return }
        guard editText != base.content else {
            cancelEdit()
            return
        }
        var draft = base.asDraft
        draft.content = editText
        do {
            _ = try db.write {
                try ChatArtifactQueries.saveVersion($0, conversationID: conversationID, messageID: base.messageID,
                                                    draft: draft, edited: true)
            }
            selectedVersion = nil
            cancelEdit()
            reload()
        } catch {
            errorMessage = "Could not save the edit: \(error.localizedDescription)"
        }
    }

    /// The key a streaming turn should auto-open: the block being written now,
    /// unless it is already shown or the owner closed it during this turn.
    package static func keyToAutoOpen(drafts: [ArtifactDraft], currentKey: String?, dismissedKeys: Set<String>) -> String? {
        guard let writing = drafts.last(where: { !$0.isComplete }),
              writing.key != currentKey,
              !dismissedKeys.contains(writing.key) else { return nil }
        return writing.key
    }
}
```

- [ ] **Step 8: Run the panel-model tests**

Run: `make test-swift FILTER=ArtifactPanelModelTests`
Expected: PASS.

- [ ] **Step 9: Write the failing App-side tests**

Create `WatchtowerDesktop/Tests/ArtifactActionPerformerTests.swift`:

```swift
import XCTest
import AppKit
import WatchtowerCore
@testable import WatchtowerDesktop

@MainActor
final class ArtifactActionPerformerTests: XCTestCase {
    private func pasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("wt-artifact-\(UUID().uuidString)"))
    }

    func testCopy() {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        let outcome = ArtifactActionPerformer.perform(.copy("draft"), pasteboard: board, open: { _ in XCTFail("no open"); return false })
        XCTAssertEqual(outcome, ArtifactActionOutcome(copied: true, opened: false))
        XCTAssertEqual(board.string(forType: .string), "draft")
    }

    func testCopyThenOpen() throws {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        var opened: [URL] = []
        let url = try XCTUnwrap(URL(string: "slack://channel?team=T1&id=C1"))
        let outcome = ArtifactActionPerformer.perform(.copyThenOpen(text: "msg", url: url), pasteboard: board,
                                                      open: { opened.append($0); return true })
        XCTAssertEqual(outcome, ArtifactActionOutcome(copied: true, opened: true))
        XCTAssertEqual(opened, [url])
        XCTAssertEqual(board.string(forType: .string), "msg")
    }

    func testDisallowedSchemeIsNeverOpened() throws {
        var opened = 0
        let outcome = ArtifactActionPerformer.perform(.open(try XCTUnwrap(URL(string: "file:///Applications/Calculator.app"))),
                                                      pasteboard: pasteboard(), open: { _ in opened += 1; return true })
        XCTAssertEqual(opened, 0)
        XCTAssertFalse(outcome.opened)
    }
}
```

Create `WatchtowerDesktop/Tests/ArtifactCardViewTests.swift`:

```swift
import XCTest
import SwiftUI
import ViewInspector
import WatchtowerCore
@testable import WatchtowerDesktop

@MainActor
final class ArtifactCardViewTests: XCTestCase {
    private let draft = ArtifactDraft(key: "q3", kind: "document", title: "Q3 plan", meta: [:], content: "x", isComplete: false)

    func testWritingStateShowsProgressTitle() throws {
        let card = ArtifactCardView(draft: draft, isWriting: true, version: nil, onOpen: {})
        XCTAssertNoThrow(try card.inspect().find(text: "Writing Q3 plan…"))
    }

    func testDoneStateShowsTitleVersionAndOpens() throws {
        var opened = 0
        let card = ArtifactCardView(draft: draft, isWriting: false, version: 2, onOpen: { opened += 1 })
        XCTAssertNoThrow(try card.inspect().find(text: "Q3 plan"))
        XCTAssertNoThrow(try card.inspect().find(text: "Document · v2"))
        try card.inspect().find(ViewType.Button.self).tap()
        XCTAssertEqual(opened, 1)
    }

    func testAssistantBodySplitsMarkdownAndCards() throws {
        let text = "Intro\n:::artifact key=\"q3\" kind=\"table\" title=\"Numbers\"\na,b\n:::\nOutro"
        let body = AssistantMessageBody(text: text, isStreaming: false, versions: ["q3": 1], onOpenArtifact: { _ in })
        XCTAssertNoThrow(try body.inspect().find(ArtifactCardView.self))
        XCTAssertNoThrow(try body.inspect().find(text: "Table · v1"))
    }
}
```

- [ ] **Step 10: Run to verify they fail**

Run: `make test-swift FILTER=ArtifactActionPerformerTests` then `make test-swift FILTER=ArtifactCardViewTests`
Expected: FAIL — `cannot find 'ArtifactActionPerformer'` / `'ArtifactCardView'`.

- [ ] **Step 11: Implement performer, exporter, card and message body**

Create `WatchtowerDesktop/Sources/Views/Chat/ArtifactActionPerformer.swift`:

```swift
import AppKit
import WatchtowerCore

struct ArtifactActionOutcome: Equatable {
    var copied = false
    var opened = false
}

/// The only place an `ArtifactAction` becomes an effect: a pasteboard write
/// and/or opening an allowlisted URL. Nothing here sends (CHAT-05).
enum ArtifactActionPerformer {
    @discardableResult
    static func perform(
        _ action: ArtifactAction,
        pasteboard: NSPasteboard = .general,
        open: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) -> ArtifactActionOutcome {
        var outcome = ArtifactActionOutcome()
        switch action {
        case .copy(let text):
            outcome.copied = copy(text, to: pasteboard)
        case .open(let url):
            outcome.opened = openIfAllowed(url, open)
        case .copyThenOpen(let text, let url):
            outcome.copied = copy(text, to: pasteboard)
            if let url { outcome.opened = openIfAllowed(url, open) }
        }
        return outcome
    }

    private static func copy(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    private static func openIfAllowed(_ url: URL, _ open: (URL) -> Bool) -> Bool {
        guard AllowedURLSchemes.permits(url) else { return false }
        return open(url)
    }
}

/// Export via NSSavePanel — the owner picks the destination, which is the
/// consent; no TCC prompt.
@MainActor
enum ArtifactExporter {
    static func export(_ draft: ArtifactDraft, onError: @escaping (String) -> Void) {
        let file = ArtifactActions.exportFile(for: draft)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try file.contents.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                onError("Export failed: \(error.localizedDescription)")
            }
        }
    }
}
```

Create `WatchtowerDesktop/Sources/Views/Chat/ArtifactCardView.swift`:

```swift
import SwiftUI
import WatchtowerCore

struct ArtifactCardView: View {
    let draft: ArtifactDraft
    let isWriting: Bool
    var version: Int?
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: Self.icon(for: draft.kind))
                    .font(.title3)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isWriting ? "Writing \(draft.title)…" : draft.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if isWriting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "sidebar.right").foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: 420, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(.separatorColor).opacity(0.5)))
        }
        .buttonStyle(.plain)
        .help("Open \(draft.title)")
    }

    private var subtitle: String {
        let label = Self.kindLabel(draft.kind)
        guard let version else { return label }
        return "\(label) · v\(version)"
    }

    static func icon(for kind: String) -> String {
        switch kind {
        case "table": return "tablecells"
        case "email": return "envelope"
        case "slack": return "number"
        case "event": return "calendar"
        case "code": return "chevron.left.forwardslash.chevron.right"
        default: return "doc.richtext"
        }
    }

    static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "table": return "Table"
        case "email": return "Email draft"
        case "slack": return "Slack message draft"
        case "event": return "Event draft"
        case "code": return "Code"
        default: return "Document"
        }
    }
}
```

Create `WatchtowerDesktop/Sources/Views/Chat/AssistantMessageBody.swift`:

```swift
import SwiftUI
import WatchtowerCore

/// Assistant text with artifact blocks replaced by cards. Parsing is per
/// message, so only the streaming message re-parses on a delta.
struct AssistantMessageBody: View {
    let text: String
    let isStreaming: Bool
    var versions: [String: Int] = [:]
    var onOpenArtifact: (String) -> Void = { _ in }

    var body: some View {
        let parsed = ArtifactParser.parse(text, final: !isStreaming)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parsed.segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .markdown(let markdown):
                    MarkdownView(text: markdown)
                case .artifact(let draft):
                    ArtifactCardView(draft: draft, isWriting: isStreaming && !draft.isComplete,
                                     version: versions[draft.key], onOpen: { onOpenArtifact(draft.key) })
                }
            }
        }
    }
}
```

In `WatchtowerDesktop/Sources/Views/Chat/MessageBubble.swift`, add `var artifactVersions: [String: Int] = [:]` and `var onOpenArtifact: (String) -> Void = { _ in }`; in the `.assistant` case replace the text rendering (the `MarkdownView(text: message.text)` Task 12/15 put there, streaming and non-streaming alike) with:

```swift
AssistantMessageBody(text: message.text, isStreaming: message.isStreaming,
                     versions: artifactVersions, onOpenArtifact: onOpenArtifact)
```

- [ ] **Step 12: Implement the panel view**

Create `WatchtowerDesktop/Sources/Views/Chat/ArtifactPanelView.swift`:

```swift
import SwiftUI
import WatchtowerCore

struct ArtifactPanelView: View {
    @Bindable var model: ArtifactPanelModel
    let gmailConnected: Bool
    let slackLinks: SlackLinkResolver?
    var onClose: () -> Void

    @State private var notice: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = model.errorMessage ?? notice {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(model.errorMessage != nil ? .red : .secondary)
                    .padding(8)
            }
            content
            Divider()
            toolbar
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: ArtifactCardView.icon(for: model.displayed?.kind ?? "document"))
            Text(model.displayed?.title ?? model.key)
                .font(.headline)
                .lineLimit(1)
            if model.selectedArtifact?.edited == true && model.liveDraft == nil {
                Text("edited").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.versions.count > 1 {
                Picker("Version", selection: $model.selectedVersion) {
                    Text("Latest").tag(Int?.none)
                    ForEach(model.versions) { version in
                        Text("v\(version.version)").tag(Optional(version.version))
                    }
                }
                .labelsHidden()
                .frame(width: 100)
            }
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Close")
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if model.isEditing {
            TextEditor(text: $model.editText)
                .font(.system(.body, design: .monospaced))
                .padding(6)
        } else if let draft = model.displayed {
            ScrollView {
                ArtifactContentView(draft: draft)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Nothing here yet", systemImage: "doc")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if model.isEditing {
                Button("Save") { model.saveEdit() }.keyboardShortcut(.defaultAction)
                Button("Cancel") { model.cancelEdit() }
            } else if let draft = model.displayed {
                Button("Edit") { model.beginEdit() }.disabled(model.liveDraft != nil)
                Button("Copy") { run(.copy(draft.content)) }
                Button("Export…") {
                    ArtifactExporter.export(draft) { notice = $0 }
                }
                ForEach(ArtifactActions.kindActions(for: draft, gmailConnected: gmailConnected, slackLinks: slackLinks), id: \.title) { item in
                    Button { run(item.action) } label: { Label(item.title, systemImage: item.systemImage) }
                }
                .disabled(!draft.isComplete)
            }
            Spacer()
        }
        .padding(10)
    }

    private func run(_ action: ArtifactAction) {
        let outcome = ArtifactActionPerformer.perform(action)
        if case .copyThenOpen(_, let url) = action, outcome.copied {
            notice = url == nil ? "Copied to the clipboard." : "Copied to the clipboard — paste it into the opened draft."
        } else if case .copy = action, outcome.copied {
            notice = "Copied to the clipboard."
        } else {
            notice = nil
        }
    }
}

private struct ArtifactContentView: View {
    let draft: ArtifactDraft

    var body: some View {
        switch draft.kind {
        case "table":
            CSVGridView(rows: CSVTable.parse(draft.content))
        case "code":
            MarkdownView(text: "````\(draft.meta["language"] ?? "")\n\(draft.content)\n````")
        case "email":
            fields([("To", draft.meta["to"]), ("Cc", draft.meta["cc"]), ("Subject", draft.meta["subject"])])
        case "slack":
            fields([("Channel", draft.meta["channel"] ?? draft.meta["permalink"])])
        case "event":
            fields([("Start", draft.meta["start"]), ("End", draft.meta["end"]),
                    ("Attendees", draft.meta["attendees"]), ("Location", draft.meta["location"])])
        default:
            MarkdownView(text: draft.content)
        }
    }

    private func fields(_ items: [(String, String?)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                ForEach(items.filter { !($0.1 ?? "").isEmpty }, id: \.0) { name, value in
                    GridRow {
                        Text(name).foregroundStyle(.secondary)
                        Text(value ?? "").textSelection(.enabled)
                    }
                }
            }
            Divider()
            Text(draft.content).textSelection(.enabled)
        }
    }
}

private struct CSVGridView: View {
    let rows: [[String]]

    var body: some View {
        let width = rows.map(\.count).max() ?? 0
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(0..<width, id: \.self) { column in
                            Text(column < row.count ? row[column] : "")
                                .fontWeight(index == 0 ? .semibold : .regular)
                                .textSelection(.enabled)
                        }
                    }
                    if index == 0 { Divider() }
                }
            }
        }
    }
}
```

- [ ] **Step 13: Wire the VM and ChatView**

In `ChatViewModel`:

```swift
    private(set) var artifactPanel: ArtifactPanelModel?
    private(set) var artifactVersionsByMessage: [Int64: [String: Int]] = [:]
    private(set) var gmailConnected = false
    private(set) var slackLinks: SlackLinkResolver?
    private var dismissedArtifactKeys: Set<String> = []

    func openArtifact(key: String) {
        guard let conversationID = currentConversationID, artifactPanel?.key != key else { return }
        artifactPanel = ArtifactPanelModel(db: dbManager.dbPool, conversationID: conversationID, key: key)
    }

    func closeArtifactPanel() {
        if let key = artifactPanel?.key { dismissedArtifactKeys.insert(key) }
        artifactPanel = nil
    }

    /// Called wherever the streaming assistant text is updated (Task 14's delta path).
    private func updateLiveArtifacts(streamingText: String) {
        let drafts = ArtifactParser.parse(streamingText, final: false).artifacts
        if let key = ArtifactPanelModel.keyToAutoOpen(drafts: drafts, currentKey: artifactPanel?.key,
                                                      dismissedKeys: dismissedArtifactKeys) {
            openArtifact(key: key)
        }
        artifactPanel?.applyStreaming(drafts)
    }
```

(`currentConversationID` is Task 14's selected-conversation property — use its actual name.) Then:
- at turn start (where Task 14 emits the `turn` command): `dismissedArtifactKeys = []`;
- in the delta handler, after the streaming text is updated: `updateLiveArtifacts(streamingText: <the streaming message's text>)`;
- after the final write that now calls `persistArtifacts` (Task 22 Step 13) succeeds: `artifactPanel?.turnFinished()` and reload `artifactVersionsByMessage`;
- where the active path loads (next to `attachmentsByMessage`): `artifactVersionsByMessage = try ChatArtifactQueries.versionsByMessage(db, messageIDs: path.map(\.id))`, and in the same read `gmailConnected = try GoogleAccountQueries.hasConnectedGmailAccount(db)` and `slackLinks = try SlackLinkResolver.load(db)`;
- in `select(conversationID:)` / `newConversation(projectID:)`: `artifactPanel = nil; dismissedArtifactKeys = []`.

In `ChatView`, pass `artifactVersions: vm.artifactVersionsByMessage[message.id] ?? [:]` and `onOpenArtifact: { vm.openArtifact(key: $0) }` to each assistant `MessageBubble`, and attach to the thread column:

```swift
        .inspector(isPresented: Binding(
            get: { vm.artifactPanel != nil },
            set: { if !$0 { vm.closeArtifactPanel() } }
        )) {
            if let panel = vm.artifactPanel {
                ArtifactPanelView(model: panel, gmailConnected: vm.gmailConnected, slackLinks: vm.slackLinks,
                                  onClose: { vm.closeArtifactPanel() })
                    .inspectorColumnWidth(min: 320, ideal: 460, max: 900)
            }
        }
```

- [ ] **Step 14: Run every Task 23 suite plus the neighbours**

Run, one at a time: `make test-swift FILTER=ArtifactActionPerformerTests`, `make test-swift FILTER=ArtifactCardViewTests`, `make test-swift FILTER=ArtifactChat05ScanTests`, `make test-swift FILTER=Artifact`, `make test-swift FILTER=ChatViewModel`, `make test-swift FILTER=MessageBubble`
Expected: PASS everywhere (`testChat05ArtifactSurfacesNeverWrite` now finds all six files).

Run: `go test ./internal/chat`
Expected: PASS.

- [ ] **Step 15: Manual check (the pieces unit tests cannot see)**

Run `make app-dev`, open the main chat, ask: "Draft an email to anna@example.com about the Q3 plan, then a Slack standup note for channel <a real channel id from a tool result>." Confirm: the card reads "Writing …" while streaming and the panel opens and fills live; after the turn the card shows "v1"; "Open in Gmail"/"Open in Mail" opens a compose window with to/subject/body filled and nothing is sent; "Copy & open in Slack" copies the text and opens the channel; Edit → Save shows `v2 · edited`; Export writes a `.txt` via the save panel; asking "make it shorter" produces v2 of the same key; closing the panel mid-stream keeps it closed for that turn. No macOS permission dialog appears at any point.

- [ ] **Step 16: Lint**

Run: `make lint-diff`
Expected: no new issues.

- [ ] **Step 17: Commit**

```bash
git add internal/chat/artifacts_examples.md internal/chat/artifacts_contract.go internal/chat/artifacts_contract_test.go \
  internal/chat/testdata \
  WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ArtifactPanelModel.swift \
  WatchtowerDesktop/Sources/Views/Chat/ArtifactCardView.swift WatchtowerDesktop/Sources/Views/Chat/AssistantMessageBody.swift \
  WatchtowerDesktop/Sources/Views/Chat/ArtifactPanelView.swift WatchtowerDesktop/Sources/Views/Chat/ArtifactActionPerformer.swift \
  WatchtowerDesktop/Sources/Views/Chat/MessageBubble.swift WatchtowerDesktop/Sources/Views/Chat/ChatView.swift \
  WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift \
  WatchtowerDesktop/Tests/Core/ArtifactPanelModelTests.swift WatchtowerDesktop/Tests/Core/ArtifactContractFixtureTests.swift \
  WatchtowerDesktop/Tests/Core/ArtifactChat05ScanTests.swift WatchtowerDesktop/Tests/ArtifactActionPerformerTests.swift \
  WatchtowerDesktop/Tests/ArtifactCardViewTests.swift
git commit -m "feat(chat): artifact cards, side panel with versions/edit/export, and the artifacts prompt contract

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

(`internal/chat/testdata` is listed for the regenerated system-prompt golden if Task 5 keeps it there; drop it from the `git add` if the golden lives elsewhere — `git status` shows the path.)
