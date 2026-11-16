package chatengine

// Message parts (unified chat spec §5.3, D14/D15): the typed pieces of a
// message every chat client draws, each with a fallback an older client can
// show instead. The engine builds every part that does not live in the answer
// text; the text-derived ones (artifact, question) are only described here for
// the fallback, the clients split them out of the text part themselves.
// Pinned by testdata/parts.json (CHAT-06).

import (
	"cmp"
	"encoding/json"
	"fmt"
	"net/url"
	"slices"
	"strings"

	"watchtower/internal/chat"
	"watchtower/internal/chatstore"
	"watchtower/internal/ideas"
	"watchtower/internal/instructions"
)

// The part kinds.
const (
	PartText          = "text"
	PartSteps         = "steps"
	PartSources       = "sources"
	PartArtifact      = "artifact"
	PartApproval      = "approval"
	PartQuestion      = "question"
	PartError         = "error"
	PartRememberMark  = "remember_mark"
	PartKnowledgeMark = "knowledge_mark"
	PartPublishedLink = "published_link"
	PartAttachment    = "attachment"
	PartRoutingNote   = "routing_note"
)

// PartKinds is every kind the engine emits, in the order of the spec.
var PartKinds = []string{
	PartText, PartSteps, PartSources, PartArtifact, PartApproval, PartQuestion, PartError,
	PartRememberMark, PartKnowledgeMark, PartPublishedLink, PartAttachment, PartRoutingNote,
}

// The fallback action kinds (CHAT-05: a fallback only opens a link, sends a
// fixed owner text the owner taps, or does nothing).
const (
	ActionChatTurn = "chat_turn"
	ActionOpenURL  = "open_url"
	ActionNone     = "none"
)

// FallbackTurnTexts is the only text a fallback `chat_turn` action may send,
// by key; the action carries the text itself.
var FallbackTurnTexts = map[string]string{
	"retry": "Please try again.",
}

// FallbackAction is one button of a fallback.
type FallbackAction struct {
	Label  string `json:"label"`
	Action string `json:"action"` // chat_turn|open_url|none
	Text   string `json:"text,omitempty"`
	URL    string `json:"url,omitempty"`
}

// Fallback is what a client that cannot draw a part shows instead.
type Fallback struct {
	Text    string           `json:"text"`
	Actions []FallbackAction `json:"actions"`
}

// Part is one typed piece of a message. Payload is nil when the client did
// not list the kind (FilterParts).
type Part struct {
	Kind     string          `json:"kind"`
	Payload  json.RawMessage `json:"payload,omitempty"`
	Fallback Fallback        `json:"fallback"`
}

// FilterParts is D15: a part whose kind the client did not list keeps its
// fallback and loses its payload. A nil PartKinds lists everything (relay,
// D21). The input is not changed.
func FilterParts(parts []Part, c Client) []Part {
	if c.PartKinds == nil {
		return parts
	}
	out := make([]Part, len(parts))
	for i, p := range parts {
		if !c.PartKinds[p.Kind] {
			p.Payload = nil
		}
		out[i] = p
	}
	return out
}

// FilterFeed is f with every part filtered for c.
func FilterFeed(f Feed, c Client) Feed {
	if c.PartKinds == nil {
		return f
	}
	msgs := make([]FeedMessage, len(f.Messages))
	for i, m := range f.Messages {
		m.Parts = FilterParts(m.Parts, c)
		msgs[i] = m
	}
	f.Messages = msgs
	return f
}

// BuildParts is m's parts: its text, attachments and marks, its steps and
// sources, the artifacts and question card its text holds, the approvals of
// its turn, published links, an error and, while its turn runs, the routing
// note. actions are the feed's actions (any turn); conv the conversation meta.
func BuildParts(m FeedMessage, conv FeedConversation, actions []FeedAction) []Part {
	parts := []Part{}
	live := m.Role == "assistant" && conv.Lease != nil && conv.Lease.TurnID != "" && conv.Lease.TurnID == m.turnID
	if m.Text != "" {
		parts = append(parts, newPart(PartText, map[string]any{"text": m.Text, "text_cut": m.TextCut},
			chat.QuestionReadableText(m.Text), nil))
	}
	for _, a := range m.Attachments {
		parts = append(parts, newPart(PartAttachment, a, fmt.Sprintf("Attachment: %s (%s, %s)", a.Name, a.Mime, byteSize(a.Size)), nil))
	}
	if m.Role == "user" {
		parts = append(parts, ownerMarks(m, conv)...)
		return parts
	}
	if len(m.Steps) > 0 {
		parts = append(parts, stepsPart(m.Steps))
		if src := sourcesPart(m.Steps); src != nil {
			parts = append(parts, *src)
		}
	}
	parts = append(parts, textDerivedParts(m, live)...)
	for _, a := range actions {
		if a.turnID == m.turnID && m.turnID != "" {
			parts = append(parts, approvalPart(a))
		}
	}
	parts = append(parts, publishedLinkParts(m.Steps)...)
	if m.Status == chatstore.StatusError || m.ErrorCode != nil {
		parts = append(parts, errorPart(m, conv))
	}
	if live && conv.ActualProvider != "" {
		parts = append(parts, routingNotePart(conv))
	}
	sortParts(parts)
	return parts
}

