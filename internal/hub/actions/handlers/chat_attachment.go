package handlers

import (
	"context"
	"errors"
	"log"
	"os"
	"path/filepath"
	"strings"

	"watchtower/internal/chatstore"
	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/secure"
)

// Chat attachment intake (iPhone chat spec §4.5, modelled on
// IntakeRecording): the phone's file for a chat message arrives as a
// chat_attachment upload with its sealed asset. The hub opens it in memory,
// checks the Mac's limits (chatstore.ValidateAttachment, the shared fixture
// with Swift's AttachmentValidator), and stores it as a pending
// chat_attachments row of the conversation (0600 under
// <workspace>/chat_files/conversations/<id>/, deduplicated by sha256 within
// the conversation). A failure writes no row and leaves no file: the phone
// keeps its file and offers Retry; a chat_turn naming an id that never
// arrived is refused attachment_missing.

const (
	chatFileMissingMessage = "The file did not reach your Mac. Send it again."
	chatFileWriteFailed    = "Your Mac could not save this file"
)

// IntakeChatAttachment stores one upload: applied {attachment_id}, or
// failed. Nothing here logs a name, a path or a key.
func (h *Handlers) IntakeChatAttachment(ctx context.Context, in actions.ChatAttachmentIntake) actions.Outcome {
	c, refused := h.chatGate(in.Device, false)
	if refused != nil {
		return *refused
	}
	if !uploadIDRE.MatchString(in.UploadID) || in.ConversationID <= 0 || strings.TrimSpace(in.Name) == "" {
		return failed(reasonInvalidParams, "This file has no usable id, chat or name.")
	}
	if refused := h.chatExists(ctx, c, in.ConversationID); refused != nil {
		return *refused
	}
	if in.Descriptor == nil || in.Download == nil {
		return failed(reasonNotFound, chatFileMissingMessage)
	}
	d := *in.Descriptor
	defer clear(d.Key[:]) // the asset key never outlives the intake
	if d.Header.TotalLength > uint64(chatstore.MaxAttachmentBytes) {
		rej := chatstore.Rejection{Reason: chatstore.RejectTooLarge, FileName: in.Name, Limit: declaredLimit(in.Mime)}
		return failed(reasonInvalidParams, rej.Message())
	}
	data, outcome := h.openChatFile(ctx, c, in, d)
	if outcome != nil {
		return *outcome
	}
	defer clear(data)
	kind, rej := chatstore.ValidateAttachment(data, in.Name)
	if rej != nil {
		return failed(reasonInvalidParams, rej.Message())
	}
	id, err := chatstore.SaveAttachment(ctx, h.d.DB, c.FilesDir, in.ConversationID, in.Name, kind, data,
		float64(h.d.Clock().UnixNano())/1e9)
	switch {
	case errors.Is(err, chatstore.ErrConversationGone):
		return failed(reasonNotFound, chatGoneMessage)
	case err != nil:
		log.Printf("hub chat: a file of chat %d was not saved (%s)", in.ConversationID, errClass(err))
		return failed(reasonWriteFailed, chatFileWriteFailed)
	}
	return applied(map[string]any{"attachment_id": id})
}

// openChatFile downloads the sealed asset beside the chat files and opens it
// in memory; the sealed copy is removed either way.
func (h *Handlers) openChatFile(ctx context.Context, c *ChatDeps, in actions.ChatAttachmentIntake, d secure.AssetDescriptor) ([]byte, *actions.Outcome) {
	fail := func(reason, msg string) ([]byte, *actions.Outcome) {
		o := failed(reason, msg)
		return nil, &o
	}
	if c.FilesDir == "" {
		return fail(reasonWriteFailed, chatFileWriteFailed)
	}
	if err := os.MkdirAll(c.FilesDir, 0o700); err != nil {
		log.Printf("hub chat: the chat files folder is unavailable")
		return fail(reasonWriteFailed, chatFileWriteFailed)
	}
	sealed := filepath.Join(c.FilesDir, "."+in.UploadID+".sealed")
	defer func() { _ = os.Remove(sealed) }()
	if err := in.Download(ctx, sealed); err != nil {
		return fail(reasonNotFound, chatFileMissingMessage)
	}
	st, err := os.Stat(sealed)
	if err != nil || st.Size() < 0 || uint64(st.Size()) > secure.SealedAssetLen(secure.AssetHeader{
		ChunkSize: d.Header.ChunkSize, ChunkCount: d.Header.ChunkCount,
	}) {
		return fail(reasonNotFound, chatFileMissingMessage)
	}
	raw, err := os.ReadFile(sealed) //nolint:gosec // the hub's own temporary file
	if err != nil {
		return fail(reasonNotFound, chatFileMissingMessage)
	}
	data, err := secure.DecryptAsset(raw, d)
	if err != nil {
		return fail(reasonNotFound, chatFileMissingMessage)
	}
	return data, nil
}

// declaredLimit is the limit of the kind the phone declared (the file is not
// opened when it is over every limit).
func declaredLimit(mime string) int64 {
	switch {
	case strings.HasPrefix(mime, "image/"):
		return chatstore.ImageLimit
	case mime == "application/pdf":
		return chatstore.PDFLimit
	case strings.HasPrefix(mime, "text/"), strings.HasPrefix(mime, "application/"):
		return chatstore.TextLimit
	}
	return chatstore.PDFLimit
}
