package chat

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"sync"
	"time"

	"watchtower/internal/chat/connectorpolicy"
	"watchtower/internal/tools"
)

// The claude.ai-mode permission gate (#737, spec D3–D5): with
// --permission-prompt-tool stdio the CLI asks the session about every call
// not pre-allowed, and the gate answers each one through connectorpolicy —
// Allow (the request's own input echoed), Deny (the reason, which the model
// receives verbatim) or Ask: one claude_ai_connector_call row the owner
// approves on a card, after which this session alone claims it and lets the
// CLI run the approved input. Every error fails closed: the call is denied,
// never run with input nobody checked.

// GateApprovalTimeout is how long a call waits for the owner's Approve
// before it is cancelled (decision Q3, ask #326). The prompt's "up to 15
// minutes" is pinned to it.
const GateApprovalTimeout = 15 * time.Minute

// gatePollInterval is how often a waiting call re-reads its row.
const gatePollInterval = time.Second

// gateStopWait bounds how long Stop and Close wait for the waiting calls to
// record their outcome and answer the CLI.
const gateStopWait = 2 * time.Second

// builtinCallServer is the agent_actions server of a built-in call the gate
// asks about (an Artifact pin or delete): the row needs one, and the
// built-in acts on the owner's claude.ai account.
const builtinCallServer = "claude.ai"

// ConnectorCall is one call the gate holds for the owner's Approve.
type ConnectorCall struct {
	TurnID string
	// Server is the connector's display name ("claude.ai Gmail"), or
	// "claude.ai" for a built-in; Tool the raw CLI tool name.
	Server, Tool string
	// Reason is the card's line: the request's display name ("Send"),
	// else the CLI's description, else a fixed text — the protocol has no
	// title.
	Reason string
	// Input is the request's input byte for byte: what runs unless the
	// owner edits it.
	Input json.RawMessage
}

// ActionSink is the gate's view of the agent_actions registry. The
// implementation binds every row to one session token generated once per
// `ai session` process (Binding.SessionToken) and passes it to every per-row
// method, so a respawned, resumed or replayed process never claims a row it
// did not propose (AGENT-05).
type ActionSink interface {
	// ProposeConnectorCall records a pending claude_ai_connector_call row.
	ProposeConnectorCall(ctx context.Context, c ConnectorCall) (int64, error)
	// ActionStatus is the row's status (pending, approved, rejected, …).
	ActionStatus(ctx context.Context, id int64) (string, error)
	// ClaimApproved moves an approved row to executing and returns the
	// approved input (the owner's edits included); false when the row was
	// not approved.
	ClaimApproved(ctx context.Context, id int64) (json.RawMessage, bool, error)
	// FinishCall records a claimed call's outcome; callErr is non-empty for
	// every failed call.
	FinishCall(ctx context.Context, id int64, result, callErr string) error
	// CancelCall withdraws a pending row (pending → rejected); false when
	// the row is no longer pending — approved meanwhile, or settled.
	CancelCall(ctx context.Context, id int64, reason string) (bool, error)
	// ExpireCall fails an unclaimed pending or approved row this session
	// will never run (Stop after the owner approved, the CLI withdrawing the
	// request, the child gone); false when it was claimed or settled.
	ExpireCall(ctx context.Context, id int64, reason string) (bool, error)
	// ExpireOrphans fails the rows a previous session of this conversation
	// (and any stale session) left open; it runs before the first spawn.
	ExpireOrphans(ctx context.Context) error
}

// GateOptions turns on the permission gate of a claude.ai-mode session.
type GateOptions struct {
	Sink ActionSink
	// Publish is the conversation's publish dir: Write and the Artifact
	// sources are confined to it, and Close removes it. Nil confines to
	// nothing (every path is denied).
	Publish *PublishDir
	// Policy carries the switched-off servers; the gate fills its catalog
	// (the session's live mcp_status snapshot), its path check and the
	// own-artifact and own-doc lookups, replacing whatever is there.
	// Disabled must be non-nil (empty = nothing switched off): a caller that
	// failed to load the owner's switches must not pass nil, so a nil map
	// refuses to start.
	Policy          connectorpolicy.Policy
	ApprovalTimeout time.Duration    // default GateApprovalTimeout
	PollInterval    time.Duration    // default 1 s
	Now             func() time.Time // default time.Now
}

