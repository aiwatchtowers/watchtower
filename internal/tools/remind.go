package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/google/jsonschema-go/jsonschema"

	"watchtower/internal/db"
)

type remindMeArgs struct {
	RemindAt   string `json:"remind_at" jsonschema:"when to resurface this: RFC 3339 with a timezone offset or Z (e.g. 2026-09-07T09:00:00+02:00), or owner-local YYYY-MM-DDTHH:MM; stored as UTC"`
	Note       string `json:"note,omitempty" jsonschema:"a short note about what to follow up on"`
	MessageRef string `json:"message_ref,omitempty" jsonschema:"optional: the Slack message this is about, as <channel_id>@<message_ts> (e.g. 1:C0123@1712345678.000100)"`
	Reason     string `json:"reason" jsonschema:"one sentence for the owner"`
}

// messageRefRE is the "<channel_id>@<message_ts>" shape the reaction binding
// writes (channel ids are namespaced "<account>:<raw>").
var messageRefRE = regexp.MustCompile(`^[^@\s]+@\d+\.\d+$`)

// reminderRef picks the stored message ref. On the reaction path it is the
// reacted message from the binding and nothing else (REACT-02: no invented
// provenance); elsewhere the binding's ContextID is a chat context, so only
// the model's explicit message_ref (or none) is used.
func reminderRef(a remindMeArgs, b Binding) string {
	if b.Surface == "reaction" {
		return b.ContextID
	}
	return strings.TrimSpace(a.MessageRef)
}

// NewRemindMe builds the remind_me write tool: a reminder that resurfaces at
// a chosen time — about the reacted message on the reaction path (REACT-02),
// or an optional explicit message_ref in the main chat.
func NewRemindMe() *Tool {
	schema, err := jsonschema.For[remindMeArgs](nil)
	if err != nil {
		panic("remind_me schema: " + err.Error())
	}
	return &Tool{
		Name:        "remind_me",
		Description: "Set a reminder that resurfaces in the Inbox at a chosen time, optionally about one Slack message.",
		InputSchema: schema,
		Access:      AccessWrite,
		// The reaction path (REACT-02 binds the reacted message) and the main
		// chat; never the target chat (TGT-BRIEF-01 axis 3).
		Surfaces: []string{"reaction", "main"},
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a remindMeArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			if strings.TrimSpace(a.RemindAt) == "" {
				return &ValidationError{Msg: "remind_at is required"}
			}
			if _, err := normalizeRemindAt(a.RemindAt); err != nil {
				return err
			}
			if ref := strings.TrimSpace(a.MessageRef); ref != "" && !messageRefRE.MatchString(ref) {
				return &ValidationError{Msg: fmt.Sprintf("message_ref %q must look like <channel_id>@<message_ts>", ref)}
			}
			return nil
		},
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a remindMeArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding remind_me args: %w", err)
			}
			remindAt, err := normalizeRemindAt(a.RemindAt)
			if err != nil {
				return nil, err
			}
			id, err := d.InsertReminder(db.Reminder{
				MessageRef: reminderRef(a, call.Binding),
				Note:       strings.TrimSpace(a.Note),
				RemindAt:   remindAt,
			})
			if err != nil {
				return nil, fmt.Errorf("creating reminder: %w", err)
			}
			return map[string]any{"reminder_id": id}, nil
		},
	}
}

// remindAtUTCLayout is the one shape reminders.remind_at is stored in. Both
// due readers (db.ListDueReminders, Swift ReminderQueries.fetchDue) compare
// the column as TEXT against a UTC "Z" now, so anything else — an offset, a
// natural-language phrase — would fire at the wrong instant or never.
const remindAtUTCLayout = "2006-01-02T15:04:05Z"

// normalizeRemindAt parses the model's remind_at into the stored UTC shape.
// RFC 3339 with any offset is converted; a bare owner-local YYYY-MM-DDTHH:MM
// follows the create_target due precedent (ownerLocalDueToUTC: the CLI runs
// in the owner's TZ, so time.Local is the owner's zone). Anything else is a
// model error, so it comes back as a ValidationError.
func normalizeRemindAt(raw string) (string, error) {
	v := strings.TrimSpace(raw)
	if t, err := time.Parse(time.RFC3339, v); err == nil {
		return t.UTC().Format(remindAtUTCLayout), nil
	}
	if t, err := time.ParseInLocation("2006-01-02T15:04", v, time.Local); err == nil {
		return t.UTC().Format(remindAtUTCLayout), nil
	}
	return "", &ValidationError{Msg: fmt.Sprintf("remind_at %q must be RFC 3339 (e.g. 2026-09-07T09:00:00+02:00) or owner-local YYYY-MM-DDTHH:MM", v)}
}
