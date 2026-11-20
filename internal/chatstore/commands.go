package chatstore

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"slices"
	"strconv"

	"watchtower/internal/db"
	"watchtower/internal/tower"
	"watchtower/internal/tower/api"
)

// The chat.* tower commands (spec 2026-11-15-mobile-inbox-design §8): the
// chat writes of the embedded chats (target, track, idea, meeting, code
// question, reviewer, tuning and automation-draft chats) and the queued
// drafts that the Desktop made through GRDB, ported to Go and pinned by
// testdata/chat_writes.json (the golden the deleted Swift writers were
// checked against); the Desktop writes no chat row itself. An embedded
// turn's own rows are `ai query --persist`'s. The main chat is not here:
// since the unified chat (#1822) its every row is the chat engine's
// (internal/chatengine over chat.sock), so a command that names a main chat
// is refused (errMainChat) and nothing writes it outside the engine's turn
// lock. Each command is a guarded write: its rows and its ledger row commit
// in one transaction (tower.Ctx.Write); files are removed after it, never
// inside it.

// chatGrant is the hub grant of every chat command: the phone's chat.
const chatGrant = "chat"

// The context types the commands write by name.
const (
	codeQuestionContext    = "code_question"
	reviewerContext        = "review_reviewer"
	automationDraftContext = "automation_draft"
)

// The refusal sentences, shown by both clients as is.
const (
	sentenceChatGone     = "This chat no longer exists."
	sentenceMessageGone  = "This message no longer exists."
	sentenceBadRequest   = "Watchtower couldn't apply this: the request is incomplete. Update the app."
	sentenceMacOnly      = "Only the Mac can do this."
	sentenceEmbeddedOnly = "This chat's replies are written by its own session."
	sentenceMainChat     = "Watchtower's chat writes this chat itself. Update the app."
)

// errMainChat: a conversation-level command for a main chat (context_type
// NULL), whose rows only the chat engine writes.
var errMainChat = errors.New("a main chat")

// refuseMainChatTx: errMainChat when conv is a main chat; nil when it is an
// embedded chat or gone (the command decides what gone means).
func refuseMainChatTx(tx *sql.Tx, conv int64) error {
	var contextType sql.NullString
	err := tx.QueryRow(`SELECT context_type FROM chat_conversations WHERE id = ?`, conv).Scan(&contextType)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return nil
	case err != nil:
		return fmt.Errorf("reading chat conversation %d: %w", conv, err)
	case !contextType.Valid:
		return errMainChat
	}
	return nil
}

// ErrNotEmbedded refuses a write of an embedded chat (chat.reply.finish,
// chat.message.append, `ai query --persist`'s BeginEmbedded) for a chat that
// is not one — the main chat's rows are the chat engine's alone.
var ErrNotEmbedded = errors.New("not an embedded chat")

// embeddedOnly is what chat.reply.finish and chat.message.append accept: the
// Mac (over its socket) writing an embedded chat's notice or reply end —
// never the hub's `chat` grant, and never a main chat's reply (review M3).
func embeddedOnly(c *tower.Ctx) error {
	if c.Origin.Transport != "socket" {
		return tower.Refuse(api.CodeNotPermitted, sentenceMacOnly)
	}
	return nil
}

// requireEmbeddedTx: the conversation exists and is an embedded chat.
func requireEmbeddedTx(tx *sql.Tx, conv int64) error {
	var contextType sql.NullString
	err := tx.QueryRow(`SELECT context_type FROM chat_conversations WHERE id = ?`, conv).Scan(&contextType)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return ErrConversationGone
	case err != nil:
		return fmt.Errorf("reading chat conversation %d: %w", conv, err)
	case !contextType.Valid:
		return ErrNotEmbedded
	}
	return nil
}

func sentenceUnknownProvider(p string) string {
	return fmt.Sprintf("Watchtower doesn't know the AI provider %q.", p)
}

var (
	tConversations = []string{"chat_conversations"}
	tDrafts        = []string{"chat_queued_drafts"}
)

