package chatstore

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

type limitFixture struct {
	LimitText map[string]string `json:"limit_text"`
	Cases     []struct {
		Name     string `json:"name"`
		FileName string `json:"file_name"`
		HeadHex  string `json:"head_hex"`
		Fill     string `json:"fill"`
		Size     int    `json:"size"`
		Expect   struct {
			OK      bool   `json:"ok"`
			Mime    string `json:"mime"`
			Ext     string `json:"ext"`
			Reason  string `json:"reason"`
			Limit   int64  `json:"limit"`
			Message string `json:"message"`
		} `json:"expect"`
	} `json:"cases"`
	PathExtensions []struct {
		Name string `json:"name"`
		Ext  string `json:"ext"`
	} `json:"path_extensions"`
	Directories []struct {
		ConversationID int64  `json:"conversation_id"`
		Dir            string `json:"dir"`
	} `json:"directories"`
}

func loadLimitFixture(t *testing.T) limitFixture {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "attachment_limit_cases.json"))
	require.NoError(t, err)
	var f limitFixture
	require.NoError(t, json.Unmarshal(raw, &f))
	return f
}

// TestChatAttachment_LimitsSharedCases runs the Mac's attachment checks'
// shared cases (Swift ChatAttachmentLimitFixtureTests is the reference)
// through the hub's port.
func TestChatAttachment_LimitsSharedCases(t *testing.T) {
	f := loadLimitFixture(t)
	require.GreaterOrEqual(t, len(f.Cases), 20)
	for limit, text := range map[int64]string{ImageLimit: "5.2 MB", PDFLimit: "33.6 MB", TextLimit: "262 KB"} {
		assert.Equal(t, f.LimitText[strconv.FormatInt(limit, 10)], text)
	}
	for _, c := range f.Cases {
		head, err := hex.DecodeString(c.HeadHex)
		require.NoError(t, err, c.Name)
		data := append(head, bytes.Repeat([]byte(c.Fill), max(0, c.Size-len(head)))...)
		kind, rej := ValidateAttachment(data, c.FileName)
		if c.Expect.OK {
			require.Nil(t, rej, c.Name)
			assert.Equal(t, c.Expect.Mime, kind.Mime, c.Name)
			assert.Equal(t, c.Expect.Ext, kind.FileExtension(c.FileName), c.Name)
			continue
		}
		require.NotNil(t, rej, c.Name)
		assert.Equal(t, c.Expect.Reason, rej.Reason, c.Name)
		assert.Equal(t, c.Expect.Limit, rej.Limit, c.Name)
		want := strings.ReplaceAll(c.Expect.Message, "{limit}", f.LimitText[strconv.FormatInt(c.Expect.Limit, 10)])
		assert.Equal(t, want, rej.Message(), c.Name)
	}
	for _, c := range f.PathExtensions {
		assert.Equal(t, c.Ext, PathExtension(c.Name), c.Name)
	}
	require.NotEmpty(t, f.Directories)
	for _, c := range f.Directories {
		assert.Equal(t, c.Dir, ConversationDir(c.ConversationID))
	}
}

func TestSaveAttachment_DedupesPerConversationAndWrites0600(t *testing.T) {
	d := openDB(t)
	root := t.TempDir()
	a, b := newConversation(t, d), newConversation(t, d)
	kind := AttachmentKind{"text", "text/plain"}
	ctx := context.Background()
	id1, err := SaveAttachment(ctx, d, root, a, "x.txt", kind, []byte("same"), 1)
	require.NoError(t, err)
	id2, err := SaveAttachment(ctx, d, root, a, "y.txt", kind, []byte("same"), 2)
	require.NoError(t, err)
	id3, err := SaveAttachment(ctx, d, root, b, "x.txt", kind, []byte("same"), 3)
	require.NoError(t, err)
	path := func(id int64) string {
		var p string
		require.NoError(t, d.QueryRow(`SELECT path FROM chat_attachments WHERE id = ? AND message_id IS NULL`, id).Scan(&p))
		return p
	}
	assert.Equal(t, path(id1), path(id2), "one file per sha within a conversation")
	assert.NotEqual(t, path(id1), path(id3), "never shared across conversations")
	assert.Equal(t, filepath.Join(root, "conversations", strconv.FormatInt(a, 10)), filepath.Dir(path(id1)))
	st, err := os.Stat(path(id1))
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), st.Mode().Perm())
	dir, err := os.Stat(filepath.Dir(path(id1)))
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o700), dir.Mode().Perm())
	entries, err := os.ReadDir(filepath.Dir(path(id1)))
	require.NoError(t, err)
	assert.Len(t, entries, 1, "no temporary file left")

	_, err = SaveAttachment(ctx, d, root, 9999, "x.txt", kind, []byte("other"), 4)
	require.ErrorIs(t, err, ErrConversationGone)
	_, statErr := os.Stat(filepath.Join(root, "conversations", "9999"))
	if statErr == nil {
		entries, _ := os.ReadDir(filepath.Join(root, "conversations", "9999"))
		assert.Empty(t, entries, "the file of a refused row is removed")
	}

	require.NoError(t, RemoveConversationFiles(root, a))
	_, err = os.Stat(filepath.Dir(path(id3)))
	require.NoError(t, err, "only the conversation's own folder goes")
	_, err = os.Stat(filepath.Join(root, "conversations", strconv.FormatInt(a, 10)))
	assert.True(t, os.IsNotExist(err))
	require.NoError(t, RemoveConversationFiles(root, a), "a missing folder is no error")
}

