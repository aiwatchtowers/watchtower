package slacklive

import (
	"context"
	"encoding/json"
	"sync"
	"time"

	"watchtower/internal/codex"
	"watchtower/internal/llmusage"
)

// ProbePurpose is the LLM usage ledger's purpose of a probe's model call
// (LLMUSAGE-01): each probe child runs one real model turn.
const ProbePurpose = "slack.live_probe"

// probeCall is what one probe child's stream reports about its model call.
type probeCall struct {
	tokens *llmusage.Tokens // summed reported usage; nil = none reported
	model  string
	output string
	ok     bool
}

// usageMeter collects one probe child's model call for the ledger. read
// is the stream's usage reader (claudeUsageLine, codexUsageLine).
type usageMeter struct {
	provider string
	read     func(line string, c *probeCall)

	mu     sync.Mutex
	prompt string // the model prompt; "" = no model turn was asked
	call   probeCall
}

func newMeter(provider string, read func(string, *probeCall)) *usageMeter {
	return &usageMeter{provider: provider, read: read}
}

func (m *usageMeter) observe(line string) {
	if m == nil || m.read == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.read(line, &m.call)
}

func (m *usageMeter) asked(prompt string) {
	if m == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.prompt = prompt
}

// recordProbeCall records the child's model call: the reported usage as it
// is; a turn asked with no usage reported (killed, timed out) as length/4
// estimates of prompt and output. A child that was never asked for a model
// turn (the connector never connected) made no call and records nothing.
func recordProbeCall(ctx context.Context, m *usageMeter, start time.Time) {
	if m == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.prompt == "" {
		return
	}
	c := llmusage.Call{Surface: "watchtower", Purpose: ProbePurpose, Provider: m.provider,
		Model: m.call.model, DurationMS: time.Since(start).Milliseconds(), OK: m.call.ok}
	if m.call.tokens != nil {
		c.Tokens = *m.call.tokens
	} else {
		c.Input, c.Output, c.Estimated = llmusage.EstimateTokens(m.prompt), llmusage.EstimateTokens(m.call.output), true
	}
	llmusage.Record(ctx, c)
}

// claudeUsageLine reads a stream-json result event: its usage, the reported
// cost (one turn per probe child, so total_cost_usd is this call's own) and
// the model from modelUsage.
func claudeUsageLine(line string, c *probeCall) {
	var ev struct {
		Type    string  `json:"type"`
		IsError bool    `json:"is_error"`
		Result  string  `json:"result"`
		CostUSD float64 `json:"total_cost_usd"`
		Usage   *struct {
			Input         int `json:"input_tokens"`
			Output        int `json:"output_tokens"`
			CacheRead     int `json:"cache_read_input_tokens"`
			CacheCreation int `json:"cache_creation_input_tokens"`
			Split         struct {
				FiveMin int `json:"ephemeral_5m_input_tokens"`
				OneHour int `json:"ephemeral_1h_input_tokens"`
			} `json:"cache_creation"`
		} `json:"usage"`
		ModelUsage map[string]json.RawMessage `json:"modelUsage"`
	}
	if json.Unmarshal([]byte(line), &ev) != nil || ev.Type != "result" {
		return
	}
	c.ok, c.output = !ev.IsError, ev.Result
	if ev.Usage != nil {
		u := ev.Usage
		t := llmusage.ClaudeTokens(u.Input, u.CacheRead, u.CacheCreation, u.Split.FiveMin, u.Split.OneHour, u.Output)
		if ev.CostUSD > 0 {
			cost := ev.CostUSD
			t.ReportedCostUSD = &cost
		}
		c.tokens = &t
	}
	c.model = llmusage.ModelFromUsage(ev.ModelUsage, c.model)
}

// codexUsageLine reads codex exec --json: the usage of turn.completed (the
// cached input split out as cache reads) and the agent's text.
func codexUsageLine(line string, c *probeCall) {
	var ev codex.CodexEvent
	if json.Unmarshal([]byte(line), &ev) != nil {
		return
	}
	switch {
	case ev.Type == "item.completed" && ev.Item != nil && ev.Item.Type == "agent_message":
		c.output += ev.Item.Text + ev.Item.Content
	case ev.Type == "turn.completed":
		c.ok = true
		if ev.Usage != nil {
			t := ev.Usage.Tokens()
			if c.tokens != nil {
				t.Add(*c.tokens)
			}
			c.tokens = &t
		}
	}
}
