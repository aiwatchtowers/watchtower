package automations

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"slices"
	"strconv"
	"strings"

	"github.com/dop251/goja"

	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// Step statuses of a tool write (automation_run_steps.status).
const (
	StepProposed = "proposed"
	StepApplied  = "applied"
	StepRejected = "rejected"
	StepFailed   = "failed"
)

// The agent_actions statuses a write ends in; a wait resolves on them.
const (
	actionApplied  = "applied"
	actionRejected = "rejected"
	actionFailed   = "failed"
)

// toolOptWait is the one option tool(name, args, opts) takes.
const toolOptWait = "wait"

// ToolWriteModule defines tool(name, args, opts?) with writes (spec §5). It
// replaces P1's ToolModule path (a later Define wins, S3): a read delegates to
// readTool unchanged; a write passes the manifest (AllowTool), then — outside
// a dry run — Registry.Propose with the run's automation binding. With
// opts.wait a pending proposal pauses the run (waiting_reason 'approval')
// until the owner's decision lands. A dry run never reaches the registry.
func ToolWriteModule(b Backends) Module {
	return sdkModule{name: "tool", fns: map[string]SDKFunc{"tool": func(env *Env, call goja.FunctionCall, rt *goja.Runtime) (any, error) {
		req, reqErr := parseToolCall(env, rt, call)
		var wait bool
		if reqErr == nil {
			wait, reqErr = parseToolOpts(env, rt, call, req.name)
		}
		return env.Call(StepKindTool, req.name, req.args, func(step *Step) (any, error) {
			if reqErr != nil {
				return nil, reqErr
			}
			t, err := admitTool(env, b, step, req)
			if err != nil {
				return nil, err
			}
			if t.Access == tools.AccessRead {
				return readTool(env, b, t, req.args)
			}
			return writeTool(env, b, step, t, req.args, wait)
		})
	}}}
}

// parseToolOpts reads tool()'s third argument: absent, null or {wait: bool}.
// Any other shape or key is a ValidationError.
func parseToolOpts(env *Env, rt *goja.Runtime, call goja.FunctionCall, name string) (bool, error) {
	v, present, err := argAt(env, rt, call, 2)
	if err != nil {
		return false, tooLargeAs(err, ErrNameValidation,
			fmt.Sprintf("tool(%q): the options are larger than %d bytes", name, maxSDKArgBytes))
	}
	if !present || v == nil {
		return false, nil
	}
	opts, ok := v.(map[string]any)
	if !ok {
		return false, validationf("tool(%q, args, opts): opts must be an object", name)
	}
	for _, k := range slices.Sorted(maps.Keys(opts)) {
		if k != toolOptWait {
			return false, validationf("tool(%q, args, opts): unknown option %q; the only option is wait", name, k)
		}
	}
	w, has := opts[toolOptWait]
	if !has {
		return false, nil
	}
	wait, ok := w.(bool)
	if !ok {
		return false, validationf("tool(%q, args, opts): wait must be true or false", name)
	}
	return wait, nil
}

// writeTool runs one admitted write: a dry run records the would-be args
// and returns {status:"dry_run"}; otherwise the proposal goes through
// Registry.Propose (a default reason when the script gave none) and the step
// closes with the receipt's outcome — or, with wait on a pending proposal,
// after the owner decided.
func writeTool(env *Env, b Backends, step *Step, t *tools.Tool, args json.RawMessage, wait bool) (any, error) {
	if t.Access != tools.AccessWrite {
		return nil, &SDKError{Name: ErrNameTool, Message: t.Name + " is neither a read nor a write tool"}
	}
	if env.DryRun {
		return dryRunResult(step, args), nil
	}
	if wait && (env.Wait == nil || b.DB == nil) {
		return nil, notAvailable("waiting for an approval needs the automation executor")
	}
	args, err := withDefaultReason(env, t.Name, args)
	if err != nil {
		return nil, err
	}
	rc, err := b.Registry.Propose(env.Ctx, t.Name, args, env.Binding())
	if err != nil {
		return nil, registryError(t, err)
	}
	if wait && !actionDecided(rc.Status) {
		return waitForAction(env, b, step, rc.ActionID)
	}
	return finishWrite(step, rc), nil
}

// actionDecided reports whether an agent_actions status is final for a
// script: applied, rejected or failed (pending, approved and executing are
// still on their way).
func actionDecided(status string) bool {
	return status == actionApplied || status == actionRejected || status == actionFailed
}

