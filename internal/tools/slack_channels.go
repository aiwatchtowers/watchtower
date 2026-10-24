package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"watchtower/internal/db"
)

// maxSlackChannels caps list_slack_channels (spec 2026-10-24 §7).
const maxSlackChannels = 500

type listSlackChannelsArgs struct {
	Query           string `json:"query,omitempty" jsonschema:"case-insensitive part of the channel name"`
	Account         string `json:"account,omitempty" jsonschema:"Slack account id: only that workspace's channels"`
	IncludeArchived bool   `json:"include_archived,omitempty" jsonschema:"also list archived channels (default false)"`
}

type slackChannelRow struct {
	ID           string `json:"id"`
	Account      string `json:"account"`
	Name         string `json:"name"`
	Type         string `json:"type"`
	IsMember     bool   `json:"is_member"`
	IsArchived   bool   `json:"is_archived"`
	NumMembers   int    `json:"num_members"`
	LastActivity string `json:"last_activity"`
}

// NewListSlackChannels lists the synced Slack channels from the local store:
// no network. It is a chat read for the main and editor chats; a recipe reads
// channels through its own tools.
func NewListSlackChannels() *Tool {
	return &Tool{
		Name: "list_slack_channels",
		Description: "List the Slack channels synced into the local store (no network): id, account, name, type, " +
			"membership, archived flag, member count and last_activity (the newest synced message time, or empty). " +
			"Newest activity first, at most 500. Use it to pick a channel id for a recipe's trigger or a Slack output.",
		InputSchema: mustSchema[listSlackChannelsArgs]("list_slack_channels"),
		Access:      AccessRead,
		Surfaces:    []string{"main", AutomationEditorSurface},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a listSlackChannelsArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments", Err: err}
			}
			q := `SELECT c.id, c.name, c.type, c.is_member, c.is_archived, c.num_members,
  COALESCE((SELECT strftime('%Y-%m-%dT%H:%M:%SZ', MAX(m.ts_unix), 'unixepoch')
            FROM messages m WHERE m.channel_id = c.id), '') AS last_activity
FROM channels c WHERE 1=1`
			var args []any
			if !a.IncludeArchived {
				q += ` AND c.is_archived = 0`
			}
			if s := strings.TrimSpace(a.Query); s != "" {
				q += ` AND LOWER(c.name) LIKE ? ESCAPE '\'`
				esc := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(strings.ToLower(s))
				args = append(args, "%"+esc+"%")
			}
			if acct := strings.TrimSpace(a.Account); acct != "" {
				q += ` AND c.id LIKE ? ESCAPE '\'`
				esc := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(acct)
				args = append(args, esc+":%")
			}
			q += fmt.Sprintf(` ORDER BY last_activity DESC, c.name LIMIT %d`, maxSlackChannels)
			rows, err := d.QueryContext(ctx, q, args...)
			if err != nil {
				return nil, fmt.Errorf("listing slack channels: %w", err)
			}
			defer rows.Close()
			out := []slackChannelRow{}
			for rows.Next() {
				var r slackChannelRow
				var member, archived int
				if err := rows.Scan(&r.ID, &r.Name, &r.Type, &member, &archived, &r.NumMembers, &r.LastActivity); err != nil {
					return nil, fmt.Errorf("scanning slack channel: %w", err)
				}
				r.IsMember, r.IsArchived = member != 0, archived != 0
				r.Account, _, _ = strings.Cut(r.ID, ":")
				out = append(out, r)
			}
			if err := rows.Err(); err != nil {
				return nil, fmt.Errorf("listing slack channels: %w", err)
			}
			return map[string]any{"channels": out}, nil
		},
	}
}
