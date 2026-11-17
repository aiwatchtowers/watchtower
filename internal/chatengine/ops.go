package chatengine

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"

	"watchtower/internal/chatstore"
)

// Client is who sent an operation or holds a subscription.
type Client struct {
	Kind      string          // mac|phone
	PartKinds map[string]bool // nil = all (relay, D21)
}

// OpHandler answers one operation; its result is encoded as JSON.
type OpHandler func(ctx context.Context, params json.RawMessage, c Client) (any, error)

// Operation errors beside chatstore's (ErrorCode maps them all).
var (
	ErrUnknownOp = errors.New("chatengine: unknown operation")
	ErrForbidden = errors.New("chatengine: forbidden")
)

// Register adds (or replaces) the handler of op.
func (e *Engine) Register(op string, h OpHandler) {
	e.opsMu.Lock()
	e.ops[op] = h
	e.opsMu.Unlock()
}

// Ops is the names of the registered operations, sorted (the relay's op
// contract, testdata/relay_ops.json, is checked against it).
func (e *Engine) Ops() []string {
	e.opsMu.RLock()
	defer e.opsMu.RUnlock()
	names := make([]string, 0, len(e.ops))
	for op := range e.ops {
		names = append(names, op)
	}
	sort.Strings(names)
	return names
}

// Do runs op with its JSON params for c and returns its JSON result.
func (e *Engine) Do(ctx context.Context, op string, params json.RawMessage, c Client) (json.RawMessage, error) {
	e.opsMu.RLock()
	h := e.ops[op]
	e.opsMu.RUnlock()
	if h == nil {
		return nil, ErrUnknownOp
	}
	if len(params) == 0 {
		params = json.RawMessage("{}")
	}
	res, err := h(ctx, params, c)
	if err != nil {
		return nil, err
	}
	b, err := json.Marshal(res)
	if err != nil {
		return nil, fmt.Errorf("chatengine: encoding the %s result: %w", op, err)
	}
	return b, nil
}

// ErrorCode is an operation error's code on the wire: busy, not_found,
// invalid, forbidden, closed or internal.
func ErrorCode(err error) string {
	switch {
	case errors.Is(err, chatstore.ErrBusy):
		return "busy"
	case errors.Is(err, chatstore.ErrConversationGone), errors.Is(err, chatstore.ErrNotFound),
		errors.Is(err, chatstore.ErrProjectGone), errors.Is(err, chatstore.ErrAttachmentMissing):
		return "not_found"
	case errors.Is(err, chatstore.ErrInvalid), errors.Is(err, ErrUnknownOp), errors.Is(err, errBadParams):
		return "invalid"
	case errors.Is(err, ErrForbidden):
		return "forbidden"
	case errors.Is(err, ErrClosed):
		return "closed"
	}
	return "internal"
}

// errBadParams wraps a params decoding failure.
var errBadParams = errors.New("chatengine: bad params")

// decode reads params into v; unknown keys are ignored.
func decode(params json.RawMessage, v any) error {
	if err := json.Unmarshal(params, v); err != nil {
		return fmt.Errorf("%w: %s", errBadParams, errClass(err))
	}
	return nil
}

// routingParams is the phone's routing ({mode: auto} or {mode: pinned,
// provider, model?}).
type routingParams struct {
	Mode     string `json:"mode"`
	Provider string `json:"provider"`
	Model    string `json:"model"`
}

// routing is r as a store routing; nil when r is (keep the conversation's).
func (r *routingParams) routing() (*chatstore.Routing, bool) {
	if r == nil {
		return nil, true
	}
	switch r.Mode {
	case "auto":
		return &chatstore.Routing{Automatic: true}, true
	case "pinned":
		if strings.TrimSpace(r.Provider) == "" {
			return nil, false
		}
		return &chatstore.Routing{Provider: r.Provider, Model: r.Model}, true
	}
	return nil, false
}

// ack is an operation's empty result.
func ack(err error) (any, error) {
	if err != nil {
		return nil, err
	}
	return struct{}{}, nil
}

// registerOps adds the chat operations (spec §5.2).
func (e *Engine) registerOps() {
	e.Register("chat_new", e.opNew)
	e.Register("chat_turn", e.opTurn)
	e.Register("chat_cancel", e.opCancel)
	e.Register("chat_page", e.opPage)
	e.Register("chat_search", e.opSearch)
	e.Register("chat_read", e.opRead)
	e.Register("chat_branch_select", e.opBranchSelect)
	e.Register("chat_manage", e.opManage)
	e.Register(opShutdown, e.opShutdownHandler)
	e.registerMacOps()
	e.registerWarmOps()
}

func (e *Engine) opNew(ctx context.Context, params json.RawMessage, _ Client) (any, error) {
	var p struct {
		ProjectID *int64         `json:"project_id"`
		Routing   *routingParams `json:"routing"`
	}
	if err := decode(params, &p); err != nil {
		return nil, err
	}
	routing, ok := p.Routing.routing()
	if !ok {
		return nil, errBadParams
	}
	id, err := e.NewConversation(ctx, p.ProjectID, routing)
	if err != nil {
		return nil, err
	}
	return map[string]int64{"conversation_id": id}, nil
}

func (e *Engine) opTurn(ctx context.Context, params json.RawMessage, _ Client) (any, error) {
	req, err := DecodeTurn(params)
	if err != nil {
		return nil, err
	}
	st, err := e.Turn(ctx, req)
	if err != nil {
		return nil, err
	}
	return map[string]any{"user_message_id": st.UserMessageID, "assistant_message_id": st.AssistantMessageID,
		"turn_id": st.TurnID}, nil
}