// Row reasons the Desktop's connector-call card matches exactly
// (ConnectorCallProposal): the two CancelCall reasons — reasonStopped also
// fails an approved call Stop ended before it was sent — and the two texts a
// call of a gone session lands with (the registry's ExpireSessionCalls
// texts). Pinned by TestGate_RowReasonTextsMatchTheCard.
const (
	reasonStopped        = "stopped"
	reasonSessionEnded   = "session ended before approval"
	reasonOutcomeUnknown = "session ended while the call ran; outcome unknown"
)

// reasonNotApproved is the timeout's CancelCall reason: "not approved
// within 15 minutes" for GateApprovalTimeout.
func reasonNotApproved(timeout time.Duration) string {
	return "not approved within " + approvalWindow(timeout)
}

// Deny messages the model receives verbatim.
const (
	denyRejected = "The owner rejected this call. Do not retry it; say it was not sent."
	denyStopped  = "The owner stopped the turn, so this call was not sent."
)

func denyTimedOut(window string) string {
	return "The owner did not approve within " + window + ", so it was cancelled. Tell the owner it was not sent."
}

// approvalWindow renders the approval timeout for the owner and the model
// ("15 minutes").
func approvalWindow(d time.Duration) string {
	if d >= time.Minute && d%time.Minute == 0 {
		if m := int(d / time.Minute); m != 1 {
			return fmt.Sprintf("%d minutes", m)
		}
		return "1 minute"
	}
	return d.String()
}

// stopReason says why a waiting call was stopped.
type stopReason int

const (
	stopByOwner   stopReason = iota // Stop or Close: the gate denies the call
	stopWithdrawn                   // the CLI withdrew the request: no answer is due
)

// gateWait is one request the gate is answering; registered by dispatch,
// before its goroutine starts, so a Stop or a withdrawal never misses it.
type gateWait struct {
	stop     chan struct{}
	stopOnce sync.Once
	why      stopReason
	done     chan struct{}
}

func (w *gateWait) signal(why stopReason) {
	w.stopOnce.Do(func() {
		w.why = why
		close(w.stop)
	})
}

// claimedCall is a row the gate claimed and let the CLI run; its result is
// due from proc.
type claimedCall struct {
	id   int64
	proc *claudeProc
}

// gate answers one session's can_use_tool requests. Safe for concurrent use:
// the reader dispatches each request to its own goroutine. Its lifecycle
// methods accept a nil gate (no ClaudeOptions.Gate) and do nothing.
type gate struct {
	opts   GateOptions
	policy connectorpolicy.Policy
	turnID func() string
	warn   io.Writer
	// catalog is the policy's Catalog; refresh, when set, re-reads it from
	// p's mcp_status (bounded) before a connector call it does not list is
	// decided.
	catalog *connectorCatalog
	refresh func(p *claudeProc)

	wg sync.WaitGroup // every request goroutine; Add only while !closed

	mu      sync.Mutex
	waits   map[string]*gateWait // CLI request id → the request being answered
	claimed map[string]claimedCall
	own     map[string]bool // ids of the pages and docs this session published
	halted  bool            // Stop arrived: asks are denied until the next turn
	closed  bool            // Close arrived: every request is denied for good
}

// newGate validates opts and binds the policy to the session.
func newGate(opts GateOptions, turnID func() string, warn io.Writer) (*gate, error) {
	if opts.Sink == nil {
		return nil, errors.New("permission gate: no action sink")
	}
	if opts.Policy.Disabled == nil {
		return nil, errors.New("permission gate: the switched-off connectors are unknown (Policy.Disabled is nil)")
	}
	if opts.ApprovalTimeout <= 0 {
		opts.ApprovalTimeout = GateApprovalTimeout
	}
	if opts.PollInterval <= 0 {
		opts.PollInterval = gatePollInterval
	}
	if opts.Now == nil {
		opts.Now = time.Now
	}
	g := &gate{opts: opts, turnID: turnID, warn: warn,
		waits: map[string]*gateWait{}, claimed: map[string]claimedCall{}, own: map[string]bool{}}
	// The path check and the ownership lookups are the gate's own: whatever
	// the caller put there is replaced, so no path or link is trusted that
	// this session did not create.
	g.policy = opts.Policy
	g.policy.PathCheck, g.policy.PublishDir = nil, ""
	if opts.Publish != nil {
		g.policy.PathCheck, g.policy.PublishDir = opts.Publish.Check, opts.Publish.Path()
	}
	g.policy.OwnArtifact, g.policy.OwnDoc = g.ownLink, g.ownLink
	g.catalog = newConnectorCatalog()
	g.policy.Catalog = g.catalog
	return g, nil
}

