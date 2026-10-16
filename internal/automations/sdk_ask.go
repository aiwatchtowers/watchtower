package automations

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/dop251/goja"

	"watchtower/internal/asks"
	"watchtower/internal/db"
)

// askInput is what ask() takes: ask_owner's shape without a review's
// document, a target or a previous ask.
type askInput struct {
	Kind      string               `json:"kind"`
	Title     string               `json:"title"`
	Summary   string               `json:"summary,omitempty"`
	Questions []asks.Question      `json:"questions,omitempty"`
	Checklist []asks.ChecklistItem `json:"checklist,omitempty"`
}

// AskModule defines ask({kind, title, summary?, questions?, checklist?})
// (spec §5, P5): ask:owner, which only a workbench recipe may declare (D7).
// The ask is a check or a question checked by ask_owner's rules — a review
// is refused, it needs a document and a session to re-round it (R-P5-5). A
// dry run files nothing and returns {status:"dry_run"}. Otherwise the ask is
// filed on the automation's workbench with no session and the run's id
// (session-side readers never see it), and the run waits (waiting_reason
// 'ask') until the owner answers: the ask is then delivered and the script
// gets the answer. A cancel or a pause timeout withdraws the ask (agent).
func AskModule(b Backends) Module {
	return sdkModule{name: "ask", fns: map[string]SDKFunc{"ask": func(env *Env, call goja.FunctionCall, rt *goja.Runtime) (any, error) {
		in, payload, reqErr := parseAskCall(env, rt, call)
		return env.Call(StepKindAsk, in.Kind, in, func(step *Step) (any, error) {
			if reqErr != nil {
				return nil, reqErr
			}
			return runAsk(env, b, step, in, payload)
		})
	}}}
}

// parseAskCall reads and validates ask()'s one argument. A bad call is
// reported inside the step.
func parseAskCall(env *Env, rt *goja.Runtime, call goja.FunctionCall) (askInput, asks.Payload, error) {
	var in askInput
	v, _, err := argAt(env, rt, call, 0)
	if err != nil {
		return in, asks.Payload{}, tooLargeAs(err, ErrNameValidation, fmt.Sprintf("ask(): the ask is larger than %d bytes", maxSDKArgBytes))
	}
	obj, ok := v.(map[string]any)
	if !ok {
		return in, asks.Payload{}, validationf("ask(ask): ask must be an object {kind, title, summary?, questions?, checklist?}")
	}
	raw, err := json.Marshal(obj)
	if err != nil {
		return in, asks.Payload{}, validationf("ask(): %v", err)
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&in); err != nil {
		return askInput{}, asks.Payload{}, validationf("ask(): %v (use kind, title, summary, questions, checklist)", err)
	}
	switch in.Kind {
	case asks.KindCheck, asks.KindQuestion:
	case asks.KindReview:
		return in, asks.Payload{}, validationf("ask(): kind review is not available to automations (a review needs a document and a session); use check or question")
	default:
		return in, asks.Payload{}, validationf("ask(): kind must be check or question")
	}
	payload, err := asks.Validate(asks.Input{Kind: in.Kind, Title: in.Title, Summary: in.Summary,
		Questions: in.Questions, Checklist: in.Checklist}, asks.OriginAgent)
	if err != nil {
		return in, asks.Payload{}, validationf("ask(): %v", err)
	}
	return in, payload, nil
}

func runAsk(env *Env, b Backends, step *Step, in askInput, payload asks.Payload) (any, error) {
	m, err := manifestOf(env)
	if err != nil {
		return nil, err
	}
	entry, err := m.AllowCapability("ask", "owner", "")
	if err != nil {
		return nil, err
	}
	step.SetPermission(entry)
	if env.DryRun {
		return dryRunResult(step, in), nil
	}
	if env.Wait == nil || b.DB == nil || env.Run == nil {
		return nil, notAvailable("ask() needs the automation executor")
	}
	wb := env.Binding().WorkbenchID
	id, err := fileAutomationAsk(b.DB, wb, env.Run.ID, in, payload)
	if err != nil {
		return nil, err
	}
	if err := step.Mark(StepWaiting, db.StepFinish{AskID: id}); err != nil {
		// No run will wait for it: withdraw the ask (the sweep catches a
		// failed withdraw once the run ended) and keep its link on the step.
		_ = b.DB.WithdrawOwnerAsk(wb, id, db.WithdrawnByAgent)
		err = fmt.Errorf("ask #%d was filed, but the run could not wait for it: %w", id, err)
		step.Finish(db.StepFinish{Status: StepError, AskID: id, Error: err.Error()})
		return nil, err
	}
	row, err := waitForAnswer(env, b.DB, wb, id)
	if err != nil {
		return nil, err
	}
	return deliverAnswer(b.DB, step, row, payload)
}

