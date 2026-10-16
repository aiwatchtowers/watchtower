// Package agentloop is runtime B: a Go-owned tool-calling loop for
// OpenAI-compatible HTTP providers (Ollama and any /v1/chat/completions server).
// It gives the ollama chat provider the same registry tools that claude/codex
// reach through the MCP subprocess, but in-process — no subprocess, no MCP.
//
// The registry stays the only authority. A write-tool call goes through
// Registry.Propose (never Execute): it records one agent_actions proposal row
// and hands the model a receipt, so AGENT-01 ("the model never writes") holds on
// this path exactly as it does through MCP. Read-tool calls go through
// Registry.CallRead with the loop's binding and touch no proposal row.
package agentloop

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"slices"
	"strings"

	"watchtower/internal/ai"
	"watchtower/internal/ollama"
	"watchtower/internal/tools"
)

// defaultMaxIterations bounds the tool loop: a weak local model can call tools
// forever, so the loop always terminates, returning whatever text it has.
const defaultMaxIterations = 6

// registry is the subset of *tools.Registry the loop needs; an interface so the
// loop logic can be tested without a database.
type registry interface {
	List(surface string) []*tools.Tool
	Get(name string) (*tools.Tool, bool)
	Propose(ctx context.Context, name string, args json.RawMessage, b tools.Binding) (tools.Receipt, error)
	CallRead(ctx context.Context, name string, args json.RawMessage, b tools.Binding) (any, error)
}

// Client implements ai.Provider by running the tool loop against an
// OpenAI-compatible endpoint.
type Client struct {
	model   string
	baseURL string
	httpc   *http.Client
	reg     registry
	binding tools.Binding
	maxIter int
	opts    Options
	allowed map[string]bool // nil = every surface tool (Options.Tools nil)

	toolEvents bool // emit ai.StreamChunk{Tool: …} around each dispatch (EmitToolEvents)
}

// EmitToolEvents makes Query report every tool call as a start and an end
// chunk (ai.StreamChunk.Tool) around its dispatch, so a protocol-v2 chat can
// show the call as a step. Off by default: v1 consumers see only the
// boundary and the text, unchanged.
func (c *Client) EmitToolEvents() { c.toolEvents = true }

// Options restrict and meter a runtime-B loop (an automation's agent(),
// spec 2026-10-14-automations-design §6.5). The zero value is NewClient's
// unrestricted loop.
type Options struct {
	// Tools is the allowlist: only Tools ∩ List(surface) is offered, and a
	// call naming any other tool is refused before the registry sees it. nil
	// offers every surface tool.
	Tools []string
	// Gate runs before each offered tool call and returns the args to
	// dispatch; its error is fed back to the model as the call's result.
	Gate func(ctx context.Context, t *tools.Tool, args json.RawMessage) (json.RawMessage, error)
	// MaxIterations caps the model calls; 0 = defaultMaxIterations.
	MaxIterations int
	// BeforeModelCall runs before every model call; its error stops the loop
	// and is returned.
	BeforeModelCall func() error
	// AfterModelCall receives each model response's token usage (0, 0 when
	// the server reports none).
	AfterModelCall func(inputTokens, outputTokens int)
}

// NewClient builds a runtime-B client. baseURL is the OpenAI-compatible server
// ("" for the Ollama default); reg is the tool registry; b carries the chat
// surface/conversation/turn a proposal is bound to.
func NewClient(model, baseURL string, reg *tools.Registry, b tools.Binding) *Client {
	return NewClientWithOptions(model, baseURL, reg, b, Options{})
}

// NewClientWithOptions is NewClient restricted and metered by opts.
func NewClientWithOptions(model, baseURL string, reg *tools.Registry, b tools.Binding, opts Options) *Client {
	if baseURL == "" {
		baseURL = ollama.DefaultBaseURL
	}
	c := &Client{
		model:   model,
		baseURL: strings.TrimRight(baseURL, "/"),
		httpc:   ollama.NewHTTPClient(),
		reg:     reg,
		binding: b,
		maxIter: defaultMaxIterations,
		opts:    opts,
	}
	if opts.MaxIterations > 0 {
		c.maxIter = opts.MaxIterations
	}
	if opts.Tools != nil {
		c.allowed = make(map[string]bool, len(opts.Tools))
		for _, name := range opts.Tools {
			c.allowed[name] = true
		}
	}
	return c
}