// expireOrphans fails the rows a dead session left open; Start runs it
// before the first spawn.
func (g *gate) expireOrphans(ctx context.Context) error {
	if g == nil {
		return nil
	}
	return g.opts.Sink.ExpireOrphans(ctx)
}

// dispatch answers req on its own goroutine: the reader never waits on a
// decision, a write or the owner.
func (g *gate) dispatch(p *claudeProc, req permissionRequest) {
	w := &gateWait{stop: make(chan struct{}), done: make(chan struct{})}
	g.mu.Lock()
	_, dup := g.waits[req.RequestID]
	refused := g.closed || dup
	if !refused {
		g.waits[req.RequestID] = w
		g.wg.Add(1)
	}
	g.mu.Unlock()
	if refused {
		msg := denyStopped
		if dup {
			msg = "A permission request with this id is already being answered; this one was not run."
		}
		go answerControl(p, permissionDenyLine(req.RequestID, msg), g.warn)
		return
	}
	go func() {
		defer g.wg.Done()
		defer func() {
			g.mu.Lock()
			if g.waits[req.RequestID] == w {
				delete(g.waits, req.RequestID)
			}
			g.mu.Unlock()
			close(w.done)
		}()
		g.handle(p, req, w)
	}()
}

func (g *gate) handle(p *claudeProc, req permissionRequest, w *gateWait) {
	if req.Malformed != "" {
		g.answer(p, permissionDenyLine(req.RequestID, req.Malformed))
		return
	}
	call := req.policyCall()
	// A connector or tool that appeared after the last mcp_status (the
	// owner connected it on claude.ai mid-session) gets one refresh; still
	// unlisted, the policy denies the server or asks for the tool.
	connector := req.MCPServerSource == "claudeai"
	if g.refresh != nil && connector && !g.catalog.isUnavailable() && !g.catalog.knows(call.Tool) {
		g.refresh(p)
		// The refresh took up to 2 s: a Stop or the CLI's withdrawal in
		// that time is honoured before anything is allowed.
		if g.settledByStop(p, req, w) {
			return
		}
	}
	d := g.policy.Decide(call)
	if reason := g.catalog.unavailableReason(); connector && d.Verdict == connectorpolicy.Deny && reason != "" {
		d.Reason = reason // why no connector is listed, not "not one of this account's"
	}
	switch d.Verdict {
	case connectorpolicy.Allow:
		// A request that reached the gate after Stop, before the CLI's
		// interrupt, runs nothing.
		if g.settledByStop(p, req, w) {
			return
		}
		input := req.Input
		if d.UpdatedInput != nil {
			input = d.UpdatedInput
		}
		line, err := permissionAllowLine(req.RequestID, input)
		if err != nil {
			line = permissionDenyLine(req.RequestID, "The call could not be passed on ("+err.Error()+"). It was not run.")
		}
		g.answer(p, line)
	case connectorpolicy.Ask:
		g.ask(p, req, w)
	default:
		reason := d.Reason
		if reason == "" {
			reason = "This call is not allowed in this chat."
		}
		g.answer(p, permissionDenyLine(req.RequestID, reason))
	}
}

// answerControl writes one control answer; a child that stopped reading is
// gone, and its calls with it.
func answerControl(p *claudeProc, line []byte, warn io.Writer) {
	if err := p.write(line); err != nil {
		fmt.Fprintf(warn, "chat gate: answering the CLI: %v\n", err)
	}
}

func (g *gate) answer(p *claudeProc, line []byte) { answerControl(p, line, g.warn) }