// turnModes are the chat_turn modes the store starts.
var turnModes = map[string]bool{
	chatstore.ModeSend: true, chatstore.ModeRegenerate: true, chatstore.ModeEdit: true,
	chatstore.ModeRetry: true, chatstore.ModeContinue: true,
}

// DecodeTurn reads chat_turn's params, as chat.sock and the relay's
// chat_turn action both carry them (spec §5.2): the one decoder of a turn, so
// a field the engine learns reaches the phone as well as the Mac (final
// review I2). A conversation id, a known mode, the routing and the compose
// are checked here, before the engine; an error wraps errBadParams
// (ErrorCode "invalid"). The relay keeps only its own caps (the text length).
func DecodeTurn(params json.RawMessage) (TurnRequest, error) {
	var p struct {
		ConversationID int64          `json:"conversation_id"`
		Mode           string         `json:"mode"`
		MessageID      int64          `json:"message_id"`
		Text           string         `json:"text"`
		AttachmentIDs  []int64        `json:"attachment_ids"`
		Routing        *routingParams `json:"routing"`
		ClientKey      string         `json:"client_key"`
		Compose        *Compose       `json:"compose"`
		ScreenContext  string         `json:"screen_context"`
		CommentIDs     []int64        `json:"artifact_comment_ids"`
	}
	if err := decode(params, &p); err != nil {
		return TurnRequest{}, err
	}
	routing, ok := p.Routing.routing()
	switch {
	case p.ConversationID <= 0:
		return TurnRequest{}, fmt.Errorf("%w: no conversation_id", errBadParams)
	case !turnModes[p.Mode]:
		return TurnRequest{}, fmt.Errorf("%w: unknown mode", errBadParams)
	case !ok:
		return TurnRequest{}, fmt.Errorf("%w: routing", errBadParams)
	case !p.Compose.Valid():
		return TurnRequest{}, fmt.Errorf("%w: compose", errBadParams)
	}
	return TurnRequest{StartRequest: chatstore.StartRequest{ConversationID: p.ConversationID, Mode: p.Mode,
		MessageID: p.MessageID, Text: p.Text, AttachmentIDs: p.AttachmentIDs, Routing: routing, Compose: p.Compose,
		ArtifactCommentIDs: p.CommentIDs, ClientKey: p.ClientKey}, ClientKey: p.ClientKey, ScreenContext: p.ScreenContext}, nil
}

func (e *Engine) opCancel(_ context.Context, params json.RawMessage, _ Client) (any, error) {
	var p struct {
		ConversationID int64  `json:"conversation_id"`
		TurnID         string `json:"turn_id"`
	}
	if err := decode(params, &p); err != nil {
		return nil, err
	}
	if p.ConversationID <= 0 || p.TurnID == "" {
		return nil, errBadParams
	}
	ok, err := e.Cancel(p.ConversationID, p.TurnID)
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, chatstore.ErrNotFound
	}
	return struct{}{}, nil
}

func (e *Engine) opPage(ctx context.Context, params json.RawMessage, c Client) (any, error) {
	var p struct {
		ConversationID  int64 `json:"conversation_id"`
		BeforeMessageID int64 `json:"before_message_id"`
	}
	if err := decode(params, &p); err != nil {
		return nil, err
	}
	if p.ConversationID <= 0 || p.BeforeMessageID <= 0 {
		return nil, errBadParams
	}
	f, err := e.Feed(ctx, p.ConversationID, p.BeforeMessageID)
	return FilterFeed(f, c), err // D15: the client's own part kinds
}

func (e *Engine) opSearch(ctx context.Context, params json.RawMessage, _ Client) (any, error) {
	var p struct {
		Query string `json:"query"`
	}
	if err := decode(params, &p); err != nil {
		return nil, err
	}
	if strings.TrimSpace(p.Query) == "" {
		return nil, errBadParams
	}
	return e.Search(ctx, p.Query)
}

func (e *Engine) opRead(ctx context.Context, params json.RawMessage, _ Client) (any, error) {
	var p struct {
		ConversationID int64 `json:"conversation_id"`
		MessageID      int64 `json:"message_id"`
	}
	if err := decode(params, &p); err != nil {
		return nil, err
	}
	return ack(e.MarkRead(ctx, p.ConversationID, p.MessageID))
}

func (e *Engine) opBranchSelect(ctx context.Context, params json.RawMessage, _ Client) (any, error) {
	var p struct {
		MessageID int64 `json:"message_id"`
	}
	if err := decode(params, &p); err != nil {
		return nil, err
	}
	return ack(e.SelectBranch(ctx, p.MessageID))
}

func (e *Engine) opManage(ctx context.Context, params json.RawMessage, _ Client) (any, error) {
	var p struct {
		ConversationID int64  `json:"conversation_id"`
		Op             string `json:"op"`
		Title          string `json:"title"`
		ProjectID      *int64 `json:"project_id"`
	}
	if err := decode(params, &p); err != nil {
		return nil, err
	}
	if p.ConversationID <= 0 {
		return nil, errBadParams
	}
	return ack(e.Manage(ctx, ManageRequest{Conversation: p.ConversationID, Op: p.Op, Title: p.Title, ProjectID: p.ProjectID}))
}