// register adds one guarded chat command.
func register[Req, Resp any](r *tower.Registry, name string, tables []string, h tower.HandlerFunc[Req, Resp]) {
	tower.Register(r, name, h, tower.Spec{Idempotent: true, Grant: chatGrant, ChangeTables: tables})
}

// RegisterCommands registers the chat.* commands in r.
func RegisterCommands(r *tower.Registry) {
	// Embedded chats' conversations.
	register(r, "chat.new", tConversations, chatNew)
	register(r, "chat.set_title", tConversations, chatSetTitle)
	register(r, "chat.delete", []string{"chat_conversations", "chat_messages", "chat_attachments"}, chatDelete)
	register(r, "chat.set_model", tConversations, chatSetModel)
	register(r, "chat.context", tConversations, chatContext)
	register(r, "chat.reviewer_thread", []string{"chat_conversations", "review_reviewer_threads"}, chatReviewerThread)
	register(r, "chat.code_question.delete_empty", tConversations, chatDeleteEmptyCodeQuestions)

	// Queued drafts.
	register(r, "chat.draft.save", tDrafts, func(ctx context.Context, c *tower.Ctx, q api.ChatDraftSaveRequest) (api.ChatDone, error) {
		return write(ctx, c, "", func(tx *sql.Tx) (api.ChatDone, error) {
			return api.ChatDone{}, db.SaveQueuedDraftTx(tx, q.SurfaceKey, q.Text, seconds(c.Now()))
		})
	})
	register(r, "chat.draft.clear", tDrafts, func(ctx context.Context, c *tower.Ctx, q api.ChatDraftClearRequest) (api.ChatDone, error) {
		return write(ctx, c, "", func(tx *sql.Tx) (api.ChatDone, error) {
			return api.ChatDone{}, db.ClearQueuedDraftTx(tx, q.SurfaceKey)
		})
	})

	// An embedded chat's notices and reply ends; a recording's delete takes
	// its meeting chat with it (the last Swift writer of the chat tables
	// outside the chat screens).
	register(r, "chat.message.append", []string{"chat_messages"}, chatMessageAppend)
	register(r, "chat.reply.finish", []string{"chat_messages", "chat_conversations"}, chatReplyFinish)
	register(r, "meetings.delete", []string{"meeting_transcripts", "meeting_recaps", "chat_conversations", "chat_messages"}, meetingsDelete)
}

// meetingsDelete is MeetingTranscriptQueries.delete; the audio file is
// removed after the commit, a missing one being success (the daemon's
// retention may have swept it).
func meetingsDelete(ctx context.Context, c *tower.Ctx, q api.MeetingsDeleteRequest) (api.MeetingsDeleteResponse, error) {
	var audio string
	out, err := write(ctx, c, "", func(tx *sql.Tx) (api.MeetingsDeleteResponse, error) {
		found, path, err := db.DeleteMeetingTranscriptTx(tx, q.TranscriptID)
		audio = path
		return api.MeetingsDeleteResponse{Deleted: found}, err
	})
	if err == nil && audio != "" {
		removeStoredFile(audio)
	}
	return out, err
}

// write runs fn in the command's write transaction and turns the store's
// errors into refusals; gone is the not_found sentence for a foreign-key
// failure (the row the write points at is gone), "" to keep it a fault.
func write[Resp any](ctx context.Context, c *tower.Ctx, gone string, fn func(tx *sql.Tx) (Resp, error)) (Resp, error) {
	res, err := c.Write(ctx, func(tx *sql.Tx) (any, error) { return fn(tx) })
	if err != nil {
		var zero Resp
		return zero, refusal(err, gone)
	}
	return res.(Resp), nil
}

// refusal maps a writer's error to the call's refusal; any other error
// stays a fault.
func refusal(err error, gone string) error {
	switch {
	case errors.Is(err, ErrConversationGone):
		return tower.Refuse(api.CodeNotFound, sentenceChatGone)
	case errors.Is(err, ErrNotFound):
		return tower.Refuse(api.CodeNotFound, sentenceMessageGone)
	case errors.Is(err, ErrNotEmbedded):
		return tower.Refuse(api.CodeNotPermitted, sentenceEmbeddedOnly)
	case errors.Is(err, errMainChat):
		return tower.Refuse(api.CodeNotPermitted, sentenceMainChat)
	case gone != "" && isForeignKeyFailure(err):
		return tower.Refuse(api.CodeNotFound, gone)
	}
	return err
}

