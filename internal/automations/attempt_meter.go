package automations

import (
	"context"
	"errors"
	"sync"

	"watchtower/internal/providerrouting"
	"watchtower/internal/providers"
)

// meteredAttempts gives physical routed calls ownership of accounting. Legacy
// generators and primitives that never enter routing retain their aggregate.
func (e *Env) meteredAttempts(step *Step, call func(context.Context) (ModelUsage, error)) error {
	h := &attemptMeter{env: e, step: step, reservations: map[providerrouting.Attempt]int64{}}
	defer h.release()
	return e.MeteredModelCall(step, func(ctx context.Context) (ModelUsage, error) {
		u, err := call(providerrouting.WithAttemptHook(ctx, h))
		h.mu.Lock()
		owned := h.routed
		h.mu.Unlock()
		if owned {
			return ModelUsage{}, err
		}
		if err != nil && u.Estimated {
			e.Meter.markUnknown()
		}
		return u, err
	})
}

type attemptMeter struct {
	mu           sync.Mutex
	env          *Env
	step         *Step
	routed       bool
	reservations map[providerrouting.Attempt]int64
}

// RoutingStarted distinguishes a routed refusal (zero children) from legacy usage.
func (h *attemptMeter) RoutingStarted() {
	h.mu.Lock()
	h.routed = true
	h.mu.Unlock()
}

func (h *attemptMeter) Before(ctx context.Context, a providerrouting.Attempt) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	input := int64(a.InputBytes+3) / 4
	if err := h.env.Meter.admitAttempt(input); err != nil {
		return err
	}
	h.reservations[a] = input
	return nil
}

func (h *attemptMeter) After(_ context.Context, a providerrouting.Attempt, o providerrouting.Outcome) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.routed = true
	u := ModelAttemptUsage(a, o)
	h.env.Meter.settleAttempt(h.reservations[a], u.InputTokens, u.OutputTokens, o.Err != nil && u.Estimated)
	delete(h.reservations, a)
	h.step.Usage(u.InputTokens, u.OutputTokens, u.Estimated, u.ReportedUSD)
	return nil
}

// A cancellation between Before and dispatch owes no usage but releases input.
func (h *attemptMeter) release() {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, input := range h.reservations {
		h.env.Meter.releaseAttempt(input)
	}
	clear(h.reservations)
}

// ModelAttemptUsage converts leaf facts once, falling back to available submitted
// input and partial output. Result usage is not added to the same leaf facts.
// Estimated prices remain in the leaf ledger; ReportedUSD is provider-reported.
func ModelAttemptUsage(a providerrouting.Attempt, o providerrouting.Outcome) ModelUsage {
	if len(o.Calls) == 0 {
		return modelUsage(o.Result.Usage, a.InputBytes, len(o.Result.Text))
	}
	var u ModelUsage
	for _, c := range o.Calls {
		// The budget debits fresh input plus output, as the unrouted path
		// does; cache reads and writes stay in the leaf ledger only
		// (docs/features/automations.md#budgets).
		in := c.Input
		// Non-estimated leaf facts include authoritative reported zeros and
		// children that never started. Only a leaf that reported nothing at
		// all, cache included, and is estimated gets input and partial-output
		// estimation here.
		reported := c.AllInput() + c.Output
		if reported == 0 && c.Estimated {
			estimate := modelUsage(nil, a.InputBytes, len(o.Result.Text))
			in, c.Output, c.Estimated = estimate.InputTokens, estimate.OutputTokens, true
		}
		u.InputTokens += in
		u.OutputTokens += c.Output
		u.Estimated = u.Estimated || c.Estimated
		if cost := c.ReportedCostUSD; cost != nil {
			if u.ReportedUSD == nil {
				v := 0.0
				u.ReportedUSD = &v
			}
			*u.ReportedUSD += *cost
		}
	}
	return u
}

// modelCallError preserves admission and policy errors across SDK wrappers.
func modelCallError(err error, name, prefix string) error {
	var sdk *SDKError
	var interrupted *RunInterrupted
	if errors.As(err, &sdk) || errors.As(err, &interrupted) {
		return err
	}
	var failure *providers.Failure
	if errors.As(err, &failure) && failure.Category == providers.Policy {
		return PolicyError(err)
	}
	return &SDKError{Name: name, Message: prefix + err.Error()}
}
