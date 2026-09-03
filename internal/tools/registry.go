// Package tools is the assistant's tool registry — the single catalog of
// what the assistant can do, with per-tool access class and trust.
//
// Controlled writes (spec §6): a write tool called through Propose never
// reaches its Execute; the registry records an agent_actions row and hands
// the model a receipt. Execution happens only through Apply, which the
// Desktop drives after the owner approved (or inline when the owner granted
// the tool "execute" trust). MCP is one adapter over this package; the Go
// tool loop for HTTP providers (runtime B) will be the second.
package tools

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"

	"github.com/google/jsonschema-go/jsonschema"

	"watchtower/internal/db"
)

// Access classifies what a tool does: a read never needs approval, a write
// always goes through the proposal flow.
type Access string

const (
	AccessRead  Access = "read"
	AccessWrite Access = "write"
)

// Trust is the owner's standing decision for a write tool: ask every time,
// or execute immediately without a per-call approval.
type Trust string

const (
	TrustAsk     Trust = "ask"
	TrustExecute Trust = "execute"
)

// Binding is where a proposal came from: the chat surface, conversation and
// turn the Desktop passed to the chat-mode server.
type Binding struct {
	Surface        string
	ConversationID int64
	ContextType    string
	ContextID      string
	TurnID         string
}

// Call is what Execute receives: the recorded row id (0 for RunDirect), the
// raw arguments and the binding.
type Call struct {
	ActionID int64
	Args     json.RawMessage
	Binding  Binding
}

// Tool is one registry entry.
type Tool struct {
	Name        string
	Description string
	InputSchema *jsonschema.Schema
	Access      Access
	// External marks writes that leave this machine (Jira). Such a tool can
	// never be granted execute trust (AGENT-03).
	External bool
	// Surfaces lists the chat surfaces that may see the tool; empty = every
	// surface.
	Surfaces []string
	// Validate runs semantic checks beyond the schema; return *ValidationError
	// for a message the model should see verbatim.
	Validate func(ctx context.Context, d *db.DB, args json.RawMessage) error
	// Execute performs the write. Only Apply (and RunDirect) call it.
	Execute func(ctx context.Context, d *db.DB, call Call) (any, error)
}

// Receipt is what the model gets back from a write-tool call.
type Receipt struct {
	ActionID int64  `json:"action_id"`
	Status   string `json:"status"`
	Tool     string `json:"tool"`
	Message  string `json:"message"`
	Result   any    `json:"result,omitempty"`
	Error    string `json:"error,omitempty"`
}

// ValidationError carries a model-facing message; no row is written for it.
type ValidationError struct{ Msg string }

func (e *ValidationError) Error() string { return e.Msg }

var (
	ErrUnknownTool     = errors.New("unknown tool")
	ErrNotWritable     = errors.New("tool is not a write tool")
	ErrExternalExecute = errors.New("an external tool can never be trusted to execute without approval")
	ErrBadTransition   = errors.New("action is not in an applicable state")
	ErrNotFound        = errors.New("action not found")
)

// Registry holds the tools and the DB the proposal rows live in.
type Registry struct {
	db    *db.DB
	tools map[string]*Tool
	order []string
}

// New creates a registry backed by d.
func New(d *db.DB) *Registry {
	return &Registry{db: d, tools: map[string]*Tool{}}
}

// Register adds a tool; names are unique and write tools need a schema.
func (r *Registry) Register(t *Tool) error {
	if t == nil || strings.TrimSpace(t.Name) == "" {
		return errors.New("register: tool has no name")
	}
	if _, dup := r.tools[t.Name]; dup {
		return fmt.Errorf("register: duplicate tool %q", t.Name)
	}
	if t.Access == AccessWrite && (t.InputSchema == nil || t.Validate == nil || t.Execute == nil) {
		return fmt.Errorf("register: write tool %q needs InputSchema, Validate and Execute", t.Name)
	}
	r.tools[t.Name] = t
	r.order = append(r.order, t.Name)
	return nil
}

// Get returns the named tool, or false when it is not registered.
func (r *Registry) Get(name string) (*Tool, bool) {
	t, ok := r.tools[name]
	return t, ok
}

// List returns the tools visible on surface, in registration order.
func (r *Registry) List(surface string) []*Tool {
	var out []*Tool
	for _, name := range r.order {
		t := r.tools[name]
		if len(t.Surfaces) == 0 || slices.Contains(t.Surfaces, surface) {
			out = append(out, t)
		}
	}
	return out
}

// All returns every registered tool in registration order.
func (r *Registry) All() []*Tool {
	out := make([]*Tool, 0, len(r.order))
	for _, name := range r.order {
		out = append(out, r.tools[name])
	}
	return out
}

// Trust returns the tool's trust level ("ask" when never set).
func (r *Registry) Trust(name string) (Trust, error) {
	if _, ok := r.tools[name]; !ok {
		return "", ErrUnknownTool
	}
	s, err := r.db.GetToolTrust(name)
	if err != nil {
		return "", err
	}
	return Trust(s), nil
}

// SetTrust changes the trust level; execute is refused for External tools.
func (r *Registry) SetTrust(name string, trust Trust) error {
	t, ok := r.tools[name]
	if !ok {
		return ErrUnknownTool
	}
	if trust != TrustAsk && trust != TrustExecute {
		return fmt.Errorf("invalid trust %q", trust)
	}
	if t.External && trust == TrustExecute {
		return ErrExternalExecute
	}
	return r.db.SetToolTrust(name, string(trust))
}