func chatNew(ctx context.Context, c *tower.Ctx, q api.ChatNewRequest) (api.ChatNewResponse, error) {
	if q.Routing != nil && !q.Routing.Automatic && !knownProvider(q.Routing.Provider) {
		return api.ChatNewResponse{}, tower.Refuse(api.CodeUnsupported, sentenceUnknownProvider(q.Routing.Provider))
	}
	if q.Context == nil {
		// A main chat is made by the chat engine (chat_new on chat.sock).
		return api.ChatNewResponse{}, tower.Refuse(api.CodeNotPermitted, sentenceMainChat)
	}
	x := q.Context
	if x.Type == "" || x.ID == "" {
		return api.ChatNewResponse{}, tower.Refuse(api.CodeUnsupported, sentenceBadRequest)
	}
	return write(ctx, c, "This project no longer exists.", func(tx *sql.Tx) (api.ChatNewResponse, error) {
		if x.Reuse {
			// EmbeddedChatStore.conversationID: the context's newest chat.
			var id int64
			err := tx.QueryRow(`SELECT id FROM chat_conversations WHERE context_type = ? AND context_id = ?
				ORDER BY updated_at DESC LIMIT 1`, x.Type, x.ID).Scan(&id)
			if err == nil {
				return api.ChatNewResponse{ConversationID: id}, nil
			}
			if !errors.Is(err, sql.ErrNoRows) {
				return api.ChatNewResponse{}, fmt.Errorf("reading the chat of %s %s: %w", x.Type, x.ID, err)
			}
		}
		id, err := insertContextChatTx(tx, x.Title, x.Type, x.ID, q.ProjectID, seconds(c.Now()))
		if err != nil || q.Routing == nil || q.Routing.Automatic {
			return api.ChatNewResponse{ConversationID: id}, err
		}
		// The code question's pick: provider and model only.
		_, err = tx.Exec(`UPDATE chat_conversations SET provider = ?, model = ? WHERE id = ?`,
			q.Routing.Provider, nullString(q.Routing.Model), id)
		return api.ChatNewResponse{ConversationID: id}, err
	})
}

// insertContextChatTx is ChatConversationQueries.create.
func insertContextChatTx(tx *sql.Tx, title, contextType, contextID string, projectID *int64, now float64) (int64, error) {
	res, err := tx.Exec(`INSERT INTO chat_conversations (title, context_type, context_id, project_id, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?)`, title, contextType, contextID, projectID, now, now)
	if err != nil {
		return 0, fmt.Errorf("creating a chat: %w", err)
	}
	return res.LastInsertId()
}

func chatSetTitle(ctx context.Context, c *tower.Ctx, q api.ChatSetTitleRequest) (api.ChatDone, error) {
	return write(ctx, c, "", func(tx *sql.Tx) (api.ChatDone, error) {
		if err := refuseMainChatTx(tx, q.ConversationID); err != nil {
			return api.ChatDone{}, err
		}
		// Unchecked, as in Swift: a chat deleted meanwhile needs no title.
		var err error
		if q.IfEmpty {
			_, err = tx.Exec(`UPDATE chat_conversations SET title = ? WHERE id = ? AND title = ''`, q.Title, q.ConversationID)
		} else {
			_, err = tx.Exec(`UPDATE chat_conversations SET title = ?, updated_at = ? WHERE id = ?`,
				q.Title, seconds(c.Now()), q.ConversationID)
		}
		return api.ChatDone{}, err
	})
}

