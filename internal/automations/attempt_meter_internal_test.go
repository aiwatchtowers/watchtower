package automations

import (
	"context"
	"errors"
	"testing"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/digest"
	"watchtower/internal/providerrouting"
	"watchtower/internal/providers"
)

func TestAttemptReservationReleasedWithoutDispatch(t *testing.T) {
	meter := NewMeter(Budget{Tokens: 100, Minutes: 1}, nil)
	env := &Env{Ctx: context.Background(), Meter: meter}
	h := &attemptMeter{env: env, step: NewMemoryJournal().Begin(StepKindLLM, "light", nil), reservations: map[providerrouting.Attempt]int64{}}
	a := providerrouting.Attempt{InputBytes: 300, Number: 1}
	if err := h.Before(context.Background(), a); err != nil {
		t.Fatal(err)
	}
	h.release() // Router cancellation between admission and invocation has no After.
	h.release() // Cleanup is idempotent, with no debit or fake leaf.
	if err := h.Before(context.Background(), a); err != nil {
		t.Fatal(err)
	}
	h.release()
	if got := meter.Remaining().Tokens; got != 100 {
		t.Fatalf("remaining=%d", got)
	}
	if got := h.step.j.Totals(); got.InputTokens+got.OutputTokens != 0 {
		t.Fatalf("usage=%+v", got)
	}
}

func TestMeterActiveDeadlineHasSubminutePrecision(t *testing.T) {
	// The active clock may be unrelated to the wall clock of context deadlines.
	c := &attemptClock{now: time.Date(2000, 1, 1, 0, 0, 0, 0, time.UTC)}
	meter := NewMeter(Budget{Tokens: 100, Minutes: 1}, c)
	c.now = c.now.Add(59 * time.Second)
	if err := meter.BeforeCall(); err != nil {
		t.Fatal(err)
	}
	c.now = c.now.Add(time.Second)
	var interrupted *RunInterrupted
	if err := meter.BeforeCall(); !errors.As(err, &interrupted) || interrupted.Reason != InterruptTimeout {
		t.Fatalf("error=%v", err)
	}
}

type attemptClock struct{ now time.Time }

func (c *attemptClock) Now() time.Time                     { return c.now }
func (*attemptClock) After(time.Duration) <-chan time.Time { return nil } // never fires: the test reads Now only

func TestReplayUsageMetadataLegacyAndStrictEnvelope(t *testing.T) {
	legacy := `[1000,2000]`
	j := NewMemoryJournal()
	step := j.Begin(StepKindLLM, "light", nil)
	step.record("hash", legacy, true)
	step.recordOutcome(encodedResult(`"done"`), nil, false)
	if step.rec.ClockJSON != legacy {
		t.Fatal("normal clock record changed")
	}
	reads, unknown, err := decodeReplayMetadata(legacy)
	if err != nil || unknown || len(reads) != 2 || reads[0] != 1000 {
		t.Fatalf("legacy: %v %v %v", reads, unknown, err)
	}
	encoded, err := withUnknownModelUsage(legacy)
	if err != nil {
		t.Fatal(err)
	}
	reads, unknown, err = decodeReplayMetadata(encoded)
	if err != nil || !unknown || len(reads) != 2 || reads[1] != 2000 {
		t.Fatalf("envelope: %v %v %v", reads, unknown, err)
	}
	for _, bad := range []string{`null`, `{}`, `{"version":2,"reads":[],"unknown_model_usage":true}`, `{"version":1,"reads":null,"unknown_model_usage":true}`, `{"version":1,"reads":[],"unknown_model_usage":false}`, `{"version":1,"reads":[1.5],"unknown_model_usage":true}`, `{"version":1,"reads":[],"unknown_model_usage":"true"}`, `{"version":1,"reads":[],"unknown_model_usage":true,"extra":1}`, encoded + ` []`} {
		if _, _, err := decodeReplayMetadata(bad); err == nil {
			t.Fatalf("accepted corrupt metadata %q", bad)
		}
	}
}

func TestReplayUsageMetadataCountsAgainstExistingCap(t *testing.T) {
	previous := MaxReplayLogBytes
	MaxReplayLogBytes = 50
	t.Cleanup(func() { MaxReplayLogBytes = previous })
	j := NewMemoryJournal()
	step := j.Begin(StepKindLLM, "light", nil)
	step.record("hash", "[]", true)
	step.recordOutcome(encodedResult(`"done"`), nil, true)
	if !j.replayOff {
		t.Fatal("metadata was not counted against the existing replay cap")
	}
	if _, _, err := decodeReplayMetadata(string(make([]byte, 51))); err == nil {
		t.Fatal("oversized metadata accepted")
	}
}

// The logical primitive can catch a physical model failure and return success;
// the execution metadata must retain the meter fact independently of its value.
func TestSuccessfulPrimitiveRecordsUnknownUsageMetadata(t *testing.T) {
	leaf := &replayUnknownLeaf{}
	cfg := &config.Config{}
	cfg.AI.Provider = "claude"
	cfg.AI.Fallback = config.AIFallbackConfig{Enabled: true, Provider: "codex"}
	gen := providerrouting.WrapGenerator(cfg, leaf, func(string) digest.Generator { return leaf }, providerrouting.GeneratorOptions{Router: &providerrouting.Router{Allowed: func(string) error { return nil }}})
	env := &Env{Ctx: context.Background(), Meter: NewMeter(Budget{Tokens: 5000, Minutes: 5}, nil), Journal: NewMemoryJournal(), Replay: newRecorder()}
	var captured *Step
	value, err := env.Call(StepKindLLM, "primitive", nil, func(step *Step) (any, error) {
		captured = step
		err := env.meteredAttempts(step, func(ctx context.Context) (ModelUsage, error) {
			_, _, _, _ = gen.Generate(ctx, "actual system", "actual user", "")
			return ModelUsage{}, nil
		})
		return "done", err
	})
	if err != nil || string(value.(encodedResult)) != `"done"` {
		t.Fatalf("result=%v error=%v", value, err)
	}
	if leaf.calls != 1 {
		t.Fatalf("model calls=%d", leaf.calls)
	}
	if captured.rec.ErrorJSON != "" || captured.rec.ResultJSON == nil || *captured.rec.ResultJSON != `"done"` {
		t.Fatalf("outcome=%+v", captured.rec)
	}
	_, unknown, err := decodeReplayMetadata(captured.rec.ClockJSON)
	if err != nil || !unknown {
		t.Fatalf("metadata=%q error=%v", captured.rec.ClockJSON, err)
	}
	if env.Journal.Steps()[0].Status != StepOK {
		t.Fatal("successful primitive was changed to an error")
	}
}

type replayUnknownLeaf struct{ calls int }

func (g *replayUnknownLeaf) Generate(context.Context, string, string, string) (string, *digest.Usage, string, error) {
	g.calls++
	return "partial", nil, "", &providers.Failure{Provider: "claude", Category: providers.Quota}
}
