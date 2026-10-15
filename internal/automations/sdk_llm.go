package automations

import (
	"context"
	"encoding/json"
	"fmt"
	"slices"
	"strings"

	"github.com/dop251/goja"
	"github.com/google/jsonschema-go/jsonschema"

	"watchtower/internal/digest"
)

// Source tags of llm() calls (digest.TierForSource): light routes to the
// light tier, strong is the owner's explicit tier: strong.
const (
	SourceLLMLight  = "automation.llm"
	SourceLLMStrong = "automation.llm.strong"
)

// LLM tiers a script may ask for.
const (
	tierLight  = "light"
	tierStrong = "strong"
)

// llmSystemPrompt frames every llm() call: the owner's prompt is the task.
const llmSystemPrompt = "You are one step of an automation script the owner wrote. " +
	"Do exactly what the owner's request asks and reply with the result only, without preamble."

// LLMModule defines llm(prompt, {input?, schema?, tier?}) (spec §5): the
// permission llm:<tier> (default light), input JSON-serialised after the
// prompt (prompt + input + schema ≤ MaxLLMInputBytes), one metered Generate call per attempt
// (Env.MeteredModelCall) and, with a schema, the reply parsed and validated
// with one retry before a ValidationError. It returns the reply string, or
// the parsed value with a schema.
func LLMModule(b Backends) Module {
	return sdkModule{name: "llm", fns: map[string]SDKFunc{"llm": func(env *Env, call goja.FunctionCall, rt *goja.Runtime) (any, error) {
		req, reqErr := parseLLMCall(env, rt, call)
		return env.Call(StepKindLLM, req.tier, req.stepArgs(), func(step *Step) (any, error) {
			if reqErr != nil {
				return nil, reqErr
			}
			return runLLM(env, b, step, req)
		})
	}}}
}

// llmCall is one llm() call's arguments.
type llmCall struct {
	prompt string
	input  json.RawMessage // nil = no input
	schema json.RawMessage // nil = free text
	tier   string
}

// size is what MaxLLMInputBytes bounds: the prompt, the serialised input and
// the serialised schema together (a stricter reading of spec §5's "input").
func (r llmCall) size() int { return len(r.prompt) + len(r.input) + len(r.schema) }

func (r llmCall) stepArgs() map[string]any {
	a := map[string]any{"prompt": r.prompt, "tier": r.tier}
	if r.input != nil {
		a["input"] = r.input
	}
	if r.schema != nil {
		a["schema"] = r.schema
	}
	return a
}

var llmOptionKeys = []string{"input", "schema", "tier"}

// parseLLMCall reads llm(prompt, opts?). It runs before the step begins; a
// bad call is reported inside the step.
func parseLLMCall(env *Env, rt *goja.Runtime, call goja.FunctionCall) (llmCall, error) {
	req := llmCall{tier: tierLight}
	p, _, err := argAt(env, rt, call, 0)
	if err != nil {
		return req, tooLargeAs(err, ErrNameValidation,
			fmt.Sprintf("llm(): input too large: the prompt is larger than %d bytes; prompt, input and schema may be at most %d bytes together",
				maxSDKArgBytes, MaxLLMInputBytes))
	}
	var ok bool
	if req.prompt, ok = p.(string); !ok || strings.TrimSpace(req.prompt) == "" {
		return req, validationf("llm(prompt): prompt must be a non-empty string")
	}
	o, present, err := argAt(env, rt, call, 1)
	if err != nil {
		return req, tooLargeAs(err, ErrNameValidation,
			fmt.Sprintf("llm(): input too large: the options object is larger than %d bytes; prompt, input and schema may be at most %d bytes together",
				maxSDKArgBytes, MaxLLMInputBytes))
	}
	if !present || o == nil {
		return req, nil
	}
	opts, ok := o.(map[string]any)
	if !ok {
		return req, validationf("llm(prompt, options): options must be an object")
	}
	return req, req.applyOptions(opts)
}

func (r *llmCall) applyOptions(opts map[string]any) error {
	for k := range opts {
		if !slices.Contains(llmOptionKeys, k) {
			return validationf("llm(): unknown option %q (use input, schema, tier)", k)
		}
	}
	if t, has := opts["tier"]; has {
		s, ok := t.(string)
		if !ok || (s != tierLight && s != tierStrong) {
			return validationf("llm(): tier must be %q or %q", tierLight, tierStrong)
		}
		r.tier = s
	}
	var err error
	if in, has := opts["input"]; has {
		if r.input, err = json.Marshal(in); err != nil {
			return validationf("llm(): input: %v", err)
		}
	}
	if s, has := opts["schema"]; has {
		if _, ok := s.(map[string]any); !ok {
			return validationf("llm(): schema must be a JSON Schema object")
		}
		if r.schema, err = json.Marshal(s); err != nil {
			return validationf("llm(): schema: %v", err)
		}
	}
	return nil
}