// Query runs the loop and streams the assistant turn. Each round that makes a
// tool call emits an ai.StreamChunk{ToolBoundary: true} before the tools run —
// so a consumer that showed any pre-tool text discards it and starts the visible
// answer fresh from the text after the last boundary, matching claude/codex
// (ai.StreamChunk's contract). The final answer is streamed as one Text chunk;
// write proposals still surface through the Desktop's AgentActionFeed.
func (c *Client) Query(ctx context.Context, systemPrompt, userMessage, _ string) (<-chan ai.StreamChunk, <-chan error, <-chan string) {
	textCh := make(chan ai.StreamChunk, 8)
	errCh := make(chan error, 1)
	sidCh := make(chan string, 1)
	go func() {
		defer close(textCh)
		defer close(errCh)
		defer close(sidCh)
		if _, _, err := c.run(ctx, systemPrompt, userMessage, func(ch ai.StreamChunk) { textCh <- ch }); err != nil {
			errCh <- err
		}
	}()
	return textCh, errCh, sidCh
}

// QuerySync runs the loop and returns the final answer (no streaming, so no
// boundary emission).
func (c *Client) QuerySync(ctx context.Context, systemPrompt, userMessage, _ string) (string, *ai.Usage, error) {
	return c.run(ctx, systemPrompt, userMessage, nil)
}

// run is the tool loop. It calls the model, dispatches any tool calls against
// the registry, feeds the results back, and returns the first assistant turn
// that makes no tool call. It always terminates: the iteration cap returns the
// last textual content the model produced. emit (nil for the sync path)
// receives a ToolBoundary chunk before each tool round and the final Text chunk.
func (c *Client) run(ctx context.Context, systemPrompt, userMessage string, emit func(ai.StreamChunk)) (string, *ai.Usage, error) {
	emitText := func(s string) {
		if emit != nil && s != "" {
			emit(ai.StreamChunk{Text: s})
		}
	}
	emitBoundary := func() {
		if emit != nil {
			emit(ai.StreamChunk{ToolBoundary: true})
		}
	}
	msgs := make([]oaMessage, 0, 4)
	if systemPrompt != "" {
		msgs = append(msgs, oaMessage{Role: "system", Content: systemPrompt})
	}
	msgs = append(msgs, oaMessage{Role: "user", Content: userMessage})

	oaTools := c.buildTools()
	var usage *ai.Usage
	var lastContent string

	for i := 0; i < c.maxIter; i++ {
		if c.opts.BeforeModelCall != nil {
			if err := c.opts.BeforeModelCall(); err != nil {
				return "", usage, err
			}
		}
		resp, err := c.chat(ctx, msgs, oaTools)
		if err != nil {
			return "", usage, err
		}
		if c.opts.AfterModelCall != nil {
			var in, out int
			if resp.Usage != nil {
				in, out = resp.Usage.PromptTokens, resp.Usage.CompletionTokens
			}
			c.opts.AfterModelCall(in, out)
		}
		if len(resp.Choices) == 0 {
			return "", usage, fmt.Errorf("model returned no choices")
		}
		usage = addUsage(usage, resp.Usage)
		m := resp.Choices[0].Message
		if strings.TrimSpace(m.Content) != "" {
			lastContent = strings.TrimSpace(m.Content)
		}
		if len(m.ToolCalls) == 0 {
			emitText(lastContent)
			return lastContent, usage, nil
		}
		// This turn makes a tool call, so any text it carried was pre-tool
		// reasoning — signal the boundary so the consumer starts the visible
		// answer fresh from what follows (ai.StreamChunk contract).
		emitBoundary()
		msgs = append(msgs, m)
		for _, call := range m.ToolCalls {
			c.emitTool(emit, &ai.ToolEvent{ID: call.ID, Name: call.Function.Name, Args: json.RawMessage(call.Function.Arguments)})
			result := c.dispatch(ctx, call)
			c.emitTool(emit, &ai.ToolEvent{ID: call.ID, Name: call.Function.Name, Done: true,
				OK: !strings.HasPrefix(result, `{"error":`), Result: result})
			msgs = append(msgs, oaMessage{
				Role:       "tool",
				ToolCallID: call.ID,
				Name:       call.Function.Name,
				Content:    result,
			})
		}
	}

	// The cap is reached only while the model is still emitting tool calls, so
	// whatever text it last produced is mid-work — flag it as truncated rather
	// than present it as a finished answer.
	if lastContent != "" {
		capped := lastContent + "\n\n(Note: I reached the tool-call limit before finishing.)"
		emitText(capped)
		return capped, usage, nil
	}
	const note = "I couldn't complete that within the tool-call limit."
	emitText(note)
	return note, usage, nil
}

