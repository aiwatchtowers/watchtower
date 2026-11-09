package providers

import (
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"net"
	"os/exec"
	"strings"
	"time"
)

// ErrorCategory separates subscription exhaustion from transient limits and
// request failures. Only Quota permits a future quota-based routing decision.
type ErrorCategory string

const (
	Quota         ErrorCategory = "subscription_quota"
	RateLimit     ErrorCategory = "rate_limit"
	Overload      ErrorCategory = "overload"
	Auth          ErrorCategory = "auth"
	Model         ErrorCategory = "model"
	Policy        ErrorCategory = "policy"
	ContextLimit  ErrorCategory = "context"
	Budget        ErrorCategory = "budget"
	Cancelled     ErrorCategory = "cancelled"
	Timeout       ErrorCategory = "timeout"
	Transport     ErrorCategory = "transport"
	InvalidOutput ErrorCategory = "invalid_output"
	Capability    ErrorCategory = "capability"
	Unknown       ErrorCategory = "unknown"
)

// Failure retains the original diagnostic/cause. Scope hints never contain
// credentials or account identifiers; a missing reset remains unknown.
type Failure struct {
	Provider string
	Category ErrorCategory
	ResetAt  time.Time
	Scope    string
	Bucket   string
	Window   string
	Required InvocationProfile
	Cause    error
}

func (e *Failure) Error() string {
	if e.Cause != nil {
		return e.Cause.Error()
	}
	return string(e.Category)
}
func (e *Failure) Unwrap() error { return e.Cause }
func WithFailure(provider string, category ErrorCategory, cause error) error {
	return &Failure{Provider: provider, Category: category, Cause: cause}
}

// FailureDetail is accepted only inside a trusted CLI terminal failure event,
// never from assistant text, tool results, stderr or successful result content.
type FailureDetail struct {
	Type     string `json:"type"`
	Code     string `json:"code"`
	Message  string `json:"message"`
	ResetsAt int64  `json:"resets_at"`
}

// TerminalFailure normalizes an identified CLI failure envelope. The caller
// establishes event identity and keeps its existing redacted diagnostic in cause.
func TerminalFailure(provider string, detail FailureDetail, status int, cause error) error {
	category := Unknown
	code := detail.Code
	if code == "" {
		code = detail.Type
	}
	switch code {
	case "usage_limit_reached":
		category = Quota
	case "rate_limit_error", "rate_limit_exceeded":
		category = RateLimit
	case "overloaded_error", "server_overloaded":
		category = Overload
	case "authentication_error", "invalid_api_key":
		category = Auth
	case "model_not_found", "model_not_supported":
		category = Model
	case "permission_error", "policy_denied", "content_filter":
		category = Policy
	case "context_length_exceeded", "context_window_exceeded":
		category = ContextLimit
	case "error_max_turns", "error_max_budget_usd", "budget_exceeded", "session_budget_exceeded":
		category = Budget
	case "cancelled", "interrupted", "turn_aborted":
		category = Cancelled
	case "request_timeout", "timeout_error":
		category = Timeout
	case "connection_error", "internal_server_error":
		category = Transport
	case "invalid_output", "error_max_structured_output_retries":
		category = InvalidOutput
	}
	// A trusted HTTP authentication/authorization refusal wins over a
	// conflicting quota code; it never admits quota-based routing.
	if status == 401 {
		category = Auth
	} else if status == 403 {
		category = Policy
	}
	if category == Unknown {
		switch status {
		case 429:
			category = RateLimit
		case 529, 503:
			category = Overload
		}
	}
	if category == Unknown {
		var existing *Failure
		if errors.As(cause, &existing) && existing.Category == Model {
			return cause
		}
		category = diagnosticCategory(detail.Message)
	}
	e := &Failure{Provider: provider, Category: category, Cause: cause}
	if category == Quota {
		e.Scope = "installation"
		e.ResetAt = resetTime(detail.ResetsAt)
	}
	return e
}

// ClaudeFailure requires the CLI's own result event plus its explicit failure
// bit. Legacy untyped envelopes remain errors, but cannot establish quota.
func ClaudeFailure(eventType, subtype string, isError bool, raw json.RawMessage, cause error) error {
	if eventType != "result" || !isError {
		return WithFailure("claude", Unknown, cause)
	}
	var detail FailureDetail
	if subtype != "error_during_execution" && subtype != "success" {
		return TerminalFailure("claude", FailureDetail{Type: subtype}, 0, cause)
	}
	_ = json.Unmarshal(raw, &detail)
	if detail.Type == "" && detail.Code == "" {
		detail.Type = subtype
	}
	return TerminalFailure("claude", detail, 0, cause)
}

// ContextFailure keeps cancellation authoritative over any late CLI envelope.
func ContextFailure(provider string, ctx context.Context, cause error) error {
	if ctx.Err() == nil {
		return cause
	}
	category := Cancelled
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		category = Timeout
	}
	return WithFailure(provider, category, errors.Join(cause, ctx.Err()))
}

// CleanExitFailure types a CLI run that exited 0 without its completion
// (a missing result line or event, gap L12): the category its stderr names
// when one of its lines is a narrow CLI diagnostic (diagnosticCategory: auth,
// rate limit, overload or policy, never quota) — "sign in" or "wait" helps
// the owner more — else InvalidOutput. The last such line wins.
func CleanExitFailure(provider, stderr string, cause error) error {
	lines := strings.Split(stderr, "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if category := diagnosticCategory(lines[i]); category != Unknown {
			return WithFailure(provider, category, cause)
		}
	}
	return WithFailure(provider, InvalidOutput, cause)
}

// diagnosticCategory deliberately has no quota dictionary. A human sentence
// alone cannot prove subscription exhaustion. These narrow CLI diagnostics
// remain distinct from confirmed machine-coded subscription failures.
func diagnosticCategory(message string) ErrorCategory {
	m := strings.ToLower(strings.TrimSpace(message))
	switch {
	case diagnosticStatus(m, "429"), m == "rate limit exceeded":
		return RateLimit
	case m == "overloaded", diagnosticStatus(m, "529"):
		return Overload
	case diagnosticStatus(m, "401"), m == "invalid api key · please run /login", m == "not logged in · please run /login":
		return Auth
	case diagnosticStatus(m, "403"):
		return Policy
	}
	return Unknown
}

// ProcessFailure types operating-system failures without inspecting model or
// tool text. Existing typed terminal errors retain priority over exit status.
func ProcessFailure(provider string, cause error) error {
	if cause == nil {
		return nil
	}
	var failure *Failure
	if errors.As(cause, &failure) {
		return cause
	}
	category := Unknown
	var execErr *exec.Error
	var pathErr *fs.PathError
	var exitErr *exec.ExitError
	var opErr *net.OpError
	switch {
	case errors.Is(cause, context.Canceled):
		category = Cancelled
	case errors.Is(cause, context.DeadlineExceeded):
		category = Timeout
	case errors.As(cause, &execErr), errors.As(cause, &pathErr), errors.As(cause, &opErr):
		category = Transport
	case errors.As(cause, &exitErr) && !exitErr.Exited():
		category = Transport
	}
	return WithFailure(provider, category, cause)
}

func diagnosticStatus(message, status string) bool {
	prefix := "api error: " + status
	return message == prefix || strings.HasPrefix(message, prefix+" ") || strings.HasPrefix(message, prefix+":")
}
