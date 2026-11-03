package tools

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/google/jsonschema-go/jsonschema"

	"watchtower/internal/db"
)

type createTargetArgs struct {
	Text     string `json:"text" jsonschema:"the task title, imperative, at most 200 characters"`
	Intent   string `json:"intent,omitempty" jsonschema:"why it matters / the desired outcome"`
	Due      string `json:"due,omitempty" jsonschema:"owner-local time (YYYY-MM-DD or YYYY-MM-DDTHH:MM); converted to UTC on save; a reminder is a task with a due"`
	Priority string `json:"priority,omitempty" jsonschema:"high | medium | low (default medium)"`
	Reason   string `json:"reason" jsonschema:"one sentence: why you propose this, shown to the owner"`
	// ParentID is accepted only on the inbox surface (an Inbox card's target
	// button, ValidateBinding); elsewhere create_target makes top-level
	// tasks only (TGT-BRIEF-01).
	ParentID int64 `json:"parent_id,omitempty" jsonschema:"only for an Inbox card's button: the personal task the new one goes under"`
}

// parentOnlyOnInboxMsg is the refusal of a parent_id off the inbox surface.
const parentOnlyOnInboxMsg = "parent_id is only for an Inbox card's button"

// openPersonalParent returns parent task id when it exists, is a personal
// task (no workbench board) and is not done or dismissed — checked at
// propose and again at apply, since the parent may close in between; the
// insert re-checks it inside its write transaction.
func openPersonalParent(d *db.DB, id int64) (*db.Target, error) {
	if id < 0 {
		return nil, &ValidationError{Msg: "parent_id must be a target id"}
	}
	p, err := d.OpenPersonalParent(id)
	if err != nil {
		return nil, parentError(err)
	}
	return p, nil
}

// parentError is a *db.ParentUnavailableError as the owner and the model read
// it ("parent_id: task #N is closed"); any other error unchanged.
func parentError(err error) error {
	var pu *db.ParentUnavailableError
	if errors.As(err, &pu) {
		return &ValidationError{Msg: "parent_id: " + pu.Error(), Err: err}
	}
	return err
}

