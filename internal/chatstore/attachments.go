package chatstore

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"unicode/utf8"

	"watchtower/internal/db"
)

// The Mac's attachment limits (Swift AttachmentValidator; Go chat.Max*Bytes).
const (
	ImageLimit int64 = 5 * 1024 * 1024
	PDFLimit   int64 = 32 * 1024 * 1024
	TextLimit  int64 = 256 * 1024
)

// MaxAttachmentBytes is the largest file any kind takes (a PDF).
const MaxAttachmentBytes = PDFLimit

// FilesDirName is the attachments' folder in the workspace
// (ChatAttachmentStore.defaultRootDir).
const FilesDirName = "chat_files"

// AttachmentKind is a validated file: its mime and kind (image, pdf, text).
type AttachmentKind struct {
	Class string // "image" | "pdf" | "text"
	Mime  string
}

// Rejection reasons (Swift AttachmentRejection).
const (
	RejectUnsupported = "unsupported_type"
	RejectTooLarge    = "too_large"
	RejectNotUTF8     = "not_utf8"
)

// Rejection is why a file cannot be attached; Message is the Mac's text.
type Rejection struct {
	Reason, FileName string
	Limit            int64
}

// limitText is ByteCountFormatter.string(fromByteCount:countStyle: .file) of
// the three limits in the en_US locale (the hub has no owner locale).
var limitText = map[int64]string{ImageLimit: "5.2 MB", PDFLimit: "33.6 MB", TextLimit: "262 KB"}

// Message is AttachmentRejection.message.
func (r *Rejection) Message() string {
	switch r.Reason {
	case RejectTooLarge:
		return r.FileName + " is larger than " + limitText[r.Limit]
	case RejectNotUTF8:
		return r.FileName + " is not a UTF-8 text file"
	default:
		return r.FileName + ": only images, PDFs and text files can be attached"
	}
}

func (r *Rejection) Error() string { return r.Message() }

// textExtensions is AttachmentValidator.textExtensions.
var textExtensions = map[string]bool{}

func init() {
	for _, e := range strings.Fields(`txt md markdown csv tsv json yaml yml log xml toml ini
		go swift py js ts tsx jsx java kt rb rs c h cpp hpp m cs php sh zsh bash sql html css scss`) {
		textExtensions[e] = true
	}
}

// ValidateAttachment is AttachmentValidator.validate(data:fileName:): the
// kind by magic bytes (Go's sniffer signatures), else a text extension, then
// the kind's size limit and, for text, UTF-8.
func ValidateAttachment(data []byte, fileName string) (AttachmentKind, *Rejection) {
	kind, limit, ok := classifyAttachment(data, fileName)
	if !ok {
		return AttachmentKind{}, &Rejection{Reason: RejectUnsupported, FileName: fileName}
	}
	if int64(len(data)) > limit {
		return AttachmentKind{}, &Rejection{Reason: RejectTooLarge, FileName: fileName, Limit: limit}
	}
	if kind.Class == "text" && !utf8.Valid(data) {
		return AttachmentKind{}, &Rejection{Reason: RejectNotUTF8, FileName: fileName}
	}
	return kind, nil
}

func classifyAttachment(data []byte, fileName string) (AttachmentKind, int64, bool) {
	has := func(sig []byte) bool { return bytes.HasPrefix(data, sig) }
	switch {
	case has([]byte{0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A}):
		return AttachmentKind{"image", "image/png"}, ImageLimit, true
	case has([]byte{0xFF, 0xD8, 0xFF}):
		return AttachmentKind{"image", "image/jpeg"}, ImageLimit, true
	case has([]byte("GIF87a")), has([]byte("GIF89a")):
		return AttachmentKind{"image", "image/gif"}, ImageLimit, true
	case has([]byte("RIFF")) && len(data) >= 14 && string(data[8:14]) == "WEBPVP":
		return AttachmentKind{"image", "image/webp"}, ImageLimit, true
	case has([]byte("%PDF-")):
		return AttachmentKind{"pdf", "application/pdf"}, PDFLimit, true
	}
	ext := strings.ToLower(PathExtension(fileName))
	if !textExtensions[ext] {
		return AttachmentKind{}, 0, false
	}
	return AttachmentKind{"text", textMime(ext)}, TextLimit, true
}

// textMime is AttachmentValidator.textMime.
func textMime(ext string) string {
	switch ext {
	case "md", "markdown":
		return "text/markdown"
	case "csv":
		return "text/csv"
	case "tsv":
		return "text/tab-separated-values"
	case "json":
		return "application/json"
	case "yaml", "yml":
		return "application/yaml"
	case "xml":
		return "application/xml"
	case "toml":
		return "application/toml"
	case "html":
		return "text/html"
	}
	return "text/plain"
}