// chatDelete deletes an embedded chat of q.ContextType only; a main chat
// (no context type) is the engine's to delete.
func chatDelete(ctx context.Context, c *tower.Ctx, q api.ChatDeleteRequest) (api.ChatDone, error) {
	if q.ContextType == "" {
		return api.ChatDone{}, tower.Refuse(api.CodeNotPermitted, sentenceMainChat)
	}
	out, err := write(ctx, c, "", func(tx *sql.Tx) (api.ChatDone, error) {
		return api.ChatDone{}, requireConversation(tx.Exec(`DELETE FROM chat_conversations WHERE id = ? AND context_type = ?`,
			q.ConversationID, q.ContextType))
	})
	if err != nil {
		return out, err
	}
	// The rows went by cascade; only the files remain.
	if rerr := RemoveConversationFiles(filesRoot(ctx, c.DB), q.ConversationID); rerr != nil {
		log.Printf("chat.delete: chat %d deleted, its attachment folder was not removed", q.ConversationID)
	}
	return out, nil
}

func chatSetModel(ctx context.Context, c *tower.Ctx, q api.ChatSetModelRequest) (api.ChatDone, error) {
	if !knownProvider(q.Provider) {
		return api.ChatDone{}, tower.Refuse(api.CodeUnsupported, sentenceUnknownProvider(q.Provider))
	}
	return write(ctx, c, "", func(tx *sql.Tx) (api.ChatDone, error) {
		if err := refuseMainChatTx(tx, q.ConversationID); err != nil {
			return api.ChatDone{}, err
		}
		return api.ChatDone{}, requireConversation(tx.Exec(`UPDATE chat_conversations SET provider = ?, model = ? WHERE id = ?`,
			q.Provider, nullString(q.Model), q.ConversationID))
	})
}

// chatContext is EmbeddedChatStore.rekeyConversation.
func chatContext(ctx context.Context, c *tower.Ctx, q api.ChatContextRequest) (api.ChatChanged, error) {
	if q.ContextType == "" || q.ContextID == "" {
		return api.ChatChanged{}, tower.Refuse(api.CodeUnsupported, sentenceBadRequest)
	}
	return write(ctx, c, "", func(tx *sql.Tx) (api.ChatChanged, error) {
		var draft int
		if err := tx.QueryRow(`SELECT COUNT(*) FROM chat_conversations WHERE id = ? AND context_type = ?`,
			q.ConversationID, automationDraftContext).Scan(&draft); err != nil || draft == 0 {
			return api.ChatChanged{}, err
		}
		var existing int64
		err := tx.QueryRow(`SELECT id FROM chat_conversations WHERE context_type = ? AND context_id = ?
			ORDER BY updated_at DESC LIMIT 1`, q.ContextType, q.ContextID).Scan(&existing)
		switch {
		case err == nil:
			var hasMessages bool
			if err := tx.QueryRow(`SELECT EXISTS (SELECT 1 FROM chat_messages WHERE conversation_id = ?)`, existing).
				Scan(&hasMessages); err != nil || hasMessages {
				return api.ChatChanged{}, err
			}
			if _, err := tx.Exec(`DELETE FROM chat_conversations WHERE id = ?`, existing); err != nil {
				return api.ChatChanged{}, err
			}
		case !errors.Is(err, sql.ErrNoRows):
			return api.ChatChanged{}, err
		}
		ok, err := changed(tx.Exec(`UPDATE chat_conversations SET context_type = ?, context_id = ?, updated_at = ?
			WHERE id = ? AND context_type = ?`, q.ContextType, q.ContextID, seconds(c.Now()), q.ConversationID, automationDraftContext))
		return api.ChatChanged{Changed: ok}, err
	})
}

