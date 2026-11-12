package builtin

import (
	"context"
	"fmt"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/db"
	"watchtower/internal/policy"
)

// SlackWindowPrimitives returns slack.window over d: the Slack messages past
// the call's Cursor (db.ReadSlackWindow, arrival order, cut at its caps) in
// the calling built-in's WindowScope, as {status: "done", day, owner: {name},
// messages: [{id, channel_id, channel, author, at, time, text, thread_id,
// permalink, by_owner, to_owner, bot}], count, truncated, skipped_older,
// below_floor}, with NextCursor the next read's cursor (never behind the
// call's) and Behind when a cap cut the window. Floor "today" starts the
// window at local midnight of now. A policy that turns Slack off reads
// nothing: {status: "skipped", reason: "source_off", day, messages: []}
// with the call's cursor. It calls no model.
func SlackWindowPrimitives(d *db.DB, now func() time.Time) map[string]automations.PrimitiveFunc {
	return map[string]automations.PrimitiveFunc{
		automations.PrimitiveSlackWindow: func(ctx context.Context, call automations.PrimitiveCall) (automations.PrimitiveResult, error) {
			if d == nil {
				return automations.PrimitiveResult{}, errNotWired
			}
			entry, ok := Lookup(call.BuiltinID)
			if !ok {
				return automations.PrimitiveResult{}, fmt.Errorf("slack.window: unknown built-in %q", call.BuiltinID)
			}
			if entry.WindowScope == "" {
				return automations.PrimitiveResult{}, fmt.Errorf("slack.window: built-in %q declares no window scope", call.BuiltinID)
			}
			at := now().In(time.Local)
			if !policy.SourceAllowed("slack") {
				return automations.PrimitiveResult{Status: "skipped", NextCursor: call.Cursor,
					Fields: map[string]any{"reason": "source_off", "day": at.Format("2006-01-02"), "messages": []any{}}}, nil
			}
			q := db.SlackWindowQuery{Scope: entry.WindowScope, AfterRowID: call.Cursor, Now: at}
			switch call.Floor {
			case "":
			case automations.WindowFloorToday:
				q.Floor = time.Date(at.Year(), at.Month(), at.Day(), 0, 0, 0, 0, time.Local)
			default:
				return automations.PrimitiveResult{}, fmt.Errorf("slack.window: unknown floor %q", call.Floor)
			}
			owner, err := d.ResolveOwner()
			if err != nil {
				return automations.PrimitiveResult{}, err
			}
			w, err := d.ReadSlackWindow(ctx, q)
			if err != nil {
				return automations.PrimitiveResult{}, err
			}
			msgs := slackWindowRows(w.Messages)
			return automations.PrimitiveResult{
				Status: "done",
				Fields: map[string]any{
					"day":           at.Format("2006-01-02"),
					"owner":         map[string]any{"name": owner.DisplayName},
					"messages":      msgs,
					"count":         len(msgs),
					"truncated":     w.Truncated,
					"skipped_older": w.SkippedOlder,
					"below_floor":   w.BelowFloor,
				},
				NextCursor: max(w.NextRowID, call.Cursor),
				Behind:     w.Truncated,
			}, nil
		},
	}
}

// slackWindowRows is the script's view of the window, in the row shape
// db.SlackWindowRowOverheadBytes is sized on: a field added here re-sizes it.
func slackWindowRows(msgs []db.SlackWindowMessage) []any {
	rows := make([]any, 0, len(msgs))
	for _, m := range msgs {
		rows = append(rows, map[string]any{
			"id":         m.ID(),
			"channel_id": m.ChannelID,
			"channel":    m.ChannelName,
			"author":     m.Author,
			"at":         m.At.UTC().Format(time.RFC3339),
			"time":       m.At.In(time.Local).Format("15:04"),
			"text":       m.Text,
			"thread_id":  m.ThreadID(),
			"permalink":  webLink(m.Permalink),
			"by_owner":   m.ByOwner,
			"to_owner":   m.ToOwner,
			"bot":        m.Bot,
		})
	}
	return rows
}