// FileExtension is AttachmentKind.fileExtension(fallbackName:): canonical for
// binaries, the original (lowercased) for text.
func (k AttachmentKind) FileExtension(fallbackName string) string {
	switch k.Class {
	case "image":
		switch k.Mime {
		case "image/jpeg":
			return "jpg"
		case "image/gif":
			return "gif"
		case "image/webp":
			return "webp"
		}
		return "png"
	case "pdf":
		return "pdf"
	}
	if ext := strings.ToLower(PathExtension(fallbackName)); ext != "" {
		return ext
	}
	return "txt"
}

// PathExtension is NSString.pathExtension as the fixture pins it: the last
// path component's text after its last dot, ignoring leading dots; "" when
// there is none, it is empty or it holds a space.
func PathExtension(name string) string {
	name = strings.TrimRight(name, "/")
	if i := strings.LastIndexByte(name, '/'); i >= 0 {
		name = name[i+1:]
	}
	name = strings.TrimLeft(name, ".")
	i := strings.LastIndexByte(name, '.')
	if i < 0 {
		return ""
	}
	ext := name[i+1:]
	if ext == "" || strings.Contains(ext, " ") {
		return ""
	}
	return ext
}

// ConversationDir is ChatAttachmentOwner.conversation(id).directoryName.
func ConversationDir(conv int64) string {
	return "conversations/" + strconv.FormatInt(conv, 10)
}

// RemoveConversationFiles is ChatAttachmentStore.removeFiles(for:
// .conversation(id)): the conversation's whole folder, after its delete
// committed. A missing folder is no error.
func RemoveConversationFiles(root string, conv int64) error {
	if root == "" {
		return nil
	}
	return os.RemoveAll(filepath.Join(root, filepath.FromSlash(ConversationDir(conv))))
}

// SaveAttachment is ChatAttachmentStore.store for a conversation's file:
// the bytes go 0600 under <root>/conversations/<id>/ (0700), reusing a file
// of the same conversation with the same sha256 that is still on disk, and a
// pending chat_attachments row (message_id NULL) is inserted. A new file is
// written to a temporary name and renamed into place; it is removed when the
// row cannot be written. ErrConversationGone when the conversation does not
// exist.
func SaveAttachment(ctx context.Context, d *db.DB, root string, conv int64, name string, kind AttachmentKind, data []byte, now float64) (int64, error) {
	sum := sha256.Sum256(data)
	sha := hex.EncodeToString(sum[:])
	var existing sql.NullString
	err := d.QueryRowContext(ctx, `SELECT path FROM chat_attachments WHERE conversation_id = ? AND sha256 = ? ORDER BY id LIMIT 1`,
		conv, sha).Scan(&existing)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return 0, fmt.Errorf("reading chat attachments: %w", err)
	}
	path, fresh := "", false
	if existing.Valid {
		if _, err := os.Stat(existing.String); err == nil {
			path = existing.String
		}
	}
	if path == "" {
		if path, err = writeAttachmentFile(root, conv, kind.FileExtension(name), data); err != nil {
			return 0, err
		}
		fresh = true
	}
	res, err := d.ExecContext(ctx, `INSERT INTO chat_attachments (conversation_id, project_id, name, mime, size, path, sha256, created_at)
		SELECT id, NULL, ?, ?, ?, ?, ?, ? FROM chat_conversations WHERE id = ?`,
		name, kind.Mime, len(data), path, sha, now, conv)
	if err == nil {
		var n int64
		if n, err = res.RowsAffected(); err == nil && n == 0 {
			err = ErrConversationGone
		}
	}
	if err != nil {
		if fresh {
			_ = os.Remove(path)
		}
		if errors.Is(err, ErrConversationGone) {
			return 0, err
		}
		return 0, fmt.Errorf("saving a chat attachment: %w", err)
	}
	return res.LastInsertId()
}

func writeAttachmentFile(root string, conv int64, ext string, data []byte) (string, error) {
	if root == "" {
		return "", errors.New("chatstore: no attachments folder")
	}
	dir := filepath.Join(root, filepath.FromSlash(ConversationDir(conv)))
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", fmt.Errorf("creating the attachments folder: %w", err)
	}
	var id [16]byte
	_, _ = rand.Read(id[:])
	id[6] = id[6]&0x0f | 0x40
	id[8] = id[8]&0x3f | 0x80
	base := fmt.Sprintf("%x-%x-%x-%x-%x", id[0:4], id[4:6], id[6:8], id[8:10], id[10:16])
	final := filepath.Join(dir, base+"."+ext)
	tmp, err := os.CreateTemp(dir, ".upload-*")
	if err != nil {
		return "", fmt.Errorf("writing a chat attachment: %w", err)
	}
	_, werr := tmp.Write(data)
	cerr := tmp.Close()
	if werr == nil {
		werr = cerr
	}
	if werr == nil {
		werr = os.Chmod(tmp.Name(), 0o600)
	}
	if werr == nil {
		werr = os.Rename(tmp.Name(), final)
	}
	if werr != nil {
		_ = os.Remove(tmp.Name())
		return "", fmt.Errorf("writing a chat attachment: %w", werr)
	}
	return final, nil
}
