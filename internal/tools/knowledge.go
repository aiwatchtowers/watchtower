package tools

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/kb"
)

type searchKnowledgeArgs struct {
	Queries []string `json:"queries" jsonschema:"1-5 search queries: the key terms, synonyms, both Russian and English variants, and word stems ending in * for Russian word forms (e.g. договор*)"`
	Sources []string `json:"sources,omitempty" jsonschema:"optional filter: slack, gmail, imap, jira, calendar, transcript, recap, digest, stream_digest, idea"`
	From    string   `json:"from,omitempty" jsonschema:"only documents active on/after this date (YYYY-MM-DD)"`
	To      string   `json:"to,omitempty" jsonschema:"only documents active on/before this date (YYYY-MM-DD)"`
	Limit   int      `json:"limit,omitempty" jsonschema:"max documents, 0 = default (10), capped at 25"`
}

type getKnowledgeDocumentArgs struct {
	Ref       string `json:"ref" jsonschema:"document ref from search_knowledge"`
	FromChunk int    `json:"from_chunk,omitempty" jsonschema:"start the text at this chunk — pass a hit's chunk to open the document at the matched part; 0 = the start"`
	MaxChars  int    `json:"max_chars,omitempty" jsonschema:"max characters of text, 0 = default (12000), capped at 50000"`
}

// NewSearchKnowledge is the topical search over every indexed source.
func NewSearchKnowledge() *Tool {
	return &Tool{
		Name: "search_knowledge",
		Description: "Search everything Watchtower has seen — Slack threads and DMs, mail, Jira issues with " +
			"comments, calendar events, meeting transcripts and recaps, digests, decisions and ideas — ranked by " +
			"relevance. Pass several queries (synonyms, Russian and English variants, stems with *). Returns " +
			"documents with snippets, a ref for get_knowledge_document, the best-matching chunk (open the " +
			"document there with from_chunk) with its chunk_anchor (e.g. the Slack message ts), and a source " +
			"anchor and permalink for links.",
		InputSchema: mustSchema[searchKnowledgeArgs]("search_knowledge"),
		Access:      AccessRead,
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a searchKnowledgeArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			req := kb.Request{Queries: a.Queries, Sources: a.Sources, Limit: a.Limit}
			var err error
			if req.From, err = parseDay(a.From, false); err != nil {
				return nil, &ValidationError{Msg: "from must be YYYY-MM-DD"}
			}
			if req.To, err = parseDay(a.To, true); err != nil {
				return nil, &ValidationError{Msg: "to must be YYYY-MM-DD"}
			}
			res, err := kb.Search(ctx, d, req)
			var re *kb.RequestError
			if errors.As(err, &re) {
				return nil, &ValidationError{Msg: re.Msg}
			}
			if err != nil {
				return nil, fmt.Errorf("searching knowledge: %w", err)
			}
			return res, nil
		},
	}
}

// parseDay parses a YYYY-MM-DD filter date in UTC; "" passes through as "no
// bound". endOfDay widens the parsed day to the next midnight (an exclusive
// upper bound), matching kb.Request.To's semantics — unlike dateBound (which
// widens to an inclusive T23:59:59Z string), kb compares against a time.Time
// exclusive bound, so it needs its own helper rather than reusing dateBound.
func parseDay(s string, endOfDay bool) (time.Time, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return time.Time{}, nil
	}
	t, err := time.Parse("2006-01-02", s)
	if err != nil {
		return time.Time{}, err
	}
	if endOfDay {
		t = t.AddDate(0, 0, 1)
	}
	return t, nil
}

// NewGetKnowledgeDocument opens one search hit in full.
func NewGetKnowledgeDocument() *Tool {
	return &Tool{
		Name:        "get_knowledge_document",
		Description: "Open one search_knowledge hit by its ref: the document text (capped; from_chunk starts it at a hit's chunk), title, time, link and source anchor.",
		InputSchema: mustSchema[getKnowledgeDocumentArgs]("get_knowledge_document"),
		Access:      AccessRead,
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a getKnowledgeDocumentArgs
			if err := json.Unmarshal(call.Args, &a); err != nil || strings.TrimSpace(a.Ref) == "" {
				return nil, &ValidationError{Msg: "ref is required"}
			}
			doc, err := kb.GetDocument(ctx, d, a.Ref, kb.DocOptions{FromChunk: a.FromChunk, MaxChars: a.MaxChars})
			if errors.Is(err, kb.ErrNotFound) {
				return nil, &ValidationError{Msg: "no document with that ref — search again"}
			}
			var re *kb.RequestError
			if errors.As(err, &re) {
				return nil, &ValidationError{Msg: re.Msg}
			}
			if err != nil {
				return nil, fmt.Errorf("opening knowledge document: %w", err)
			}
			return doc, nil
		},
	}
}