// partOrder is the order a message's parts come in.
var partOrder = []string{
	PartText, PartAttachment, PartRememberMark, PartKnowledgeMark, PartSteps, PartSources, PartArtifact,
	PartQuestion, PartApproval, PartPublishedLink, PartError, PartRoutingNote,
}

func sortParts(parts []Part) {
	rank := func(p Part) int { return slices.Index(partOrder, p.Kind) }
	slices.SortStableFunc(parts, func(a, b Part) int { return cmp.Compare(rank(a), rank(b)) })
}

// RefitParts rebuilds the parts that read the message's text and steps after
// a record cap cut them (the hub's fit): the approvals, the error and the
// routing note, which read neither, are kept as they were.
func (m *FeedMessage) RefitParts() {
	kept := slices.DeleteFunc(slices.Clone(m.Parts), func(p Part) bool {
		return p.Kind != PartApproval && p.Kind != PartError && p.Kind != PartRoutingNote
	})
	live := slices.ContainsFunc(m.Parts, func(p Part) bool { return p.Kind == PartRoutingNote })
	conv := FeedConversation{}
	if live {
		conv.Lease = &FeedLease{TurnID: m.turnID}
	}
	for _, p := range BuildParts(*m, conv, nil) {
		if p.Kind != PartApproval && p.Kind != PartError && p.Kind != PartRoutingNote {
			kept = append(kept, p)
		}
	}
	sortParts(kept)
	m.Parts = kept
}

// newPart builds a part; nil actions become an empty list (the wire has no
// null).
func newPart(kind string, payload any, text string, actions []FallbackAction) Part {
	b, err := json.Marshal(payload)
	if err != nil {
		b = nil // a payload of plain structs cannot fail; the fallback still shows
	}
	if actions == nil {
		actions = []FallbackAction{}
	}
	return Part{Kind: kind, Payload: b, Fallback: Fallback{Text: text, Actions: actions}}
}

// ownerMarks is the owner message's remember and knowledge notes: the same
// prefixes the Swift RememberCommand and KnowledgePrefix read (and the Go
// twins that act on them). Whether the CLI stored the line stays the
// Desktop's own note.
func ownerMarks(m FeedMessage, conv FeedConversation) []Part {
	var out []Part
	if rule, ok := instructions.ParseRemember(m.Text); ok {
		text := "Remembering for all chats: " + rule
		if rule == "" {
			text = "A remember command with no rule"
		}
		out = append(out, newPart(PartRememberMark, map[string]any{"rule": rule}, text, nil))
	}
	// LIVE-01: a chat that used Live Slack saves no knowledge.
	if kind, body, ok := ideas.ParseKnowledgePrefix(m.Text); ok && conv.LiveSlackSince == nil {
		word := "a fact"
		if kind == "decision" {
			word = "a decision"
		}
		text := "Saved as " + word
		if body == "" {
			text = "Nothing to save after the prefix"
		}
		out = append(out, newPart(PartKnowledgeMark, map[string]any{"kind": kind}, text, nil))
	}
	return out
}

func stepsPart(steps []FeedStep) Part {
	type step struct {
		Name    string `json:"name"`
		OK      *bool  `json:"ok,omitempty"`
		Summary string `json:"summary"`
	}
	payload := make([]step, len(steps))
	lines := make([]string, len(steps))
	for i, s := range steps {
		payload[i] = step{s.Name, s.OK, s.Summary}
		label := s.Summary
		if label == "" {
			label = s.Name
		}
		switch {
		case s.OK == nil:
			lines[i] = "- " + label
		case *s.OK:
			lines[i] = "- " + label + " (done)"
		default:
			lines[i] = "- " + label + " (failed)"
		}
	}
	return newPart(PartSteps, map[string]any{"steps": payload}, "Steps:\n"+strings.Join(lines, "\n"), nil)
}

