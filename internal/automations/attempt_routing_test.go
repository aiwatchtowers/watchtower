package automations_test

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/llmusage"
	"watchtower/internal/providerhealth"
	"watchtower/internal/providerrouting"
	"watchtower/internal/providers"
)

type routedTestLeaf struct {
	mu       sync.Mutex
	provider string
	replies  []string
	usage    *digest.Usage
	fail     bool
	record   bool
	after    func(context.Context)
	calls    int
}

func (g *routedTestLeaf) Generate(ctx context.Context, _, _, _ string) (string, *digest.Usage, string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.calls++
	reply := "done"
	if len(g.replies) > 0 {
		reply = g.replies[min(g.calls-1, len(g.replies)-1)]
	}
	var err error
	if g.fail {
		err = &providers.Failure{Provider: g.provider, Category: providers.Quota}
	}
	if g.record {
		c := llmusage.Call{Provider: g.provider, Model: "haiku", OK: err == nil, Estimated: g.usage == nil}
		if g.usage != nil {
			c.Input = int64(g.usage.InputTokens)
			c.Output = int64(g.usage.OutputTokens)
		}
		llmusage.Record(ctx, c)
	}
	if g.after != nil {
		g.after(ctx)
	}
	return reply, g.usage, "", err
}
func routedSDKGenerator(t *testing.T, preferred, reserve *routedTestLeaf, knownBoth bool) digest.Generator {
	t.Helper()
	llmusage.SetSink(&collectingSink{})
	t.Cleanup(func() { llmusage.SetSink(nil) })
	cfg := &config.Config{}
	cfg.AI.Provider = "claude"
	cfg.AI.Fallback = config.AIFallbackConfig{Enabled: true, Provider: "codex"}
	store := providerhealth.New(t.TempDir(), time.Now)
	if knownBoth {
		for _, p := range []string{"claude", "codex"} {
			require.NoError(t, store.RecordQuota(context.Background(), providerhealth.AccountScope(p, ""), &providers.Failure{Provider: p, Category: providers.Quota}))
		}
	}
	return providerrouting.WrapGenerator(cfg, preferred, func(p string) digest.Generator {
		if p == "claude" {
			return preferred
		}
		return reserve
	}, providerrouting.GeneratorOptions{Router: &providerrouting.Router{Health: store, Allowed: func(string) error { return nil }}})
}
func routedLeaves(unknown bool) (*routedTestLeaf, *routedTestLeaf) {
	p := &routedTestLeaf{provider: "claude", fail: true, usage: &digest.Usage{InputTokens: 200, OutputTokens: 5}, record: true}
	r := &routedTestLeaf{provider: "codex", usage: &digest.Usage{InputTokens: 300, OutputTokens: 10}, record: true}
	if unknown {
		p.usage = nil
	}
	return p, r
}

func TestLLMRoutingDenseStepAndLeafTotals(t *testing.T) {
	for _, schema := range []bool{false, true} {
		t.Run(map[bool]string{false: "text", true: "schema_retry"}[schema], func(t *testing.T) {
			sink := &collectingSink{}
			llmusage.SetSink(sink)
			t.Cleanup(func() { llmusage.SetSink(nil) })
			p, r := routedLeaves(false)
			script := `return llm("task")`
			wantIn, wantOut := int64(500), int64(15)
			if schema {
				r.replies = []string{"bad", `{"ok":true}`}
				script = `return llm("task",{schema:{type:"object"}}).ok`
				wantIn, wantOut = 800, 25
			}
			gen := routedSDKGenerator(t, p, r, false)
			llmusage.SetSink(sink)
			f := newExFixture(t, exOpts{gen: gen})
			a := f.seedText(t, "routed", exRecipeText(script, ""), false)
			id := f.enqueue(t, a, db.TriggerManual)
			f.step(t, 1)
			run := f.wantRun(t, id, db.RunSucceeded, "")
			steps := f.steps(t, id)
			require.Len(t, steps, 1)
			require.Equal(t, wantIn, run.InputTokens)
			require.Equal(t, wantOut, run.OutputTokens)
			require.Equal(t, wantIn, steps[0].InputTokens)
			require.Equal(t, wantOut, steps[0].OutputTokens)
			calls := sink.snapshot()
			require.Len(t, calls, 1+r.calls)
			var in, out int64
			for _, c := range calls {
				require.NotEmpty(t, c.OperationID)
				require.NotZero(t, c.Attempt)
				require.NotNil(t, c.AutomationRunID)
				require.Equal(t, id, *c.AutomationRunID)
				in += c.Input
				out += c.Output
			}
			require.Equal(t, run.InputTokens, in)
			require.Equal(t, run.OutputTokens, out)
			require.Nil(t, run.ReportedCostUSD, "estimated prices are not reported cost")
			for _, c := range calls {
				require.NotNil(t, c.EstCostUSD)
				require.Greater(t, *c.EstCostUSD, 0.0)
			}
		})
	}
}

