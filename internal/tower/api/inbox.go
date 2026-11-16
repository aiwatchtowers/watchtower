package api

import "encoding/json"

// FeedVersion is Feed.V: the feed document's shape. It moves only when a
// change is not additive.
const FeedVersion = 1

// FeedRequest asks for the Inbox feed (inbox.feed). It carries no time
// zone: the feed is zone-free, and grouping and every displayed time happen
// in the client's screen models.
type FeedRequest struct {
	// Folder narrows the cards to one folder; every folder is still sent.
	Folder *int64 `json:"folder,omitempty"`
	// Limit caps the cards (the phone sends 300; 0 = none): Needs approval
	// and Waiting for me first, then the rest newest first, the cut counted
	// per folder in Feed.More.
	Limit int `json:"limit,omitempty"`
	// Clip clips each card's body to 16 KB on a rune boundary.
	Clip bool `json:"clip,omitempty"`
}

// Feed is the Inbox as one read-only snapshot: every folder with its counts
// and the cards in list order (folders in pre-order, each folder's cards in
// its own order).
type Feed struct {
	V int `json:"v"`
	// BuiltAt is when the feed was built (RFC 3339 UTC).
	BuiltAt string   `json:"built_at"`
	Folders []Folder `json:"folders"`
	Cards   []Card   `json:"cards"`
	// More counts, per folder, the cards Limit left out.
	More []FolderMore `json:"more,omitempty"`
}

// FolderKind is a folder's kind: the one root, the one Needs approval, or
// one of the owner's.
type FolderKind string

// The folder kinds.
const (
	FolderRoot      FolderKind = "root"
	FolderApprovals FolderKind = "approvals"
	FolderOwner     FolderKind = "owner"
)

// EnumValues lists every FolderKind.
func (FolderKind) EnumValues() []string { return []string{"root", "approvals", "owner"} }

// Folder is one folder of the Inbox menu.
type Folder struct {
	ID    int64      `json:"id"`
	Kind  FolderKind `json:"kind"`
	Slug  string     `json:"slug"`
	Title string     `json:"title"`
	// Icon is an SF Symbol name; "" draws the default folder icon.
	Icon string `json:"icon"`
	// ParentID is nil only for the root.
	ParentID *int64 `json:"parent_id,omitempty"`
	Position int    `json:"position"`
	// Hidden is the effective value, not the row's own flag: set when the
	// folder or one of its ancestors is hidden. Such a folder leaves the menu
	// (unless the owner shows hidden folders) and the badge; which ancestor
	// hid it is found by walking parent_id.
	Hidden bool `json:"hidden"`
	// Count is the folder's own count (not its children's).
	Count int `json:"count"`
	// Waiting is the part of Count that waits on the owner.
	Waiting int `json:"waiting"`
}

// FolderMore is how many of a folder's cards FeedRequest.Limit left out.
type FolderMore struct {
	FolderID int64 `json:"folder_id"`
	Count    int   `json:"count"`
}

// CardKind is what a card shows.
type CardKind string

// The card kinds.
const (
	CardArtifact       CardKind = "artifact"
	CardApprovalNative CardKind = "approval_native"
	CardReminder       CardKind = "reminder"
	CardNotice         CardKind = "notice"
	CardLegacy         CardKind = "legacy"
)

// EnumValues lists every CardKind.
func (CardKind) EnumValues() []string {
	return []string{"artifact", "approval_native", "reminder", "notice", "legacy"}
}

