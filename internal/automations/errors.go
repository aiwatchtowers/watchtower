package automations

import (
	"errors"
	"fmt"
)

// The JS Error.name values the SDK throws (spec §4). A script can catch every
// one of them; the run-ending interrupts (InterruptReason) are not errors the
// script ever sees.
const (
	ErrNamePermissionDenied = "PermissionDenied"
	ErrNameResultTooLarge   = "ResultTooLarge"
	ErrNameStateTooLarge    = "StateTooLarge"
	ErrNameValidation       = "ValidationError"
	ErrNameTool             = "ToolError"
	ErrNameBudget           = "BudgetExceeded"
	ErrNameNotAvailable     = "NotAvailable"
)

// SDKError is an error an SDK function returns to the script: it becomes a JS
// Error whose name is Name, with a `needed` property when Needed is set.
type SDKError struct {
	Name, Message, Needed string
}

func (e *SDKError) Error() string {
	if e.Message == "" {
		return e.Name
	}
	return e.Name + ": " + e.Message
}

// InterruptReason is why a run was stopped from outside the script.
type InterruptReason string

// Interrupt reasons. None of them is catchable by the script.
const (
	InterruptTimeout InterruptReason = "timeout"
	InterruptBudget  InterruptReason = "budget"
	InterruptCancel  InterruptReason = "cancel"
	// InterruptExpired: a wait outlasted the recipe's pause_timeout_hours
	// (the executor's Waiter returns it; the run ends expired).
	InterruptExpired InterruptReason = "expired"
	// InterruptDraftStop: a draft's in-memory dry run reached a call it
	// never makes (mcp(), ask #326); DryRunInMemory reports DryRunStopped.
	InterruptDraftStop InterruptReason = "draft_stop"
)

// RunInterrupted is what Sandbox.Run returns when an interrupt stopped the
// script. An SDK function may also return it (the Waiter on an expired
// wait): the sandbox then interrupts the run instead of throwing.
type RunInterrupted struct {
	Reason InterruptReason
	// Abandoned: the script goroutine was still inside a native builtin
	// AbandonGrace after the interrupt and was left behind (AbandonedRuns).
	Abandoned bool
}

func (e *RunInterrupted) Error() string {
	if e.Abandoned {
		return fmt.Sprintf("the run was interrupted (%s); its script goroutine did not stop and was abandoned", e.Reason)
	}
	return fmt.Sprintf("the run was interrupted (%s)", e.Reason)
}

// ErrSDKPanic marks a Go panic inside an SDK function or the runtime: the run
// ends (it is a bug, never something the script can catch).
var ErrSDKPanic = errors.New("automation sandbox panic")

// ScriptError is an exception the script did not catch, or a syntax error.
// Line is the recipe file line (0 when unknown); Name is the JS error's name
// (an SDK name such as PermissionDenied, or TypeError, SyntaxError, …).
type ScriptError struct {
	Name, Message, Stack string
	Line                 int
}

func (e *ScriptError) Error() string {
	msg := e.Message
	if e.Name != "" {
		msg = e.Name + ": " + msg
	}
	if e.Line > 0 {
		return fmt.Sprintf("line %d: %s", e.Line, msg)
	}
	return msg
}

// PreParseError is a script PreParse refuses; Line is the script's own
// 1-based line (ParseRecipe adds the block offset).
type PreParseError struct {
	Word string
	Line int
}

func (e *PreParseError) Error() string {
	return fmt.Sprintf("the script API is synchronous: %q is not available", e.Word)
}