// emitTool forwards a tool start/end chunk when tool events are on.
func (c *Client) emitTool(emit func(ai.StreamChunk), ev *ai.ToolEvent) {
	if emit != nil && c.toolEvents {
		emit(ai.StreamChunk{Tool: ev})
	}
}

// dispatch runs one tool call against the registry and returns the JSON string
// that becomes the tool-result message. A tool error is returned as an error
// JSON fed back to the model, never up the stack — one bad call must not kill
// the turn.
func (c *Client) dispatch(ctx context.Context, call oaToolCall) string {
	name := call.Function.Name
	// The allowlist is checked first: a tool outside it was never offered,
	// whatever the registry or the surface would say about it.
	if c.allowed != nil && !c.allowed[name] {
		return errJSON("tool " + name + " is not offered here")
	}
	t, ok := c.reg.Get(name)
	if !ok {
		return errJSON("unknown tool " + name)
	}
	// A model may name a tool it was never offered on this surface (buildTools
	// advertises only List(surface)). Get is surface-blind, so enforce the same
	// boundary the MCP adapter gets for free by mounting only List(surface) —
	// without it a target-surface call could reach a main-only tool like
	// create_target (TGT-BRIEF-01 axis 3).
	if len(t.Surfaces) > 0 && !slices.Contains(t.Surfaces, c.binding.Surface) {
		return errJSON("tool " + name + " is not available on this surface")
	}
	// Pass the raw arguments through: Propose and CallRead both normalise an
	// empty body and reject invalid JSON with a model-facing message, so a
	// pre-coercion here would only hide that message from the model.
	args := json.RawMessage(call.Function.Arguments)
	if c.opts.Gate != nil {
		gated, err := c.opts.Gate(ctx, t, args)
		if err != nil {
			return errJSON(err.Error())
		}
		args = gated
	}
	switch t.Access {
	case tools.AccessWrite:
		rc, err := c.reg.Propose(ctx, name, args, c.binding)
		if err != nil {
			return errJSON(err.Error())
		}
		return marshalResult(rc)
	default:
		data, err := c.reg.CallRead(ctx, name, args, c.binding)
		if err != nil {
			return errJSON(err.Error())
		}
		return marshalResult(data)
	}
}

// buildTools renders the registry's surface-visible tools (narrowed to
// Options.Tools when set) as OpenAI function definitions, each tool's
// declared InputSchema becoming the parameters schema.
func (c *Client) buildTools() []oaTool {
	list := c.reg.List(c.binding.Surface)
	out := make([]oaTool, 0, len(list))
	for _, t := range list {
		if c.allowed != nil && !c.allowed[t.Name] {
			continue
		}
		var params json.RawMessage
		if t.InputSchema != nil {
			b, err := json.Marshal(t.InputSchema)
			if err != nil {
				// A schema that cannot render (practically impossible — Register
				// already Resolved it) would advertise the tool with no parameters,
				// inviting invented args. Skip it rather than offer it half-formed.
				continue
			}
			params = b
		}
		out = append(out, oaTool{Type: "function", Function: oaToolDef{
			Name: t.Name, Description: t.Description, Parameters: params,
		}})
	}
	return out
}

// chat makes one non-streaming chat-completions request.
func (c *Client) chat(ctx context.Context, msgs []oaMessage, oaTools []oaTool) (*oaResponse, error) {
	body, err := json.Marshal(oaRequest{Model: c.model, Messages: msgs, Tools: oaTools, Stream: false})
	if err != nil {
		return nil, fmt.Errorf("marshaling request: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/v1/chat/completions", bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("creating request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.httpc.Do(req)
	if err != nil {
		return nil, fmt.Errorf("model request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		return nil, fmt.Errorf("model returned HTTP %d: %s", resp.StatusCode, string(b))
	}
	var out oaResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, fmt.Errorf("decoding model response: %w", err)
	}
	return &out, nil
}

func errJSON(msg string) string {
	b, _ := json.Marshal(map[string]string{"error": msg})
	return string(b)
}

func marshalResult(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		return errJSON("could not encode tool result")
	}
	return string(b)
}

func addUsage(acc *ai.Usage, u *oaUsage) *ai.Usage {
	if u == nil {
		return acc
	}
	if acc == nil {
		acc = &ai.Usage{}
	}
	acc.InputTokens += u.PromptTokens
	acc.OutputTokens += u.CompletionTokens
	acc.TotalAPITokens += u.TotalTokens
	return acc
}