// chatReviewerThread is ReviewerThreadQueries.ensure: one thread per
// (workbench, folder, branch) since migration 00209, so two folders with the
// same branch never share one. No folder is the workbench's home folder.
func chatReviewerThread(ctx context.Context, c *tower.Ctx, q api.ChatReviewerThreadRequest) (api.ChatNewResponse, error) {
	if q.ProjectID <= 0 || q.Branch == "" || q.FolderID < 0 {
		return api.ChatNewResponse{}, tower.Refuse(api.CodeUnsupported, sentenceBadRequest)
	}
	folderSQL, folderArg := reviewerThreadFolder(q.ProjectID, q.FolderID)
	return write(ctx, c, "This workbench no longer exists.", func(tx *sql.Tx) (api.ChatNewResponse, error) {
		var id int64
		err := tx.QueryRow(`SELECT conversation_id FROM review_reviewer_threads
			WHERE project_id = ? AND workbench_folder_id = `+folderSQL+` AND branch = ?`,
			q.ProjectID, folderArg, q.Branch).Scan(&id)
		if err == nil {
			return api.ChatNewResponse{ConversationID: id}, nil
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return api.ChatNewResponse{}, err
		}
		if id, err = insertContextChatTx(tx, "Reviewer: "+q.Branch, reviewerContext,
			reviewerContextID(q.ProjectID, q.FolderID, q.Branch), nil, seconds(c.Now())); err != nil {
			return api.ChatNewResponse{}, err
		}
		//nolint:gosec // G202: folderSQL is one of two constant fragments; every value is a bound arg.
		_, err = tx.Exec(`INSERT INTO review_reviewer_threads (project_id, workbench_folder_id, branch, conversation_id)
			VALUES (?, `+folderSQL+`, ?, ?)`, q.ProjectID, folderArg, q.Branch, id)
		return api.ChatNewResponse{ConversationID: id}, err
	})
}

// reviewerHomeFolderSQL is the home folder of the workbench bound as its one
// argument (db.HomeFolder, WorkbenchFolderQueries.homeFolderIDSQL).
const reviewerHomeFolderSQL = `(SELECT f.id FROM workbench_folders f JOIN projects p ON p.id = f.workbench_id
	WHERE f.workbench_id = ?
	ORDER BY (f.removed_at IS NULL AND f.folder_path = p.folder_path COLLATE NOCASE) DESC, f.position, f.id
	LIMIT 1)`

// reviewerThreadFolder is a thread's folder key: folderID, else the
// workbench's home folder.
func reviewerThreadFolder(projectID, folderID int64) (string, int64) {
	if folderID == 0 {
		return reviewerHomeFolderSQL, projectID
	}
	return "?", folderID
}

// reviewerContextID is ReviewerSurface.contextID: <project>:<branch> for the
// home folder (as before 00209), <project>:f<folder>:<branch> for a
// session's folder.
func reviewerContextID(projectID, folderID int64, branch string) string {
	if folderID == 0 {
		return strconv.FormatInt(projectID, 10) + ":" + branch
	}
	return strconv.FormatInt(projectID, 10) + ":f" + strconv.FormatInt(folderID, 10) + ":" + branch
}

// chatDeleteEmptyCodeQuestions is CodeQuestionList.deleteEmpty.
func chatDeleteEmptyCodeQuestions(ctx context.Context, c *tower.Ctx, q api.ChatDeleteEmptyCodeQuestionsRequest) (api.ChatCount, error) {
	prefix := strconv.FormatInt(q.WorkbenchID, 10) + ":"
	keep := map[int64]bool{}
	for _, id := range q.Keeping {
		keep[id] = true
	}
	return write(ctx, c, "", func(tx *sql.Tx) (api.ChatCount, error) {
		ids, err := emptyCodeQuestionsTx(tx, prefix, q.CreatedBefore)
		if err != nil {
			return api.ChatCount{}, err
		}
		var n int64
		for _, id := range ids {
			if keep[id] {
				continue
			}
			res, err := tx.Exec(`DELETE FROM chat_conversations WHERE id = ?`, id)
			if err != nil {
				return api.ChatCount{}, err
			}
			k, err := res.RowsAffected()
			if err != nil {
				return api.ChatCount{}, err
			}
			n += k
		}
		return api.ChatCount{Count: n}, nil
	})
}

func emptyCodeQuestionsTx(tx *sql.Tx, prefix string, before float64) ([]int64, error) {
	rows, err := tx.Query(`SELECT c.id FROM chat_conversations c
		WHERE c.context_type = ? AND substr(c.context_id, 1, length(?)) = ? AND c.created_at < ?
		AND NOT EXISTS (SELECT 1 FROM chat_messages m WHERE m.conversation_id = c.id)`,
		codeQuestionContext, prefix, prefix, before)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

// filesRoot is <workspace>/chat_files, the folder beside the database file
// (ChatAttachmentStore.defaultRootDir); "" for a database with no file.
func filesRoot(ctx context.Context, d *db.DB) string {
	var file string
	if err := d.QueryRowContext(ctx, `SELECT file FROM pragma_database_list WHERE name = 'main'`).Scan(&file); err != nil || file == "" {
		return ""
	}
	return filepath.Join(filepath.Dir(file), FilesDirName)
}

// removeStoredFile removes a stored attachment after its rows are gone; a
// missing file is already the end state.
func removeStoredFile(path string) {
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		log.Printf("chat: a stored attachment was not removed (%v)", errors.Unwrap(err))
	}
}

