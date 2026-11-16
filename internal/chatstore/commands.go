package chatstore

import (
	"context"
	"database/sql"
	"encoding/base64"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	"watchtower/internal/db"
	"watchtower/internal/tower"
	"watchtower/internal/tower/api"
)

// The chat.* tower commands (spec 2026-11-15-mobile-inbox-design §8): every
// conversation-level chat write the Desktop made through GRDB, ported to Go
// and pinned with its Swift writer by testdata/chat_writes.json until Task
// 18 deletes the Swift writers. A turn's own rows are not here: `ai session
// --persist` writes them. Each command is a guarded write: its rows and its
// ledger row commit in one transaction (tower.Ctx.Write); files are written
// before it and removed after it, never inside it.

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
	sentenceProjectGone  = "This project no longer exists."
	sentenceEmptyName    = "A chat's name can't be empty."
	sentenceBadRequest   = "Watchtower couldn't apply this: the request is incomplete. Update the app."
	sentenceNoFilesDir   = "Watchtower couldn't find its attachments folder."
	sentencePathOnMac    = "Only the Mac can attach a file by its path."
	sentenceMacOnly      = "Only the Mac can do this."
	sentenceBadKind      = "Watchtower can't add this kind of source to a project."
	sentenceUnreadable   = "Watchtower couldn't read this file."
	sentenceEmptyComment = "Write a comment first."
	sentenceEmptyQuote   = "Select the text to comment on."
	sentenceLiveSlack    = "This chat used Live Slack, so its artifacts can't be kept in Knowledge."
)

func sentenceUnknownProvider(p string) string {
	return fmt.Sprintf("Watchtower doesn't know the AI provider %q.", p)
}

var (
	tConversations = []string{"chat_conversations"}
	tAttachments   = []string{"chat_attachments"}
	tProjects      = []string{"chat_projects", "chat_conversations"}
	tSources       = []string{"chat_project_sources", "chat_projects", "chat_conversations"}
	tComments      = []string{"chat_artifact_comments"}
	tDrafts        = []string{"chat_queued_drafts"}
	tKept          = []string{"chat_knowledge_artifacts"}
	tLeases        = []string{"chat_turn_leases", "chat_messages"}
)

// register adds one guarded chat command.
func register[Req, Resp any](r *tower.Registry, name string, tables []string, h tower.HandlerFunc[Req, Resp]) {
	tower.Register(r, name, h, tower.Spec{Idempotent: true, Grant: chatGrant, ChangeTables: tables})
}