// Card is one entry of a folder's list.
type Card struct {
	// ID is typed so that ids never collide: o<output>, a<action>,
	// r<reminder>, n<built-in move>, brief-<date>, tracks, ideas,
	// thread-briefs, messages.
	ID       string   `json:"id"`
	FolderID int64    `json:"folder_id"`
	CardKind CardKind `json:"card_kind"`
	Title    string   `json:"title"`
	// SourceLine is where the card came from, with no time: the screen
	// models append the time from Stamp in the client's zone.
	SourceLine string `json:"source_line"`
	// Preview is the body as one line of plain text, clipped.
	Preview string `json:"preview"`
	// Stamp is the card's time (RFC 3339 UTC): a living card's last write,
	// else its creation.
	Stamp  string `json:"stamp"`
	Living bool   `json:"living"`
	Unread bool   `json:"unread"`
	// Priority is high, medium or low.
	Priority string `json:"priority"`
	// Pinned is set on a card listed before the timed ones (Waiting for me
	// while it has rows that wait on the owner).
	Pinned     bool            `json:"pinned"`
	Automation *CardAutomation `json:"automation,omitempty"`
	// Blocks is the stored block document, or "" for a markdown card.
	Blocks string `json:"blocks"`
	Body   string `json:"body"`
	// BodyClipped is set when FeedRequest.Clip cut Body.
	BodyClipped bool `json:"body_clipped"`
	// Link is the card's own link (automation_outputs.link), the Mac's
	// common-row Open; "" for none and for every card that is not an
	// artifact.
	Link string `json:"link"`
	// ContentHash is the version drawn (an output's content hash, a native
	// approval's args SHA-256): every guarded write carries it back.
	ContentHash string       `json:"content_hash"`
	Actions     []CardAction `json:"actions"`
	RefFacts    []RefFacts   `json:"ref_facts"`
	// Approval is set on approval cards only.
	Approval *Approval `json:"approval,omitempty"`
	// Legacy is set on legacy cards only.
	Legacy *LegacySection `json:"legacy,omitempty"`
}

// CardAutomation is the automation behind an artifact card.
type CardAutomation struct {
	ID        int64  `json:"id"`
	Name      string `json:"name"`
	BuiltinID string `json:"builtin_id"`
	RunID     int64  `json:"run_id"`
}

// ActionState is how a card's button draws.
type ActionState string

// The action states.
const (
	ActionEnabled  ActionState = "enabled"
	ActionDisabled ActionState = "disabled"
	ActionPressed  ActionState = "pressed"
	ActionMacOnly  ActionState = "mac_only"
)

// EnumValues lists every ActionState.
func (ActionState) EnumValues() []string {
	return []string{"enabled", "disabled", "pressed", "mac_only"}
}

// CardAction is one button of a card.
type CardAction struct {
	// Index is the press address: the position in the card's flattened
	// action list (its own actions, then its blocks' in document order).
	Index int    `json:"index"`
	Kind  string `json:"kind"`
	// Label is the label the Mac draws ("Sent — run #N" on a pressed Reply).
	Label string      `json:"label"`
	State ActionState `json:"state"`
	// Detail is the button's own state where State is coarser: a Reply's
	// (ready, sent, needs_confirmation, off, unreadable, removed) or a
	// target's (idle, waiting, creating, stuck, failed, created); "" for
	// the other kinds.
	Detail string `json:"detail"`
	// Note is the line the Mac draws with it: a Reply's caption ("Needs
	// confirmation", "Off", …) or a failed target's message; "" for none.
	Note string `json:"note"`
	// Until is when Detail stops holding by time alone (RFC 3339 UTC): a
	// creating target reads as stuck from then on, with no write to wake a
	// watch, so a client compares it with its own clock; "" otherwise.
	Until string `json:"until"`
}

// RefKind is the kind of record a list row's ref points at.
type RefKind string

// The ref kinds.
const (
	RefInboxItem RefKind = "inbox_item"
	RefTrack     RefKind = "track"
	RefIdea      RefKind = "idea"
	RefReminder  RefKind = "reminder"
	RefAction    RefKind = "action"
	RefPlanItem  RefKind = "plan_item"
)

// EnumValues lists every RefKind.
func (RefKind) EnumValues() []string {
	return []string{"inbox_item", "track", "idea", "reminder", "action", "plan_item"}
}

// RefFacts is what a row's record is now.
type RefFacts struct {
	Kind RefKind `json:"kind"`
	ID   int64   `json:"id"`
	// Open: the row is drawn. Waits: it waits on the owner (counted).
	Open  bool `json:"open"`
	Waits bool `json:"waits"`
	// Reply: the record can be replied to; ReplyWaiting: a reply proposal
	// for it is open.
	Reply        bool   `json:"reply"`
	ReplyWaiting bool   `json:"reply_waiting"`
	Link         string `json:"link"`
}

