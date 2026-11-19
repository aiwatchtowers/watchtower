package api

// The chat.* commands (stage 3, spec 2026-11-15-mobile-inbox-design §8): the
// embedded chats' and queued drafts' writes the Desktop made through GRDB.
// An embedded turn's own rows are written by `ai query --persist`, and the
// main chat's every row by the chat engine (#1822, chat.sock), not here.
// Each request embeds WriteParams; each command is a guarded (idempotent)
// write.

// ChatModelPick is an embedded chat's provider choice (the code question's
// pick): automatic, or pinned to Provider (and Model, empty for the
// provider's default). Not ChatRouting: ChatWire's main-chat type has that
// name, and the Desktop imports both.
type ChatModelPick struct {
	Automatic bool   `json:"automatic"`
	Provider  string `json:"provider,omitempty"`
	Model     string `json:"model,omitempty"`
}

// ChatContext places a new conversation in an embedded chat's context (a
// target, a track, a code question…). Reuse answers the context's newest
// existing conversation instead of making one (EmbeddedChatStore's
// find-or-create).
type ChatContext struct {
	Type  string `json:"type"`
	ID    string `json:"id"`
	Title string `json:"title,omitempty"`
	Reuse bool   `json:"reuse,omitempty"`
}

// ChatNewRequest is chat.new: an embedded chat in Context (in ProjectID,
// nil = none); a pinned Routing only records its provider and model (the
// code question's pick). Without Context it is refused: a main chat is made
// by the chat engine.
type ChatNewRequest struct {
	WriteParams
	ProjectID *int64         `json:"project_id,omitempty"`
	Routing   *ChatModelPick `json:"routing,omitempty"`
	Context   *ChatContext   `json:"context,omitempty"`
}

// ChatNewResponse answers chat.new and chat.reviewer_thread.
type ChatNewResponse struct {
	ConversationID int64 `json:"conversation_id"`
}

// ChatDone answers a write that has nothing to report.
type ChatDone struct{}

// ChatChanged answers a write that may find nothing to change: Changed is
// false when no row matched (the Swift writer's false).
type ChatChanged struct {
	Changed bool `json:"changed"`
}

// ChatSetTitleRequest is chat.set_title: an automatic title, never the
// owner's (an embedded chat's tab name, the tuning chat's first line).
// IfEmpty writes it only while the title is empty.
type ChatSetTitleRequest struct {
	WriteParams
	ConversationID int64  `json:"conversation_id"`
	Title          string `json:"title"`
	IfEmpty        bool   `json:"if_empty,omitempty"`
}

// ChatDeleteRequest is chat.delete: an embedded chat of ContextType, its
// rows by cascade and then its attachment folder. An empty ContextType (a
// main chat) is refused: the chat engine deletes main chats.
type ChatDeleteRequest struct {
	WriteParams
	ConversationID int64  `json:"conversation_id"`
	ContextType    string `json:"context_type,omitempty"`
}

// ChatSetModelRequest is chat.set_model: an embedded chat's provider and
// model (the code question's pick), leaving its routing mode alone.
type ChatSetModelRequest struct {
	WriteParams
	ConversationID int64  `json:"conversation_id"`
	Provider       string `json:"provider"`
	Model          string `json:"model,omitempty"`
}

// ChatContextRequest is chat.context: a new automation's draft chat becomes
// the saved automation's chat. A conversation the target context already
// has wins when it holds messages (Changed false).
type ChatContextRequest struct {
	WriteParams
	ConversationID int64  `json:"conversation_id"`
	ContextType    string `json:"context_type"`
	ContextID      string `json:"context_id"`
}

// ChatReviewerThreadRequest is chat.reviewer_thread: the Branch review
// reviewer's conversation for one branch of one workbench folder, made on
// first use. FolderID is the reviewed session's folder
// (terminal_sessions.workbench_folder_id); 0 = the workbench's home folder.
type ChatReviewerThreadRequest struct {
	WriteParams
	ProjectID int64  `json:"project_id"`
	FolderID  int64  `json:"folder_id,omitempty"`
	Branch    string `json:"branch"`
}

// ChatDeleteEmptyCodeQuestionsRequest is chat.code_question.delete_empty: a
// workbench's code questions with no message made before CreatedBefore,
// except Keeping.
type ChatDeleteEmptyCodeQuestionsRequest struct {
	WriteParams
	WorkbenchID   int64   `json:"workbench_id"`
	CreatedBefore float64 `json:"created_before"`
	Keeping       []int64 `json:"keeping,omitempty"`
}

// ChatCount answers a write with how many rows it changed.
type ChatCount struct {
	Count int64 `json:"count"`
}

// ChatDraftSaveRequest is chat.draft.save: an embedded chat's queued text.
type ChatDraftSaveRequest struct {
	WriteParams
	SurfaceKey string `json:"surface_key"`
	Text       string `json:"text"`
}

// ChatDraftClearRequest is chat.draft.clear.
type ChatDraftClearRequest struct {
	WriteParams
	SurfaceKey string `json:"surface_key"`
}

// ChatMessageAppendRequest is chat.message.append: one complete row of an
// embedded chat that is not a turn (a system notice after a reply, a local
// line), as ChatMessageQueries.insert wrote it. Role is user, assistant or
// system.
type ChatMessageAppendRequest struct {
	WriteParams
	ConversationID int64  `json:"conversation_id"`
	Role           string `json:"role"`
	Text           string `json:"text"`
}

// ChatMessageAppendResponse answers chat.message.append.
type ChatMessageAppendResponse struct {
	MessageID int64 `json:"message_id"`
}

// ChatReplyFinishRequest is chat.reply.finish: an embedded chat's reply as
// the Mac shows it once its turn ended (`ai query --persist` saved the
// streamed text): the surface's own reply text, or the turn's failure
// (ChatMessageQueries.finalizeEmbedded). Status is complete, partial or
// error; a complete reply touches its conversation.
type ChatReplyFinishRequest struct {
	WriteParams
	ConversationID int64  `json:"conversation_id"`
	MessageID      int64  `json:"message_id"`
	Text           string `json:"text"`
	Status         string `json:"status"`
	ErrorCode      string `json:"error_code,omitempty"`
	ErrorMessage   string `json:"error_message,omitempty"`
}

// MeetingsDeleteRequest is meetings.delete: a recording with its meeting
// chat (MeetingTranscriptQueries.delete); its audio file goes after the
// commit.
type MeetingsDeleteRequest struct {
	WriteParams
	TranscriptID int64 `json:"transcript_id"`
}

// MeetingsDeleteResponse answers meetings.delete; Deleted is false when no
// such recording existed.
type MeetingsDeleteResponse struct {
	Deleted bool `json:"deleted"`
}