func TestLLMRoutingFailedUnknownBlocksReserve(t *testing.T) {
	for _, record := range []bool{false, true} {
		t.Run(map[bool]string{false: "result_only", true: "leaf_unknown"}[record], func(t *testing.T) {
			p, r := routedLeaves(true)
			p.record = record
			p.replies = []string{"partial"}
			gen := routedSDKGenerator(t, p, r, false)
			run := runSDK(t, `try {llm("task")}catch(e){}; try{llm("again")}catch(e){}; return 1`, sdkCase{perms: []string{"llm:light"}, backends: &automations.Backends{Generator: gen}})
			require.NoError(t, run.err)
			require.Equal(t, 1, p.calls)
			require.Zero(t, r.calls)
			total := run.env.Journal.Totals()
			require.True(t, total.Estimated)
			require.Greater(t, total.InputTokens, int64(0))
			require.Greater(t, total.OutputTokens, int64(0))
		})
	}
}

func TestLLMRoutingBudgetCancellationAndKnownWait(t *testing.T) {
	for _, kind := range []string{"tokens", "time", "cancel", "both_wait"} {
		t.Run(kind, func(t *testing.T) {
			p, r := routedLeaves(false)
			clock := automationstest.NewFakeClock(time.Now())
			meter := automations.NewMeter(automations.Budget{Tokens: 300, Minutes: 5}, clock)
			if kind == "time" {
				p.after = func(context.Context) { clock.Advance(5 * time.Minute) }
			}
			if kind == "cancel" {
				p.after = func(ctx context.Context) { /* parent deadline expires before reserve */ <-ctx.Done() }
			}
			gen := routedSDKGenerator(t, p, r, kind == "both_wait")
			if kind == "cancel" { // A very short total call bound is enough; no second child.
				cfg := &config.Config{}
				cfg.AI.Provider = "claude"
				cfg.AI.Fallback = config.AIFallbackConfig{Enabled: true, Provider: "codex"}
				gen = providerrouting.WrapGenerator(cfg, p, func(id string) digest.Generator {
					if id == "claude" {
						return p
					}
					return r
				}, providerrouting.GeneratorOptions{Timeout: time.Millisecond, Router: &providerrouting.Router{Allowed: func(string) error { return nil }}})
			}
			run := runSDK(t, `try{llm("task")}catch(e){};return 1`, sdkCase{perms: []string{"llm:light"}, backends: &automations.Backends{Generator: gen}, meter: meter})
			require.Zero(t, r.calls)
			if kind == "both_wait" {
				require.Zero(t, p.calls)
				require.Zero(t, run.env.Journal.Totals().InputTokens)
			} else {
				require.Equal(t, 1, p.calls)
				require.Equal(t, int64(200), run.env.Journal.Totals().InputTokens)
			}
		})
	}
}

func TestBuiltinRoutingOneStepAndLegacyUsage(t *testing.T) {
	for _, kind := range []string{"routed", "unknown", "legacy"} {
		t.Run(kind, func(t *testing.T) {
			p, r := routedLeaves(kind == "unknown")
			gen := routedSDKGenerator(t, p, r, false)
			f := newExFixture(t, exOpts{backends: func(_ *exFixture, b *automations.Backends) {
				b.Primitives = map[string]automations.PrimitiveFunc{"brief.compose": func(ctx context.Context, _ automations.PrimitiveCall) (automations.PrimitiveResult, error) {
					if kind == "legacy" {
						return automations.PrimitiveResult{Status: "done", Usage: automations.PrimitiveUsage{InputTokens: 42}}, nil
					}
					_, _, _, err := gen.Generate(ctx, "system", "serialized input", "")
					return automations.PrimitiveResult{Status: "done", Usage: automations.PrimitiveUsage{InputTokens: 300, OutputTokens: 10}}, err
				}}
			}})
			a := f.seedBuiltin(t, builtinRecipeText(`brief.compose({prompt:"P"})`, "", "builtin:brief.compose"), true)
			run := f.runBuiltin(t, a, db.TriggerSync, "")
			require.Len(t, f.steps(t, run.ID), 1)
			switch kind {
			case "routed":
				require.Equal(t, db.RunSucceeded, run.Status)
				require.Equal(t, int64(500), run.InputTokens)
				require.Equal(t, int64(15), run.OutputTokens)
			case "unknown":
				require.Equal(t, db.RunFailed, run.Status)
				require.True(t, run.TokensEstimated)
				require.Positive(t, run.InputTokens)
				require.Zero(t, r.calls)
			case "legacy":
				require.Equal(t, int64(42), run.InputTokens)
			}
		})
	}
}

