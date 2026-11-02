package planusage

import (
	"context"
	"errors"
	"log"
	"path/filepath"
	"sync"
	"time"

	"watchtower/internal/codex"
	"watchtower/internal/fsutil"
)

// OperationError is safe to expose: source payloads and filesystem paths never
// become public diagnostics. Cause is kept only for errors.Is/As internally.
type OperationError struct {
	Code  string
	Cause error
}

func (e *OperationError) Error() string { return "plan usage: " + e.Code }
func (e *OperationError) Unwrap() error { return e.Cause }

// ErrorCode maps an operation to the closed public error vocabulary.
func ErrorCode(err error) string {
	var op *OperationError
	var ce *codex.UsageError
	var he *HTTPError
	var pe *parseError
	switch {
	case err == nil:
		return ""
	case errors.As(err, &op):
		return op.Code
	case errors.Is(err, context.DeadlineExceeded):
		return "timeout"
	case errors.Is(err, context.Canceled):
		return "cancelled"
	case errors.As(err, &ce):
		return ce.Code
	case errors.Is(err, ErrNoCredentials):
		return "no_credentials"
	case errors.As(err, &he):
		if he.Status == 401 {
			return "no_credentials"
		}
		return "network"
	case errors.As(err, &pe):
		return "parse"
	default:
		return "storage"
	}
}

// Provider serializes every production writer for one workspace/subscription.
// Poll is the entire fetch + publication, and is invoked only while locked.
type Provider struct {
	Name         string
	Workspace    string
	Enabled      func() (bool, error)
	Poll         func(context.Context) (time.Duration, error)
	MarkDisabled func(context.Context) error
	Logger       *log.Logger
	Budget       time.Duration
	LockWait     time.Duration
	// After is the scheduling seam; tests advance it without real minutes.
	After  func(time.Duration) <-chan time.Time
	pollMu sync.Mutex // Also establishes Go memory ordering for in-process callers.
}

func (p *Provider) lockPath() string {
	return filepath.Join(p.Workspace, ".plan-usage-"+p.Name+".lock")
}

func (p *Provider) enabled() (bool, error) {
	if p.Enabled == nil {
		return true, nil
	}
	return p.Enabled()
}

// PollOnce is the daemon path: contention is a normal skipped five-minute tick.
func (p *Provider) PollOnce(ctx context.Context) (time.Duration, error) { return p.poll(ctx, false) }

// Refresh waits for this provider only, within a single bounded operation.
func (p *Provider) Refresh(ctx context.Context) error { _, err := p.poll(ctx, true); return err }

func (p *Provider) poll(parent context.Context, manual bool) (time.Duration, error) {
	budget := p.Budget
	if budget <= 0 {
		budget = 45 * time.Second
	}
	ctx, cancel := context.WithTimeout(parent, budget)
	defer cancel()
	if err := ctx.Err(); err != nil {
		return pollInterval, &OperationError{Code: ErrorCode(err), Cause: err}
	}
	var unlock func()
	var err error
	if manual {
		wait := p.LockWait
		if wait <= 0 {
			wait = 20 * time.Second
		}
		lockCtx, stop := context.WithTimeout(ctx, wait)
		unlock, err = fsutil.LockFile(lockCtx, p.lockPath())
		stop()
		if err != nil {
			code := "storage"
			if ctx.Err() != nil {
				code = ErrorCode(ctx.Err())
			} else if errors.Is(err, context.DeadlineExceeded) {
				code = "busy"
			}
			return pollInterval, &OperationError{Code: code, Cause: err}
		}
	} else {
		var ok bool
		unlock, ok, err = fsutil.TryLockFile(p.lockPath())
		if err != nil {
			return pollInterval, &OperationError{Code: "storage", Cause: err}
		}
		if !ok {
			return pollInterval, &OperationError{Code: "busy"}
		}
	}
	defer unlock()
	if err := ctx.Err(); err != nil {
		return pollInterval, &OperationError{Code: ErrorCode(err), Cause: err}
	}
	enabled, err := p.enabled() // Re-read after acquiring the writer lock.
	if err != nil {
		return pollInterval, &OperationError{Code: "storage", Cause: err}
	}
	if err := ctx.Err(); err != nil {
		return pollInterval, &OperationError{Code: ErrorCode(err), Cause: err}
	}
	if !enabled {
		if !manual && p.MarkDisabled != nil {
			if err := p.MarkDisabled(ctx); err != nil {
				return pollInterval, &OperationError{Code: "storage", Cause: err}
			}
		}
		return pollInterval, &OperationError{Code: "feature_disabled"}
	}
	p.pollMu.Lock()
	delay, err := p.Poll(ctx)
	p.pollMu.Unlock()
	if ctx.Err() != nil {
		return pollInterval, &OperationError{Code: ErrorCode(ctx.Err()), Cause: ctx.Err()}
	}
	return delay, err
}