var dueDateRE = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2})?$`)

// decodeStrict decodes args into v rejecting unknown fields — the schema
// check every write tool applies before its own semantic rules.
func decodeStrict(raw json.RawMessage, v any) error {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		return &ValidationError{Msg: "invalid arguments: " + err.Error()}
	}
	return nil
}

func validDue(due string) bool {
	if due == "" {
		return true
	}
	if !dueDateRE.MatchString(due) {
		return false
	}
	layout := "2006-01-02"
	if len(due) > len(layout) {
		layout = "2006-01-02T15:04"
	}
	_, err := time.Parse(layout, due)
	return err == nil
}

// ownerLocalDueToUTC converts the model's owner-local due datetime into the
// UTC convention every reader of targets.due_date already expects
// (cmd/remind.go's parseRemindWhen, NotifyDueTargets, nextstep.go, and the
// Swift Target.parseDueDate/formatDueDate pair). The CLI process runs on the
// owner's machine — the chat-mode MCP server is spawned by the Desktop with
// the owner's inherited TZ — so time.Local IS the owner's zone. A date-only
// due is day-granular (NotifyDueTargets) and is stored verbatim.
func ownerLocalDueToUTC(due string) (string, error) {
	if due == "" || len(due) == len("2006-01-02") {
		return due, nil
	}
	t, err := time.ParseInLocation("2006-01-02T15:04", due, time.Local)
	if err != nil {
		return "", fmt.Errorf("parsing due %q as owner-local time: %w", due, err)
	}
	return t.UTC().Format("2006-01-02T15:04"), nil
}

// NewCreateTarget builds the create_target write tool: a new top-level task
// (a reminder is a task with a due date) in the `watchtower remind` shape.
// Never on the target chat — its mandate forbids creating work outside the
// target's vertical line (TGT-BRIEF-01). On the inbox surface (an Inbox
// card's target button, never trusted) it may take a parent_id and creates
// the task under that personal task.
func NewCreateTarget() *Tool {
	schema, err := jsonschema.For[createTargetArgs](nil)
	if err != nil {
		panic("create_target schema: " + err.Error())
	}
	return &Tool{
		Name: "create_target",
		Description: "Propose a new top-level task (or reminder: a task with a due date) in the owner's Watchtower " +
			"task list. The owner approves it in the chat before it is created. Use it when the owner asks to " +
			"remember, remind, or track something as a task.",
		InputSchema: schema,
		Access:      AccessWrite,
		// "reaction": the seeded :white_check_mark: reaction command proposes it.
		// "inbox": an Inbox card's target button; never a trust place, so
		// its proposal always waits for the owner's Approve.
		Surfaces: []string{"main", "reaction", AutomationSurface, InboxSurface},
		Validate: func(_ context.Context, d *db.DB, raw json.RawMessage) error {
			var a createTargetArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			text := strings.TrimSpace(a.Text)
			switch {
			case text == "":
				return &ValidationError{Msg: "text is required"}
			case len([]rune(text)) > 200:
				return &ValidationError{Msg: "text must be at most 200 characters"}
			case a.Priority != "" && a.Priority != "high" && a.Priority != "medium" && a.Priority != "low":
				return &ValidationError{Msg: "priority must be high, medium or low"}
			case !validDue(a.Due):
				return &ValidationError{Msg: "due must be YYYY-MM-DD or YYYY-MM-DDTHH:MM"}
			}
			if a.ParentID != 0 {
				_, err := openPersonalParent(d, a.ParentID)
				return err
			}
			return nil
		},
		// Runs before Validate, so off the inbox a parent_id is refused
		// before any lookup of the parent (no existence leak). Args that
		// do not decode are left to Validate's message.
		ValidateBinding: func(b Binding, raw json.RawMessage) error {
			var a createTargetArgs
			if json.Unmarshal(raw, &a) != nil {
				return nil
			}
			if a.ParentID != 0 && b.Surface != InboxSurface {
				return &ValidationError{Msg: parentOnlyOnInboxMsg}
			}
			return nil
		},
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a createTargetArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding create_target args: %w", err)
			}
			priority := a.Priority
			if priority == "" {
				priority = "medium"
			}
			due, err := ownerLocalDueToUTC(a.Due)
			if err != nil {
				return nil, fmt.Errorf("converting due date: %w", err)
			}
			today := time.Now().UTC().Format("2006-01-02")
			t := db.Target{
				Text:        strings.TrimSpace(a.Text),
				Intent:      strings.TrimSpace(a.Intent),
				Level:       "day",
				PeriodStart: today,
				PeriodEnd:   today,
				Status:      "todo",
				Priority:    priority,
				Ownership:   "mine",
				DueDate:     due,
				SourceType:  "chat",
				// Prefixed like the existing `chat` writer's `target:<id>`
				// (TargetsViewModel.createChild): one source_type, several id
				// spaces, so each id says which one it belongs to.
				SourceID: "action:" + strconv.FormatInt(call.ActionID, 10),
			}
			if call.ActionID > 0 {
				// A reclaim after an apply that crashed past its insert
				// returns that task first — before the parent checks, which
				// would fail it if the parent went away since.
				existing, err := d.TargetForAction(call.ActionID)
				if err != nil {
					return nil, err
				}
				if existing != 0 {
					return map[string]any{"target_id": existing}, nil
				}
			}
			if a.ParentID != 0 {
				// Only an inbox row carries one (ValidateBinding); the parent
				// may have closed since the propose.
				p, err := openPersonalParent(d, a.ParentID)
				if err != nil {
					return nil, err
				}
				t.ParentID = sql.NullInt64{Int64: a.ParentID, Valid: true}
				t.Level, t.CustomLabel, t.PeriodStart, t.PeriodEnd = p.Level, p.CustomLabel, p.PeriodStart, p.PeriodEnd
			}
			id, err := createTargetOnce(d, t, call.ActionID)
			if err != nil {
				var pu *db.ParentUnavailableError
				if errors.As(err, &pu) {
					// The parent closed between the check above and the insert.
					return nil, parentError(err)
				}
				return nil, fmt.Errorf("creating target: %w", err)
			}
			return map[string]any{"target_id": id}, nil
		},
	}
}

// createTargetOnce is create_target's insert. A registry row (actionID > 0)
// creates at most one task per action id — idx_targets_action_source with
// insert-or-return, so a reclaimed or overlapping apply returns the task the
// first one made (AGENT-05). A registry-less Execute (actionID 0, source
// 'action:0', outside the index) is a plain insert.
func createTargetOnce(d *db.DB, t db.Target, actionID int64) (int64, error) {
	if actionID <= 0 {
		return d.CreateTarget(t)
	}
	id, _, err := d.CreateTargetForAction(t, actionID)
	return id, err
}
