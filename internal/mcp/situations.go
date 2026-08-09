package mcp

import (
	"context"
	"strconv"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

type listSituationsArgs struct {
	Status string `json:"status,omitempty" jsonschema:"filter by status: open|done|dismissed|converted|stale|snoozed (default: open)"`
	Since  string `json:"since,omitempty" jsonschema:"only situations with a signal on/after this date (YYYY-MM-DD)"`
	Limit  int    `json:"limit,omitempty" jsonschema:"max results, 0 = default (50), capped at 200"`
}

type getSituationArgs struct {
	ID int `json:"id" jsonschema:"situation id from list_situations"`
}

// situationRow is the list shape: what the situation is and why it matters,
// without the full chronology (that is get_situation's job).
type situationRow struct {
	ID           int    `json:"id"`
	Title        string `json:"title"`
	Status       string `json:"status"`
	Priority     string `json:"priority"`
	Kind         string `json:"kind"`
	WhyMatters   string `json:"why_matters,omitempty"`
	LastSignalAt string `json:"last_signal_at,omitempty"`
}

// situationSignal is one member message folded into a situation.
type situationSignal struct {
	SenderUserID string `json:"sender"`
	ChannelID    string `json:"channel_id,omitempty"`
	MessageTS    string `json:"message_ts,omitempty"`
	Snippet      string `json:"snippet"`
	Permalink    string `json:"permalink,omitempty"`
}

// situationDetail is the get_situation shape: the row plus the secretary card
// and the signals that produced it.
type situationDetail struct {
	situationRow
	Summary           string            `json:"summary,omitempty"`
	Chronology        string            `json:"chronology,omitempty"`
	ConvertedTargetID int               `json:"converted_target_id,omitempty"`
	ConvertedTrackID  int               `json:"converted_track_id,omitempty"`
	Signals           []situationSignal `json:"signals"`
}

func registerSituations(s *mcpsdk.Server, database *db.DB) {
	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name: "list_situations",
		Description: "List the secretary's situations — clustered stories from Slack, Jira, " +
			"mail and calendar that need the owner's attention. Use to answer " +
			"'what is going on' or 'what changed recently'.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args listSituationsArgs) (*mcpsdk.CallToolResult, any, error) {
		if msg := validateEnum("status", args.Status,
			"open", "done", "dismissed", "converted", "stale", "snoozed"); msg != "" {
			return errResult(msg), nil, nil
		}
		since, sinceMsg := dateBound(args.Since, "since", "T00:00:00Z")
		if sinceMsg != "" {
			return errResult(sinceMsg), nil, nil
		}
		status := args.Status
		if status == "" {
			status = "open"
		}

		situations, err := database.ListSituations(db.SituationFilter{
			Status:   status,
			SinceISO: since,
			Limit:    listLimit(args.Limit),
		})
		if err != nil {
			return errResult("listing situations: " + err.Error()), nil, nil
		}
		rows := make([]situationRow, 0, len(situations))
		for i := range situations {
			rows = append(rows, renderSituationRow(&situations[i]))
		}
		return jsonListResult(rows)
	})

	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name: "get_situation",
		Description: "Fetch one situation by id: the secretary's card (why it matters, summary, " +
			"chronology) plus the member messages it was built from.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args getSituationArgs) (*mcpsdk.CallToolResult, any, error) {
		situation, err := database.GetSituation(args.ID)
		if err != nil {
			return errResult("no situation with id " + strconv.Itoa(args.ID)), nil, nil
		}
		signals, err := database.ListSituationSignals(args.ID)
		if err != nil {
			return errResult("listing signals: " + err.Error()), nil, nil
		}
		detail := situationDetail{
			situationRow: renderSituationRow(&situation),
			Summary:      situation.Summary,
			Chronology:   situation.Chronology,
			Signals:      make([]situationSignal, 0, len(signals)),
		}
		if situation.ConvertedTargetID != nil {
			detail.ConvertedTargetID = *situation.ConvertedTargetID
		}
		if situation.ConvertedTrackID != nil {
			detail.ConvertedTrackID = *situation.ConvertedTrackID
		}
		for _, item := range signals {
			detail.Signals = append(detail.Signals, situationSignal{
				SenderUserID: item.SenderUserID,
				ChannelID:    item.ChannelID,
				MessageTS:    item.MessageTS,
				Snippet:      item.Snippet,
				Permalink:    item.Permalink,
			})
		}
		return jsonResult(detail)
	})
}

func renderSituationRow(s *db.DashboardSituation) situationRow {
	return situationRow{
		ID:           s.ID,
		Title:        s.Title,
		Status:       s.Status,
		Priority:     s.Priority,
		Kind:         s.Kind,
		WhyMatters:   s.WhyMatters,
		LastSignalAt: s.LastSignalAt,
	}
}