// finishWrite closes the step with rc's outcome and returns what the script
// sees: {status:"applied", id, result}, {status:"rejected", id},
// {status:"failed", id, error} or, while undecided, {status:"proposed", id}.
// The step is auto=1 only for an auto write (rc.Auto: a grant decided and the
// inline apply landed).
func finishWrite(step *Step, rc tools.Receipt) map[string]any {
	out := map[string]any{"id": rc.ActionID}
	f := db.StepFinish{ActionID: rc.ActionID}
	switch rc.Status {
	case actionApplied:
		out["status"], out["result"] = StepApplied, jsonValue(rc.Result)
		f.Status, f.Auto = StepApplied, rc.Auto
	case actionRejected:
		out["status"] = StepRejected
		f.Status = StepRejected
	case actionFailed:
		out["status"], out["error"] = StepFailed, rc.Error
		f.Status, f.Error = StepFailed, rc.Error
	default:
		out["status"] = StepProposed
		f.Status = StepProposed
	}
	f.ResultSummary = marshalForStep(out)
	step.Finish(f)
	return out
}

// waitForAction pauses the run on the executor's Waiter until action id is
// decided, then finishes the step with that decision. The step is marked
// waiting first, linked to the action (a failed mark closes it as an error
// that keeps the link). A cancel or a pause timeout ends the
// wait with the executor's interrupt (the proposal stays pending).
func waitForAction(env *Env, b Backends, step *Step, id int64) (any, error) {
	if err := step.Mark(StepWaiting, db.StepFinish{ActionID: id}); err != nil {
		// The proposal exists: close the step as an error that still links it,
		// so the journal never loses the action id.
		err = fmt.Errorf("proposal #%d is recorded, but the run could not wait for it: %w", id, err)
		step.Finish(db.StepFinish{Status: StepError, ActionID: id, Error: err.Error()})
		return nil, err
	}
	var row *db.AgentAction
	err := env.Wait.Wait(env.Ctx, db.WaitApproval, func(context.Context) (bool, error) {
		r, err := b.DB.GetAgentAction(id)
		if err != nil {
			return false, err
		}
		if r == nil {
			return false, fmt.Errorf("agent action %d no longer exists", id)
		}
		row = r
		return actionDecided(r.Status), nil
	})
	if err != nil {
		return nil, err
	}
	return finishWrite(step, decidedReceipt(row)), nil
}

// decidedReceipt is the outcome of a decided agent_actions row (an owner's
// decision is never an auto write).
func decidedReceipt(row *db.AgentAction) tools.Receipt {
	rc := tools.Receipt{ActionID: row.ID, Status: row.Status, Tool: row.Tool, Error: row.Error}
	if row.Status == actionApplied && row.ResultJSON != "" {
		var result any
		if err := json.Unmarshal([]byte(row.ResultJSON), &result); err != nil {
			rc.Result = row.ResultJSON // keep what Apply stored rather than drop it
		} else {
			rc.Result = result
		}
	}
	return rc
}

// withDefaultReason fills the registry's mandatory reason when the script
// gave none (absent, null or blank): "⚙ <automation name> · run #<run id>".
// A script-given reason is kept verbatim; a non-string one is left for the
// registry to refuse.
func withDefaultReason(env *Env, name string, args json.RawMessage) (json.RawMessage, error) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(args, &fields); err != nil {
		return nil, validationf("tool(%q, args): %v", name, err)
	}
	if fields == nil {
		fields = map[string]json.RawMessage{}
	}
	if raw, ok := fields["reason"]; ok && string(raw) != "null" {
		var s string
		isString := json.Unmarshal(raw, &s) == nil
		if !isString || strings.TrimSpace(s) != "" {
			return args, nil
		}
	}
	reason, err := json.Marshal(defaultReason(env))
	if err != nil {
		return nil, fmt.Errorf("encoding the default reason: %w", err)
	}
	fields["reason"] = reason
	out, err := json.Marshal(fields)
	if err != nil {
		return nil, fmt.Errorf("encoding tool(%q) args: %w", name, err)
	}
	return out, nil
}

// defaultReason is "⚙ <automation name> · run #<run id>".
func defaultReason(env *Env) string {
	name := ""
	switch {
	case env.Automation != nil && env.Automation.Name != "":
		name = env.Automation.Name
	case env.Recipe != nil && env.Recipe.Name != "":
		name = env.Recipe.Name
	case env.Automation != nil:
		name = env.Automation.Slug
	}
	var runID int64
	if env.Run != nil {
		runID = env.Run.ID
	}
	return "⚙ " + name + " · run #" + strconv.FormatInt(runID, 10)
}

// registryError maps a registry failure for the script: a registry
// ValidationError is a ValidationError; an unknown or non-writable tool and
// every other failure a ToolError.
func registryError(t *tools.Tool, err error) error {
	var ve *tools.ValidationError
	if errors.As(err, &ve) {
		return &SDKError{Name: ErrNameValidation, Message: ve.Msg}
	}
	return &SDKError{Name: ErrNameTool, Message: fmt.Sprintf("%s: %v", t.Name, err)}
}
