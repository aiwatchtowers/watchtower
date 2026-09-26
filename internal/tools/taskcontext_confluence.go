package tools

import (
	"context"
	"strconv"
	"strings"

	"watchtower/internal/db"
	"watchtower/internal/kb"
)

const (
	taskContextMaxConfluence = 5
	// confluenceSnippetRadius is how many runes of a linked page's text
	// surround the key in its snippet.
	confluenceSnippetRadius = 120
)

// taskConfluencePage is one Confluence page or attachment in the dossier.
// Via is the evidence that put it there (DEV-03): "link" — its text
// mentions the key (doc_links) — or "search" — the knowledge index ranks it
// for the key. Ref opens it with get_knowledge_document.
type taskConfluencePage struct {
	Title   string `json:"title"`
	Link    string `json:"link,omitempty"`
	Space   string `json:"space,omitempty"`
	Snippet string `json:"snippet,omitempty"`
	Ref     string `json:"ref"`
	Via     string `json:"via"`
}

// collectTaskConfluence lists up to taskContextMaxConfluence pages for key:
// the documents that link it first, then search hits restricted to
// Confluence, deduped by ref.
func collectTaskConfluence(ctx context.Context, d *db.DB, key string, notes []string) ([]taskConfluencePage, []string) {
	var out []taskConfluencePage
	seen := map[string]bool{}
	links, err := d.DocLinksTo("jira_issue", key, taskContextMaxConfluence*2)
	if err != nil {
		notes = append(notes, "confluence links unavailable: "+err.Error())
	}
	for _, l := range links {
		if len(out) >= taskContextMaxConfluence {
			return out, notes
		}
		page, ok, err := linkedConfluencePage(d, l.FromRef, key)
		if err != nil {
			notes = append(notes, "confluence page unavailable for "+l.FromRef+": "+err.Error())
			continue
		}
		if ok && !seen[page.Ref] {
			seen[page.Ref] = true
			out = append(out, page)
		}
	}
	return appendConfluenceHits(ctx, d, key, out, seen, notes)
}

// linkedConfluencePage resolves a linking document ref to its stored page;
// ok is false for a ref that is not a stored Confluence document (a stale
// link: the page is gone), which is skipped silently.
func linkedConfluencePage(d *db.DB, ref, key string) (taskConfluencePage, bool, error) {
	sourceID, extID, ok := parseConfluenceRef(ref)
	if !ok {
		return taskConfluencePage{}, false, nil
	}
	b, err := d.ExtDocumentBrief(sourceID, extID)
	if err != nil || b == nil {
		return taskConfluencePage{}, false, err
	}
	return taskConfluencePage{Title: b.Title, Link: b.URL, Space: b.Space,
		Snippet: confluenceSnippet(b.Text, key), Ref: ref, Via: "link"}, true, nil
}

// parseConfluenceRef splits "confluence:<source_id>:<ext_id>".
func parseConfluenceRef(ref string) (int64, string, bool) {
	rest, ok := strings.CutPrefix(ref, "confluence:")
	if !ok {
		return 0, "", false
	}
	sourceStr, extID, ok := strings.Cut(rest, ":")
	if !ok || extID == "" {
		return 0, "", false
	}
	sourceID, err := strconv.ParseInt(sourceStr, 10, 64)
	return sourceID, extID, err == nil
}

// appendConfluenceHits fills the rest of the section from the knowledge
// index. An index that is empty (not built yet) simply adds nothing.
func appendConfluenceHits(ctx context.Context, d *db.DB, key string, out []taskConfluencePage, seen map[string]bool, notes []string) ([]taskConfluencePage, []string) {
	if len(out) >= taskContextMaxConfluence {
		return out, notes
	}
	res, err := kb.Search(ctx, d, kb.Request{Queries: []string{key}, Sources: []string{"confluence"}, Limit: taskContextMaxConfluence * 2})
	if err != nil {
		return out, append(notes, "confluence search unavailable: "+err.Error())
	}
	for _, h := range res.Hits {
		if len(out) >= taskContextMaxConfluence {
			break
		}
		if seen[h.Ref] {
			continue
		}
		seen[h.Ref] = true
		var snippet string
		if len(h.Snippets) > 0 {
			snippet = h.Snippets[0]
		}
		out = append(out, taskConfluencePage{Title: h.Title, Link: h.Link, Space: h.Anchor["space"],
			Snippet: snippet, Ref: h.Ref, Via: "search"})
	}
	return out, notes
}

// confluenceSnippet excerpts text around the first mention of key (the
// start of the text when it has none, e.g. a key only a comment mentions),
// confluenceSnippetRadius runes each side, "…" marking a cut.
func confluenceSnippet(text, key string) string {
	runes := []rune(text)
	at := 0
	if i := strings.Index(text, key); i >= 0 {
		at = len([]rune(text[:i]))
	}
	from := max(at-confluenceSnippetRadius, 0)
	to := min(at+len([]rune(key))+confluenceSnippetRadius, len(runes))
	if at == 0 {
		to = min(2*confluenceSnippetRadius, len(runes))
	}
	s := strings.TrimSpace(string(runes[from:to]))
	if from > 0 {
		s = "…" + s
	}
	if to < len(runes) {
		s += "…"
	}
	return s
}
