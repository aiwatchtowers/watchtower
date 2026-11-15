package handlers

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/wire"
	"watchtower/internal/logcanary"
)

// upload seals plain and returns the intake whose Download writes the
// sealed bytes (cut to keep of them when keep >= 0).
func (c *chatEnv) upload(conv int64, name string, plain []byte, keep int) actions.ChatAttachmentIntake {
	c.t.Helper()
	key := make([]byte, 32)
	sealed, d, err := secure.EncryptAsset(plain, secure.ID{1}, key, 1024)
	if err != nil {
		c.t.Fatal(err)
	}
	if keep >= 0 {
		sealed = sealed[:keep]
	}
	return actions.ChatAttachmentIntake{
		Device: c.device, UploadID: "8F1C2B3A-0000-4000-8000-000000000001", ConversationID: conv, Name: name,
		Mime: "text/plain", Size: int64(len(plain)), Descriptor: &d,
		Download: func(_ context.Context, dst string) error { return os.WriteFile(dst, sealed, 0o600) },
	}
}

func (c *chatEnv) leftovers() []string {
	var out []string
	_ = filepath.WalkDir(c.files, func(p string, d os.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			out = append(out, filepath.Base(p))
		}
		return nil
	})
	return out
}

func TestChatAttachment_StoresAPendingRow(t *testing.T) {
	c := newChatEnv(t, false)
	conv := c.conversation()
	out := c.h.IntakeChatAttachment(context.Background(), c.upload(conv, "notes.md", []byte("# plan"), -1))
	wantOutcome(t, out, wire.StatusApplied, "")
	id, _ := out.Result["attachment_id"].(int64)
	if c.count(`SELECT COUNT(*) FROM chat_attachments WHERE id = ? AND conversation_id = ? AND message_id IS NULL
		AND mime = 'text/markdown' AND name = 'notes.md' AND size = 6`, id, conv) != 1 {
		t.Fatalf("row of %d", id)
	}
	path := c.scalar(`SELECT path FROM chat_attachments WHERE id = ?`, id)
	got, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(got, []byte("# plan")) {
		t.Fatalf("file: %v", err)
	}
	if left := c.leftovers(); len(left) != 1 || strings.HasSuffix(left[0], ".sealed") {
		t.Fatalf("files %v", left)
	}
	// The file then goes with a chat_turn, linked to the owner's message.
	turn := c.run("chat_turn", map[string]any{"conversation_id": conv, "mode": "send", "text": "see", "attachment_ids": []int64{id}})
	wantOutcome(t, turn, wire.StatusApplied, "")
	if c.count(`SELECT COUNT(*) FROM chat_attachments WHERE id = ? AND message_id = ?`, id, turn.Result["user_message_id"]) != 1 {
		t.Fatal("the file is not linked to the owner's message")
	}
}

func TestChatAttachment_PartialUploadWritesNothing(t *testing.T) {
	c := newChatEnv(t, false)
	conv := c.conversation()
	plain := bytes.Repeat([]byte("a"), 3000)
	for name, in := range map[string]actions.ChatAttachmentIntake{
		"cut": c.upload(conv, "log.txt", plain, 1500),
		"no_asset": func() actions.ChatAttachmentIntake {
			in := c.upload(conv, "log.txt", plain, -1)
			in.Descriptor = nil
			return in
		}(),
		"no_download": func() actions.ChatAttachmentIntake {
			in := c.upload(conv, "log.txt", plain, -1)
			in.Download = nil
			return in
		}(),
		"download_failed": func() actions.ChatAttachmentIntake {
			in := c.upload(conv, "log.txt", plain, -1)
			in.Download = func(context.Context, string) error { return errors.New("cut") }
			return in
		}(),
	} {
		out := c.h.IntakeChatAttachment(context.Background(), in)
		wantOutcome(t, out, wire.StatusFailed, reasonNotFound)
		if out.Message != chatFileMissingMessage {
			t.Errorf("%s: %q", name, out.Message)
		}
	}
	if n := c.count(`SELECT COUNT(*) FROM chat_attachments`); n != 0 {
		t.Fatalf("%d rows written", n)
	}
	if left := c.leftovers(); len(left) != 0 {
		t.Fatalf("files left: %v", left)
	}
	// A chat_turn naming a file that never arrived is attachment_missing.
	wantOutcome(t, c.run("chat_turn", map[string]any{"conversation_id": conv, "mode": "send", "text": "x",
		"attachment_ids": []int64{77}}), wire.StatusFailed, reasonAttachmentMissing)
}

func TestChatAttachment_MacLimitsAndRefusals(t *testing.T) {
	c := newChatEnv(t, false)
	conv := c.conversation()
	out := c.h.IntakeChatAttachment(context.Background(), c.upload(conv, "archive.zip", []byte("PK\x03\x04zz"), -1))
	wantOutcome(t, out, wire.StatusFailed, reasonInvalidParams)
	if out.Message != "archive.zip: only images, PDFs and text files can be attached" {
		t.Fatalf("message %q", out.Message)
	}
	out = c.h.IntakeChatAttachment(context.Background(), c.upload(conv, "log.txt", bytes.Repeat([]byte("a"), 262145), -1))
	if out.Message != "log.txt is larger than 262 KB" {
		t.Fatalf("message %q", out.Message)
	}
	// Over every limit: refused from the descriptor, nothing downloaded.
	big := c.upload(conv, "huge.pdf", []byte("%PDF-"), -1)
	big.Descriptor.Header.TotalLength = 33554433
	big.Mime = "application/pdf"
	big.Download = func(context.Context, string) error { t.Fatal("downloaded an oversized file"); return nil }
	out = c.h.IntakeChatAttachment(context.Background(), big)
	if out.Message != "huge.pdf is larger than 33.6 MB" {
		t.Fatalf("message %q", out.Message)
	}
	wantOutcome(t, c.h.IntakeChatAttachment(context.Background(), c.upload(9999, "a.txt", []byte("a"), -1)), wire.StatusFailed, reasonNotFound)
	c.setGrant("chat_allowed", false)
	wantOutcome(t, c.h.IntakeChatAttachment(context.Background(), c.upload(conv, "a.txt", []byte("a"), -1)), wire.StatusFailed, reasonDeviceNotAllowed)
	c.setGrant("chat_allowed", true)
	c.on, c.reason = false, wire.ChatOffNotRelay
	wantOutcome(t, c.h.IntakeChatAttachment(context.Background(), c.upload(conv, "a.txt", []byte("a"), -1)), wire.StatusFailed, reasonNotSupported)
	if n := c.count(`SELECT COUNT(*) FROM chat_attachments`); n != 0 {
		t.Fatalf("%d rows written", n)
	}
}

// TestFILES01_ChatHandlers: the chat handlers log ids only, never a file's
// name, a message or a title.
func TestFILES01_ChatHandlers(t *testing.T) {
	sink := logcanary.Capture(t)
	c := newChatEnv(t, false)
	conv := c.conversation()
	// The folder is a file: the intake cannot write, and logs.
	if err := os.WriteFile(c.files, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	_ = c.h.IntakeChatAttachment(context.Background(), c.upload(conv, logcanary.Text("name")+".txt", []byte(logcanary.Text("body")), -1))
	_ = c.run("chat_manage", map[string]any{"conversation_id": conv, "op": "rename", "title": logcanary.Text("title")})
	_ = c.run("chat_manage", map[string]any{"conversation_id": conv, "op": "delete"})
	if !strings.Contains(sink.String(), "hub chat") {
		t.Fatalf("nothing logged: %q", sink.String())
	}
	sink.AssertClean(t)
}