// reasonOf extracts the mandatory "reason" argument every write tool carries.
func reasonOf(args json.RawMessage) string {
	var r struct {
		Reason string `json:"reason"`
	}
	_ = json.Unmarshal(args, &r)
	return strings.TrimSpace(r.Reason)
}

// Propose validates a write-tool call and records it. With trust "ask" the
// row is pending and nothing executes; with "execute" the row is inserted as
// approved and applied inline, so the model sees the result immediately.
func (r *Registry) Propose(ctx context.Context, name string, args json.RawMessage, b Binding) (Receipt, error) {
	t, ok := r.tools[name]
	if !ok {
		return Receipt{}, ErrUnknownTool
	}
	if t.Access != AccessWrite {
		return Receipt{}, ErrNotWritable
	}
	if len(args) == 0 {
		args = json.RawMessage(`{}`)
	}
	if !json.Valid(args) {
		return Receipt{}, &ValidationError{Msg: "arguments are not valid JSON"}
	}
	if err := t.Validate(ctx, r.db, args); err != nil {
		return Receipt{}, err
	}
	reason := reasonOf(args)
	if reason == "" {
		return Receipt{}, &ValidationError{Msg: `"reason" is required: say why you propose this`}
	}
	trust, err := r.Trust(name)
	if err != nil {
		return Receipt{}, err
	}
	row := db.AgentAction{
		Tool: name, External: t.External, ArgsJSON: string(args), Reason: reason,
		Surface: b.Surface, ConversationID: b.ConversationID,
		ContextType: b.ContextType, ContextID: b.ContextID, TurnID: b.TurnID,
		Status: "pending", TrustAtCreate: string(trust),
	}
	if trust == TrustExecute {
		row.Status = "approved"
	}
	id, err := r.db.InsertAgentAction(row)
	if err != nil {
		return Receipt{}, err
	}
	if trust == TrustExecute {
		// Stamp decided_at the way an owner approval would.
		if _, err := r.finishTransition(id, []string{"approved"}, "approved", "", ""); err != nil {
			return Receipt{}, err
		}
		applied, err := r.Apply(ctx, id)
		if err != nil {
			return Receipt{}, err
		}
		return receiptFor(applied), nil
	}
	return Receipt{
		ActionID: id, Status: "pending", Tool: name,
		Message: fmt.Sprintf("Proposal #%d recorded (%s). The owner must approve it in this chat before "+
			"anything happens — tell the owner it awaits their approval and do not claim it is done.", id, name),
	}, nil
}

// Apply executes an approved (or previously failed) row exactly once and
// records applied/failed. applied and rejected are terminal (AGENT-05).
func (r *Registry) Apply(ctx context.Context, id int64) (*db.AgentAction, error) {
	row, err := r.db.GetAgentAction(id)
	if err != nil {
		return nil, err
	}
	if row == nil {
		return nil, ErrNotFound
	}
	if row.Status != "approved" && row.Status != "failed" {
		return nil, fmt.Errorf("%w: #%d is %s", ErrBadTransition, id, row.Status)
	}
	from := []string{"approved", "failed"}
	t, ok := r.tools[row.Tool]
	if !ok {
		return r.finishTransition(id, from, "failed", "", "unknown tool "+row.Tool)
	}
	call := Call{ActionID: id, Args: json.RawMessage(row.ArgsJSON), Binding: Binding{
		Surface: row.Surface, ConversationID: row.ConversationID,
		ContextType: row.ContextType, ContextID: row.ContextID, TurnID: row.TurnID,
	}}
	result, execErr := t.Execute(ctx, r.db, call)
	if execErr != nil {
		return r.finishTransition(id, from, "failed", "", execErr.Error())
	}
	resultJSON, err := json.Marshal(result)
	if err != nil {
		resultJSON = []byte("{}")
	}
	return r.finishTransition(id, from, "applied", string(resultJSON), "")
}

// finishTransition moves id from one of `from` to `to` and re-reads the row.
// A lost race — the row was no longer in `from` when the UPDATE ran, e.g. the
// owner rejected it while Execute was in flight, or a concurrent Apply won —
// is reported as ErrBadTransition rather than silently returning stale state;
// a row missing on re-read (it should never be deleted, but defend anyway) is
// ErrNotFound. Apply must never return (nil, nil).
func (r *Registry) finishTransition(id int64, from []string, to, resultJSON, errMsg string) (*db.AgentAction, error) {
	ok, err := r.db.TransitionAgentAction(id, from, to, resultJSON, errMsg)
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, fmt.Errorf("%w: #%d changed state before it could be marked %s", ErrBadTransition, id, to)
	}
	row, err := r.db.GetAgentAction(id)
	if err != nil {
		return nil, err
	}
	if row == nil {
		return nil, ErrNotFound
	}
	return row, nil
}

func receiptFor(row *db.AgentAction) Receipt {
	rc := Receipt{ActionID: row.ID, Status: row.Status, Tool: row.Tool}
	switch row.Status {
	case "applied":
		var result any
		_ = json.Unmarshal([]byte(row.ResultJSON), &result)
		rc.Result = result
		rc.Message = fmt.Sprintf("Action #%d executed (%s).", row.ID, row.Tool)
	default:
		rc.Error = row.Error
		rc.Message = fmt.Sprintf("Action #%d failed (%s): %s", row.ID, row.Tool, row.Error)
	}
	return rc
}

// RunDirect validates and executes a tool outside the proposal flow — the
// CLI face (`watchtower jira create`) for humans and tests. ActionID is 0.
func RunDirect(ctx context.Context, d *db.DB, t *Tool, args json.RawMessage) (any, error) {
	if err := t.Validate(ctx, d, args); err != nil {
		return nil, err
	}
	return t.Execute(ctx, d, Call{Args: args})
}