// Approval is an approval card's proposal.
type Approval struct {
	Tool       string `json:"tool"`
	Title      string `json:"title"`
	Summary    string `json:"summary"`
	ArgsSHA256 string `json:"args_sha256"`
	Status     string `json:"status"`
	Error      string `json:"error"`
	Proposer   string `json:"proposer"`
	Reason     string `json:"reason"`
	// EditOnMac is set for a tool whose args the Mac's Edit… changes.
	EditOnMac bool `json:"edit_on_mac"`
	// Target is an Inbox target button's state on its newest proposal (a
	// create_target row of an automation_output context): the
	// CardAction.Detail values of a target (idle, waiting, creating, stuck,
	// failed, created); "" on any other row. The Mac draws it in place of
	// the decision row (AgentActionCardView.targetRow): stuck, or failed on
	// a row that is not itself failed, offers Try again; creating shows
	// progress; anything else keeps the decision row.
	Target     string `json:"target"`
	TargetNote string `json:"target_note"`
	// TargetUntil is when a creating Target reads as stuck (RFC 3339 UTC),
	// as CardAction.Until; "" otherwise.
	TargetUntil string `json:"target_until"`
	// Superseded: an older proposal of an Inbox button whose newest row is
	// another one; it offers no Retry (the CLI refuses it).
	Superseded bool `json:"superseded"`
	// Disclosure is the title of the recipe disclosure a save_automation
	// past pending draws ("Show the whole recipe (N lines)", "Show
	// changes", "No change to the recipe text"); "" for none.
	Disclosure string `json:"disclosure"`
	// RecipeText is a new recipe's whole text behind the disclosure; ""
	// for an edit.
	RecipeText string `json:"recipe_text"`
	// Diff is an edit's line diff against the saved recipe; empty for a
	// new recipe and for an unchanged one.
	Diff []DiffLine `json:"diff"`
	// RecipeClipped is set when FeedRequest.Clip cut RecipeText or Diff to
	// ClipBytes.
	RecipeClipped bool `json:"recipe_clipped"`
}

// DiffKind is one diff line's kind.
type DiffKind string

// The diff line kinds.
const (
	DiffSame    DiffKind = "same"
	DiffAdded   DiffKind = "added"
	DiffRemoved DiffKind = "removed"
)

// EnumValues lists every DiffKind.
func (DiffKind) EnumValues() []string { return []string{"same", "added", "removed"} }

// DiffLine is one line of a recipe diff (OwnerAskSnapshotDiff.Line).
type DiffLine struct {
	Kind DiffKind `json:"kind"`
	Text string   `json:"text"`
}

// LegacyKind is a legacy root entry's kind.
type LegacyKind string

// The legacy kinds.
const (
	LegacyMorningBrief LegacyKind = "morning_brief"
	LegacyTracks       LegacyKind = "tracks"
	LegacyIdeas        LegacyKind = "ideas"
	LegacyThreadBriefs LegacyKind = "thread_briefs"
	LegacyMessages     LegacyKind = "messages"
)

// EnumValues lists every LegacyKind.
func (LegacyKind) EnumValues() []string {
	return []string{"morning_brief", "tracks", "ideas", "thread_briefs", "messages"}
}

// LegacySection is a legacy root entry's list.
type LegacySection struct {
	Kind  LegacyKind   `json:"kind"`
	Items []LegacyItem `json:"items"`
	// Attention is a Morning brief day's attention list (the briefing's
	// attention items, in order); empty for the other kinds.
	Attention []LegacyAttention `json:"attention"`
}

// LegacyAttention is one attention item of a Morning brief (the briefing's
// AttentionItem).
type LegacyAttention struct {
	Text       string `json:"text"`
	Reason     string `json:"reason"`
	Priority   string `json:"priority"`
	SourceType string `json:"source_type"`
	SourceID   string `json:"source_id"`
}

// LegacyItem is one row of a legacy entry, with the words the Mac's list
// row draws (InboxListRow.content).
type LegacyItem struct {
	RefKind RefKind `json:"ref_kind"`
	ID      int64   `json:"id"`
	Title   string  `json:"title"`
	// Subtitle is the row's source line without its time (the screen
	// models add it from Stamp).
	Subtitle string `json:"subtitle"`
	// Preview is the row's second line ("2 new", an idea's essence, a
	// message's why-it-matters).
	Preview string `json:"preview"`
	// Stamp is the row's time (a plan item's start; "" for a backlog item).
	Stamp string `json:"stamp"`
	// End is a plan item's end (RFC 3339 UTC; "" when it has none): the Mac
	// draws a time block as its start–end range.
	End    string `json:"end"`
	Unread bool   `json:"unread"`
	// High: the row is high priority.
	High    bool `json:"high"`
	Stopped bool `json:"stopped"`
	// Done: a plan item is done.
	Done bool `json:"done"`
	// Date is a Morning brief's day (yyyy-MM-dd); "" otherwise.
	Date string `json:"date"`
}