func TestBuiltinRoutingParallelWorkersShareInputReservation(t *testing.T) {
	p, r := routedLeaves(false)
	p.fail = false
	p.usage = &digest.Usage{InputTokens: 10, OutputTokens: 2}
	started, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	p.after = func(ctx context.Context) {
		once.Do(func() { close(started) })
		select {
		case <-release:
		case <-ctx.Done():
		}
	}
	gen := routedSDKGenerator(t, p, r, false)
	f := newExFixture(t, exOpts{backends: func(_ *exFixture, b *automations.Backends) {
		b.Primitives = map[string]automations.PrimitiveFunc{"brief.compose": func(ctx context.Context, _ automations.PrimitiveCall) (automations.PrimitiveResult, error) {
			ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
			defer cancel()
			first := make(chan error, 1)
			go func() { _, _, _, err := gen.Generate(ctx, strings.Repeat("x", 4000), "", ""); first <- err }()
			<-started
			_, _, _, secondErr := gen.Generate(ctx, strings.Repeat("x", 4000), "", "")
			close(release)
			firstErr := <-first
			if firstErr != nil {
				return automations.PrimitiveResult{}, firstErr
			}
			var budget *automations.SDKError
			if !errors.As(secondErr, &budget) || budget.Name != automations.ErrNameBudget {
				return automations.PrimitiveResult{}, fmt.Errorf("second worker error: %v", secondErr)
			}
			return automations.PrimitiveResult{Status: "done", Usage: automations.PrimitiveUsage{InputTokens: 10, OutputTokens: 2}}, nil
		}}
	}})
	a := f.seedBuiltin(t, builtinRecipeText(`brief.compose({prompt:"P"})`, "budget: {tokens: 1500}\n", "builtin:brief.compose"), true)
	run := f.runBuiltin(t, a, db.TriggerSync, "")
	require.Equal(t, db.RunSucceeded, run.Status, run.Error)
	require.Equal(t, 1, p.calls)
	require.Zero(t, r.calls)
	require.Equal(t, int64(10), run.InputTokens)
	require.Equal(t, int64(2), run.OutputTokens)
	require.Len(t, f.steps(t, run.ID), 1)
}

func TestLLMRoutingUnknownSuccessIsEstimated(t *testing.T) {
	p, r := routedLeaves(true)
	p.fail = false
	p.replies = []string{"partial"}
	gen := routedSDKGenerator(t, p, r, false)
	run := mustReturn(t, `return llm("task")`, sdkCase{perms: []string{"llm:light"}, backends: &automations.Backends{Generator: gen}}, "partial")
	require.Equal(t, 1, p.calls)
	require.Zero(t, r.calls)
	usage := run.env.Journal.Totals()
	require.True(t, usage.Estimated)
	require.Positive(t, usage.InputTokens)
	require.Positive(t, usage.OutputTokens)
	require.Nil(t, usage.ReportedCostUSD)
}

func TestLLMRoutingSchemaRetryUsesRemainingBudget(t *testing.T) {
	p, r := routedLeaves(false)
	p.fail = false
	p.usage = &digest.Usage{InputTokens: 300, OutputTokens: 10}
	p.replies = []string{"invalid"}
	gen := routedSDKGenerator(t, p, r, false)
	meter := automations.NewMeter(automations.Budget{Tokens: 400, Minutes: 5}, nil)
	run := mustReturn(t, `try {llm("task",{schema:{type:"object"}})} catch(e){return e.name}`, sdkCase{perms: []string{"llm:light"}, backends: &automations.Backends{Generator: gen}, meter: meter}, automations.ErrNameBudget)
	require.Equal(t, 1, p.calls)
	require.Zero(t, r.calls)
	require.Len(t, run.env.Journal.Steps(), 1)
	require.Equal(t, int64(300), run.env.Journal.Totals().InputTokens)
	require.Equal(t, 90, meter.Remaining().Tokens)
}
