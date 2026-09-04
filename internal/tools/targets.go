package tools

import (
	"bytes"
	"context"
	"encoding/json"
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
// Main chat only — the target chat's mandate forbids creating work outside
// the target's vertical line (TGT-BRIEF-01).
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
		Surfaces:    []string{"main"},
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
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
			id, err := d.CreateTarget(db.Target{
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
			})
			if err != nil {
				return nil, fmt.Errorf("creating target: %w", err)
			}
			return map[string]any{"target_id": id}, nil
		},
	}
}