func TestConversationOps(t *testing.T) {
	d, s, _ := newStore(t)
	ctx := context.Background()
	id, err := s.NewConversation(ctx, nil, &Routing{Provider: "claude", Model: "opus"})
	require.NoError(t, err)
	var mode, provider, source string
	require.NoError(t, d.QueryRow(`SELECT routing_mode, provider, title_source FROM chat_conversations WHERE id = ?`, id).Scan(&mode, &provider, &source))
	assert.Equal(t, []string{"pinned", "claude", "prefix"}, []string{mode, provider, source})

	auto, err := s.NewConversation(ctx, nil, &Routing{Automatic: true})
	require.NoError(t, err)
	require.NoError(t, d.QueryRow(`SELECT routing_mode FROM chat_conversations WHERE id = ?`, auto).Scan(&mode))
	assert.Equal(t, "preferred_reserve", mode)

	missing := int64(4242)
	_, err = s.NewConversation(ctx, &missing, nil)
	require.ErrorIs(t, err, ErrProjectGone)
	_, err = s.NewConversation(ctx, nil, &Routing{Provider: "no-such-provider"})
	require.ErrorIs(t, err, ErrInvalid)

	require.NoError(t, s.Pin(ctx, id, true))
	require.NoError(t, s.Rename(ctx, id, " Plans "))
	var title string
	var pinned bool
	require.NoError(t, d.QueryRow(`SELECT title, title_source, pinned FROM chat_conversations WHERE id = ?`, id).Scan(&title, &source, &pinned))
	assert.Equal(t, "Plans", title)
	assert.Equal(t, "user", source)
	assert.True(t, pinned)
	require.ErrorIs(t, s.Rename(ctx, id, "  "), ErrInvalid)

	ok, err := s.ConversationExists(ctx, id)
	require.NoError(t, err)
	assert.True(t, ok)
	require.NoError(t, s.Delete(ctx, id))
	require.ErrorIs(t, s.Delete(ctx, id), ErrConversationGone)
	require.ErrorIs(t, s.Pin(ctx, id, false), ErrConversationGone)
	ok, err = s.ConversationExists(ctx, id)
	require.NoError(t, err)
	assert.False(t, ok)
}

// TestConversationOps_MainChatsOnly: a Discuss chat (context_type set) is
// not a main chat; the phone's conversation ops treat it as absent and
// write nothing to it (iPhone chat spec §1).
func TestConversationOps_MainChatsOnly(t *testing.T) {
	d, s, _ := newStore(t)
	ctx := context.Background()
	res, err := d.Exec(`INSERT INTO chat_conversations (title, context_type, context_id, created_at, updated_at) VALUES ('Standup', 'meeting', '7', 1, 1)`)
	require.NoError(t, err)
	conv, err := res.LastInsertId()
	require.NoError(t, err)
	msg, err := d.Exec(`INSERT INTO chat_messages (conversation_id, role, text, created_at) VALUES (?, 'user', 'q', 1)`, conv)
	require.NoError(t, err)
	msgID, err := msg.LastInsertId()
	require.NoError(t, err)

	ok, err := s.ConversationExists(ctx, conv)
	require.NoError(t, err)
	assert.False(t, ok)
	require.ErrorIs(t, s.Pin(ctx, conv, true), ErrConversationGone)
	require.ErrorIs(t, s.Rename(ctx, conv, "Mine"), ErrConversationGone)
	require.ErrorIs(t, s.Delete(ctx, conv), ErrConversationGone)
	require.ErrorIs(t, s.SelectBranch(ctx, msgID), ErrNotFound)
	_, err = SaveAttachment(ctx, d, t.TempDir(), conv, "x.txt", AttachmentKind{"text", "text/plain"}, []byte("x"), 1)
	require.ErrorIs(t, err, ErrConversationGone)

	var title string
	var pinned bool
	require.NoError(t, d.QueryRow(`SELECT title, pinned FROM chat_conversations WHERE id = ?`, conv).Scan(&title, &pinned))
	assert.Equal(t, "Standup", title)
	assert.False(t, pinned)
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM chat_attachments WHERE conversation_id = ?`, conv).Scan(&n))
	assert.Zero(t, n)
}