// WatchRequest opens a watch (inbox.watch): the call answers ok, then the
// socket streams ChangedEvent frames until the client closes it.
type WatchRequest struct{}

// WatchResponse answers a watch request.
type WatchResponse struct{}

// ActVerb is what inbox.act does to its target.
type ActVerb string

// The act verbs.
const (
	ActRead         ActVerb = "read"
	ActDone         ActVerb = "done"
	ActDismiss      ActVerb = "dismiss"
	ActPress        ActVerb = "press"
	ActRunNow       ActVerb = "run_now"
	ActRef          ActVerb = "ref"
	ActReplyPropose ActVerb = "reply_propose"
	ActApproval     ActVerb = "approval"
)

// EnumValues lists every ActVerb.
func (ActVerb) EnumValues() []string {
	return []string{"read", "done", "dismiss", "press", "run_now", "ref", "reply_propose", "approval"}
}

// RefVerb is what a ref act does to its record.
type RefVerb string

// The ref verbs.
const (
	RefResolve  RefVerb = "resolve"
	RefDismiss  RefVerb = "dismiss"
	RefSnooze   RefVerb = "snooze"
	RefDone     RefVerb = "done"
	RefStop     RefVerb = "stop"
	RefRestore  RefVerb = "restore"
	RefMakeTask RefVerb = "make_task"
	RefApprove  RefVerb = "approve"
	RefReject   RefVerb = "reject"
	RefNotNow   RefVerb = "not_now"
	RefCheck    RefVerb = "check"
	RefUncheck  RefVerb = "uncheck"
)

// EnumValues lists every RefVerb.
func (RefVerb) EnumValues() []string {
	return []string{"resolve", "dismiss", "snooze", "done", "stop", "restore", "make_task",
		"approve", "reject", "not_now", "check", "uncheck"}
}

// ApprovalVerb is what an approval act does.
type ApprovalVerb string

// The approval verbs.
const (
	ApprovalApprove ApprovalVerb = "approve"
	ApprovalReject  ApprovalVerb = "reject"
	ApprovalRetry   ApprovalVerb = "retry"
	ApprovalDismiss ApprovalVerb = "dismiss"
)

// EnumValues lists every ApprovalVerb.
func (ApprovalVerb) EnumValues() []string { return []string{"approve", "reject", "retry", "dismiss"} }

// ActRequest is one Inbox write (inbox.act).
type ActRequest struct {
	WriteParams
	// Target is a card id (Card.ID).
	Target string    `json:"target"`
	Verb   ActVerb   `json:"verb"`
	Params ActParams `json:"params"`
}

// ActParams are a verb's parameters; each verb reads its own.
type ActParams struct {
	ContentHash  string          `json:"content_hash,omitempty"`
	Index        *int            `json:"index,omitempty"`
	Text         string          `json:"text,omitempty"`
	RefKind      RefKind         `json:"ref_kind,omitempty"`
	RefID        int64           `json:"ref_id,omitempty"`
	RefVerb      RefVerb         `json:"ref_verb,omitempty"`
	Until        string          `json:"until,omitempty"`
	ApprovalVerb ApprovalVerb    `json:"approval_verb,omitempty"`
	ArgsSHA256   string          `json:"args_sha256,omitempty"`
	Patch        json.RawMessage `json:"patch,omitempty"`
}

// ActResult answers inbox.act.
type ActResult struct {
	// Already: a guarded no-op (the write was already in place).
	Already bool `json:"already,omitempty"`
	// Status is an approval's state after the call: applying, applied or
	// failed.
	Status string `json:"status,omitempty"`
	Error  string `json:"error,omitempty"`
	RunID  int64  `json:"run_id,omitempty"`
}
