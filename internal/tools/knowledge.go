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
	Sources []string `json:"sources,omitempty" jsonschema:"optional filter: slack, gmail, imap, jira, confluence, calendar, transcript, recap, digest, stream_digest, idea, project_doc (this workbench folder's .md/.markdown/.txt files; workbench sessions only)"`
	From    string   `json:"from,omitempty" jsonschema:"only documents active on/after this date (YYYY-MM-DD)"`
	To      string   `json:"to,omitempty" jsonschema:"only documents active on/before this date (YYYY-MM-DD)"`
	Limit   int      `json:"limit,omitempty" jsonschema:"max documents, 0 = default (10), capped at 25"`
	// WorkbenchScope is honoured only in a workbench session (watchtower mcp
	// --workbench N) or a chat project's chat (--chat-project N); elsewhere a
	// value is refused rather than ignored.
	WorkbenchScope string `json:"workbench_scope,omitempty" jsonschema:"workbench sessions and chat-project chats only: boost (default) ranks hits from the workbench's or chat project's Slack channels, Jira projects and Confluence spaces first (marked in_scope) and drops nothing; only returns just those; off ignores them"`
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
			"anchor and permalink for links. In a workbench session or a chat project's chat, hits from its own " +
			"Slack/Jira/Confluence sources rank first and carry in_scope (workbench_scope: only or off to change " +
			"that); a workbench folder's text files (source project_doc) are searchable too.",
		InputSchema: mustSchema[searchKnowledgeArgs]("search_knowledge"),
		Access:      AccessRead,
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a searchKnowledgeArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			// A workbench session sees its own folder's files; every other
			// caller (ProjectID 0) none of them (PROJ-08) — and is told so
			// rather than handed an empty result that reads as "no match".
			if call.Binding.WorkbenchID == 0 && slices.Contains(a.Sources, kb.WorkbenchDocSource) {
				return nil, &ValidationError{Msg: "project_doc is searchable only from that workbench's own session (watchtower mcp --workbench N)"}
			}
			req := kb.Request{Queries: a.Queries, Sources: a.Sources, Limit: a.Limit, WorkbenchID: call.Binding.WorkbenchID}
			var err error
			if req.From, err = parseDay(a.From, false); err != nil {
				return nil, &ValidationError{Msg: "from must be YYYY-MM-DD"}
			}
			if req.To, err = parseDay(a.To, true); err != nil {
				return nil, &ValidationError{Msg: "to must be YYYY-MM-DD"}
			}
			scopeNote, err := applyWorkbenchScope(ctx, d, call.Binding, a.WorkbenchScope, &req)
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

// scopeSources are the kb sources a workbench scope can hold documents of.
var scopeSources = []string{"slack", "jira", "confluence"}

// applyWorkbenchScope sets req's scope from the session's pinned sources —
// its workbench's, or its chat project's: boost by default, only/off on
// request. An explicit sources filter still applies on top (kb.Search
// honours it in the scoped retrieval too). The returned note names the
// sources that matched no synced data.
func applyWorkbenchScope(ctx context.Context, d *db.DB, b Binding, mode string, req *kb.Request) (string, error) {
	const arg = "workbench_scope" // named back in every refusal
	mode = strings.TrimSpace(mode)
	if b.WorkbenchID == 0 && b.ChatProjectID == 0 {
		if mode != "" {
			return "", &ValidationError{Msg: arg + " works only in a workbench session (watchtower mcp --workbench N) or a chat project's chat"}
		}
		return "", nil
	}
	if err := validateEnum(arg, mode, "boost", "only", "off"); err != nil {
		return "", err
	}
	if mode == "off" {
		return "", nil
	}
	scope, unresolved, owner, err := sessionKnowledgeScope(ctx, d, b)
	if err != nil {
		return "", err
	}
	only := mode == "only"
	if only && scope.Empty() {
		return "", &ValidationError{Msg: "this " + owner.noun + " has no usable Slack channel, Jira project or Confluence space source — " + owner.addHint + ", or search without " + arg}
	}
	if only && len(req.Sources) > 0 && !slices.ContainsFunc(req.Sources, func(s string) bool { return slices.Contains(scopeSources, s) }) {
		return "", &ValidationError{Msg: arg + " only covers slack, jira and confluence; sources names none of them"}
	}
	req.Scope, req.ScopeOnly = scope, only
	if len(unresolved) == 0 {
		return "", nil
	}
	return "left out of the " + owner.noun + " scope (no synced Slack channel by that ref, or not a Jira project or Confluence space key): " + strings.Join(unresolved, "; "), nil
}

// scopeOwner names whose sources a scope came from, for the texts that say
// so: the noun, and how a source is added to it.
type scopeOwner struct{ noun, addHint string }

// sessionKnowledgeScope resolves the bound session's scope and names whose
// it is: the workbench's (a workbench session) or the chat project's (a
// project chat). A binding never carries both — `mcp --workbench` refuses
// --chat, and --chat-project needs --chat.
func sessionKnowledgeScope(ctx context.Context, d *db.DB, b Binding) (kb.Scope, []string, scopeOwner, error) {
	if b.WorkbenchID != 0 {
		scope, unresolved, err := WorkbenchKnowledgeScope(ctx, d, b.WorkbenchID)
		return scope, unresolved, scopeOwner{"workbench", "add one with " + AddWorkbenchSourceTool}, err
	}
	scope, unresolved, err := chatProjectKnowledgeScope(ctx, d, b.ChatProjectID)
	return scope, unresolved, scopeOwner{"chat project", "the owner pins one in the project's settings"}, err
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
			doc, err := kb.GetDocument(ctx, d, a.Ref, kb.DocOptions{FromChunk: a.FromChunk, MaxChars: a.MaxChars, WorkbenchID: call.Binding.WorkbenchID})
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
