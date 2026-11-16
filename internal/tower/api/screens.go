package api

// The other Mac screens' write commands (plan Task 9; internal/inboxfeed/
// screens.go): Home and the Inbox strip, Tracks, Ideas and Decisions,
// Digests, Day plan, Catch-Up and the targets' status. Each request embeds
// WriteParams; most answer ActResult.

// ScreenIDRequest names one row (inbox_items.read, tracks.done,
// tracks.restore, tracks.delete, ideas.delete, ideas.decision_seen,
// catchup.acknowledge, targets.work_on).
type ScreenIDRequest struct {
	WriteParams
	ID int64 `json:"id"`
}

// ScreenIDsRequest names rows (briefing.read, tracks.read, tracks.stop,
// digests.read).
type ScreenIDsRequest struct {
	WriteParams
	IDs []int64 `json:"ids"`
}

// OutputMarkRequest marks an Inbox card read, done or dismissed
// (outputs.read, outputs.done, outputs.dismiss) while it still has the
// content the owner saw.
type OutputMarkRequest struct {
	WriteParams
	ID          int64  `json:"id"`
	ContentHash string `json:"content_hash"`
}

// ReminderWriteRequest marks a reminder done (reminders.done) or snoozes it
// until Until (reminders.snooze, RFC 3339 UTC).
type ReminderWriteRequest struct {
	WriteParams
	ID    int64  `json:"id"`
	Until string `json:"until,omitempty"`
}

// TrackPriorityRequest corrects a track's priority (tracks.priority).
type TrackPriorityRequest struct {
	WriteParams
	ID       int64  `json:"id"`
	Priority string `json:"priority"`
}

// TrackOwnershipRequest sets a track's ownership (tracks.ownership).
type TrackOwnershipRequest struct {
	WriteParams
	ID        int64  `json:"id"`
	Ownership string `json:"ownership"`
}

// TrackSubItemRequest sets sub-item Index of a track done or open
// (tracks.sub_items).
type TrackSubItemRequest struct {
	WriteParams
	ID    int64 `json:"id"`
	Index int   `json:"index"`
	Done  bool  `json:"done"`
}

// TrackEnabledRequest turns a track's collection on or off (tracks.enabled).
type TrackEnabledRequest struct {
	WriteParams
	ID      int64 `json:"id"`
	Enabled bool  `json:"enabled"`
}

// TrackInstructionRequest edits a custom track's instruction
// (tracks.instruction).
type TrackInstructionRequest struct {
	WriteParams
	ID          int64  `json:"id"`
	Instruction string `json:"instruction"`
}

// TrackEventStatusRequest sets a track event's action status
// (tracks.event_status).
type TrackEventStatusRequest struct {
	WriteParams
	EventID int64  `json:"event_id"`
	Status  string `json:"status"`
}

// TrackEventsReadRequest marks a track's events read (tracks.events_read):
// EventID's alone, or every unread one when it is 0.
type TrackEventsReadRequest struct {
	WriteParams
	TrackID int64 `json:"track_id"`
	EventID int64 `json:"event_id,omitempty"`
}

// IdeaStatusRequest sets an idea's status (ideas.status).
type IdeaStatusRequest struct {
	WriteParams
	ID     int64  `json:"id"`
	Status string `json:"status"`
}

// IdeaSnoozeRequest puts an idea off until a date, "" for no date
// (ideas.snooze).
type IdeaSnoozeRequest struct {
	WriteParams
	ID    int64  `json:"id"`
	Until string `json:"until,omitempty"`
}

// IdeaMergeRequest merges an idea into another (ideas.merge).
type IdeaMergeRequest struct {
	WriteParams
	ID   int64 `json:"id"`
	Into int64 `json:"into"`
}

// IdeaSupersedeRequest marks an idea superseded, by By when set
// (ideas.supersede).
type IdeaSupersedeRequest struct {
	WriteParams
	ID int64  `json:"id"`
	By *int64 `json:"by,omitempty"`
}

// IdeaRatingRequest rates an idea (ideas.rating).
type IdeaRatingRequest struct {
	WriteParams
	ID      int64  `json:"id"`
	Rating  int    `json:"rating"`
	Comment string `json:"comment"`
}

// IdeaCreateRequest writes an owner idea (ideas.create).
type IdeaCreateRequest struct {
	WriteParams
	Kind    string `json:"kind"`
	Title   string `json:"title"`
	Essence string `json:"essence"`
}

