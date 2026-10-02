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
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strconv"
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
// turn the Desktop passed to the chat-mode server. TurnIDFunc, when set, is
// read at propose time and wins over TurnID — a warm `ai session` spans many
// turns and publishes the running one through a turn file (spec §1.2).
//
// ProjectID binds the session to one project (`watchtower mcp --project N`):
// every call first checks the project still exists, and project tools scope
// every row they touch to it (DEV-06). DirectApply makes Propose apply a
// non-External tool inline for this call only — the owner's standing trust
// rows are neither read nor changed — and refuses an External one outright.
type Binding struct {
	Surface        string
	ConversationID int64
	ContextType    string
	ContextID      string
	TurnID         string
	TurnIDFunc     func() string
	ProjectID      int64
	DirectApply    bool
}

// turnID is the turn a proposal attaches to right now.
func (b Binding) turnID() string {
	if b.TurnIDFunc != nil {
		return b.TurnIDFunc()
	}
	return b.TurnID
}

// Call is what Execute receives: the recorded row id (0 for RunDirect), the
// raw arguments and the binding. Retry is set when Apply runs a row that
// had failed before: a failed External write may still have landed (a
// timeout after the request was sent), so such a tool checks for its own
// earlier write before sending it again.
type Call struct {
	ActionID int64
	Args     json.RawMessage
	Binding  Binding
	Retry    bool
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
	// Normalize runs once, in Propose, after Validate succeeds and before the
	// args are persisted to agent_actions.args_json: whatever it returns is
	// exactly what Execute sees when Apply runs later, possibly hours after
	// approval. A tool whose Validate resolves something ambiguous (which
	// site a key lives on, which person a name means) uses Normalize to pin
	// that resolution into the stored args, so Execute never re-derives it
	// from free text against data that may have since changed — the owner's
	// approval is of the resolved action, not of a string that gets
	// re-interpreted at apply time. Optional; nil leaves args unchanged.
	Normalize func(ctx context.Context, d *db.DB, args json.RawMessage) (json.RawMessage, error)

	// Scope runs the checks that need the binding — "does this row belong to
	// the bound project" — after Validate in Propose, and again in Apply
	// before Execute, against the binding rebuilt from the stored row. A
	// *ValidationError from Propose writes no row. Optional.
	Scope func(ctx context.Context, d *db.DB, args json.RawMessage, b Binding) error

	// ProposeUnderDirectApply lets an External tool that names the binding's
	// surface run in a direct-apply session — as a PENDING proposal the owner
	// approves in the Desktop, never inline (send_slack_message from a project
	// terminal, DEV-06). Without it an External tool is refused there.
	ProposeUnderDirectApply bool
	// Revise merges an owner edit (patch, a JSON object) into a pending row's
	// stored args and returns the new args; it decides what is editable and
	// re-validates it. Optional: a tool without it takes no edits.
	Revise func(ctx context.Context, d *db.DB, stored, patch json.RawMessage) (json.RawMessage, error)
	// Ready is what must hold before a row may be approved — e.g. the owner
	// picked one of several pinned candidates. Optional.
	Ready func(args json.RawMessage) error

	// resolved is InputSchema prepared for validation. Unexported: a tool
	// author declares the schema, the registry prepares it once in Register
	// (RunDirect prepares it for a tool built outside the registry).
	resolved *jsonschema.Resolved
}

// resolveSchema prepares InputSchema for validation. Idempotent, and a no-op
// for a tool without a schema (only write tools are required to have one).
func (t *Tool) resolveSchema() error {
	if t.InputSchema == nil || t.resolved != nil {
		return nil
	}
	res, err := t.InputSchema.Resolve(&jsonschema.ResolveOptions{})
	if err != nil {
		return err
	}
	t.resolved = res
	return nil
}