// stopRequested reports whether w must not go on — Stop, Close or the CLI's
// withdrawal — and why.
func (g *gate) stopRequested(w *gateWait) (bool, stopReason) {
	select {
	case <-w.stop:
		return true, w.why
	default:
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.halted || g.closed, stopByOwner
}

// settledByStop answers a request that Stop or Close ended (denied when the
// owner stopped it; the CLI's withdrawal needs no answer). False when it may
// go on.
func (g *gate) settledByStop(p *claudeProc, req permissionRequest, w *gateWait) bool {
	stop, why := g.stopRequested(w)
	if stop && why == stopByOwner {
		g.answer(p, permissionDenyLine(req.RequestID, denyStopped))
	}
	return stop
}

// childGone reports whether p exited or was replaced.
func childGone(p *claudeProc) bool {
	select {
	case <-p.exited:
		return true
	case <-p.stop:
		return true
	default:
		return false
	}
}

// ask proposes the call, shows the waiting step and waits for the owner.
func (g *gate) ask(p *claudeProc, req permissionRequest, w *gateWait) {
	if stop, why := g.stopRequested(w); stop {
		if why == stopByOwner {
			g.answer(p, permissionDenyLine(req.RequestID, denyStopped))
		}
		return
	}
	turn := g.turnID()
	id, err := g.opts.Sink.ProposeConnectorCall(context.Background(), connectorCall(turn, req))
	if err == nil && id <= 0 {
		err = fmt.Errorf("invalid action id %d", id)
	}
	if err != nil {
		g.answer(p, permissionDenyLine(req.RequestID, fmt.Sprintf(
			"This call needs the owner's approval, but the approval card could not be created (%v). It was not sent.", err)))
		return
	}
	select {
	case p.events <- toolWaitEvent(turn, req.ToolUseID, id):
	case <-w.stop:
	case <-p.exited:
	case <-p.stop:
	}
	g.await(p, req, w, id)
}

// connectorCall is the row an asked request proposes.
func connectorCall(turnID string, req permissionRequest) ConnectorCall {
	server := req.MCPServer
	if server == "" {
		server = builtinCallServer
	}
	reason := req.DisplayName
	if reason == "" {
		reason = req.Description
	}
	if reason == "" {
		reason = "claude.ai connector write"
	}
	return ConnectorCall{TurnID: turnID, Server: server, Tool: req.ToolName, Reason: reason, Input: req.Input}
}

// await polls the row until the owner decides, the timeout, Stop, the CLI
// withdrawing the request or the child's exit — exactly one of them settles
// the call, and only a claim of an approved row by a live child ever lets it
// run.
func (g *gate) await(p *claudeProc, req permissionRequest, w *gateWait, id int64) {
	ctx := context.Background()
	deadline := g.opts.Now().Add(g.opts.ApprovalTimeout)
	var lastErr string
	for {
		if g.settledByStopOrExit(p, req, w, id) {
			return
		}
		status, err := g.opts.Sink.ActionStatus(ctx, id)
		if err != nil && err.Error() != lastErr {
			fmt.Fprintf(g.warn, "chat gate: reading action #%d: %v\n", id, err)
		}
		lastErr = ""
		if err != nil {
			lastErr = err.Error()
		}
		switch {
		case errors.Is(err, tools.ErrNotFound), errors.Is(err, tools.ErrNotThisSession):
			// Permanent: polling on would only deny "not approved in time"
			// 15 minutes later.
			fmt.Fprintf(g.warn, "chat gate: action #%d can never be approved by this session; denied\n", id)
			g.answer(p, permissionDenyLine(req.RequestID, denyRowGone))
			return
		case err != nil, status == "pending":
		case status == "approved":
			if g.claim(p, req, w, id) {
				return
			}
		default:
			g.answer(p, permissionDenyLine(req.RequestID, closedRowMessage(status)))
			return
		}
		if !g.opts.Now().Before(deadline) {
			g.timeOut(p, req, w, id)
			return
		}
		select {
		case <-w.stop:
		case <-p.exited:
		case <-p.stop:
		case <-time.After(g.opts.PollInterval):
		}
	}
}

// settledByStopOrExit settles a waiting call that Stop, Close or the CLI
// withdrew (rejected or expired, and denied when the owner stopped it) or
// whose child is gone (expired, nothing written). False when it may go on.
func (g *gate) settledByStopOrExit(p *claudeProc, req permissionRequest, w *gateWait, id int64) bool {
	if stop, why := g.stopRequested(w); stop {
		g.stopped(p, req, why, id)
		return true
	}
	if childGone(p) {
		g.expire(id, reasonSessionEnded)
		return true
	}
	return false
}

// denyRowGone answers a call whose row is missing or bound to another
// session token — only if the database was replaced or the row removed
// under a live session: no Approve this session could act on can arrive.
const denyRowGone = "This call's approval record is gone or belongs to another chat session. It was not sent."

// closedRowMessage is the deny text for a row the owner or another path
// settled.
func closedRowMessage(status string) string {
	switch status {
	case "rejected":
		return denyRejected
	case "":
		status = "unknown"
	}
	return fmt.Sprintf("This call can no longer run (its approval is %s). It was not sent.", status)
}

// claim takes an approved row and lets the CLI run the approved input — only
// while nothing stopped the call and its child lives, checked right before
// the claim and again before the answer. False when the row was not
// claimable after all (the caller polls again).
func (g *gate) claim(p *claudeProc, req permissionRequest, w *gateWait, id int64) bool {
	if g.settledByStopOrExit(p, req, w, id) {
		return true
	}
	input, ok, err := g.opts.Sink.ClaimApproved(context.Background(), id)
	if err != nil {
		g.expire(id, "the approved call could not be started: "+err.Error())
		g.answer(p, permissionDenyLine(req.RequestID, fmt.Sprintf(
			"The owner approved this call, but it could not be started (%v). It was not sent.", err)))
		return true
	}
	if !ok {
		return false
	}
	g.mu.Lock()
	g.claimed[req.ToolUseID] = claimedCall{id: id, proc: p}
	g.mu.Unlock()
	if stop, why := g.stopRequested(w); stop || childGone(p) {
		reason := reasonSessionEnded
		if stop {
			reason = reasonStopped
		}
		g.finish(req.ToolUseID, "", reason)
		if stop && why == stopByOwner {
			g.answer(p, permissionDenyLine(req.RequestID, denyStopped))
		}
		return true
	}
	line, err := permissionAllowLine(req.RequestID, input)
	if err != nil {
		g.finish(req.ToolUseID, "", "the approved input could not be sent: "+err.Error())
		g.answer(p, permissionDenyLine(req.RequestID,
			"The approved input could not be sent ("+err.Error()+"). It was not sent."))
		return true
	}
	if err := p.write(line); err != nil {
		g.finish(req.ToolUseID, "", "the session ended before the approved call was sent")
		fmt.Fprintf(g.warn, "chat gate: sending approved action #%d: %v\n", id, err)
	}
	return true
}

// timeOut cancels a call the owner did not answer in time. An Approve that
// landed first wins: the row is then claimed and runs. Every other outcome
// that is not a settled row expires it and tells the model.
func (g *gate) timeOut(p *claudeProc, req permissionRequest, w *gateWait, id int64) {
	ctx := context.Background()
	window := approvalWindow(g.opts.ApprovalTimeout)
	cancelled, err := g.opts.Sink.CancelCall(ctx, id, reasonNotApproved(g.opts.ApprovalTimeout))
	if err == nil && cancelled {
		g.answer(p, permissionDenyLine(req.RequestID, denyTimedOut(window)))
		return
	}
	if err == nil {
		var status string
		status, err = g.opts.Sink.ActionStatus(ctx, id)
		if err == nil && status == "approved" && g.claim(p, req, w, id) {
			return
		}
		if err == nil && status != "approved" {
			g.answer(p, permissionDenyLine(req.RequestID, closedRowMessage(status)))
			return
		}
	}
	if err != nil {
		fmt.Fprintf(g.warn, "chat gate: cancelling action #%d: %v\n", id, err)
	}
	g.expire(id, reasonNotApproved(g.opts.ApprovalTimeout))
	g.answer(p, permissionDenyLine(req.RequestID, denyTimedOut(window)))
}

// stopped settles a call Stop, Close or the CLI's withdrawal ended: a pending
// row is rejected, an approved one the session will not run is expired.
func (g *gate) stopped(p *claudeProc, req permissionRequest, why stopReason, id int64) {
	cancelled, err := g.opts.Sink.CancelCall(context.Background(), id, reasonStopped)
	if err != nil {
		fmt.Fprintf(g.warn, "chat gate: cancelling action #%d: %v\n", id, err)
	}
	if !cancelled {
		g.expire(id, reasonStopped)
	}
	if why == stopByOwner {
		g.answer(p, permissionDenyLine(req.RequestID, denyStopped))
	}
}

// expire fails a row this session will never run.
func (g *gate) expire(id int64, reason string) {
	if _, err := g.opts.Sink.ExpireCall(context.Background(), id, reason); err != nil {
		fmt.Fprintf(g.warn, "chat gate: expiring action #%d: %v\n", id, err)
	}
}

// finish records the outcome of a claimed call, once; false when toolUseID
// was not a claimed call.
func (g *gate) finish(toolUseID, result, callErr string) bool {
	g.mu.Lock()
	c, ok := g.claimed[toolUseID]
	delete(g.claimed, toolUseID)
	g.mu.Unlock()
	if !ok {
		return false
	}
	if err := g.opts.Sink.FinishCall(context.Background(), c.id, result, callErr); err != nil {
		fmt.Fprintf(g.warn, "chat gate: recording action #%d: %v\n", c.id, err)
	}
	return true
}

// onResult records the tool result of a call the gate claimed, and takes a
// fresh page or doc of a call it let run without approval as the session's
// own — never one an approved call made, so one Approve is never a standing
// grant.
func (g *gate) onResult(r toolResult) {
	if g == nil {
		return
	}
	callErr := ""
	if r.isError {
		if callErr = strings.TrimSpace(r.text); callErr == "" {
			callErr = "the connector call failed"
		}
	}
	if !g.finish(r.toolUseID, r.text, callErr) && r.newLink != "" {
		g.noteOwn(r.newLink)
	}
}

// procGone records every claimed call of p whose result never arrived (the
// child exited or was replaced) as of unknown outcome.
func (g *gate) procGone(p *claudeProc) {
	if g == nil {
		return
	}
	g.mu.Lock()
	var open []string
	for toolUseID, c := range g.claimed {
		if c.proc == p {
			open = append(open, toolUseID)
		}
	}
	g.mu.Unlock()
	for _, toolUseID := range open {
		g.finish(toolUseID, "", reasonOutcomeUnknown)
	}
}

// withdraw stops the request the CLI withdrew (an interrupt reached it
// first): no answer is due.
func (g *gate) withdraw(requestID string) {
	if g == nil {
		return
	}
	g.mu.Lock()
	w := g.waits[requestID]
	g.mu.Unlock()
	if w != nil {
		w.signal(stopWithdrawn)
	}
}

// halt is Stop (closing=false) or Close (true): every waiting call is denied
// and its row rejected or expired, and later asks are denied — until the
// next turn after a Stop, every request for good after Close. It waits,
// bounded, for the requests to settle, so their answers precede the
// interrupt.
func (g *gate) halt(closing bool) {
	if g == nil {
		return
	}
	g.mu.Lock()
	g.halted = true
	g.closed = g.closed || closing
	waits := make(map[string]*gateWait, len(g.waits))
	for id, w := range g.waits {
		waits[id] = w
	}
	g.mu.Unlock()
	for _, w := range waits {
		w.signal(stopByOwner)
	}
	deadline := time.After(gateStopWait)
	for id, w := range waits {
		select {
		case <-w.done:
		case <-deadline:
			fmt.Fprintf(g.warn, "chat gate: request %s did not settle within %v of the stop\n", id, gateStopWait)
			return
		}
	}
}

// resume lets a new turn's calls ask again after a Stop.
func (g *gate) resume() {
	if g == nil {
		return
	}
	g.mu.Lock()
	g.halted = g.closed
	g.mu.Unlock()
}

// shutdown runs once the child is stopped (Close, after halt): it waits,
// bounded, for the request goroutines — dispatch adds none once closed —,
// records every claimed call whose result never arrived as of unknown
// outcome and removes the publish dir.
func (g *gate) shutdown() {
	if g == nil {
		return
	}
	done := make(chan struct{})
	go func() {
		g.wg.Wait()
		close(done)
	}()
	if !waitClosed(done, gateStopWait) {
		fmt.Fprintf(g.warn, "chat gate: permission requests still settling at close\n")
	}
	g.mu.Lock()
	open := make([]string, 0, len(g.claimed))
	for toolUseID := range g.claimed {
		open = append(open, toolUseID)
	}
	g.mu.Unlock()
	for _, toolUseID := range open {
		g.finish(toolUseID, "", reasonOutcomeUnknown)
	}
	if g.opts.Publish != nil {
		if err := g.opts.Publish.Remove(); err != nil {
			fmt.Fprintf(g.warn, "chat gate: %v\n", err)
		}
	}
}

// noteOwn records a page or doc this session published, so updating it
// later needs no approval.
func (g *gate) noteOwn(link string) {
	if id := artifactID(link); id != "" {
		g.mu.Lock()
		g.own[id] = true
		g.mu.Unlock()
	}
}

// ownLink is the policy's OwnArtifact and OwnDoc: a link or id of a page or
// doc this session published.
func (g *gate) ownLink(s string) bool {
	id := artifactID(s)
	if id == "" {
		return false
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.own[id]
}