// sourcesPart is the message's sources, once per source (a published page is
// a published_link, not listed here); nil when there are none.
func sourcesPart(steps []FeedStep) *Part {
	var list []chat.Source
	seen := map[string]bool{}
	for _, s := range steps {
		for _, src := range s.Sources {
			key := src.Kind + "\x00" + src.Ref + "\x00" + src.URL
			if src.Kind == chat.SourceKindPublished || seen[key] {
				continue
			}
			seen[key] = true
			list = append(list, src)
		}
	}
	if len(list) == 0 {
		return nil
	}
	lines := make([]string, len(list))
	for i, src := range list {
		lines[i] = "- " + src.Title
		if src.URL != "" {
			lines[i] += " (" + src.URL + ")"
		}
	}
	p := newPart(PartSources, map[string]any{"sources": list}, "Sources:\n"+strings.Join(lines, "\n"), nil)
	return &p
}

// textDerivedParts describes the artifacts and the question card of the text;
// clients take them from the text part (D14), so these are for a client that
// reads parts only, and for the fallbacks.
func textDerivedParts(m FeedMessage, live bool) []Part {
	var out []Part
	for _, a := range chatstore.ParseArtifacts(m.Text, !live) {
		out = append(out, newPart(PartArtifact, map[string]any{"key": a.Key, "kind": a.Kind, "title": a.Title, "meta": a.Meta},
			fmt.Sprintf("Artifact: %s (%s)", a.Title, a.Kind), nil))
	}
	if _, card := chat.ParseQuestionCard(m.Text, !live); card != nil {
		out = append(out, newPart(PartQuestion, card, cardReadable(card), nil))
	}
	return out
}

func cardReadable(card *chat.QuestionCard) string {
	blocks := make([]string, len(card.Questions))
	for i, q := range card.Questions {
		lines := []string{q.Question}
		for _, o := range q.Options {
			line := "- " + o.Label
			if o.Recommended {
				line += " (recommended)"
			}
			lines = append(lines, line)
		}
		blocks[i] = strings.Join(lines, "\n")
	}
	return strings.Join(blocks, "\n\n")
}

// approvalPart is an agent action waiting for, or decided by, the owner.
func approvalPart(a FeedAction) Part {
	payload := map[string]any{
		"id": a.ID, "tool": a.Tool, "title": a.Title, "args_display": a.ArgsDisplay,
		"args_sha256": a.ArgsSHA256, "status": a.Status,
	}
	if a.Reason != nil {
		payload["reason"] = *a.Reason
	}
	var tail string
	switch a.Status {
	case "pending":
		tail = "waiting for your approval"
	case "applied":
		tail = "done"
	case "rejected":
		tail = "declined"
	case "failed":
		tail = "failed"
	default:
		tail = a.Status
	}
	text := actionSentence(a) + " — " + tail
	if a.Status == "pending" {
		return newPart(PartApproval, payload, text, []FallbackAction{{Label: "Open on the Mac", Action: ActionNone}})
	}
	return newPart(PartApproval, payload, text, nil)
}

// actionSentence is what a tool call proposes, in words ("Send a Slack
// message to #general"); the tool's title when the args name nothing.
func actionSentence(a FeedAction) string {
	var args map[string]any
	_ = json.Unmarshal([]byte(a.ArgsDisplay), &args)
	str := func(k string) string {
		s, _ := args[k].(string)
		return strings.TrimSpace(s)
	}
	switch a.Tool {
	case "send_slack_message":
		if to := firstNonEmpty(str("channel"), str("user")); to != "" {
			return "Send a Slack message to " + to
		}
		return "Send a Slack message"
	case "add_jira_comment", "add_linear_comment":
		if k := str("key"); k != "" {
			return "Comment on " + k
		}
	case "transition_jira_issue", "transition_linear_issue":
		if k := str("key"); k != "" {
			return "Move " + k + " to " + firstNonEmpty(str("status"), str("state_name"), str("state"), "a new status")
		}
	case "remind_me":
		if at := str("remind_at"); at != "" {
			return "Set a reminder for " + at
		}
	}
	if k := str("key"); k != "" {
		return a.Title + " " + k
	}
	return a.Title
}

