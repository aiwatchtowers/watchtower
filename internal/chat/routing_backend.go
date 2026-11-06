package chat

import (
	"context"
	"errors"
	"sync"

	"watchtower/internal/providerrouting"
	"watchtower/internal/providers"
)

// RoutingOptions keeps selection and construction separate: even a warm
// backend's Start must wait until the pending turn's capabilities are known.
type RoutingOptions struct {
	Router          *providerrouting.Router
	Select          func(context.Context, Command) (providerrouting.Request, string, error)
	Build           func(context.Context, string, string) (Backend, error)
	Selected        func(string, string, string) error
	Mode, Preferred string
}

type routingBackend struct {
	opts            RoutingOptions
	mu              sync.Mutex
	backend         Backend
	provider, model string
	closed          bool
	turnCancel      context.CancelFunc
}

func NewRoutingBackend(opts RoutingOptions) Backend { return &routingBackend{opts: opts} }

// Start intentionally launches no provider. Turn is the first point where
// attachment requirements and the current policy can both be checked.
func (b *routingBackend) Start(ctx context.Context) (string, error) { return "", ctx.Err() }

func (b *routingBackend) RoutingEvent() Event {
	return Event{Type: EventSessionReady, PreferredProvider: b.opts.Preferred, RoutingMode: b.opts.Mode}
}

func (b *routingBackend) Turn(ctx context.Context, cmd Command, emit func(Event)) (resultErr error) {
	turnCtx, cancel := context.WithCancel(ctx)
	ctx = turnCtx
	b.mu.Lock()
	b.turnCancel = cancel
	b.mu.Unlock()
	defer func() { cancel(); b.mu.Lock(); b.turnCancel = nil; b.mu.Unlock() }()
	terminal := false
	originalEmit := emit
	emit = func(e Event) {
		if isTerminal(e) {
			terminal = true
		}
		originalEmit(e)
	}
	defer func() {
		if resultErr != nil && !terminal {
			e := fallbackTerminal(ctx, cmd.TurnID, resultErr)
			e.Retryable = false
			e.Reason = routingErrorReason(resultErr)
			e.RoutingMode = b.opts.Mode
			e.PreferredProvider = b.opts.Preferred
			emit(e)
		}
	}()

	req, reason, err := b.opts.Select(ctx, cmd)
	if err != nil {
		return err
	}
	provider, err := b.opts.Router.Select(ctx, req)
	if err != nil {
		return err
	}
	model := ""
	if req.Model != nil {
		model = req.Model(provider, req.Tier)
	}
	if provider != req.Preferred {
		reason = "quota_exhausted"
	}
	if b.opts.Selected != nil {
		if err := b.opts.Selected(provider, model, reason); err != nil {
			return err
		}
	}
	// Select checks known health; Run is pinned to that single child/turn and
	// only supplies existing attempt linkage and typed outcome health recording.
	req.Preferred, req.Mode, req.Retry = provider, providerrouting.Pinned, providerrouting.Never
	_, err = b.opts.Router.Run(ctx, req, func(callCtx context.Context, _ providerrouting.Attempt) (providerrouting.Result, error) {
		backend, startErr := b.prepare(callCtx, provider, model)
		if startErr != nil {
			return providerrouting.Result{}, startErr
		}
		emit(Event{Type: EventSessionReady, Provider: provider, Model: model, PreferredProvider: b.opts.Preferred, RoutingMode: b.opts.Mode, Reason: reason})
		var cause error
		turnErr := backend.Turn(callCtx, cmd, func(e Event) {
			e.Provider, e.Model, e.PreferredProvider, e.RoutingMode, e.Reason = provider, model, b.opts.Preferred, b.opts.Mode, reason
			if e.Cause != nil {
				cause = e.Cause
				e.Reason = routingErrorReason(e.Cause)
				if e.Reason == "quota_exhausted" {
					e.Retryable = false
				}
			}
			emit(e)
		})
		return providerrouting.Result{}, errors.Join(turnErr, cause)
	})
	return err
}

func (b *routingBackend) prepare(ctx context.Context, provider, model string) (Backend, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return nil, errors.New("chat session closed")
	}
	if b.backend != nil && (provider != b.provider || model != b.model) {
		if err := b.backend.Close(); err != nil {
			return nil, err
		}
		b.backend = nil
	}
	if b.backend == nil {
		backend, err := b.opts.Build(ctx, provider, model)
		if err != nil {
			return nil, err
		}
		b.backend = backend
		b.provider, b.model = provider, model
		if _, err := backend.Start(ctx); err != nil {
			_ = backend.Close()
			b.backend = nil
			return nil, err
		}
	}
	return b.backend, nil
}

// Cancelling an auto session retires the child. Its next turn replays the
// persisted path, so a late terminal event cannot be mistaken for a new turn.
func (b *routingBackend) Cancel() error {
	b.mu.Lock()
	if b.turnCancel != nil {
		b.turnCancel()
	}
	backend := b.backend
	b.backend = nil
	b.mu.Unlock()
	if backend != nil {
		return errors.Join(backend.Cancel(), backend.Close())
	}
	return nil
}

func (b *routingBackend) Close() error {
	b.mu.Lock()
	b.closed = true
	if b.turnCancel != nil {
		b.turnCancel()
	}
	backend := b.backend
	b.mu.Unlock()
	if backend != nil {
		return backend.Close()
	}
	return nil
}

func routingErrorReason(err error) string {
	if errors.Is(err, context.Canceled) {
		return "cancelled"
	}
	if errors.Is(err, providerrouting.ErrDeferred) {
		return "quota_wait"
	}
	var f *providers.Failure
	if errors.As(err, &f) {
		switch f.Category {
		case providers.Quota:
			return "quota_exhausted"
		case providers.Capability:
			return "required_capability_missing"
		case providers.Policy:
			return "policy_denied"
		case providers.Auth:
			return "auth_required"
		case providers.Model:
			return "model_unavailable"
		case providers.Transport:
			return "transport_error"
		case providers.InvalidOutput:
			return "invalid_output"
		case providers.Budget:
			return "budget_exhausted"
		case providers.Cancelled:
			return "cancelled"
		case providers.RateLimit, providers.Overload, providers.ContextLimit, providers.Timeout, providers.Unknown:
			return "turn_already_started"
		}
	}
	return ""
}
