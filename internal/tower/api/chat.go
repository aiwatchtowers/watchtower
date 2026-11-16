package api

// The chat.* commands (stage 3, spec 2026-11-15-mobile-inbox-design §8): the
// conversation-level chat writes the Desktop made through GRDB. A turn's own
// rows are written by `ai session --persist`, not here. Each request embeds
// WriteParams; each command is a guarded (idempotent) write.

// ChatRouting is a conversation's provider choice: automatic, or pinned to
// Provider (and Model, empty for the provider's default).
type ChatRouting struct {
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

// ChatNewRequest is chat.new. Without Context it makes a main chat in
// ProjectID (nil = none) with Routing (nil = automatic). With Context it
// makes an embedded chat; a pinned Routing then only records its provider
// and model (the code question's pick).
type ChatNewRequest struct {
	WriteParams
	ProjectID *int64       `json:"project_id,omitempty"`
	Routing   *ChatRouting `json:"routing,omitempty"`
	Context   *ChatContext `json:"context,omitempty"`
}

// ChatNewResponse answers chat.new and chat.reviewer_thread.
type ChatNewResponse struct {
	ConversationID int64 `json:"conversation_id"`
}

// ChatConversationRequest names one conversation (chat.archive).
type ChatConversationRequest struct {
	WriteParams
	ConversationID int64 `json:"conversation_id"`
}

// ChatDone answers a write that has nothing to report.
type ChatDone struct{}

// ChatChanged answers a write that may find nothing to change: Changed is
// false when no row matched (the Swift writer's false).
type ChatChanged struct {
	Changed bool `json:"changed"`
}

// ChatPinRequest is chat.pin.
type ChatPinRequest struct {
	WriteParams
	ConversationID int64 `json:"conversation_id"`
	Pinned         bool  `json:"pinned"`
}

// ChatRenameRequest is chat.rename: the owner's title (title_source user).
type ChatRenameRequest struct {
	WriteParams
	ConversationID int64  `json:"conversation_id"`
	Title          string `json:"title"`
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

// ChatDeleteRequest is chat.delete: the conversation, its rows by cascade
// and then its attachment folder. ContextType empty deletes a main chat
// only; set, it deletes only a conversation of that context type.
type ChatDeleteRequest struct {
	WriteParams
	ConversationID int64  `json:"conversation_id"`
	ContextType    string `json:"context_type,omitempty"`
}

// ChatDeleteUntouchedRequest is chat.delete_untouched: the Chat landing's
// draft, only while it is untouched and still the row made at CreatedAt.
type ChatDeleteUntouchedRequest struct {
	WriteParams
	ConversationID int64   `json:"conversation_id"`
	CreatedAt      float64 `json:"created_at"`
	ProjectID      *int64  `json:"project_id,omitempty"`
}

// ChatBranchRequest is chat.branch: show MessageID's branch.
type ChatBranchRequest struct {
	WriteParams
	MessageID int64 `json:"message_id"`
}

// ChatReadRequest is chat.read; a positive MessageID bounds the answer the
// mark covers to what the reader saw.
type ChatReadRequest struct {
	WriteParams
	ConversationID int64 `json:"conversation_id"`
	MessageID      int64 `json:"message_id,omitempty"`
}

// ChatAttachRequest is chat.attach: one file for a conversation's composer
// (ConversationID) or a project's files (ProjectID), exactly one of them.
// The bytes come as DataBase64, or, over the daemon socket only, as Path, a
// file the daemon reads.
type ChatAttachRequest struct {
	WriteParams
	ConversationID int64  `json:"conversation_id,omitempty"`
	ProjectID      int64  `json:"project_id,omitempty"`
	Name           string `json:"name"`
	DataBase64     string `json:"data_base64,omitempty"`
	Path           string `json:"path,omitempty"`
}

// ChatAttachResponse answers chat.attach with the new chat_attachments row.
type ChatAttachResponse struct {
	AttachmentID int64  `json:"attachment_id"`
	Mime         string `json:"mime"`
	Size         int64  `json:"size"`
	Path         string `json:"path"`
}

// ChatAttachLinkRequest is chat.attach_link: pending attachments join the
// message they were sent with (a row a link already claimed stays).
type ChatAttachLinkRequest struct {
	WriteParams
	AttachmentIDs []int64 `json:"attachment_ids"`
	MessageID     int64   `json:"message_id"`
}

// ChatAttachmentRequest names one attachment (chat.attach_delete,
// chat.project.remove_file).
type ChatAttachmentRequest struct {
	WriteParams
	AttachmentID int64 `json:"attachment_id"`
}

// ChatSetProjectRequest is chat.set_project (nil ProjectID = out of any).
type ChatSetProjectRequest struct {
	WriteParams
	ConversationID int64  `json:"conversation_id"`
	ProjectID      *int64 `json:"project_id,omitempty"`
}

// ChatSetRoutingRequest is chat.set_routing: the picker's complete choice.
type ChatSetRoutingRequest struct {
	WriteParams
	ConversationID int64       `json:"conversation_id"`
	Routing        ChatRouting `json:"routing"`
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
// reviewer's conversation for one project branch, made on first use.
type ChatReviewerThreadRequest struct {
	WriteParams
	ProjectID int64  `json:"project_id"`
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

// ChatTurnRequest names one turn of a conversation (chat.stop, chat.recover).
type ChatTurnRequest struct {
	WriteParams
	ConversationID int64  `json:"conversation_id"`
	TurnID         string `json:"turn_id"`
}

// ChatRecoverResponse answers chat.recover: the replies marked session_lost
// and whether the turn's lease was released.
type ChatRecoverResponse struct {
	Marked   int64 `json:"marked"`
	Released bool  `json:"released"`
}

// ChatReleaseLaunchesRequest is chat.release_launches: at launch, the
// Desktop frees the leases its earlier launches left (every desktop lease
// whose owner id is not Keep); hub leases are never touched.
type ChatReleaseLaunchesRequest struct {
	WriteParams
	Keep string `json:"keep"`
}

// ChatReleaseLaunchesResponse answers chat.release_launches.
type ChatReleaseLaunchesResponse struct {
	Released int64 `json:"released"`
}

// ChatProjectCreateRequest is chat.project.create (a blank name becomes
// "New project").
type ChatProjectCreateRequest struct {
	WriteParams
	Name string `json:"name"`
}

// ChatProjectCreateResponse answers chat.project.create.
type ChatProjectCreateResponse struct {
	ProjectID int64  `json:"project_id"`
	Name      string `json:"name"`
}

// ChatProjectRequest names one project (chat.project.archive, .delete).
type ChatProjectRequest struct {
	WriteParams
	ProjectID int64 `json:"project_id"`
}

// ChatProjectRenameRequest is chat.project.rename (a blank name is ignored).
type ChatProjectRenameRequest struct {
	WriteParams
	ProjectID int64  `json:"project_id"`
	Name      string `json:"name"`
}

// ChatProjectInstructionsRequest is chat.project.instructions.
type ChatProjectInstructionsRequest struct {
	WriteParams
	ProjectID    int64  `json:"project_id"`
	Instructions string `json:"instructions"`
}

// ChatProjectAddSourceRequest is chat.project.add_source. Kind is one of
// jira_project, slack_channel, confluence_space, target, track, person.
type ChatProjectAddSourceRequest struct {
	WriteParams
	ProjectID int64  `json:"project_id"`
	Kind      string `json:"kind"`
	Ref       string `json:"ref"`
	Label     string `json:"label"`
}

// ChatProjectSourceRequest is chat.project.remove_source.
type ChatProjectSourceRequest struct {
	WriteParams
	SourceID int64 `json:"source_id"`
}

// ChatCommentAnchor is where an artifact comment points.
type ChatCommentAnchor struct {
	Quote   string `json:"quote"`
	Prefix  string `json:"prefix"`
	Suffix  string `json:"suffix"`
	Heading string `json:"heading"`
}

// ChatCommentAddRequest is chat.comment.add.
type ChatCommentAddRequest struct {
	WriteParams
	ConversationID int64             `json:"conversation_id"`
	ArtifactKey    string            `json:"artifact_key"`
	Version        int64             `json:"version"`
	Anchor         ChatCommentAnchor `json:"anchor"`
	Body           string            `json:"body"`
}

// ChatCommentAddResponse answers chat.comment.add.
type ChatCommentAddResponse struct {
	CommentID int64 `json:"comment_id"`
}

// ChatCommentRequest names one comment (chat.comment.delete_unsent, .resolve).
type ChatCommentRequest struct {
	WriteParams
	CommentID int64 `json:"comment_id"`
}

// ChatCommentMarkSentRequest is chat.comment.mark_sent: exactly these
// comments, those still open.
type ChatCommentMarkSentRequest struct {
	WriteParams
	CommentIDs []int64 `json:"comment_ids"`
	SentAt     float64 `json:"sent_at"`
}

// ChatCommentApplyRequest is chat.comment.apply: a re-anchor plan. Moved
// live comments move onto Version, Lost ones become outdated.
type ChatCommentApplyRequest struct {
	WriteParams
	Moved   []int64 `json:"moved,omitempty"`
	Lost    []int64 `json:"lost,omitempty"`
	Version int64   `json:"version"`
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

// ChatArtifactKeepRequest is chat.artifact.keep: Version of the key becomes
// the conversation's knowledge (refused in a Live Slack chat, LIVE-01).
type ChatArtifactKeepRequest struct {
	WriteParams
	ConversationID int64  `json:"conversation_id"`
	ArtifactKey    string `json:"artifact_key"`
	Version        int64  `json:"version"`
}

// ChatArtifactUnkeepRequest is chat.artifact.unkeep.
type ChatArtifactUnkeepRequest struct {
	WriteParams
	ConversationID int64  `json:"conversation_id"`
	ArtifactKey    string `json:"artifact_key"`
}

// ChatArtifactSaveEditRequest is chat.artifact.save_edit: the owner's edit
// of an artifact becomes its next version (edited).
type ChatArtifactSaveEditRequest struct {
	WriteParams
	ConversationID int64             `json:"conversation_id"`
	MessageID      int64             `json:"message_id"`
	ArtifactKey    string            `json:"artifact_key"`
	Kind           string            `json:"kind"`
	Title          string            `json:"title"`
	Content        string            `json:"content"`
	Meta           map[string]string `json:"meta,omitempty"`
}

// ChatArtifactSaveEditResponse answers chat.artifact.save_edit.
type ChatArtifactSaveEditResponse struct {
	Version int64 `json:"version"`
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