// Disable uses the same stable inode as daemon and CLI refreshes.
func (p *Provider) Disable(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	if err := ctx.Err(); err != nil {
		return &OperationError{Code: ErrorCode(err), Cause: err}
	}
	unlock, err := fsutil.LockFile(ctx, p.lockPath())
	if err != nil {
		return &OperationError{Code: ErrorCode(err), Cause: err}
	}
	defer unlock()
	if err := ctx.Err(); err != nil {
		return &OperationError{Code: ErrorCode(err), Cause: err}
	}
	if p.MarkDisabled != nil {
		return p.MarkDisabled(ctx)
	}
	return nil
}

func (p *Provider) Run(ctx context.Context) error {
	after := p.After
	if after == nil {
		after = time.After
	}
	delay := firstPollDelay
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-after(delay):
		}
		next, err := p.PollOnce(ctx)
		if ctx.Err() != nil {
			return nil
		}
		if err != nil && ErrorCode(err) != "busy" && ErrorCode(err) != "feature_disabled" && p.Logger != nil {
			p.Logger.Printf("%s plan usage: %s (next poll in %s)", p.Name, ErrorCode(err), next)
		}
		delay = next
	}
}

// Providers runs independent clocks and waits for both on shutdown.
type Providers []*Provider

func (ps Providers) Run(ctx context.Context) error {
	var wg sync.WaitGroup
	for _, p := range ps {
		wg.Add(1)
		go func() { defer wg.Done(); _ = p.Run(ctx) }()
	}
	wg.Wait()
	return nil
}

// CodexPoller stores only safe source codes; parent cancellation never publishes
// a source failure. Its backoff state is independent of Claude's poller.
type CodexPoller struct {
	Store    CodexStore
	Read     func(context.Context) (codex.UsageSnapshot, error)
	Now      func() time.Time
	failures int
}

func (p *CodexPoller) PollOnce(ctx context.Context) (time.Duration, error) {
	previousFailures := p.failures
	defer func() {
		if ctx.Err() != nil {
			p.failures = previousFailures
		}
	}()
	if err := ctx.Err(); err != nil {
		return pollInterval, err
	}
	if _, err := p.Store.GetCodexPlanUsageStatusContext(ctx); err != nil {
		return pollInterval, &OperationError{Code: "storage", Cause: err}
	}
	snapshot, err := p.Read(ctx)
	if ctx.Err() != nil {
		return pollInterval, ctx.Err()
	}
	if err == nil {
		if err := StoreCodexUsageContext(ctx, p.Store, p.Now(), snapshot); err != nil {
			return pollInterval, &OperationError{Code: "storage", Cause: err}
		}
		p.failures = 0
		return pollInterval, nil
	}
	code := ErrorCode(err)
	delay := pollInterval
	switch code {
	case "no_credentials", "unsupported_auth", "cli_missing", "unsupported_cli":
		p.failures = 0
	default:
		p.failures++
		delay = backoff(p.failures)
	}
	if err := StoreCodexFailureContext(ctx, p.Store, p.Now(), snapshot, code); err != nil {
		return delay, &OperationError{Code: "storage", Cause: err}
	}
	return delay, &OperationError{Code: code}
}
