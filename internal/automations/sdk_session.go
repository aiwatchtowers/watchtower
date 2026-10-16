package automations

import (
	"context"
	"errors"
	"fmt"
	"maps"
	"slices"
	"unicode/utf8"

	"github.com/dop251/goja"

	"watchtower/internal/agentkind"
	"watchtower/internal/db"
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

// The statuses session() returns once the session ended.
const (
	sessionFinished = "finished"
	sessionError    = "error"
	sessionDeleted  = "deleted"
	sessionStopped  = db.SessionStepStopped
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
// or stopped and returns {session_id, status, summary, error?}. A launch the
// Desktop could not make throws NotAvailable with its reason (R-P5-4).
func SessionModule(b Backends) Module {
	return sdkModule{name: "session", fns: map[string]SDKFunc{"session": func(env *Env, call goja.FunctionCall, rt *goja.Runtime) (any, error) {
		req, reqErr := parseSessionCall(env, rt, call)
		if reqErr == nil {
			reqErr = req.resolve(env, b)
		}
		return env.Call(StepKindSession, req.agent, req.stepArgs(), func(step *Step) (any, error) {
			if reqErr != nil {
				return nil, reqErr
			}
			return runSession(env, b, step, req)
		})
	}}}
}

// sessionCall is one session() call's arguments.
type sessionCall struct {
	prompt, agent, title string // title: the script's until resolve formats it
	wait                 string
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
	if a, has := opts["agent"]; has {
		s, _ := a.(string)
		if _, ok := agentkind.Parse(s); !ok {
			return req, validationf("session(): agent must be %q or %q", agentkind.Claude, agentkind.Codex)
		}
		req.agent = s
	}
	if t, has := opts["title"]; has {
		if req.title, ok = t.(string); !ok || utf8.RuneCountInString(req.title) > maxSessionTitleRunes {
			return req, validationf("session(): title must be a string of at most %d characters", maxSessionTitleRunes)
		}
	}
	if w, has := opts["wait"]; has {
		if req.wait, ok = w.(string); !ok || (req.wait != sessionWaitFinish && req.wait != sessionWaitNone) {
			return req, validationf("session(): wait must be %q or %q", sessionWaitFinish, sessionWaitNone)
		}
	}
	return req, nil
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
	m, err := manifestOf(env)
	if err != nil {
		return nil, err
	}
	entry, err := m.AllowCapability("session", "start", req.agent)
	if err != nil {
		return nil, err
	}
	step.SetPermission(entry)
	if env.DryRun {
		return dryRunResult(step, req.stepArgs()), nil
	}
	if env.Wait == nil || b.DB == nil {
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
// gone, finished (finish_session), failed (agent_failed_at), then the
// Desktop's own report (session-ended: stopped, or launch_failed before a
// launch). An idle turn without finish_session keeps the run waiting
// (R-P5-3).
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
	switch {
	case w.sessionID != 0 && s.SessionGone:
		w.end(sessionDeleted, "", "")
	case w.sessionID != 0 && s.Finished:
		w.end(sessionFinished, s.FinishSummary, "")
	case w.sessionID != 0 && s.Failed:
		w.end(sessionError, "", s.AgentError)
	case s.Status == StepError:
		msg := s.Error
		if msg == "" {
			msg = "the Desktop could not start the session"
		}
		w.launchErr = notAvailable(msg)
	case s.Status == StepOK:
		w.end(sessionStopped, "", "")
	default:
		return false, nil
	}
	return true, nil
}

func (w *sessionWait) end(status, summary, errText string) {
	w.out = map[string]any{"session_id": w.sessionID, "status": status, "summary": summary}
	if status == sessionError {
		w.out["error"] = errText
	}
}