func runLLM(env *Env, b Backends, step *Step, req llmCall) (any, error) {
	m, err := manifestOf(env)
	if err != nil {
		return nil, err
	}
	entry, err := m.AllowLLM(req.tier)
	if err != nil {
		return nil, err
	}
	step.SetPermission(entry)
	if n := req.size(); n > MaxLLMInputBytes {
		return nil, validationf("llm(): input too large: prompt, input and schema are %d bytes serialised; the limit is %d",
			n, MaxLLMInputBytes)
	}
	if b.Generator == nil {
		return nil, notAvailable("no model provider is configured")
	}
	var schema *jsonschema.Resolved
	if req.schema != nil {
		if schema, err = resolveReplySchema(req.schema); err != nil {
			return nil, err
		}
	}
	user := llmUserMessage(req)
	reply, err := generateMetered(env, b, step, req.tier, user)
	if err != nil || schema == nil {
		return reply, err
	}
	v, verr := parseReply(reply, schema)
	if verr == nil {
		return jsonValue(v), nil
	}
	retry := user + "\n\nYour previous reply was not accepted: " + verr.Error() +
		"\nReply again with only the JSON value."
	if reply, err = generateMetered(env, b, step, req.tier, retry); err != nil {
		return nil, err
	}
	if v, verr = parseReply(reply, schema); verr != nil {
		return nil, validationf("llm(): the reply does not match the schema after one retry: %v", verr)
	}
	return jsonValue(v), nil
}

// llmUserMessage is the prompt, then the input as JSON, then the schema
// instruction.
func llmUserMessage(req llmCall) string {
	var b strings.Builder
	b.WriteString(req.prompt)
	if req.input != nil {
		b.WriteString("\n\nInput (JSON):\n")
		b.Write(req.input)
	}
	if req.schema != nil {
		b.WriteString("\n\nReply with only a JSON value, without code fences or commentary, that validates against this JSON Schema:\n")
		b.Write(req.schema)
	}
	return b.String()
}

func resolveReplySchema(raw json.RawMessage) (*jsonschema.Resolved, error) {
	var s jsonschema.Schema
	if err := json.Unmarshal(raw, &s); err != nil {
		return nil, validationf("llm(): schema is not a JSON Schema: %v", err)
	}
	res, err := s.Resolve(&jsonschema.ResolveOptions{})
	if err != nil {
		return nil, validationf("llm(): schema is not a usable JSON Schema: %v", err)
	}
	return res, nil
}

// parseReply decodes the reply (a single surrounding code fence is dropped)
// and validates it.
func parseReply(reply string, schema *jsonschema.Resolved) (any, error) {
	text := stripCodeFence(strings.TrimSpace(reply))
	var v any
	if err := json.Unmarshal([]byte(text), &v); err != nil {
		return nil, fmt.Errorf("the reply is not JSON: %w", err)
	}
	if err := schema.Validate(v); err != nil {
		return nil, fmt.Errorf("the reply does not validate: %w", err)
	}
	return v, nil
}

func stripCodeFence(s string) string {
	if !strings.HasPrefix(s, "```") || !strings.HasSuffix(s, "```") || len(s) < 6 {
		return s
	}
	body := strings.TrimSuffix(s[3:], "```")
	if nl := strings.IndexByte(body, '\n'); nl >= 0 {
		body = body[nl+1:] // drop the info string ("json")
	}
	return strings.TrimSpace(body)
}

// generateMetered is one metered Generate call; a successful call whose
// usage the provider does not report is estimated as
// ceil(len(prompt+reply)/4) tokens, a failed one debits only reported usage.
func generateMetered(env *Env, b Backends, step *Step, tier, user string) (string, error) {
	var reply string
	err := env.MeteredModelCall(step, func(ctx context.Context) (ModelUsage, error) {
		r, usage, err := generateTier(ctx, b.Generator, tier, user)
		if err != nil {
			// A failed call debits only the usage the provider reported.
			return reportedUsage(usage), &SDKError{Name: ErrNameTool, Message: "the model call failed: " + err.Error()}
		}
		reply = r
		return modelUsage(usage, len(llmSystemPrompt)+len(user), len(r)), nil
	})
	return reply, err
}

// generateTier calls the generator under the tier's source tag (one literal
// tag per branch, so the tier scan resolves both).
func generateTier(ctx context.Context, g digest.Generator, tier, user string) (string, *digest.Usage, error) {
	if tier == tierStrong {
		r, u, _, err := g.Generate(digest.WithSource(ctx, SourceLLMStrong), llmSystemPrompt, user, "")
		return r, u, err
	}
	r, u, _, err := g.Generate(digest.WithSource(ctx, SourceLLMLight), llmSystemPrompt, user, "")
	return r, u, err
}

// modelUsage converts the provider's usage. None (nil or zero tokens) is an
// estimate of ceil((promptBytes+replyBytes)/4) tokens, the reply's share
// counted as output. A reported dollar cost is kept for display only.
func modelUsage(u *digest.Usage, promptBytes, replyBytes int) ModelUsage {
	if u == nil || (u.InputTokens == 0 && u.OutputTokens == 0) {
		total := int64(promptBytes+replyBytes+3) / 4
		out := min(total, int64(replyBytes+3)/4)
		return ModelUsage{InputTokens: total - out, OutputTokens: out, Estimated: true}
	}
	return reportedUsage(u)
}

// reportedUsage is exactly what the provider reported (zero for nil).
func reportedUsage(u *digest.Usage) ModelUsage {
	if u == nil {
		return ModelUsage{}
	}
	mu := ModelUsage{InputTokens: int64(u.InputTokens), OutputTokens: int64(u.OutputTokens)}
	if u.CostUSD > 0 {
		cost := u.CostUSD
		mu.ReportedUSD = &cost
	}
	return mu
}
