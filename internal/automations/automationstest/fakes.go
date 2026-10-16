package automationstest

import (
	"context"
	"encoding/json"
	"sync"

	"watchtower/internal/automations"
	"watchtower/internal/digest"
	"watchtower/internal/tools"
)

// FakeCall is one Generate call a FakeGenerator received; Source is the
// ctx's digest.WithSource tag ("" when untagged).
type FakeCall struct {
	SystemPrompt, UserMessage, SessionID string
	Source                               string
}

// FakeGenerator is a digest.Generator that records its calls. Call i replies
// Replies[i] with Usage[i]; past the end of a slice it repeats the slice's
// last element (an empty reply and nil usage when the slice is empty).
// Errors[i], when non-nil, makes call i fail with it (and Usage[i], if any);
// Errors is not repeated past its end.
type FakeGenerator struct {
	Replies []string
	Usage   []digest.Usage
	Errors  []error
	Calls   []FakeCall

	mu sync.Mutex
}

var _ digest.Generator = (*FakeGenerator)(nil)

// Generate records the call and returns the scripted reply.
func (g *FakeGenerator) Generate(ctx context.Context, systemPrompt, userMessage, sessionID string) (string, *digest.Usage, string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	i := len(g.Calls)
	source, _ := digest.SourceFromContext(ctx)
	g.Calls = append(g.Calls, FakeCall{SystemPrompt: systemPrompt, UserMessage: userMessage, SessionID: sessionID, Source: source})
	var reply string
	if n := len(g.Replies); n > 0 {
		reply = g.Replies[min(i, n-1)]
	}
	var usage *digest.Usage
	if n := len(g.Usage); n > 0 {
		u := g.Usage[min(i, n-1)]
		usage = &u
	}
	if i < len(g.Errors) && g.Errors[i] != nil {
		return "", usage, sessionID, g.Errors[i]
	}
	return reply, usage, sessionID, nil
}

// Snapshot returns a copy of the calls received so far.
func (g *FakeGenerator) Snapshot() []FakeCall {
	g.mu.Lock()
	defer g.mu.Unlock()
	return append([]FakeCall(nil), g.Calls...)
}

// CallCount returns how many Generate calls the fake received.
func (g *FakeGenerator) CallCount() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return len(g.Calls)
}

// FakeRead is one CallRead a FakeRegistry received.
type FakeRead struct {
	Name    string
	Args    json.RawMessage
	Binding tools.Binding
}

// FakeProposal is one Propose a FakeRegistry received.
type FakeProposal struct {
	Name    string
	Args    json.RawMessage
	Binding tools.Binding
}

// FakeRegistry is an automations.ToolRegistry over a fixed tool set. CallRead
// returns ReadResults[name] (or ReadErrors[name]) and refuses an unknown or
// write tool the way *tools.Registry does; Propose records the call and
// returns ProposeReceipts[name] (or ProposeErrors[name]; a pending receipt
// when neither is set). Neither runs a tool's Execute.
type FakeRegistry struct {
	Tools       map[string]*tools.Tool
	ReadResults map[string]any
	ReadErrors  map[string]error
	Reads       []FakeRead
	Proposed    []FakeProposal
	// ProposeReceipts and ProposeErrors script Propose per tool name. A
	// scripted receipt with ActionID 0 gets the proposal's number.
	ProposeReceipts map[string]tools.Receipt
	ProposeErrors   map[string]error

	mu sync.Mutex
}

var _ automations.ToolRegistry = (*FakeRegistry)(nil)

// Get returns the named tool.
func (r *FakeRegistry) Get(name string) (*tools.Tool, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	t, ok := r.Tools[name]
	return t, ok
}

// CallRead records the read and returns its scripted result.
func (r *FakeRegistry) CallRead(_ context.Context, name string, args json.RawMessage, b tools.Binding) (any, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	t, ok := r.Tools[name]
	if !ok {
		return nil, tools.ErrUnknownTool
	}
	if t.Access != tools.AccessRead {
		return nil, tools.ErrNotReadable
	}
	r.Reads = append(r.Reads, FakeRead{Name: name, Args: append(json.RawMessage(nil), args...), Binding: b})
	if err := r.ReadErrors[name]; err != nil {
		return nil, err
	}
	return r.ReadResults[name], nil
}

// Propose records the proposal and returns its scripted receipt or error
// (a pending receipt by default).
func (r *FakeRegistry) Propose(_ context.Context, name string, args json.RawMessage, b tools.Binding) (tools.Receipt, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, ok := r.Tools[name]; !ok {
		return tools.Receipt{}, tools.ErrUnknownTool
	}
	r.Proposed = append(r.Proposed, FakeProposal{Name: name, Args: append(json.RawMessage(nil), args...), Binding: b})
	if err := r.ProposeErrors[name]; err != nil {
		return tools.Receipt{}, err
	}
	rc, ok := r.ProposeReceipts[name]
	if !ok {
		rc = tools.Receipt{Status: "pending", Tool: name}
	}
	if rc.ActionID == 0 {
		rc.ActionID = int64(len(r.Proposed))
	}
	return rc, nil
}

// ReadCalls returns a copy of the reads received so far.
func (r *FakeRegistry) ReadCalls() []FakeRead {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]FakeRead(nil), r.Reads...)
}

// ProposedCalls returns a copy of the proposals received so far.
func (r *FakeRegistry) ProposedCalls() []FakeProposal {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]FakeProposal(nil), r.Proposed...)
}

// FakeMCPCall is one Call a FakeMCP received.
type FakeMCPCall struct {
	Server, Tool string
	Args         json.RawMessage
}

// FakeMCP is an automations.MCPCaller that records its calls. It returns
// Result (null when empty) or Err.
type FakeMCP struct {
	Result json.RawMessage
	Err    error

	mu    sync.Mutex
	calls []FakeMCPCall
}

var _ automations.MCPCaller = (*FakeMCP)(nil)

// Call records the call and returns the scripted outcome.
func (m *FakeMCP) Call(_ context.Context, server, tool string, args json.RawMessage) (json.RawMessage, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.calls = append(m.calls, FakeMCPCall{Server: server, Tool: tool, Args: append(json.RawMessage(nil), args...)})
	return m.Result, m.Err
}

// Calls returns a copy of the calls received so far.
func (m *FakeMCP) Calls() []FakeMCPCall {
	m.mu.Lock()
	defer m.mu.Unlock()
	return append([]FakeMCPCall(nil), m.calls...)
}