// fileAutomationAsk inserts the open ask of run runID on workbench wb: no
// session, origin agent, the level by asks.Level. The cap is a ToolError.
func fileAutomationAsk(d *db.DB, wb, runID int64, in askInput, payload asks.Payload) (int64, error) {
	payloadJSON, err := json.Marshal(payload)
	if err != nil {
		return 0, fmt.Errorf("encoding ask payload: %w", err)
	}
	ask := db.OwnerAsk{
		WorkbenchID: wb, Kind: in.Kind, Title: strings.TrimSpace(in.Title), Summary: strings.TrimSpace(in.Summary),
		Payload: string(payloadJSON), Level: asks.Level(in.Kind, payload, asks.OriginAgent), Origin: asks.OriginAgent,
		AutomationRunID: sql.NullInt64{Int64: runID, Valid: true},
	}
	var id int64
	err = d.WithTx(func(tx *sql.Tx) error {
		var err error
		id, _, err = d.InsertOwnerAsk(tx, ask)
		return err
	})
	if errors.Is(err, db.ErrTooManyOpenAsks) {
		return 0, &SDKError{Name: ErrNameTool,
			Message: fmt.Sprintf("this workbench has %d open asks; answer some first", asks.MaxOpenPerWorkbench)}
	}
	return id, err
}

// waitForAnswer pauses the run (waiting_reason 'ask') until ask id is
// answered and returns its row. A wait that ends otherwise — a cancel, a
// pause timeout, the ask gone — withdraws the ask (agent; one no longer
// open is left as it is) and returns the Waiter's error.
func waitForAnswer(env *Env, d *db.DB, wb, id int64) (*db.OwnerAsk, error) {
	var row *db.OwnerAsk
	err := env.Wait.Wait(env.Ctx, db.WaitAsk, func(context.Context) (bool, error) {
		a, err := d.GetOwnerAsk(wb, id)
		if err != nil {
			return false, err
		}
		switch a.Status {
		case "open":
			return false, nil
		case "answered":
			row = a
			return true, nil
		}
		return false, fmt.Errorf("ask #%d is %s", id, a.Status)
	})
	if err != nil {
		// An ask answered just before the wait ended (a cancel while the
		// resume waited for a slot) is not open: it stays answered, never
		// delivered, and only the owner-facing readers show it.
		_ = d.WithdrawOwnerAsk(wb, id, db.WithdrawnByAgent)
		return nil, err
	}
	return row, nil
}

// deliverAnswer checks the stored answer against the ask, marks the ask
// delivered and closes the step ok with the answer, which the script gets as
// an object.
func deliverAnswer(d *db.DB, step *Step, row *db.OwnerAsk, payload asks.Payload) (any, error) {
	answer, err := asks.ParseAnswer([]byte(row.Answer))
	if err == nil {
		err = asks.ValidateAnswer(row.Kind, payload, answer)
	}
	if err != nil {
		return nil, fmt.Errorf("ask #%d: stored answer: %w", row.ID, err)
	}
	if _, err := d.MarkOwnerAskDelivered(row.WorkbenchID, row.ID); err != nil {
		return nil, err
	}
	raw, err := json.Marshal(answer)
	if err != nil {
		return nil, fmt.Errorf("encoding ask #%d's answer: %w", row.ID, err)
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, fmt.Errorf("decoding ask #%d's answer: %w", row.ID, err)
	}
	step.Finish(db.StepFinish{Status: StepOK, AskID: row.ID, ResultSummary: string(raw)})
	return out, nil
}
