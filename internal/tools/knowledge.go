package tools

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/kb"
)

type searchKnowledgeArgs struct {
	Queries []string `json:"queries" jsonschema:"1-5 search queries: the key terms, synonyms, both Russian and English variants, and word stems ending in * for Russian word forms (e.g. договор*)"`
	Sources []string `json:"sources,omitempty" jsonschema:"optional filter: slack, gmail, imap, jira, confluence, calendar, transcript, recap, digest, stream_digest, idea, project_doc (this project's attached documents; project sessions only)"`
	From    string   `json:"from,omitempty" jsonschema:"only documents active on/after this date (YYYY-MM-DD)"`
	To      string   `json:"to,omitempty" jsonschema:"only documents active on/before this date (YYYY-MM-DD)"`
	Limit   int      `json:"limit,omitempty" jsonschema:"max documents, 0 = default (10), capped at 25"`
	// ProjectScope is honoured only in a project session (watchtower mcp
	// --project N); elsewhere a value is refused rather than ignored.
	ProjectScope string `json:"project_scope,omitempty" jsonschema:"project sessions only: boost (default) ranks hits from this project's Slack channels, Jira projects and Confluence spaces first (marked in_scope) and drops nothing; only returns just those; off ignores them"`
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
			"comments, Confluence pages with comments and attachments, calendar events, meeting transcripts and recaps, digests, decisions and ideas — ranked by " +
			"relevance. Pass several queries (synonyms, Russian and English variants, stems with *). Returns " +
			"documents with snippets, a ref for get_knowledge_document, the best-matching chunk (open the " +
			"document there with from_chunk) with its chunk_anchor (e.g. the Slack message ts), and a source " +
			"anchor and permalink for links. In a project session, hits from the project's own sources rank " +
			"first and carry in_scope (project_scope: only or off to change that), and the project's attached " +
			"documents (source project_doc) are searchable too.",
		InputSchema: mustSchema[searchKnowledgeArgs]("search_knowledge"),
		Access:      AccessRead,
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a searchKnowledgeArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			// A project session sees its own attached documents; every other
			// caller (ProjectID 0) none of them (PROJ-08).
			req := kb.Request{Queries: a.Queries, Sources: a.Sources, Limit: a.Limit, ProjectID: call.Binding.ProjectID}
			var err error
			if req.From, err = parseDay(a.From, false); err != nil {
				return nil, &ValidationError{Msg: "from must be YYYY-MM-DD"}
			}
			if req.To, err = parseDay(a.To, true); err != nil {
				return nil, &ValidationError{Msg: "to must be YYYY-MM-DD"}
			}
			scopeNote, err := applyProjectScope(ctx, d, call.Binding, a.ProjectScope, &req)
			if err != nil {
				return nil, err
			}
			res, err := kb.Search(ctx, d, req)
			var re *kb.RequestError
			if errors.As(err, &re) {
				return nil, &ValidationError{Msg: re.Msg}
			}
			if err != nil {
				return nil, fmt.Errorf("searching knowledge: %w", err)
			}
			res.ScopeNote = scopeNote
			return res, nil
		},
	}
}

// scopeSources are the kb sources a project scope can hold documents of.
var scopeSources = []string{"slack", "jira", "confluence"}

// applyProjectScope sets req's scope from the bound project's sources:
// boost by default, only/off on request. An explicit sources filter still
// applies on top (kb.Search honours it in the scoped retrieval too). The
// returned note names the project's sources that matched no synced data.
func applyProjectScope(ctx context.Context, d *db.DB, b Binding, mode string, req *kb.Request) (string, error) {
	mode = strings.TrimSpace(mode)
	if b.ProjectID == 0 {
		if mode != "" {
			return "", &ValidationError{Msg: "project_scope works only in a project session (watchtower mcp --project N)"}
		}
		return "", nil
	}
	if err := validateEnum("project_scope", mode, "boost", "only", "off"); err != nil {
		return "", err
	}
	if mode == "off" {
		return "", nil
	}
	scope, unresolved, err := ProjectKnowledgeScope(ctx, d, b.ProjectID)
	if err != nil {
		return "", err
	}
	only := mode == "only"
	if only && scope.Empty() {
		return "", &ValidationError{Msg: "this project has no usable Slack channel, Jira project or Confluence space source — add one with add_project_source, or search without project_scope"}
	}
	if only && len(req.Sources) > 0 && !slices.ContainsFunc(req.Sources, func(s string) bool { return slices.Contains(scopeSources, s) }) {
		return "", &ValidationError{Msg: "project_scope only covers slack, jira and confluence; sources names none of them"}
	}
	req.Scope, req.ScopeOnly = scope, only
	if len(unresolved) == 0 {
		return "", nil
	}
	return "left out of the project scope (no synced Slack channel by that ref, or not a Jira project or Confluence space key): " + strings.Join(unresolved, "; "), nil
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
			doc, err := kb.GetDocument(ctx, d, a.Ref, kb.DocOptions{FromChunk: a.FromChunk, MaxChars: a.MaxChars, ProjectID: call.Binding.ProjectID})
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