func firstNonEmpty(vs ...string) string {
	for _, v := range vs {
		if v != "" {
			return v
		}
	}
	return ""
}

// publishedLinkParts is one card per claude.ai page the turn published.
func publishedLinkParts(steps []FeedStep) []Part {
	var out []Part
	seen := map[string]bool{}
	for _, s := range steps {
		for _, src := range s.Sources {
			if src.Kind != chat.SourceKindPublished || !publishedURLPermitted(src.URL) || seen[src.URL] {
				continue
			}
			seen[src.URL] = true
			title := strings.TrimSpace(src.Title)
			if title == "" {
				title = src.URL
			}
			out = append(out, newPart(PartPublishedLink, map[string]any{"title": title, "url": src.URL},
				"Published on claude.ai: "+title, []FallbackAction{{Label: "Open", Action: ActionOpenURL, URL: src.URL}}))
		}
	}
	return out
}

// publishedURLPermitted is Swift PublishedLink.permits: https, host exactly
// claude.ai, no credentials or port, a path past "/". Fail closed.
func publishedURLPermitted(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil || strings.ToLower(u.Scheme) != "https" || u.User != nil || u.Port() != "" {
		return false
	}
	return strings.ToLower(u.Host) == "claude.ai" && len(u.EscapedPath()) > 1
}

// OpenURLPermitted is the CHAT-05 rule for a fallback `open_url`: a
// claude.ai page the owner's own turn published.
func OpenURLPermitted(raw string) bool { return publishedURLPermitted(raw) }

// errorPart is a failed or interrupted turn's error card.
func errorPart(m FeedMessage, conv FeedConversation) Part {
	code := ""
	if m.ErrorCode != nil {
		code = *m.ErrorCode
	}
	payload := map[string]any{"code": code}
	text := ErrorText(code, conv.ActualProvider)
	if m.ErrorMessage != nil && *m.ErrorMessage != "" {
		payload["message"] = *m.ErrorMessage
		text += "\n" + *m.ErrorMessage
	}
	var actions []FallbackAction
	if errorRetryable(code) {
		actions = []FallbackAction{{Label: "Try again", Action: ActionChatTurn, Text: FallbackTurnTexts["retry"]}}
	}
	return newPart(PartError, payload, text, actions)
}

// ErrorText is the Go twin of WatchtowerChatText's ChatErrorText.message.
func ErrorText(code, provider string) string {
	switch code {
	case "auth":
		return "The AI provider isn't signed in. " + signInHint(provider)
	case "quota_exhausted":
		return "Limit reached after work started"
	case "rate_limit":
		return "The provider is rate-limiting requests. Try again in a moment."
	case "provider_unavailable":
		return "The AI provider couldn't be started."
	case "session_lost":
		return "The previous session couldn't be resumed."
	case "attachment_unsupported":
		return "An attachment isn't supported by this provider."
	case "workdir_unsafe":
		return "Watchtower's chat folder isn't private. Delete it, then send your message again."
	}
	return "Something went wrong while answering."
}

func errorRetryable(code string) bool {
	return code != "quota_exhausted" && code != "auth" && code != "attachment_unsupported" && code != "workdir_unsafe"
}

func signInHint(provider string) string {
	switch provider {
	case "", "claude":
		return "Open Terminal and run: claude login"
	case "codex":
		return "Open Terminal and run: codex login"
	}
	return "Check its settings in Settings → AI."
}

// routingNotePart is which provider answers the running turn (from the
// session's own session_ready, so it shows before the database row does).
func routingNotePart(conv FeedConversation) Part {
	payload := map[string]any{
		"mode": conv.Routing.Mode, "actual_provider": conv.ActualProvider, "actual_model": conv.ActualModel,
	}
	if conv.Routing.Provider != nil {
		payload["provider"] = *conv.Routing.Provider
	}
	if conv.Routing.Model != nil {
		payload["model"] = *conv.Routing.Model
	}
	text := "Current provider: " + conv.ActualProvider
	if conv.ActualModel != "" {
		text += " · " + conv.ActualModel
	}
	return newPart(PartRoutingNote, payload, text, nil)
}

func byteSize(n int64) string {
	switch {
	case n >= 1<<20:
		return fmt.Sprintf("%.1f MB", float64(n)/(1<<20))
	case n >= 1<<10:
		return fmt.Sprintf("%.0f KB", float64(n)/(1<<10))
	}
	return fmt.Sprintf("%d B", n)
}