// validateSchema checks args against the tool's declared InputSchema — the
// first gate a call passes, ahead of the tool's own semantic Validate
// (spec §4). Model-facing: the schema's message goes back verbatim, so the
// model learns which argument it got wrong.
func (t *Tool) validateSchema(args json.RawMessage) error {
	if t.resolved == nil {
		return nil
	}
	var v any
	if err := json.Unmarshal(args, &v); err != nil {
		return &ValidationError{Msg: "arguments are not valid JSON"}
	}
	if err := t.resolved.Validate(v); err != nil {
		return &ValidationError{Msg: err.Error()}
	}
	return nil
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
// Err, when set, is the sentinel behind it (e.g. db.ErrNotInProject), so a
// caller can still match the cause with errors.Is.
type ValidationError struct {
	Msg string
	Err error
}

func (e *ValidationError) Error() string { return e.Msg }

func (e *ValidationError) Unwrap() error { return e.Err }

var (
	ErrUnknownTool     = errors.New("unknown tool")
	ErrNotWritable     = errors.New("tool is not a write tool")
	ErrNotReadable     = errors.New("tool is not a read tool")
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
	if t.Access != AccessRead && t.Access != AccessWrite {
		return fmt.Errorf("register: tool %q has invalid access %q", t.Name, t.Access)
	}
	if t.Access == AccessWrite && (t.InputSchema == nil || t.Validate == nil || t.Execute == nil) {
		return fmt.Errorf("register: write tool %q needs InputSchema, Validate and Execute", t.Name)
	}
	// A read tool is mounted over MCP with the raw AddTool path, which panics on
	// a nil schema (go-sdk mcp/server.go:242-248); a parameterless read tool
	// therefore carries an explicit empty-object schema. Execute is what a read
	// runs (CallRead never calls the write-only Validate). Required here so a bad
	// tool is caught at construction, not by a runtime panic on the MCP path.
	if t.Access == AccessRead && (t.InputSchema == nil || t.Execute == nil) {
		return fmt.Errorf("register: read tool %q needs InputSchema and Execute", t.Name)
	}
	if err := t.resolveSchema(); err != nil {
		return fmt.Errorf("register: tool %q has an unusable InputSchema: %w", t.Name, err)
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
	args, err := r.admitProposal(ctx, t, args, b)
	if err != nil {
		return Receipt{}, err
	}
	trust, err := r.resolveTrust(t, b)
	if err != nil {
		return Receipt{}, err
	}
	id, err := r.db.InsertAgentAction(newProposalRow(t, args, trust, b))
	if err != nil {
		return Receipt{}, err
	}
	if trust == TrustExecute {
		return r.applyTrusted(ctx, id)
	}
	where := "in this chat"
	if b.DirectApply {
		// A project session has no chat card: the proposal waits in the
		// Desktop's Inbox → Actions strip.
		where = "in Watchtower Desktop (Inbox → Actions)"
	}
	return Receipt{
		ActionID: id, Status: "pending", Tool: name,
		Message: fmt.Sprintf("Proposal #%d recorded (%s). The owner must approve it %s before "+
			"anything happens — tell the owner it awaits their approval and do not claim it is done.", id, name, where),
	}, nil
}

// Approve moves a pending row to approved, first merging the owner's edit
// (patch, optional) through the tool's Revise and checking the tool's Ready.
// With a patch, the new args and the approval land in ONE conditional update
// (still pending, args unchanged since read), so an edit can neither
// overwrite another decision nor approve args the owner did not see. It only
// decides — Apply runs the row afterwards, exactly as before. False (no
// error) means the row was not pending; a Revise/Ready refusal is a
// *ValidationError and leaves the row pending.
func (r *Registry) Approve(ctx context.Context, id int64, patch json.RawMessage) (bool, error) {
	row, err := r.db.GetAgentAction(id)
	if err != nil {
		return false, err
	}
	if row == nil {
		return false, ErrNotFound
	}
	if row.Status != "pending" {
		return false, nil
	}
	t, known := r.tools[row.Tool]
	hasPatch := len(bytes.TrimSpace(patch)) > 0
	args, err := r.revisedArgs(ctx, row, t, known, hasPatch, patch)
	if err != nil {
		return false, err
	}
	if known && t.Ready != nil {
		if err := t.Ready(args); err != nil {
			return false, err
		}
	}
	if !hasPatch {
		return r.db.TransitionAgentAction(id, []string{"pending"}, "approved", "", "")
	}
	return r.approveEdited(row, args)
}

// revisedArgs is a pending row's args after the owner's patch (unchanged
// without one); only a tool with Revise takes edits.
func (r *Registry) revisedArgs(ctx context.Context, row *db.AgentAction, t *Tool, known, hasPatch bool, patch json.RawMessage) (json.RawMessage, error) {
	args := json.RawMessage(row.ArgsJSON)
	if !hasPatch {
		return args, nil
	}
	if !known || t.Revise == nil {
		return nil, &ValidationError{Msg: row.Tool + " takes no edits"}
	}
	args, err := t.Revise(ctx, r.db, args, patch)
	if err != nil {
		return nil, err
	}
	if !json.Valid(args) {
		return nil, fmt.Errorf("revise: tool %q returned invalid JSON", row.Tool)
	}
	return args, nil
}

// approveEdited lands the edited args and the approval in one conditional
// update; a lost race on a still-pending row means another edit landed after
// this one read the row — refused rather than approving what the owner did
// not see.
func (r *Registry) approveEdited(row *db.AgentAction, args json.RawMessage) (bool, error) {
	ok, err := r.db.ApproveAgentActionWithArgs(row.ID, row.ArgsJSON, string(args))
	if err != nil || ok {
		return ok, err
	}
	cur, err := r.db.GetAgentAction(row.ID)
	if err != nil {
		return false, fmt.Errorf("re-reading action #%d after a lost approve: %w", row.ID, err)
	}
	if cur != nil && cur.Status == "pending" {
		return false, fmt.Errorf("%w: #%d was edited elsewhere; reload it and approve again", ErrBadTransition, row.ID)
	}
	return false, nil
}

// admitProposal runs every gate a write call passes before a row is written:
// the bound project is alive, the direct-apply gate, the args checks, the
// mandatory reason, then the tool's Scope. Any failure writes nothing.
func (r *Registry) admitProposal(ctx context.Context, t *Tool, args json.RawMessage, b Binding) (json.RawMessage, error) {
	if err := r.ProjectAlive(ctx, b); err != nil {
		return nil, err
	}
	if err := directApplyGate(t, b); err != nil {
		return nil, err
	}
	args, err := r.prepareProposalArgs(ctx, t, args)
	if err != nil {
		return nil, err
	}
	if reasonOf(args) == "" {
		return nil, &ValidationError{Msg: `"reason" is required: say why you propose this`}
	}
	if err := t.scope(ctx, r.db, args, b); err != nil {
		return nil, err
	}
	return args, nil
}

// directApplyGate is what keeps DirectApply narrow: it never runs an External
// tool (AGENT-03, DEV-06), and it runs only a tool that names the binding's
// surface explicitly — a surface-less tool is visible everywhere, so it must
// not inherit direct apply by accident.
func directApplyGate(t *Tool, b Binding) error {
	if !b.DirectApply {
		return nil
	}
	if t.External && !t.ProposeUnderDirectApply {
		return &ValidationError{Msg: t.Name + " leaves this machine and never runs in a direct-apply session"}
	}
	if !slices.Contains(t.Surfaces, b.Surface) {
		return &ValidationError{Msg: fmt.Sprintf("%s is not available on the %s surface", t.Name, b.Surface)}
	}
	return nil
}

// resolveTrust decides how this one call runs. External is always ask —
// including a ProposeUnderDirectApply tool in a direct-apply session, which is
// therefore recorded pending and waits for the owner's Approve:
// SetTrust refuses `execute` for an external tool, but db.SetToolTrust does
// not, and a trust row keyed by tool NAME outlives a tool later being marked
// External — the read side decides too (AGENT-03). DirectApply is execute for
// this call only; the stored trust row is not consulted or changed.
func (r *Registry) resolveTrust(t *Tool, b Binding) (Trust, error) {
	if t.External {
		return TrustAsk, nil
	}
	if b.DirectApply {
		return TrustExecute, nil
	}
	return r.Trust(t.Name)
}

// newProposalRow is the agent_actions row a proposal records. A project-bound
// call stores its project in context_type/context_id, so Apply — possibly a
// later `actions apply` — rebuilds the same binding (bindingOf).
func newProposalRow(t *Tool, args json.RawMessage, trust Trust, b Binding) db.AgentAction {
	ctxType, ctxID := b.ContextType, b.ContextID
	if b.ProjectID != 0 {
		ctxType, ctxID = ProjectContextType, strconv.FormatInt(b.ProjectID, 10)
	}
	row := db.AgentAction{
		Tool: t.Name, External: t.External, ArgsJSON: string(args), Reason: reasonOf(args),
		Surface: b.Surface, ConversationID: b.ConversationID,
		ContextType: ctxType, ContextID: ctxID, TurnID: b.turnID(),
		Status: "pending", TrustAtCreate: string(trust),
	}
	if trust == TrustExecute {
		row.Status = "approved"
	}
	return row
}

// bindingOf rebuilds the binding a stored row was proposed under.
func bindingOf(row *db.AgentAction) Binding {
	b := Binding{
		Surface: row.Surface, ConversationID: row.ConversationID,
		ContextType: row.ContextType, ContextID: row.ContextID, TurnID: row.TurnID,
	}
	if row.ContextType == ProjectContextType {
		// A malformed id leaves ProjectID 0, which every project tool refuses.
		b.ProjectID, _ = strconv.ParseInt(row.ContextID, 10, 64)
	}
	return b
}

// ProjectAlive fails a project-bound call once its project is gone — the
// first check of every call, read or write, project tool or not, so a
// session outliving its project answers "project N no longer exists".
// Exported for the MCP adapter's get_action, which reads agent_actions
// directly rather than through a registry tool.
func (r *Registry) ProjectAlive(ctx context.Context, b Binding) error {
	if b.ProjectID == 0 {
		return nil
	}
	_, err := projectOf(ctx, r.db, b)
	return err
}

// scope runs the tool's optional Scope.
func (t *Tool) scope(ctx context.Context, d *db.DB, args json.RawMessage, b Binding) error {
	if t.Scope == nil {
		return nil
	}
	return t.Scope(ctx, d, args, b)
}

// prepareProposalArgs validates a write-tool call's arguments (JSON, schema,
// the tool's own Validate) and returns them after the tool's Normalize — the
// exact args that get persisted and later executed.
func (r *Registry) prepareProposalArgs(ctx context.Context, t *Tool, args json.RawMessage) (json.RawMessage, error) {
	if len(args) == 0 {
		args = json.RawMessage(`{}`)
	}
	if !json.Valid(args) {
		return nil, &ValidationError{Msg: "arguments are not valid JSON"}
	}
	if err := t.validateSchema(args); err != nil {
		return nil, err
	}
	if err := t.Validate(ctx, r.db, args); err != nil {
		return nil, err
	}
	if t.Normalize == nil {
		return args, nil
	}
	normalized, err := t.Normalize(ctx, r.db, args)
	if err != nil {
		return nil, err
	}
	if !json.Valid(normalized) {
		return nil, fmt.Errorf("normalize: tool %q returned invalid JSON", t.Name)
	}
	return normalized, nil
}

// applyTrusted runs an execute-trust proposal inline: the row was inserted
// as approved, so stamp decided_at the way an owner approval would, then
// apply it.
func (r *Registry) applyTrusted(ctx context.Context, id int64) (Receipt, error) {
	if _, err := r.finishTransition(id, []string{"approved"}, "approved", "", ""); err != nil {
		return Receipt{}, err
	}
	applied, err := r.Apply(ctx, id)
	if err != nil {
		// The row exists even though Apply itself could not finish the
		// transition (a rare DB-level race) — the model must still learn
		// the action id and the row's own status, not be told the
		// proposal was never recorded, which risks a duplicate re-propose.
		if row, rerr := r.db.GetAgentAction(id); rerr == nil && row != nil {
			return receiptFor(row), nil
		}
		return Receipt{}, err
	}
	return receiptFor(applied), nil
}

// CallRead runs a read tool's Execute and returns its data. It is the read
// path of both adapters (MCP and the runtime-B loop) — the read twin of
// Propose. It writes NO agent_actions row: a read is not a proposal. A write
// tool is refused with ErrNotReadable, so the proposal flow can never be
// bypassed by calling a write through the read path. b reaches Execute as
// Call.Binding, so a read can scope itself (list_targets in a project session).
func (r *Registry) CallRead(ctx context.Context, name string, args json.RawMessage, b Binding) (any, error) {
	t, ok := r.tools[name]
	if !ok {
		return nil, ErrUnknownTool
	}
	if t.Access != AccessRead {
		return nil, ErrNotReadable
	}
	if err := r.ProjectAlive(ctx, b); err != nil {
		return nil, err
	}
	// A parameterless call arrives as absent, empty, or literal null (an MCP
	// client with no arguments, e.g. `ls.Call(name, nil)`); all mean "no
	// filters", so normalize to an empty object before the object schema runs —
	// otherwise a bare read tool would reject its own no-arg call.
	if len(args) == 0 || string(bytes.TrimSpace(args)) == "null" {
		args = json.RawMessage(`{}`)
	}
	if !json.Valid(args) {
		return nil, &ValidationError{Msg: "arguments are not valid JSON"}
	}
	if err := t.validateSchema(args); err != nil {
		return nil, err
	}
	return t.Execute(ctx, r.db, Call{Args: args, Binding: b})
}

// Apply executes an approved (or previously failed) row exactly once and
// records applied/failed. applied and rejected are terminal (AGENT-05).
//
// The row is CLAIMED before the tool runs: `approved|failed → executing` is a
// conditional UPDATE, so of two overlapping applies only one ever reaches
// Execute — the other is refused before its side effect, not after it. A row
// left in `executing` by a process that died mid-flight is not applicable
// either; `watchtower actions apply --force` reclaims it.
func (r *Registry) Apply(ctx context.Context, id int64) (*db.AgentAction, error) {
	row, err := r.db.GetAgentAction(id)
	if err != nil {
		return nil, err
	}
	if row == nil {
		return nil, ErrNotFound
	}
	// The read is needed for the tool name and args anyway; checking the status
	// here only buys the caller a message naming the state it was actually in.
	// The claim below is what makes the decision exclusive.
	if row.Status != "approved" && row.Status != "failed" {
		return nil, fmt.Errorf("%w: #%d is %s", ErrBadTransition, id, row.Status)
	}
	// Carry the row's existing error through the claim: TransitionAgentAction
	// writes error unconditionally, so claiming `failed → executing` with ""
	// would wipe a prior failure's text before the retry has even started —
	// the audit trail (rows are never deleted) would lose the very thing it
	// exists to keep if the retry then died mid-execute.
	claimed, err := r.db.TransitionAgentAction(id, []string{"approved", "failed"}, "executing", "", row.Error)
	if err != nil {
		return nil, err
	}
	if !claimed {
		return nil, fmt.Errorf("%w: #%d is already executing or decided", ErrBadTransition, id)
	}
	from := []string{"executing"}
	t, ok := r.tools[row.Tool]
	if !ok {
		return r.finishTransition(id, from, "failed", "", "unknown tool "+row.Tool)
	}
	call := Call{ActionID: id, Args: json.RawMessage(row.ArgsJSON), Binding: bindingOf(row), Retry: row.Status == "failed"}
	// Re-scope against the stored binding: a retried or late-applied project
	// row must still belong to a live project and touch only its rows.
	if err := r.ProjectAlive(ctx, call.Binding); err != nil {
		return r.recordFailure(id, from, err)
	}
	if err := t.scope(ctx, r.db, call.Args, call.Binding); err != nil {
		return r.recordFailure(id, from, err)
	}
	result, execErr := t.Execute(ctx, r.db, call)
	if execErr != nil {
		return r.recordFailure(id, from, execErr)
	}
	resultJSON, err := json.Marshal(result)
	if err != nil {
		resultJSON = []byte("{}")
	}
	return r.finishTransition(id, from, "applied", string(resultJSON), "")
}

// recordFailure lands a claimed row in `failed` with cause as its error.
func (r *Registry) recordFailure(id int64, from []string, cause error) (*db.AgentAction, error) {
	row, dbErr := r.finishTransition(id, from, "failed", "", cause.Error())
	if dbErr != nil {
		// finishTransition's own CAS can lose a race too (something else
		// moved the row out of `executing` while Execute was still running) —
		// the caller must still learn what the tool itself failed on, not
		// just that recording the failure didn't stick.
		return nil, fmt.Errorf("recording failure %q: %w", cause, dbErr)
	}
	return row, nil
}

// finishTransition moves id from one of `from` to `to` and re-reads the row.
// A lost race — the row was no longer in `from` when the UPDATE ran — is
// reported as ErrBadTransition rather than silently returning stale state; a
// row missing on re-read (it should never be deleted, but defend anyway) is
// ErrNotFound. Apply must never return (nil, nil). Since Apply claims the row
// as `executing` first, nothing but another claim can take it away mid-flight:
// an owner reject that lands while Execute runs simply does not match.
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
	case "executing", "approved", "pending":
		// Not a failure — say so honestly instead of reporting "failed" with
		// whatever error text the row happens to carry (e.g. a prior
		// attempt's error, preserved through the executing claim for the
		// audit trail, but not a fact about THIS status).
		rc.Message = fmt.Sprintf("Action #%d is %s.", row.ID, row.Status)
	default:
		rc.Error = row.Error
		rc.Message = fmt.Sprintf("Action #%d failed (%s): %s", row.ID, row.Tool, row.Error)
	}
	return rc
}

// RunDirect validates and executes a tool outside the proposal flow — the
// CLI face (`watchtower jira create`) for humans and tests. ActionID is 0.
func RunDirect(ctx context.Context, d *db.DB, t *Tool, args json.RawMessage) (any, error) {
	// The CLI builds its tool inline, so it never went through Register —
	// prepare the schema here (a no-op for a registered tool).
	if err := t.resolveSchema(); err != nil {
		return nil, err
	}
	if err := t.validateSchema(args); err != nil {
		return nil, err
	}
	if err := t.Validate(ctx, d, args); err != nil {
		return nil, err
	}
	return t.Execute(ctx, d, Call{Args: args})
}
