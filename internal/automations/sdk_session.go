package automations

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"slices"
	"unicode/utf8"

	"github.com/dop251/goja"

	"watchtower/internal/agentkind"
	"watchtower/internal/db"
	"watchtower/internal/policy"
)

// StepKindSession is the journal kind of a session() call.
const StepKindSession = "session"

// maxSessionTitleRunes bounds session()'s title (plan ruling R-P5-2); the
// prompt is bounded by the journal (resolve: {prompt, agent, title} fits
// StepClipBytes).
const maxSessionTitleRunes = 80

// session() wait modes: finish (the default) resumes the script when the
// session ends; none as soon as the Desktop launched it.
const (
	sessionWaitFinish = "finish"
	sessionWaitNone   = "none"
)

// The statuses session() returns once the session ended. sessionNotWatched
// is no end of the session itself: the Mac cannot watch it (N6, ask #516),
// so the wait ends at once with the reason and the session keeps running;
// a recipe reads it as "outcome unknown", never as success.
const (
	sessionFinished   = "finished"
	sessionError      = "error"
	sessionDeleted    = "deleted"
	sessionStopped    = db.SessionStepStopped
	sessionNotWatched = "not_watched"
)

var sessionOptionKeys = []string{"prompt", "agent", "title", "wait"}

// SessionModule defines session({prompt, agent?, title?, wait?}) (spec §5,
// §13): a visible workbench session the Desktop opens. session:start[@kind]
// for a workbench automation only; the kind is agent or the workbench's
// default agent, resolved before the permission check. A dry run returns
// {status:"dry_run"} and asks the Desktop for nothing. Otherwise the step
// (args {prompt, agent, title}, the title "⚙ <title or automation name> ·
// run #N") is marked waiting and the run waits for the app; once the Desktop
// attached its session (`automations session-launched`) the wait's reason
// becomes session, in the same wait. wait:"none" returns {session_id} then;
// otherwise the run resumes when the session finished, failed, was deleted
// or stopped and returns {session_id, status, summary, error?}, or at once
// with {session_id, status: "not_watched", summary: "", reason} when the Mac
// cannot watch it (N6, ask #516: the default, no option; the reason also
// goes to the run log as one log step). A launch the
// Desktop could not make throws NotAvailable with its reason (R-P5-4). A run
// starts at most MaxSessionCalls sessions: every session's wait pauses the
// minutes budget, so the count bounds them (board #562); the call past it is
// a ValidationError step.
func SessionModule(b Backends) Module {
	return sdkModule{name: "session", fns: map[string]SDKFunc{"session": func(env *Env, call goja.FunctionCall, rt *goja.Runtime) (any, error) {
		req, reqErr := parseSessionCall(env, rt, call)
		key := req.replayKey() // before resolve fills the default agent and the label
		if reqErr == nil && sessionsStarted(env.Journal) >= MaxSessionCalls {
			reqErr = validationf("session() already started %d sessions in this run; the limit is %d", MaxSessionCalls, MaxSessionCalls)
		}
		if reqErr == nil {
			reqErr = req.resolve(env, b)
		}
		out, err := env.CallWithReplayKey(StepKindSession, req.agent, req.stepArgs(), key, func(step *Step) (any, error) {
			if reqErr != nil {
				return nil, reqErr
			}
			return runSession(env, b, step, req)
		})
		if err == nil {
			err = logNotWatched(env, out)
		}
		return out, err
	}}}
}

// logNotWatched writes the run-log line of a not_watched end (N6): one log
// step naming the session and the reason, within log()'s per-run cap (past
// it the reason is still in the session step's journalled result). A
// replayed run replays it like the script's own log lines, so its error (a
// replay mismatch) is the call's.
func logNotWatched(env *Env, out any) error {
	raw, ok := out.(encodedResult)
	if !ok || env.Journal.CountKind(StepKindLog) >= MaxLogCalls {
		return nil
	}
	var end struct {
		SessionID int64  `json:"session_id"`
		Status    string `json:"status"`
		Reason    string `json:"reason"`
	}
	if err := json.Unmarshal(raw, &end); err != nil {
		return fmt.Errorf("reading the session step's result: %w", err)
	}
	if end.Status != sessionNotWatched {
		return nil
	}
	msg := fmt.Sprintf("session %d is not watched (%s): its outcome is unknown", end.SessionID, end.Reason)
	_, err := env.Call(StepKindLog, "log", msg, func(*Step) (any, error) { return nil, nil })
	return err
}

