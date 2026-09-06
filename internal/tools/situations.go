package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"time"

	"github.com/google/jsonschema-go/jsonschema"

	"watchtower/internal/db"
)

// situationStatuses are the values list_situations accepts, matching the MCP
// list_situations handler's enum.
var situationStatuses = []string{"open", "done", "dismissed", "converted", "stale", "snoozed"}

type listSituationsArgs struct {
	Status string `json:"status,omitempty" jsonschema:"filter by status: open|done|dismissed|converted|stale|snoozed (default open)"`
	Since  string `json:"since,omitempty" jsonschema:"only situations with a signal on/after this date (YYYY-MM-DD)"`
	Limit  int    `json:"limit,omitempty" jsonschema:"max results, 0 = default 50"`
}

type getSituationArgs struct {
	ID int `json:"id" jsonschema:"situation id from list_situations"`
}

// situationView is the read shape returned to the model — a curated projection
// of db.DashboardSituation with stable snake_case keys. It duplicates no logic
// (a field copy, not behaviour); the tools package cannot reuse internal/mcp's
// renderer without an import cycle, since mcp already imports tools.
type situationView struct {
	ID           int    `json:"id"`
	Title        string `json:"title"`
	Status       string `json:"status"`
	Priority     string `json:"priority"`
	Kind         string `json:"kind"`
	WhyMatters   string `json:"why_matters,omitempty"`
	LastSignalAt string `json:"last_signal_at,omitempty"`
}

type situationDetailView struct {
	situationView
	Summary           string       `json:"summary,omitempty"`
	Chronology        string       `json:"chronology,omitempty"`
	ConvertedTargetID int          `json:"converted_target_id,omitempty"`
	ConvertedTrackID  int          `json:"converted_track_id,omitempty"`
	Signals           []signalView `json:"signals"`
}

type signalView struct {
	Sender    string `json:"sender"`
	ChannelID string `json:"channel_id,omitempty"`
	MessageTS string `json:"message_ts,omitempty"`
	Snippet   string `json:"snippet"`
	Permalink string `json:"permalink,omitempty"`
}

func viewOf(s *db.DashboardSituation) situationView {
	return situationView{
		ID: s.ID, Title: s.Title, Status: s.Status, Priority: s.Priority,
		Kind: s.Kind, WhyMatters: s.WhyMatters, LastSignalAt: s.LastSignalAt,
	}
}

// NewListSituations is the read tool listing the assistant's situations. It is a
// thin adapter over db.ListSituations, registered for the runtime-B tool loop
// (the MCP list_situations handler stays as it is until the full migration).
func NewListSituations() *Tool {
	schema, err := jsonschema.For[listSituationsArgs](nil)
	if err != nil {
		panic("list_situations schema: " + err.Error())
	}
	return &Tool{
		Name: "list_situations",
		Description: "List the assistant's situations — clustered stories from Slack, Jira, mail and " +
			"calendar that need the owner's attention. Use to answer 'what is going on' or 'what changed'.",
		InputSchema: schema,
		Access:      AccessRead,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a listSituationsArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			status := a.Status
			if status == "" {
				status = "open"
			} else if !slices.Contains(situationStatuses, status) {
				// Without this an unknown status silently matches no rows; the model
				// must learn it passed a bad value, not get an empty list.
				return nil, &ValidationError{Msg: "status must be one of: open, done, dismissed, converted, stale, snoozed"}
			}
			var since string
			if a.Since != "" {
				if _, err := time.Parse("2006-01-02", a.Since); err != nil {
					return nil, &ValidationError{Msg: `since must be a date in YYYY-MM-DD form`}
				}
				since = a.Since + "T00:00:00Z"
			}
			situations, err := d.ListSituations(db.SituationFilter{Status: status, SinceISO: since, Limit: listLimit(a.Limit)})
			if err != nil {
				return nil, fmt.Errorf("listing situations: %w", err)
			}
			rows := make([]situationView, 0, len(situations))
			for i := range situations {
				rows = append(rows, viewOf(&situations[i]))
			}
			return rows, nil
		},
	}
}

// NewGetSituation is the read tool fetching one situation with its member
// signals — a thin adapter over db.GetSituation + db.ListSituationSignals.
func NewGetSituation() *Tool {
	schema, err := jsonschema.For[getSituationArgs](nil)
	if err != nil {
		panic("get_situation schema: " + err.Error())
	}
	return &Tool{
		Name: "get_situation",
		Description: "Fetch one situation by id: the assistant's card (why it matters, summary, chronology) " +
			"plus the member messages it was built from.",
		InputSchema: schema,
		Access:      AccessRead,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a getSituationArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			s, err := d.GetSituation(a.ID)
			if err != nil {
				if errors.Is(err, sql.ErrNoRows) {
					return nil, fmt.Errorf("no situation with id %d", a.ID)
				}
				return nil, fmt.Errorf("getting situation: %w", err)
			}
			signals, err := d.ListSituationSignals(a.ID)
			if err != nil {
				return nil, fmt.Errorf("listing signals: %w", err)
			}
			detail := situationDetailView{
				situationView: viewOf(&s),
				Summary:       s.Summary,
				Chronology:    s.Chronology,
				Signals:       make([]signalView, 0, len(signals)),
			}
			if s.ConvertedTargetID != nil {
				detail.ConvertedTargetID = *s.ConvertedTargetID
			}
			if s.ConvertedTrackID != nil {
				detail.ConvertedTrackID = *s.ConvertedTrackID
			}
			for _, it := range signals {
				detail.Signals = append(detail.Signals, signalView{
					Sender: it.SenderUserID, ChannelID: it.ChannelID,
					MessageTS: it.MessageTS, Snippet: it.Snippet, Permalink: it.Permalink,
				})
			}
			return detail, nil
		},
	}
}