func changed(res sql.Result, err error) (bool, error) {
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n > 0, err
}

func nullString(s string) sql.NullString { return sql.NullString{String: s, Valid: s != ""} }

// chatMessageAppend is ChatMessageQueries.insert behind requireConversation:
// a complete row with no turn.
func chatMessageAppend(ctx context.Context, c *tower.Ctx, q api.ChatMessageAppendRequest) (api.ChatMessageAppendResponse, error) {
	if q.ConversationID <= 0 || !slices.Contains([]string{"user", "assistant", "system"}, q.Role) {
		return api.ChatMessageAppendResponse{}, tower.Refuse(api.CodeUnsupported, sentenceBadRequest)
	}
	if err := embeddedOnly(c); err != nil {
		return api.ChatMessageAppendResponse{}, err
	}
	return write(ctx, c, sentenceChatGone, func(tx *sql.Tx) (api.ChatMessageAppendResponse, error) {
		if err := requireEmbeddedTx(tx, q.ConversationID); err != nil {
			return api.ChatMessageAppendResponse{}, err
		}
		res, err := tx.Exec(`INSERT INTO chat_messages (conversation_id, role, text, created_at, turn_id) VALUES (?, ?, ?, ?, '')`,
			q.ConversationID, q.Role, q.Text, seconds(c.Now()))
		if err != nil {
			return api.ChatMessageAppendResponse{}, fmt.Errorf("appending a chat message: %w", err)
		}
		id, err := res.LastInsertId()
		return api.ChatMessageAppendResponse{MessageID: id}, err
	})
}

// chatReplyFinish is ChatMessageQueries.finalizeEmbedded (and the store's
// touch of a complete reply): the reply's text, status and error, by its id
// within its conversation.
func chatReplyFinish(ctx context.Context, c *tower.Ctx, q api.ChatReplyFinishRequest) (api.ChatDone, error) {
	if q.ConversationID <= 0 || q.MessageID <= 0 ||
		!slices.Contains([]string{StatusComplete, StatusPartial, StatusError}, q.Status) {
		return api.ChatDone{}, tower.Refuse(api.CodeUnsupported, sentenceBadRequest)
	}
	if err := embeddedOnly(c); err != nil {
		return api.ChatDone{}, err
	}
	code := sql.NullString{String: q.ErrorCode, Valid: q.ErrorCode != ""}
	msg := sql.NullString{String: q.ErrorMessage, Valid: q.ErrorMessage != "" || q.ErrorCode != ""}
	return write(ctx, c, sentenceMessageGone, func(tx *sql.Tx) (api.ChatDone, error) {
		if err := requireEmbeddedTx(tx, q.ConversationID); errors.Is(err, ErrConversationGone) {
			return api.ChatDone{}, ErrNotFound
		} else if err != nil {
			return api.ChatDone{}, err
		}
		res, err := tx.Exec(`UPDATE chat_messages SET text = ?, status = ?, error_code = ?, error_message = ?
			WHERE id = ? AND conversation_id = ? AND role = 'assistant'`,
			q.Text, q.Status, code, msg, q.MessageID, q.ConversationID)
		if err := requireRow(res, err); errors.Is(err, ErrConversationGone) {
			return api.ChatDone{}, ErrNotFound
		} else if err != nil {
			return api.ChatDone{}, fmt.Errorf("finishing chat reply %d: %w", q.MessageID, err)
		}
		if q.Status != StatusComplete {
			return api.ChatDone{}, nil
		}
		_, err = tx.Exec(`UPDATE chat_conversations SET updated_at = ? WHERE id = ?`, seconds(c.Now()), q.ConversationID)
		return api.ChatDone{}, err
	})
}