// sessionsStarted counts the run's session() steps that started a session
// (or would have, in a dry run): every one but a refused or failed call.
func sessionsStarted(j *Journal) int {
	n := 0
	for _, s := range j.Steps() {
		if s.Kind == StepKindSession && s.Status != StepError && s.Status != StepDenied {
			n++
		}
	}
	return n
}

// sessionCall is one session() call's arguments.
type sessionCall struct {
	prompt, agent, title string // title: the script's until resolve formats it
	wait                 string
}

// replayKey is what the script asked session() for (its own agent and
// title, or none): the workbench's default agent may change while the run
// waits, and a resumed call keeps the agent it started with.
func (r sessionCall) replayKey() map[string]any {
	return map[string]any{"prompt": r.prompt, "agent": r.agent, "title": r.title, "wait": r.wait}
}

func (r sessionCall) stepArgs() map[string]any {
	return map[string]any{"prompt": r.prompt, "agent": r.agent, "title": r.title}
}

// parseSessionCall reads session(options). A bad call is reported inside the
// step.
func parseSessionCall(env *Env, rt *goja.Runtime, call goja.FunctionCall) (sessionCall, error) {
	req := sessionCall{wait: sessionWaitFinish}
	v, present, err := argAt(env, rt, call, 0)
	if err != nil {
		return req, tooLargeAs(err, ErrNameValidation, fmt.Sprintf("session(): the options are larger than %d bytes", maxSDKArgBytes))
	}
	opts, ok := v.(map[string]any)
	if !present || !ok {
		return req, validationf("session(options): options must be an object {prompt, agent?, title?, wait?}")
	}
	for _, k := range slices.Sorted(maps.Keys(opts)) {
		if !slices.Contains(sessionOptionKeys, k) {
			return req, validationf("session(): unknown option %q (use prompt, agent, title, wait)", k)
		}
	}
	if req.prompt, ok = opts["prompt"].(string); !ok || req.prompt == "" {
		return req, validationf("session(): prompt must be a non-empty string")
	}
	err = req.parseOptional(opts)
	return req, err
}

// parseOptional reads session()'s optional agent, title and wait, in that
// order.
func (r *sessionCall) parseOptional(opts map[string]any) error {
	var ok bool
	if a, has := opts["agent"]; has {
		s, _ := a.(string)
		if _, err := agentkind.ParseOrRefuse(s); err != nil {
			return validationf("session(): %v", err)
		}
		r.agent = s
	}
	if t, has := opts["title"]; has {
		if r.title, ok = t.(string); !ok || utf8.RuneCountInString(r.title) > maxSessionTitleRunes {
			return validationf("session(): title must be a string of at most %d characters", maxSessionTitleRunes)
		}
	}
	if w, has := opts["wait"]; has {
		if r.wait, ok = w.(string); !ok || (r.wait != sessionWaitFinish && r.wait != sessionWaitNone) {
			return validationf("session(): wait must be %q or %q", sessionWaitFinish, sessionWaitNone)
		}
	}
	return nil
}

// resolve fills the agent (the workbench's default when the script gave
// none) and the session title, and checks the call's args fit the journal:
// the Desktop reads the prompt from the step's args_json, clipped at
// StepClipBytes, so a prompt that would be clipped is refused.
func (r *sessionCall) resolve(env *Env, b Backends) error {
	wbID := env.Binding().WorkbenchID
	if wbID == 0 {
		return &PermissionDenied{Reason: "session() is available to workbench automations only"}
	}
	if r.agent == "" {
		if b.Workbench == nil {
			return notAvailable("no workbench resolver is configured")
		}
		wb, err := b.Workbench.Workbench(env.Ctx, wbID)
		if err != nil {
			return fmt.Errorf("session(): resolving workbench %d: %w", wbID, err)
		}
		r.agent = wb.DefaultAgent
	}
	name := r.title
	if name == "" {
		name = automationName(env)
	}
	r.title = runLabel(env, name)
	if n := len(marshalForStep(r.stepArgs())); n > StepClipBytes {
		return validationf("session(): the prompt is too long: {prompt, agent, title} take %d bytes as JSON; the limit is %d", n, StepClipBytes)
	}
	return nil
}

