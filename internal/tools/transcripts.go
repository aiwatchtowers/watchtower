package tools

import (
	"context"
	"encoding/json"
	"fmt"

	"watchtower/internal/db"
)

type listTranscriptsArgs struct {
	Query   string `json:"query,omitempty" jsonschema:"full-text search over transcript content; when set, returns ranked matches with a snippet instead of a plain listing (cannot be combined with event_id/from/to)"`
	EventID string `json:"event_id,omitempty" jsonschema:"filter to one calendar event id"`
	From    string `json:"from,omitempty" jsonschema:"only transcripts recorded on/after this date (YYYY-MM-DD)"`
	To      string `json:"to,omitempty" jsonschema:"only transcripts recorded on/before this date (YYYY-MM-DD)"`
	Limit   int    `json:"limit,omitempty" jsonschema:"max results, 0 = default (50), capped at 200"`
}

type getTranscriptArgs struct {
	ID int64 `json:"id" jsonschema:"transcript id from list_transcripts"`
}

// transcriptRecap mirrors the recap JSON shape produced by the meeting pipeline
// ({summary, key_decisions, action_items, open_questions}) — stored in
// meeting_transcripts.summary_json for ad-hoc recordings, or in
// meeting_recaps.recap_json via the linked calendar event.
type transcriptRecap struct {
	Summary       string   `json:"summary"`
	KeyDecisions  []string `json:"key_decisions"`
	ActionItems   []string `json:"action_items"`
	OpenQuestions []string `json:"open_questions"`
}

// transcriptRow is the LLM-facing list shape: metadata plus a one-line recap
// summary, never the full transcript text (that is get_transcript's job).
// Snippet is populated only by the query path (renderSearchHit).
type transcriptRow struct {
	ID          int64  `json:"id"`
	Title       string `json:"title"`
	EventID     string `json:"event_id,omitempty"`
	EventTitle  string `json:"event_title,omitempty"`
	DurationSec int    `json:"duration_sec"`
	CreatedAt   string `json:"created_at"`
	Summary     string `json:"summary,omitempty"`
	Snippet     string `json:"snippet,omitempty"`
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

// NewListTranscripts lists locally-recorded meeting transcripts, or — when
// query is set — full-text-searches them for ranked snippet hits.
func NewListTranscripts() *Tool {
	return &Tool{
		Name: "list_transcripts",
		Description: "List locally-recorded meeting transcripts (title, linked calendar event, " +
			"recap summary). Use to find what was discussed/decided in a meeting; fetch full " +
			"text with get_transcript.",
		InputSchema: mustSchema[listTranscriptsArgs]("list_transcripts"),
		Access:      AccessRead,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a listTranscriptsArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			if a.Query != "" {
				if a.EventID != "" || a.From != "" || a.To != "" {
					return nil, &ValidationError{Msg: "query cannot be combined with event_id/from/to"}
				}
				hits, err := d.SearchTranscripts(a.Query, listLimit(a.Limit))
				if err != nil {
					return nil, fmt.Errorf("searching transcripts: %w", err)
				}
				rows := make([]transcriptRow, 0, len(hits))
				for i := range hits {
					rows = append(rows, renderSearchHit(d, &hits[i]))
				}
				return rows, nil
			}

			from, err := dateBound(a.From, "from", "T00:00:00Z")
			if err != nil {
				return nil, err
			}
			to, err := dateBound(a.To, "to", "T23:59:59Z")
			if err != nil {
				return nil, err
			}
			transcripts, err := d.ListMeetingTranscripts(db.MeetingTranscriptFilter{
				EventID: a.EventID, FromTime: from, ToTime: to, Limit: listLimit(a.Limit),
			})
			if err != nil {
				return nil, fmt.Errorf("listing transcripts: %w", err)
			}
			rows := make([]transcriptRow, 0, len(transcripts))
			for i := range transcripts {
				tr := &transcripts[i]
				rows = append(rows, renderTranscriptRow(d, tr, transcriptRecapFor(d, tr)))
			}
			return rows, nil
		},
	}
}

// NewGetTranscript fetches one transcript by id: full text plus the parsed recap.
func NewGetTranscript() *Tool {
	return &Tool{
		Name: "get_transcript",
		Description: "Fetch one meeting transcript by id: the full transcript text plus the " +
			"parsed recap (summary, key decisions, action items, open questions).",
		InputSchema: mustSchema[getTranscriptArgs]("get_transcript"),
		Access:      AccessRead,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a getTranscriptArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			tr, err := d.GetMeetingTranscript(a.ID)
			if err != nil {
				return nil, fmt.Errorf("loading transcript: %w", err)
			}
			if tr == nil {
				return nil, fmt.Errorf("no transcript with id %d", a.ID)
			}
			recap := transcriptRecapFor(d, tr)
			return transcriptDetail{
				transcriptRow:  renderTranscriptRow(d, tr, recap),
				TranscriptText: tr.TranscriptText,
				KeyDecisions:   recap.KeyDecisions,
				ActionItems:    recap.ActionItems,
				OpenQuestions:  recap.OpenQuestions,
			}, nil
		},
	}
}

// renderTranscriptRow builds the list shape: the linked calendar event's title
// (when the event still exists) and the one-line summary from the caller's
// already-computed recap (see transcriptRecapFor).
func renderTranscriptRow(d *db.DB, tr *db.MeetingTranscript, recap transcriptRecap) transcriptRow {
	row := transcriptRow{
		ID: tr.ID, Title: tr.Title, DurationSec: tr.DurationSec, CreatedAt: tr.CreatedAt, Summary: recap.Summary,
	}
	if tr.EventID.Valid {
		row.EventID = tr.EventID.String
		if ev, err := d.GetCalendarEventByID(tr.EventID.String); err == nil && ev != nil {
			row.EventTitle = ev.Title
		}
	}
	return row
}

// renderSearchHit builds the list shape from a full-text hit. Unlike
// renderTranscriptRow it never loads the transcript row itself — that would mean
// fetching transcript_text for every hit just to render a snippet (the perf
// guard the Desktop list projection follows). The event title is still resolved
// (a cheap calendar_events lookup); DurationSec/Summary stay zero for hits.
func renderSearchHit(d *db.DB, h *db.TranscriptHit) transcriptRow {
	row := transcriptRow{ID: h.ID, Title: h.Title, CreatedAt: h.CreatedAt, Snippet: h.Snippet}
	if h.EventID != "" {
		row.EventID = h.EventID
		if ev, err := d.GetCalendarEventByID(h.EventID); err == nil && ev != nil {
			row.EventTitle = ev.Title
		}
	}
	return row
}

// transcriptRecapFor parses the recap attached to a transcript: its own
// summary_json (ad-hoc recordings) or, for event-linked transcripts, the
// meeting_recaps row of the linked event. Missing or malformed recap JSON yields
// a zero recap — transcripts are useful without one.
func transcriptRecapFor(d *db.DB, tr *db.MeetingTranscript) transcriptRecap {
	raw := ""
	if tr.SummaryJSON.Valid && tr.SummaryJSON.String != "" {
		raw = tr.SummaryJSON.String
	} else if tr.EventID.Valid {
		if r, err := d.GetMeetingRecap(tr.EventID.String); err == nil && r != nil {
			raw = r.RecapJSON
		}
	}
	var recap transcriptRecap
	if raw != "" {
		_ = json.Unmarshal([]byte(raw), &recap)
	}
	return recap
}