// RegisterCommands registers the chat.* commands in r.
func RegisterCommands(r *tower.Registry) {
	// Conversations.
	register(r, "chat.new", tConversations, chatNew)
	register(r, "chat.pin", tConversations, func(ctx context.Context, c *tower.Ctx, q api.ChatPinRequest) (api.ChatDone, error) {
		return write(ctx, c, sentenceChatGone, func(tx *sql.Tx) (api.ChatDone, error) {
			return api.ChatDone{}, pinTx(tx, q.ConversationID, q.Pinned)
		})
	})
	register(r, "chat.rename", tConversations, func(ctx context.Context, c *tower.Ctx, q api.ChatRenameRequest) (api.ChatDone, error) {
		if strings.TrimSpace(q.Title) == "" {
			return api.ChatDone{}, tower.Refuse(api.CodeUnsupported, sentenceEmptyName)
		}
		return write(ctx, c, sentenceChatGone, func(tx *sql.Tx) (api.ChatDone, error) {
			return api.ChatDone{}, renameTx(tx, q.ConversationID, q.Title, seconds(c.Now()))
		})
	})
	register(r, "chat.set_title", tConversations, chatSetTitle)
	register(r, "chat.delete", []string{"chat_conversations", "chat_messages", "chat_attachments", "chat_turn_leases"}, chatDelete)
	register(r, "chat.delete_untouched", tConversations, chatDeleteUntouched)
	register(r, "chat.archive", tConversations, func(ctx context.Context, c *tower.Ctx, q api.ChatConversationRequest) (api.ChatDone, error) {
		return write(ctx, c, sentenceChatGone, func(tx *sql.Tx) (api.ChatDone, error) {
			return api.ChatDone{}, requireConversation(tx.Exec(`UPDATE chat_conversations SET archived_at = ? WHERE id = ?`,
				seconds(c.Now()), q.ConversationID))
		})
	})
	register(r, "chat.branch", tConversations, func(ctx context.Context, c *tower.Ctx, q api.ChatBranchRequest) (api.ChatDone, error) {
		return write(ctx, c, sentenceMessageGone, func(tx *sql.Tx) (api.ChatDone, error) {
			return api.ChatDone{}, selectBranchTx(tx, q.MessageID)
		})
	})
	register(r, "chat.read", tConversations, func(ctx context.Context, c *tower.Ctx, q api.ChatReadRequest) (api.ChatDone, error) {
		return write(ctx, c, sentenceChatGone, func(tx *sql.Tx) (api.ChatDone, error) {
			return api.ChatDone{}, markReadTx(tx, q.ConversationID, q.MessageID)
		})
	})
	register(r, "chat.set_project", tConversations, chatSetProject)
	register(r, "chat.set_routing", tConversations, chatSetRouting)
	register(r, "chat.set_model", tConversations, chatSetModel)
	register(r, "chat.context", tConversations, chatContext)
	register(r, "chat.reviewer_thread", []string{"chat_conversations", "review_reviewer_threads"}, chatReviewerThread)
	register(r, "chat.code_question.delete_empty", tConversations, chatDeleteEmptyCodeQuestions)

	// Attachments.
	register(r, "chat.attach", []string{"chat_attachments", "chat_conversations"}, chatAttach)
	register(r, "chat.attach_link", tAttachments, chatAttachLink)
	register(r, "chat.attach_delete", tAttachments, chatAttachDelete)

	// Turn leases.
	register(r, "chat.stop", []string{"chat_turn_leases"}, func(ctx context.Context, c *tower.Ctx, q api.ChatTurnRequest) (api.ChatChanged, error) {
		return write(ctx, c, sentenceChatGone, func(tx *sql.Tx) (api.ChatChanged, error) {
			ok, err := db.RequestChatCancelTx(tx, q.ConversationID, q.TurnID, c.Now().UnixMilli())
			return api.ChatChanged{Changed: ok}, err
		})
	})
	register(r, "chat.recover", tLeases, func(ctx context.Context, c *tower.Ctx, q api.ChatTurnRequest) (api.ChatRecoverResponse, error) {
		if q.ConversationID <= 0 || q.TurnID == "" {
			return api.ChatRecoverResponse{}, tower.Refuse(api.CodeUnsupported, sentenceBadRequest)
		}
		return write(ctx, c, sentenceChatGone, func(tx *sql.Tx) (api.ChatRecoverResponse, error) {
			marked, released, err := db.RecoverChatTurnTx(tx, q.ConversationID, q.TurnID)
			return api.ChatRecoverResponse{Marked: marked, Released: released}, err
		})
	})
	register(r, "chat.release_launches", tLeases, func(ctx context.Context, c *tower.Ctx, q api.ChatReleaseLaunchesRequest) (api.ChatReleaseLaunchesResponse, error) {
		if q.Keep == "" {
			return api.ChatReleaseLaunchesResponse{}, tower.Refuse(api.CodeUnsupported, sentenceBadRequest)
		}
		if c.Origin.Transport != "socket" {
			return api.ChatReleaseLaunchesResponse{}, tower.Refuse(api.CodeNotPermitted, sentenceMacOnly)
		}
		return write(ctx, c, sentenceChatGone, func(tx *sql.Tx) (api.ChatReleaseLaunchesResponse, error) {
			released, err := db.ReleaseDesktopLeasesExceptTx(tx, q.Keep)
			return api.ChatReleaseLaunchesResponse{Released: int64(len(released))}, err
		})
	})

	registerProjectCommands(r)
	registerCommentCommands(r)

	// Queued drafts and kept artifacts.
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
	register(r, "chat.artifact.keep", tKept, func(ctx context.Context, c *tower.Ctx, q api.ChatArtifactKeepRequest) (api.ChatDone, error) {
		return write(ctx, c, sentenceChatGone, func(tx *sql.Tx) (api.ChatDone, error) {
			return api.ChatDone{}, db.KeepChatArtifactTx(tx, q.ConversationID, q.ArtifactKey, q.Version)
		})
	})
	register(r, "chat.artifact.unkeep", tKept, func(ctx context.Context, c *tower.Ctx, q api.ChatArtifactUnkeepRequest) (api.ChatDone, error) {
		return write(ctx, c, "", func(tx *sql.Tx) (api.ChatDone, error) {
			return api.ChatDone{}, db.UnkeepChatArtifactTx(tx, q.ConversationID, q.ArtifactKey)
		})
	})
	register(r, "chat.artifact.save_edit", []string{"chat_artifacts"}, chatArtifactSaveEdit)

	// A recording's delete takes its meeting chat with it (the last Swift
	// writer of the chat tables outside the chat screens).
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

func registerProjectCommands(r *tower.Registry) {
	register(r, "chat.project.create", []string{"chat_projects"}, func(ctx context.Context, c *tower.Ctx, q api.ChatProjectCreateRequest) (api.ChatProjectCreateResponse, error) {
		return write(ctx, c, "", func(tx *sql.Tx) (api.ChatProjectCreateResponse, error) {
			id, name, err := db.CreateChatProjectTx(tx, q.Name, seconds(c.Now()))
			return api.ChatProjectCreateResponse{ProjectID: id, Name: name}, err
		})
	})
	register(r, "chat.project.rename", []string{"chat_projects"}, func(ctx context.Context, c *tower.Ctx, q api.ChatProjectRenameRequest) (api.ChatDone, error) {
		return write(ctx, c, sentenceProjectGone, func(tx *sql.Tx) (api.ChatDone, error) {
			return api.ChatDone{}, db.RenameChatProjectTx(tx, q.ProjectID, q.Name, seconds(c.Now()))
		})
	})
	register(r, "chat.project.instructions", tProjects, func(ctx context.Context, c *tower.Ctx, q api.ChatProjectInstructionsRequest) (api.ChatDone, error) {
		return write(ctx, c, sentenceProjectGone, func(tx *sql.Tx) (api.ChatDone, error) {
			return api.ChatDone{}, db.SetChatProjectInstructionsTx(tx, q.ProjectID, q.Instructions, seconds(c.Now()))
		})
	})
	register(r, "chat.project.archive", []string{"chat_projects"}, func(ctx context.Context, c *tower.Ctx, q api.ChatProjectRequest) (api.ChatDone, error) {
		return write(ctx, c, sentenceProjectGone, func(tx *sql.Tx) (api.ChatDone, error) {
			return api.ChatDone{}, db.ArchiveChatProjectTx(tx, q.ProjectID, seconds(c.Now()))
		})
	})
	register(r, "chat.project.delete", []string{"chat_projects", "chat_project_sources", "chat_attachments", "chat_conversations"},
		func(ctx context.Context, c *tower.Ctx, q api.ChatProjectRequest) (api.ChatDone, error) {
			var paths []string
			out, err := write(ctx, c, "", func(tx *sql.Tx) (api.ChatDone, error) {
				var err error
				paths, err = db.DeleteChatProjectTx(tx, q.ProjectID)
				return api.ChatDone{}, err
			})
			if err != nil {
				return out, err
			}
			for _, p := range paths {
				removeStoredFile(p)
			}
			if root := filesRoot(ctx, c.DB); root != "" {
				dir := attachmentOwner{projectID: true, id: q.ProjectID}.dir()
				if err := os.RemoveAll(filepath.Join(root, filepath.FromSlash(dir))); err != nil {
					log.Printf("chat.project.delete: project %d deleted, its folder was not removed", q.ProjectID)
				}
			}
			return out, nil
		})
	register(r, "chat.project.add_source", tSources, func(ctx context.Context, c *tower.Ctx, q api.ChatProjectAddSourceRequest) (api.ChatChanged, error) {
		if !slices.Contains(db.ChatProjectSourceKinds, q.Kind) {
			return api.ChatChanged{}, tower.Refuse(api.CodeUnsupported, sentenceBadKind)
		}
		return write(ctx, c, sentenceProjectGone, func(tx *sql.Tx) (api.ChatChanged, error) {
			added, err := db.AddChatProjectSourceTx(tx, q.ProjectID, q.Kind, q.Ref, q.Label, seconds(c.Now()))
			return api.ChatChanged{Changed: added}, err
		})
	})
	register(r, "chat.project.remove_source", tSources, func(ctx context.Context, c *tower.Ctx, q api.ChatProjectSourceRequest) (api.ChatChanged, error) {
		return write(ctx, c, "", func(tx *sql.Tx) (api.ChatChanged, error) {
			removed, err := db.RemoveChatProjectSourceTx(tx, q.SourceID)
			return api.ChatChanged{Changed: removed}, err
		})
	})
	register(r, "chat.project.remove_file", []string{"chat_attachments", "chat_conversations"},
		func(ctx context.Context, c *tower.Ctx, q api.ChatAttachmentRequest) (api.ChatChanged, error) {
			var orphan string
			out, err := write(ctx, c, "", func(tx *sql.Tx) (api.ChatChanged, error) {
				removed, o, err := db.RemoveChatProjectFileTx(tx, q.AttachmentID)
				orphan = o
				return api.ChatChanged{Changed: removed}, err
			})
			if err == nil && orphan != "" {
				removeStoredFile(orphan)
			}
			return out, err
		})
}

func registerCommentCommands(r *tower.Registry) {
	register(r, "chat.comment.add", tComments, func(ctx context.Context, c *tower.Ctx, q api.ChatCommentAddRequest) (api.ChatCommentAddResponse, error) {
		return write(ctx, c, sentenceChatGone, func(tx *sql.Tx) (api.ChatCommentAddResponse, error) {
			a := db.ArtifactCommentAnchor{Quote: q.Anchor.Quote, Prefix: q.Anchor.Prefix, Suffix: q.Anchor.Suffix, Heading: q.Anchor.Heading}
			id, err := db.AddArtifactCommentTx(tx, q.ConversationID, q.ArtifactKey, q.Version, a, q.Body, seconds(c.Now()))
			return api.ChatCommentAddResponse{CommentID: id}, err
		})
	})
	register(r, "chat.comment.delete_unsent", tComments, func(ctx context.Context, c *tower.Ctx, q api.ChatCommentRequest) (api.ChatChanged, error) {
		return write(ctx, c, "", func(tx *sql.Tx) (api.ChatChanged, error) {
			ok, err := db.DeleteUnsentArtifactCommentTx(tx, q.CommentID)
			return api.ChatChanged{Changed: ok}, err
		})
	})
	register(r, "chat.comment.resolve", tComments, func(ctx context.Context, c *tower.Ctx, q api.ChatCommentRequest) (api.ChatChanged, error) {
		return write(ctx, c, "", func(tx *sql.Tx) (api.ChatChanged, error) {
			ok, err := db.ResolveArtifactCommentTx(tx, q.CommentID)
			return api.ChatChanged{Changed: ok}, err
		})
	})
	register(r, "chat.comment.mark_sent", tComments, func(ctx context.Context, c *tower.Ctx, q api.ChatCommentMarkSentRequest) (api.ChatCount, error) {
		return write(ctx, c, "", func(tx *sql.Tx) (api.ChatCount, error) {
			n, err := db.MarkArtifactCommentsSentTx(tx, q.CommentIDs, q.SentAt)
			return api.ChatCount{Count: n}, err
		})
	})
	register(r, "chat.comment.apply", tComments, func(ctx context.Context, c *tower.Ctx, q api.ChatCommentApplyRequest) (api.ChatDone, error) {
		return write(ctx, c, "", func(tx *sql.Tx) (api.ChatDone, error) {
			return api.ChatDone{}, db.ApplyArtifactCommentReanchorTx(tx, q.Moved, q.Lost, q.Version)
		})
	})
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
	case errors.Is(err, ErrProjectGone), errors.Is(err, db.ErrChatProjectGone):
		return tower.Refuse(api.CodeNotFound, sentenceProjectGone)
	case errors.Is(err, db.ErrCommentEmptyBody):
		return tower.Refuse(api.CodeUnsupported, sentenceEmptyComment)
	case errors.Is(err, db.ErrCommentEmptyQuote):
		return tower.Refuse(api.CodeUnsupported, sentenceEmptyQuote)
	case errors.Is(err, db.ErrChatLiveSlack):
		return tower.Refuse(api.CodeNotPermitted, sentenceLiveSlack)
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
		var routing *Routing
		if q.Routing != nil {
			routing = &Routing{Automatic: q.Routing.Automatic, Provider: q.Routing.Provider, Model: q.Routing.Model}
		}
		return write(ctx, c, sentenceProjectGone, func(tx *sql.Tx) (api.ChatNewResponse, error) {
			id, err := newConversationTx(tx, q.ProjectID, routing, seconds(c.Now()))
			return api.ChatNewResponse{ConversationID: id}, err
		})
	}
	x := q.Context
	if x.Type == "" || x.ID == "" {
		return api.ChatNewResponse{}, tower.Refuse(api.CodeUnsupported, sentenceBadRequest)
	}
	return write(ctx, c, sentenceProjectGone, func(tx *sql.Tx) (api.ChatNewResponse, error) {
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

func chatDelete(ctx context.Context, c *tower.Ctx, q api.ChatDeleteRequest) (api.ChatDone, error) {
	out, err := write(ctx, c, "", func(tx *sql.Tx) (api.ChatDone, error) {
		return api.ChatDone{}, deleteTx(tx, q.ConversationID, q.ContextType)
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

func chatDeleteUntouched(ctx context.Context, c *tower.Ctx, q api.ChatDeleteUntouchedRequest) (api.ChatChanged, error) {
	return write(ctx, c, "", func(tx *sql.Tx) (api.ChatChanged, error) {
		ok, err := changed(tx.Exec(`DELETE FROM chat_conversations WHERE id IN (
			SELECT c.id FROM chat_conversations c WHERE c.id = ? AND c.created_at = ?
			AND c.context_type IS NULL AND c.project_id IS ? AND c.archived_at IS NULL
			AND c.pinned = 0 AND c.title_source <> 'user'
			AND NOT EXISTS (SELECT 1 FROM chat_messages m WHERE m.conversation_id = c.id)
			AND NOT EXISTS (SELECT 1 FROM chat_attachments a WHERE a.conversation_id = c.id))`,
			q.ConversationID, q.CreatedAt, q.ProjectID))
		return api.ChatChanged{Changed: ok}, err
	})
}

func chatSetProject(ctx context.Context, c *tower.Ctx, q api.ChatSetProjectRequest) (api.ChatDone, error) {
	return write(ctx, c, sentenceProjectGone, func(tx *sql.Tx) (api.ChatDone, error) {
		// A move to the project it is already in changes nothing, so zero
		// rows is a normal outcome (unchecked, as in Swift).
		_, err := tx.Exec(`UPDATE chat_conversations SET project_id = ?, session_id = NULL WHERE id = ? AND project_id IS NOT ?`,
			q.ProjectID, q.ConversationID, q.ProjectID)
		return api.ChatDone{}, err
	})
}

func chatSetRouting(ctx context.Context, c *tower.Ctx, q api.ChatSetRoutingRequest) (api.ChatDone, error) {
	r := q.Routing
	if !r.Automatic && !knownProvider(r.Provider) {
		return api.ChatDone{}, tower.Refuse(api.CodeUnsupported, sentenceUnknownProvider(r.Provider))
	}
	mode, provider, model := "pinned", nullString(r.Provider), nullString(r.Model)
	if r.Automatic {
		mode, provider, model = "preferred_reserve", sql.NullString{}, sql.NullString{}
	}
	return write(ctx, c, "", func(tx *sql.Tx) (api.ChatDone, error) {
		return api.ChatDone{}, requireConversation(tx.Exec(`UPDATE chat_conversations SET routing_mode = ?, provider = ?, model = ?,
			actual_provider = '', actual_model = '', routing_reason = '' WHERE id = ?`, mode, provider, model, q.ConversationID))
	})
}

func chatSetModel(ctx context.Context, c *tower.Ctx, q api.ChatSetModelRequest) (api.ChatDone, error) {
	if !knownProvider(q.Provider) {
		return api.ChatDone{}, tower.Refuse(api.CodeUnsupported, sentenceUnknownProvider(q.Provider))
	}
	return write(ctx, c, "", func(tx *sql.Tx) (api.ChatDone, error) {
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

// chatReviewerThread is ReviewerThreadQueries.ensure.
func chatReviewerThread(ctx context.Context, c *tower.Ctx, q api.ChatReviewerThreadRequest) (api.ChatNewResponse, error) {
	if q.ProjectID <= 0 || q.Branch == "" {
		return api.ChatNewResponse{}, tower.Refuse(api.CodeUnsupported, sentenceBadRequest)
	}
	return write(ctx, c, "This workbench no longer exists.", func(tx *sql.Tx) (api.ChatNewResponse, error) {
		var id int64
		err := tx.QueryRow(`SELECT conversation_id FROM review_reviewer_threads WHERE project_id = ? AND branch = ?`,
			q.ProjectID, q.Branch).Scan(&id)
		if err == nil {
			return api.ChatNewResponse{ConversationID: id}, nil
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return api.ChatNewResponse{}, err
		}
		contextID := strconv.FormatInt(q.ProjectID, 10) + ":" + q.Branch
		if id, err = insertContextChatTx(tx, "Reviewer: "+q.Branch, reviewerContext, contextID, nil, seconds(c.Now())); err != nil {
			return api.ChatNewResponse{}, err
		}
		_, err = tx.Exec(`INSERT INTO review_reviewer_threads (project_id, branch, conversation_id) VALUES (?, ?, ?)`,
			q.ProjectID, q.Branch, id)
		return api.ChatNewResponse{ConversationID: id}, err
	})
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

// chatAttach is ChatAttachmentStore.importFile/importData: the file is
// checked and stored before the write, and removed again when its row is
// not written.
func chatAttach(ctx context.Context, c *tower.Ctx, q api.ChatAttachRequest) (api.ChatAttachResponse, error) {
	owner := attachmentOwner{id: q.ConversationID}
	if q.ProjectID > 0 {
		owner = attachmentOwner{projectID: true, id: q.ProjectID}
	}
	if (q.ConversationID > 0) == (q.ProjectID > 0) || q.Name == "" || (q.DataBase64 == "") == (q.Path == "") {
		return api.ChatAttachResponse{}, tower.Refuse(api.CodeUnsupported, sentenceBadRequest)
	}
	data, err := attachmentBytes(c, q)
	if err != nil {
		return api.ChatAttachResponse{}, err
	}
	kind, rejection := ValidateAttachment(data, q.Name)
	if rejection != nil {
		return api.ChatAttachResponse{}, tower.Refuse(api.CodeUnsupported, rejection.Message())
	}
	root := filesRoot(ctx, c.DB)
	if root == "" {
		return api.ChatAttachResponse{}, tower.Refuse(api.CodeUnsupported, sentenceNoFilesDir)
	}
	f, err := prepareAttachmentFile(ctx, c.DB, root, owner, kind.FileExtension(q.Name), data)
	if err != nil {
		return api.ChatAttachResponse{}, err
	}
	gone := sentenceChatGone
	if owner.project() {
		gone = sentenceProjectGone
	}
	out, err := write(ctx, c, gone, func(tx *sql.Tx) (api.ChatAttachResponse, error) {
		// The owner's row must be there (Swift fails its foreign key).
		insert := `INSERT INTO chat_attachments (conversation_id, name, mime, size, path, sha256, created_at)
			SELECT id, ?, ?, ?, ?, ?, ? FROM chat_conversations WHERE id = ?`
		if owner.project() {
			insert = `INSERT INTO chat_attachments (project_id, name, mime, size, path, sha256, created_at)
			SELECT id, ?, ?, ?, ?, ?, ? FROM chat_projects WHERE id = ?`
		}
		res, err := tx.Exec(insert, q.Name, kind.Mime, len(data), f.path, f.sha, seconds(c.Now()), owner.id)
		if err != nil {
			return api.ChatAttachResponse{}, err
		}
		if n, err := res.RowsAffected(); err != nil || n == 0 {
			if err == nil {
				err = tower.Refuse(api.CodeNotFound, gone)
			}
			return api.ChatAttachResponse{}, err
		}
		id, err := res.LastInsertId()
		if err == nil && owner.project() {
			err = db.DropChatProjectSessionsTx(tx, owner.id)
		}
		out := api.ChatAttachResponse{AttachmentID: id, Mime: kind.Mime, Size: int64(len(data))}
		if c.Origin.Transport == "socket" {
			out.Path = f.path // the Mac's own path; the phone gets none
		}
		return out, err
	})
	if err != nil {
		f.discard()
	}
	return out, err
}

// attachmentBytes reads the request's file: its base64 bytes, or (over the
// daemon socket only, never for the phone) the local file at Path.
func attachmentBytes(c *tower.Ctx, q api.ChatAttachRequest) ([]byte, error) {
	if q.Path == "" {
		data, err := base64.StdEncoding.DecodeString(q.DataBase64)
		if err != nil {
			return nil, tower.Refuse(api.CodeUnsupported, sentenceUnreadable)
		}
		return data, nil
	}
	if c.Origin.Transport != "socket" {
		return nil, tower.Refuse(api.CodeNotPermitted, sentencePathOnMac)
	}
	info, err := os.Stat(q.Path)
	if err != nil || !info.Mode().IsRegular() {
		return nil, tower.Refuse(api.CodeUnsupported, sentenceUnreadable)
	}
	if info.Size() > MaxAttachmentBytes {
		// Too large for any kind: never read it.
		r := Rejection{Reason: RejectTooLarge, FileName: q.Name, Limit: MaxAttachmentBytes}
		return nil, tower.Refuse(api.CodeUnsupported, r.Message())
	}
	data, err := os.ReadFile(q.Path)
	if err != nil {
		return nil, tower.Refuse(api.CodeUnsupported, sentenceUnreadable)
	}
	return data, nil
}

func chatAttachLink(ctx context.Context, c *tower.Ctx, q api.ChatAttachLinkRequest) (api.ChatDone, error) {
	return write(ctx, c, sentenceMessageGone, func(tx *sql.Tx) (api.ChatDone, error) {
		return api.ChatDone{}, linkAttachmentsTx(tx, q.AttachmentIDs, q.MessageID)
	})
}

// chatAttachDelete is ChatAttachmentStore.discard: the row, then its file
// once no row points at it.
func chatAttachDelete(ctx context.Context, c *tower.Ctx, q api.ChatAttachmentRequest) (api.ChatChanged, error) {
	var orphan string
	out, err := write(ctx, c, "", func(tx *sql.Tx) (api.ChatChanged, error) {
		var path string
		err := tx.QueryRow(`SELECT path FROM chat_attachments WHERE id = ?`, q.AttachmentID).Scan(&path)
		if errors.Is(err, sql.ErrNoRows) {
			return api.ChatChanged{}, nil
		}
		if err != nil {
			return api.ChatChanged{}, err
		}
		if _, err := tx.Exec(`DELETE FROM chat_attachments WHERE id = ?`, q.AttachmentID); err != nil {
			return api.ChatChanged{}, err
		}
		orphan, err = db.ChatAttachmentOrphanTx(tx, path)
		return api.ChatChanged{Changed: true}, err
	})
	if err == nil && orphan != "" {
		removeStoredFile(orphan)
	}
	return out, err
}

// chatArtifactSaveEdit is ChatArtifactQueries.saveVersion(edited: true):
// the owner's edit is always a new version, MAX(version)+1.
func chatArtifactSaveEdit(ctx context.Context, c *tower.Ctx, q api.ChatArtifactSaveEditRequest) (api.ChatArtifactSaveEditResponse, error) {
	if q.ArtifactKey == "" {
		return api.ChatArtifactSaveEditResponse{}, tower.Refuse(api.CodeUnsupported, sentenceBadRequest)
	}
	return write(ctx, c, sentenceMessageGone, func(tx *sql.Tx) (api.ChatArtifactSaveEditResponse, error) {
		meta, err := metaJSON(q.Meta)
		if err != nil {
			return api.ChatArtifactSaveEditResponse{}, err
		}
		var version int64
		err = tx.QueryRow(`INSERT INTO chat_artifacts
			(conversation_id, message_id, artifact_key, version, kind, title, content, meta_json, edited, created_at)
			VALUES (?, ?, ?, (SELECT COALESCE(MAX(version), 0) + 1 FROM chat_artifacts WHERE conversation_id = ? AND artifact_key = ?),
				?, ?, ?, ?, 1, ?) RETURNING version`,
			q.ConversationID, q.MessageID, q.ArtifactKey, q.ConversationID, q.ArtifactKey,
			q.Kind, q.Title, q.Content, meta, seconds(c.Now())).Scan(&version)
		return api.ChatArtifactSaveEditResponse{Version: version}, err
	})
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
	return write(ctx, c, sentenceChatGone, func(tx *sql.Tx) (api.ChatMessageAppendResponse, error) {
		var one int
		if err := tx.QueryRow(`SELECT 1 FROM chat_conversations WHERE id = ?`, q.ConversationID).Scan(&one); errors.Is(err, sql.ErrNoRows) {
			return api.ChatMessageAppendResponse{}, ErrConversationGone
		} else if err != nil {
			return api.ChatMessageAppendResponse{}, fmt.Errorf("reading chat conversation %d: %w", q.ConversationID, err)
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
	code := sql.NullString{String: q.ErrorCode, Valid: q.ErrorCode != ""}
	msg := sql.NullString{String: q.ErrorMessage, Valid: q.ErrorMessage != "" || q.ErrorCode != ""}
	return write(ctx, c, sentenceMessageGone, func(tx *sql.Tx) (api.ChatDone, error) {
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