// runSession runs one validated session() call.
func runSession(env *Env, b Backends, step *Step, req sessionCall) (any, error) {
	if args, ok := step.ResumedArgs(); ok {
		// A resumed run re-enters the wait of the session it started: the
		// agent and title it resolved then, whatever the default is now.
		var started struct{ Agent, Title string }
		if err := json.Unmarshal([]byte(args), &started); err == nil && started.Agent != "" {
			req.agent, req.title = started.Agent, started.Title
		}
	}
	m, err := manifestOf(env)
	if err != nil {
		return nil, err
	}
	entry, err := m.AllowCapability("session", "start", req.agent)
	if err != nil {
		return nil, err
	}
	step.SetPermission(entry)
	// The agent kinds are their providers: one the organization's policy
	// forbids (#608) is never asked of the Desktop.
	if p := policy.Current(); !p.ProviderAllowed(req.agent) {
		return nil, PolicyError(p.ProviderError(req.agent))
	}
	if env.DryRun {
		return dryRunResult(step, req.stepArgs()), nil
	}
	if env.Wait == nil || b.DB == nil || env.Run == nil {
		return nil, notAvailable("session() needs the automation executor")
	}
	if err := step.Mark(StepWaiting, db.StepFinish{}); err != nil {
		return nil, err
	}
	w := &sessionWait{db: b.DB, runID: env.Run.ID, stepID: step.ID(), noWait: req.wait == sessionWaitNone}
	if err := env.Wait.Wait(env.Ctx, db.WaitApp, w.ready); err != nil {
		return nil, err
	}
	if w.launchErr != nil {
		return nil, w.launchErr
	}
	step.Finish(db.StepFinish{Status: StepOK, SessionID: w.sessionID, ResultSummary: marshalForStep(w.out)})
	return w.out, nil
}

// sessionWait is one session() call's wait: for the Desktop's launch (the
// run waits app), then — unless noWait — for the session's end (session).
type sessionWait struct {
	db            *db.DB
	runID, stepID int64
	noWait        bool
	sessionID     int64          // set once the Desktop attached a session
	out           map[string]any // what the script gets
	launchErr     error          // the Desktop could not launch the session
}

// ready is the Waiter's check. The ends are read in order: the session row
// gone, finished (finish_session), failed (agent_failed_at), not watched
// (agent_watch_issue on a working row, N6), then the Desktop's own report
// (session-ended: stopped, or launch_failed before a launch). An idle turn
// without finish_session keeps the run waiting (R-P5-3).
func (w *sessionWait) ready(context.Context) (bool, error) {
	s, err := w.db.GetAutomationSessionStep(w.stepID)
	if err != nil {
		return false, err
	}
	if w.sessionID == 0 && s.SessionID != 0 {
		w.sessionID = s.SessionID
		if w.noWait {
			w.out = map[string]any{"session_id": w.sessionID}
			return true, nil
		}
		err := w.db.SetAutomationRunWaiting(w.runID, db.WaitSession)
		if errors.Is(err, db.ErrRunNotActive) {
			return false, nil // ended meanwhile: the wait's next check sees the cancel
		}
		if err != nil {
			return false, err
		}
	}
	if w.sessionID != 0 {
		if end, ok := attachedEnd(s); ok {
			w.end(end)
			return true, nil
		}
	}
	switch s.Status {
	case StepError:
		msg := s.Error
		if msg == "" {
			msg = "the Desktop could not start the session"
		}
		w.launchErr = notAvailable(msg)
	case StepOK:
		w.end(sessionEnd{status: sessionStopped})
	default:
		return false, nil
	}
	return true, nil
}

// sessionEnd is how a session() wait ended.
type sessionEnd struct {
	status, summary string
	errText         string // sessionError only
	reason          string // sessionNotWatched only
}

// attachedEnd is the end an attached session's row gives the wait, read in
// order: gone, finished, failed, not watched; ok is false while it goes on.
func attachedEnd(s db.AutomationSessionStep) (sessionEnd, bool) {
	switch {
	case s.SessionGone:
		return sessionEnd{status: sessionDeleted}, true
	case s.Finished:
		return sessionEnd{status: sessionFinished, summary: s.FinishSummary}, true
	case s.Failed:
		return sessionEnd{status: sessionError, errText: s.AgentError}, true
	case s.WatchIssue != "":
		return sessionEnd{status: sessionNotWatched, reason: s.WatchIssue}, true
	}
	return sessionEnd{}, false
}

// SessionWaitEnd is attachedEnd for the contract suite: the status an
// attached session's row s gives a session() wait and, for not_watched,
// its reason; ended is false while the wait goes on.
func SessionWaitEnd(s db.AutomationSessionStep) (status, reason string, ended bool) {
	end, ok := attachedEnd(s)
	return end.status, end.reason, ok
}

func (w *sessionWait) end(e sessionEnd) {
	w.out = map[string]any{"session_id": w.sessionID, "status": e.status, "summary": e.summary}
	switch e.status {
	case sessionError:
		w.out["error"] = e.errText
	case sessionNotWatched:
		w.out["reason"] = e.reason
	}
}
