package automations

import (
	"encoding/json"
	"fmt"
	"math/big"
	"slices"
	"sync"

	"watchtower/internal/db"
)

// CommitBuffer holds a run's state and outputs until the run ends: they are
// committed only with a succeeded run (AUTO-04). Reads see the committed
// state plus this run's own sets.
type CommitBuffer struct {
	mu      sync.Mutex
	state   map[string]json.RawMessage
	touched bool
	encoded json.RawMessage // the whole state as of the last successful Set
	outputs []db.AutomationOutput
	// removals are the living keys output.remove deletes, in call order.
	// A key is never both here and on a buffered output: the later of the
	// two calls wins (AddOutput, RemoveOutput).
	removals []string
	loadErr  error
}

// NewCommitBuffer starts from the automation's committed state (a JSON
// object; empty means {}). A state that does not decode as an object makes
// Set and Err fail, so a broken state is never overwritten silently.
func NewCommitBuffer(committedState json.RawMessage) *CommitBuffer {
	b := &CommitBuffer{state: map[string]json.RawMessage{}}
	if len(committedState) == 0 {
		return b
	}
	if err := json.Unmarshal(committedState, &b.state); err != nil {
		b.loadErr = fmt.Errorf("decoding the committed automation state: %w", err)
		b.state = map[string]json.RawMessage{}
	} else if b.state == nil { // the literal null
		b.state = map[string]json.RawMessage{}
	}
	return b
}

// Err is the committed state's decoding error, or nil.
func (b *CommitBuffer) Err() error { return b.loadErr }

// Get returns a fresh decoded copy of key's value.
func (b *CommitBuffer) Get(key string) (any, bool) {
	b.mu.Lock()
	raw, ok := b.state[key]
	b.mu.Unlock()
	if !ok {
		return nil, false
	}
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		return nil, false // unreachable: every stored value was marshalled by Set or decoded as JSON
	}
	return v, true
}

// Set buffers key = v. A value JSON cannot represent (a function, NaN,
// Infinity, a cycle, a BigInt) is a ValidationError; a state that would
// serialise beyond MaxStateBytes is StateTooLarge. Neither buffers anything.
func (b *CommitBuffer) Set(key string, v any) error {
	if b.loadErr != nil {
		return b.loadErr
	}
	raw, err := json.Marshal(v)
	if err != nil {
		return &SDKError{Name: ErrNameValidation, Message: fmt.Sprintf("state.set(%q): the value is not JSON: %v", key, err)}
	}
	if hasBigInt(v) {
		return &SDKError{Name: ErrNameValidation, Message: fmt.Sprintf("state.set(%q): a BigInt is not JSON", key)}
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	prev, had := b.state[key]
	b.state[key] = raw
	all, err := json.Marshal(b.state)
	size := len(all)
	if err != nil || size > MaxStateBytes {
		if had {
			b.state[key] = prev
		} else {
			delete(b.state, key)
		}
		if err != nil {
			return fmt.Errorf("measuring the automation state: %w", err)
		}
		return &SDKError{Name: ErrNameStateTooLarge,
			Message: fmt.Sprintf("the state would be %d bytes; the limit is %d", size, MaxStateBytes)}
	}
	b.touched, b.encoded = true, all
	return nil
}

// hasBigInt reports a *big.Int anywhere in v (json.Marshal would write it as
// a number). v has already marshalled, so it holds no cycle.
func hasBigInt(v any) bool {
	switch x := v.(type) {
	case *big.Int, big.Int:
		return true
	case map[string]any:
		for _, e := range x {
			if hasBigInt(e) {
				return true
			}
		}
	case []any:
		if slices.ContainsFunc(x, hasBigInt) {
			return true
		}
	}
	return false
}

// All returns a decoded copy of the whole state.
func (b *CommitBuffer) All() map[string]any {
	b.mu.Lock()
	defer b.mu.Unlock()
	out := make(map[string]any, len(b.state))
	for k, raw := range b.state {
		var v any
		if json.Unmarshal(raw, &v) == nil {
			out[k] = v
		}
	}
	return out
}

// AddOutput buffers an output; a body beyond MaxOutputBodyBytes is
// ResultTooLarge, an output past MaxOutputsPerRun a ValidationError. A
// living output (OutputKey set) replaces an earlier buffered output of its
// key and cancels a buffered removal of it — the later call wins — so the
// cap counts each kept output once.
func (b *CommitBuffer) AddOutput(o db.AutomationOutput) error {
	if len(o.Body) > MaxOutputBodyBytes {
		return &SDKError{Name: ErrNameResultTooLarge,
			Message: fmt.Sprintf("output body is %d bytes; the limit is %d", len(o.Body), MaxOutputBodyBytes)}
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if o.OutputKey != "" {
		if i := b.outputIndex(o.OutputKey); i >= 0 {
			b.outputs[i] = o
			return nil
		}
	}
	if len(b.outputs) >= MaxOutputsPerRun {
		return &SDKError{Name: ErrNameValidation,
			Message: fmt.Sprintf("this run already made %d outputs; the limit is %d per run", len(b.outputs), MaxOutputsPerRun)}
	}
	if o.OutputKey != "" {
		b.removals = slices.DeleteFunc(b.removals, func(k string) bool { return k == o.OutputKey })
	}
	b.outputs = append(b.outputs, o)
	return nil
}

// RemoveOutput buffers the removal of the living output key: it drops an
// earlier buffered output of the key (the later call wins) and records the
// key once. An empty key is a ValidationError.
func (b *CommitBuffer) RemoveOutput(key string) error {
	if key == "" {
		return &SDKError{Name: ErrNameValidation, Message: "a removal needs a key"}
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if i := b.outputIndex(key); i >= 0 {
		b.outputs = slices.Delete(b.outputs, i, i+1)
	}
	if !slices.Contains(b.removals, key) {
		b.removals = append(b.removals, key)
	}
	return nil
}

// outputIndex is the index of the buffered living output key, or -1. The
// caller holds b.mu.
func (b *CommitBuffer) outputIndex(key string) int {
	return slices.IndexFunc(b.outputs, func(o db.AutomationOutput) bool { return o.OutputKey == key })
}

// Outputs returns the buffered outputs in order.
func (b *CommitBuffer) Outputs() []db.AutomationOutput {
	b.mu.Lock()
	defer b.mu.Unlock()
	return append([]db.AutomationOutput(nil), b.outputs...)
}

// Removals returns the buffered living-key removals in order.
func (b *CommitBuffer) Removals() []string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return append([]string(nil), b.removals...)
}

// Commit is what a succeeded run commits: StateJSON is nil when the run set
// nothing (the committed state stays as it is).
func (b *CommitBuffer) Commit() *db.RunCommit {
	b.mu.Lock()
	defer b.mu.Unlock()
	c := &db.RunCommit{Outputs: append([]db.AutomationOutput(nil), b.outputs...),
		Removals: append([]string(nil), b.removals...)}
	if b.touched {
		c.StateJSON = append(json.RawMessage(nil), b.encoded...)
	}
	return c
}