// IdeaConvertedRequest converts an idea into a day target of Today (the
// Mac's local date, "2006-01-02") and marks it converted, in one write
// (ideas.converted).
type IdeaConvertedRequest struct {
	WriteParams
	ID    int64  `json:"id"`
	Today string `json:"today"`
}

// IdeaConvertResult answers ideas.converted with the target: the new one,
// or (Already) the one the idea was converted to before.
type IdeaConvertResult struct {
	TargetID int64 `json:"target_id"`
	Already  bool  `json:"already,omitempty"`
}

// DecisionsSeenAllRequest marks every decision seen
// (ideas.decisions_seen_all).
type DecisionsSeenAllRequest struct {
	WriteParams
}

// IdeaFromChatRequest writes a chat message's knowledge prefix as an item
// (ideas.create_from_chat).
type IdeaFromChatRequest struct {
	WriteParams
	ConversationID int64  `json:"conversation_id"`
	MessageID      int64  `json:"message_id"`
	Kind           string `json:"kind"`
	Body           string `json:"body"`
}

// IdeaUndoChatRequest undoes a chat-born item while it is untouched
// (ideas.undo_chat): CreatedUpdatedAt is its updated_at read right after
// it was made.
type IdeaUndoChatRequest struct {
	WriteParams
	ID               int64  `json:"id"`
	CreatedUpdatedAt string `json:"created_updated_at"`
}

// UndoChatResult answers ideas.undo_chat: false when the item was touched
// since, and nothing was deleted (the Mac opens it instead).
type UndoChatResult struct {
	Undone bool `json:"undone"`
}

// CreatedResult answers a command that adds a row with its id.
type CreatedResult struct {
	ID int64 `json:"id"`
}

// PlanItemStatusRequest checks a day plan item off (dayplan.done) or back
// (dayplan.pending); Cascade carries it to the item's task.
type PlanItemStatusRequest struct {
	WriteParams
	ItemID  int64 `json:"item_id"`
	Cascade bool  `json:"cascade"`
}

// PlanItemRequest names a day plan item (dayplan.delete).
type PlanItemRequest struct {
	WriteParams
	ItemID int64 `json:"item_id"`
}

// PlanReorderRequest orders a plan's backlog (dayplan.reorder).
type PlanReorderRequest struct {
	WriteParams
	PlanID     int64   `json:"plan_id"`
	OrderedIDs []int64 `json:"ordered_ids"`
}

// PlanAddRequest adds a manual item to a plan's backlog (dayplan.add):
// StartTime and EndTime are RFC 3339, "" for none.
type PlanAddRequest struct {
	WriteParams
	PlanID    int64  `json:"plan_id"`
	Kind      string `json:"kind"`
	Title     string `json:"title"`
	StartTime string `json:"start_time,omitempty"`
	EndTime   string `json:"end_time,omitempty"`
}

// TargetStatusRequest sets a target's status as the owner
// (targets.set_status).
type TargetStatusRequest struct {
	WriteParams
	ID     int64  `json:"id"`
	Status string `json:"status"`
}

// TargetColumnRequest moves a target's card to board column ColumnID of
// Status, nil for the status's first column (targets.set_column).
type TargetColumnRequest struct {
	WriteParams
	ID       int64  `json:"id"`
	Status   string `json:"status"`
	ColumnID *int64 `json:"column_id,omitempty"`
}

// TargetSnoozeRequest snoozes a target until a date ("2006-01-02") or a UTC
// minute ("2006-01-02T15:04") (targets.snooze).
type TargetSnoozeRequest struct {
	WriteParams
	ID    int64  `json:"id"`
	Until string `json:"until"`
}

// TargetStatusResult answers an owner target write.
type TargetStatusResult struct {
	// RolledUp are the ancestors whose status the PROJ-05 rollup moved in
	// the same write, sorted: the owner's doing too, so they never notify.
	RolledUp []int64 `json:"rolled_up"`
}

// WorkOnResult answers targets.work_on.
type WorkOnResult struct {
	// Moved is true when the task moved from todo to in_progress.
	Moved    bool    `json:"moved"`
	RolledUp []int64 `json:"rolled_up"`
}

// DigestDecisionReadRequest marks one decision of a digest read
// (digests.decision_read).
type DigestDecisionReadRequest struct {
	WriteParams
	DigestID int64 `json:"digest_id"`
	Idx      int   `json:"idx"`
}

// DigestRequest names a digest (digests.decisions_read_all).
type DigestRequest struct {
	WriteParams
	DigestID int64 `json:"digest_id"`
}
