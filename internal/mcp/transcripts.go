package mcp

import (
	"context"
	"encoding/json"
	"strconv"
	"time"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

type listTranscriptsArgs struct {
	EventID string `json:"event_id,omitempty" jsonschema:"filter to one calendar event id"`
	From    string `json:"from,omitempty" jsonschema:"only transcripts recorded on/after this date (YYYY-MM-DD)"`
	To      string `json:"to,omitempty" jsonschema:"only transcripts recorded on/before this date (YYYY-MM-DD)"`
	Limit   int    `json:"limit,omitempty" jsonschema:"max results, 0 = default (50), capped at 200"`
}

type getTranscriptArgs struct {
	ID int64 `json:"id" jsonschema:"transcript id from list_transcripts"`
}

// transcriptRecap mirrors the recap JSON shape produced by the meeting
// pipeline ({summary, key_decisions, action_items, open_questions}) — stored
// in meeting_transcripts.summary_json for ad-hoc recordings, or in
// meeting_recaps.recap_json via the linked calendar event.
type transcriptRecap struct {
	Summary       string   `json:"summary"`
	KeyDecisions  []string `json:"key_decisions"`
	ActionItems   []string `json:"action_items"`
	OpenQuestions []string `json:"open_questions"`
}

// transcriptRow is the LLM-facing list shape: metadata plus a one-line recap
// summary, never the full transcript text (that is get_transcript's job).
type transcriptRow struct {
	ID          int64  `json:"id"`
	Title       string `json:"title"`
	EventID     string `json:"event_id,omitempty"`
	EventTitle  string `json:"event_title,omitempty"`
	DurationSec int    `json:"duration_sec"`
	CreatedAt   string `json:"created_at"`
	Summary     string `json:"summary,omitempty"`
}

// transcriptDetail is the get_transcript shape: the list row plus the full
// transcript text and the parsed recap fields.
type transcriptDetail struct {
	transcriptRow
	TranscriptText string   `json:"transcript_text"`
	KeyDecisions   []string `json:"key_decisions,omitempty"`
	ActionItems    []string `json:"action_items,omitempty"`
	OpenQuestions  []string `json:"open_questions,omitempty"`
}

func registerTranscripts(s *mcpsdk.Server, database *db.DB) {
	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name: "list_transcripts",
		Description: "List locally-recorded meeting transcripts (title, linked calendar event, " +
			"recap summary). Use to find what was discussed/decided in a meeting; fetch full " +
			"text with get_transcript.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args listTranscriptsArgs) (*mcpsdk.CallToolResult, any, error) {
		from, fromMsg := dateBound(args.From, "from", "T00:00:00Z")
		to, toMsg := dateBound(args.To, "to", "T23:59:59Z")
		if msg := firstError(fromMsg, toMsg); msg != "" {
			return errResult(msg), nil, nil
		}

		transcripts, err := database.ListMeetingTranscripts(db.MeetingTranscriptFilter{
			EventID:  args.EventID,
			FromTime: from,
			ToTime:   to,
			Limit:    listLimit(args.Limit),
		})
		if err != nil {
			return errResult("listing transcripts: " + err.Error()), nil, nil
		}
		rows := make([]transcriptRow, 0, len(transcripts))
		for i := range transcripts {
			tr := &transcripts[i]
			rows = append(rows, renderTranscriptRow(database, tr, transcriptRecapFor(database, tr)))
		}
		return jsonListResult(rows)
	})

	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name: "get_transcript",
		Description: "Fetch one meeting transcript by id: the full transcript text plus the " +
			"parsed recap (summary, key decisions, action items, open questions).",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args getTranscriptArgs) (*mcpsdk.CallToolResult, any, error) {
		tr, err := database.GetMeetingTranscript(args.ID)
		if err != nil {
			return errResult("loading transcript: " + err.Error()), nil, nil
		}
		if tr == nil {
			return errResult("no transcript with id " + strconv.FormatInt(args.ID, 10)), nil, nil
		}
		recap := transcriptRecapFor(database, tr)
		return jsonResult(transcriptDetail{
			transcriptRow:  renderTranscriptRow(database, tr, recap),
			TranscriptText: tr.TranscriptText,
			KeyDecisions:   recap.KeyDecisions,
			ActionItems:    recap.ActionItems,
			OpenQuestions:  recap.OpenQuestions,
		})
	})
}

// dateBound validates a YYYY-MM-DD filter date and widens it to an ISO8601
// bound for created_at comparison ("" passes through as "no filter").
func dateBound(date, field, timeSuffix string) (bound, errMsg string) {
	if date == "" {
		return "", ""
	}
	if _, err := time.Parse("2006-01-02", date); err != nil {
		return "", "invalid " + field + " date " + strconv.Quote(date) + ": must be YYYY-MM-DD"
	}
	return date + timeSuffix, ""
}

// renderTranscriptRow builds the list shape: the linked calendar event's title
// (when the event still exists) and the one-line summary from the caller's
// already-computed recap (see transcriptRecapFor).
func renderTranscriptRow(database *db.DB, tr *db.MeetingTranscript, recap transcriptRecap) transcriptRow {
	row := transcriptRow{
		ID:          tr.ID,
		Title:       tr.Title,
		DurationSec: tr.DurationSec,
		CreatedAt:   tr.CreatedAt,
		Summary:     recap.Summary,
	}
	if tr.EventID.Valid {
		row.EventID = tr.EventID.String
		if ev, err := database.GetCalendarEventByID(tr.EventID.String); err == nil && ev != nil {
			row.EventTitle = ev.Title
		}
	}
	return row
}

// transcriptRecapFor parses the recap attached to a transcript: its own
// summary_json (ad-hoc recordings) or, for event-linked transcripts, the
// meeting_recaps row of the linked event. Missing or malformed recap JSON
// yields a zero recap — transcripts are useful without one.
func transcriptRecapFor(database *db.DB, tr *db.MeetingTranscript) transcriptRecap {
	raw := ""
	if tr.SummaryJSON.Valid && tr.SummaryJSON.String != "" {
		raw = tr.SummaryJSON.String
	} else if tr.EventID.Valid {
		if r, err := database.GetMeetingRecap(tr.EventID.String); err == nil && r != nil {
			raw = r.RecapJSON
		}
	}
	var recap transcriptRecap
	if raw != "" {
		_ = json.Unmarshal([]byte(raw), &recap)
	}
	return recap
}
