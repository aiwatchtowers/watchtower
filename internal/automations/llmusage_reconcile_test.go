package automations_test

import (
	"context"
	"sync"
	"testing"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/llmusage"
)

// collectingSink keeps every recorded LLM call.
type collectingSink struct {
	mu    sync.Mutex
	calls []llmusage.Call
}

func (s *collectingSink) Write(c llmusage.Call) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.calls = append(s.calls, c)
	return nil
}

func (s *collectingSink) snapshot() []llmusage.Call {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]llmusage.Call(nil), s.calls...)
}

// recordingGenerator is a provider leaf: it records each call's reported
// usage in the ledger under the caller's ctx, as the real generators do.
type recordingGenerator struct{ automationstest.FakeGenerator }

func (g *recordingGenerator) Generate(ctx context.Context, system, user, session string) (string, *digest.Usage, string, error) {
	reply, u, sid, err := g.FakeGenerator.Generate(ctx, system, user, session)
	c := llmusage.Call{Provider: "fake", Model: "fake", OK: err == nil}
	if u != nil {
		c.Input, c.Output = int64(u.InputTokens), int64(u.OutputTokens)
	}
	llmusage.Record(ctx, c)
	return reply, u, sid, err
}

// recordingAgent is an agent() runner whose child's usage is recorded once
// after the call (a CLI child's shape).
type recordingAgent struct{ automationstest.FakeAgent }

func (a *recordingAgent) Run(ctx context.Context, req automations.AgentRequest) (automations.AgentResult, error) {
	r, err := a.FakeAgent.Run(ctx, req)
	llmusage.Record(ctx, llmusage.Call{Provider: "fake", Model: "fake", Input: r.InputTokens, Output: r.OutputTokens, OK: err == nil})
	return r, err
}

// TestAutomationRunLedgerMatchesRun: an automation run with two llm() calls
// and one agent() call → the ledger rows carrying its run id sum to the
// tokens the run's automation_runs row counts.
func TestAutomationRunLedgerMatchesRun(t *testing.T) {
	sink := &collectingSink{}
	llmusage.SetSink(sink)
	t.Cleanup(func() { llmusage.SetSink(nil) })

	gen := &recordingGenerator{automationstest.FakeGenerator{Replies: []string{"done"},
		Usage: []digest.Usage{{InputTokens: 10, OutputTokens: 5}, {InputTokens: 70, OutputTokens: 30}}}}
	agent := &recordingAgent{automationstest.FakeAgent{Result: automations.AgentResult{Text: "triaged", InputTokens: 300, OutputTokens: 100}}}
	f := newExFixture(t, exOpts{gen: gen, backends: func(_ *exFixture, b *automations.Backends) { b.Agent = agent }})
	recipe := "---\nname: Ledger test\ntrigger:\n  manual: true\npermissions:\n  - llm:light\n  - agent:run\n" +
		"outputs: [inbox]\n---\nA ledger test recipe.\n\n```js\nllm(\"one\"); llm(\"two\"); agent(\"triage\"); return 1\n```\n"
	a := f.seedText(t, "ledger", recipe, false)
	id := f.enqueue(t, a, db.TriggerManual)
	f.step(t, 1)
	r := f.wantRun(t, id, db.RunSucceeded, "")

	var in, out int64
	var n int
	for _, c := range sink.snapshot() {
		if c.AutomationRunID == nil || *c.AutomationRunID != id {
			continue
		}
		if c.AutomationID == nil || *c.AutomationID != a.ID {
			t.Fatalf("call %+v: automation id %v; want %d", c, c.AutomationID, a.ID)
		}
		n++
		in, out = in+c.Input, out+c.Output
	}
	if n != 3 {
		t.Fatalf("ledger rows for run %d = %d; want 3 (two llm(), one agent()); all calls %+v", id, n, sink.snapshot())
	}
	if in != r.InputTokens || out != r.OutputTokens {
		t.Fatalf("ledger tokens = %d+%d; run row = %d+%d", in, out, r.InputTokens, r.OutputTokens)
	}
	if r.InputTokens != 380 || r.OutputTokens != 135 {
		t.Fatalf("run row = %d+%d; want 380+135", r.InputTokens, r.OutputTokens)
	}
}
