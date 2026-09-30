package tools

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"

	"watchtower/internal/confluenceedit"
	"watchtower/internal/db"
	"watchtower/internal/jira"
	"watchtower/internal/kb"
)

// Caps of the Confluence page tools (spec
// docs/superpowers/specs/2026-09-30-confluence-page-editing-design.md §4).
const (
	// confluenceMaxTextRunes caps the editable text get_confluence_page
	// returns; edits must stay inside what was shown.
	confluenceMaxTextRunes = 60_000
	// confluenceMaxComments caps the comments returned (replies included).
	confluenceMaxComments = 200
	// confluenceMaxCommentRunes caps one comment body.
	confluenceMaxCommentRunes = 8_000
	// confluenceMaxStorageBytes caps the storage XHTML either tool parses
	// (the fetcher's own page cap is 1M runes ≈ 4 MiB).
	confluenceMaxStorageBytes = 4 << 20
	// confluenceTitleHits bounds the title search.
	confluenceTitleHits = 10
)

// ---- page resolution -------------------------------------------------------

// confluenceCandidate is one page a title search found.
type confluenceCandidate struct {
	AccountID int64  `json:"account_id"`
	PageID    string `json:"page_id"`
	Title     string `json:"title"`
	Space     string `json:"space,omitempty"`
	URL       string `json:"url,omitempty"`
}

// confluenceTarget is a resolved page reference: the account it lives on
// and its id. candidates is set instead when a title matched several pages
// (or none exactly) — nothing is guessed.
type confluenceTarget struct {
	account    db.JiraAccount
	pageID     string
	candidates []confluenceCandidate
}

var (
	confluencePagePathRE = regexp.MustCompile(`/pages/(\d+)(?:/|$)`)
	confluenceBlogPathRE = regexp.MustCompile(`/blog/(?:\d{4}/\d{2}/\d{2}/)?(\d+)(?:/|$)`)
)

func isNumericPageID(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// resolveConfluencePage turns get_confluence_page's page argument — a
// numeric id, a page URL, or a title — into an account and a page id.
func resolveConfluencePage(ctx context.Context, d *db.DB, accountID int64, page string) (confluenceTarget, error) {
	page = strings.TrimSpace(page)
	switch {
	case page == "":
		return confluenceTarget{}, &ValidationError{Msg: "page is required: a page id, a Confluence page URL, or a page title"}
	case isNumericPageID(page):
		account, err := ResolveJiraAccount(d, accountID)
		return confluenceTarget{account: account, pageID: page}, err
	case strings.Contains(page, "://"):
		return resolveConfluenceURL(d, accountID, page)
	}
	return resolveConfluenceTitle(ctx, d, accountID, page)
}

// resolveConfluenceURL reads the page id out of a Confluence URL and picks
// the connected site whose URL shares its host.
func resolveConfluenceURL(d *db.DB, accountID int64, raw string) (confluenceTarget, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return confluenceTarget{}, &ValidationError{Msg: fmt.Sprintf("%q is not a valid URL", raw)}
	}
	id := u.Query().Get("pageId")
	for _, re := range []*regexp.Regexp{confluencePagePathRE, confluenceBlogPathRE} {
		if m := re.FindStringSubmatch(u.Path); id == "" && m != nil {
			id = m[1]
		}
	}
	if !isNumericPageID(id) {
		return confluenceTarget{}, &ValidationError{Msg: fmt.Sprintf("no page id in %q; pass the page id or a /pages/<id> URL", raw)}
	}
	if accountID > 0 {
		account, err := ResolveJiraAccount(d, accountID)
		return confluenceTarget{account: account, pageID: id}, err
	}
	accounts, err := d.ListEnabledJiraAccounts()
	if err != nil {
		return confluenceTarget{}, err
	}
	for _, a := range accounts {
		if su, err := url.Parse(a.SiteURL); err == nil && strings.EqualFold(su.Host, u.Host) {
			return confluenceTarget{account: a, pageID: id}, nil
		}
	}
	return confluenceTarget{}, &ValidationError{Msg: fmt.Sprintf("%s is not on a connected Atlassian site (see list_jira_projects)", u.Host)}
}

// resolveConfluenceTitle finds a page by title through the knowledge index
// (synced spaces only). One exact title match resolves; anything else
// returns the candidates.
func resolveConfluenceTitle(ctx context.Context, d *db.DB, accountID int64, title string) (confluenceTarget, error) {
	res, err := kb.Search(ctx, d, kb.Request{Queries: []string{title}, Sources: []string{"confluence"}, Limit: confluenceTitleHits})
	if err != nil {
		return confluenceTarget{}, fmt.Errorf("searching Confluence pages: %w", err)
	}
	var all, exact []confluenceCandidate
	for _, h := range res.Hits {
		c, ok, err := pageCandidate(d, h)
		if err != nil {
			return confluenceTarget{}, err
		}
		if !ok || (accountID > 0 && c.AccountID != accountID) {
			continue
		}
		all = append(all, c)
		if strings.EqualFold(strings.TrimSpace(c.Title), title) {
			exact = append(exact, c)
		}
	}
	switch {
	case len(exact) == 1:
		account, err := ResolveJiraAccount(d, exact[0].AccountID)
		return confluenceTarget{account: account, pageID: exact[0].PageID}, err
	case len(exact) > 1:
		return confluenceTarget{candidates: exact}, nil
	case len(all) > 0:
		return confluenceTarget{candidates: all}, nil
	}
	return confluenceTarget{}, &ValidationError{Msg: fmt.Sprintf("no synced Confluence page matches %q — pass the page id or its URL", title)}
}

// pageCandidate maps a knowledge hit to a page candidate; ok is false for a
// hit that is not a page or blog post of a Jira-owned source (an
// attachment, a stale ref).
func pageCandidate(d *db.DB, h kb.Hit) (confluenceCandidate, bool, error) {
	sourceID, extID := h.Anchor["source_id"], h.Anchor["ext_id"]
	var kind string
	var accountID *int64
	err := d.QueryRow(`SELECT d.kind, s.jira_account_id FROM ext_documents d JOIN ext_sources s ON s.id = d.source_id
		WHERE d.source_id = ? AND d.ext_id = ?`, sourceID, extID).Scan(&kind, &accountID)
	if errors.Is(err, sql.ErrNoRows) {
		return confluenceCandidate{}, false, nil
	}
	if err != nil {
		return confluenceCandidate{}, false, fmt.Errorf("resolving Confluence hit %s: %w", h.Ref, err)
	}
	if (kind != "page" && kind != "blogpost") || accountID == nil {
		return confluenceCandidate{}, false, nil
	}
	return confluenceCandidate{AccountID: *accountID, PageID: extID, Title: h.Title, Space: h.Anchor["space"], URL: h.Link}, true, nil
}

// ---- errors ----------------------------------------------------------------

// confluenceReadErr turns a failed page read into what the model can act on.
func confluenceReadErr(err error, accountID int64, pageID string) error {
	switch st := httpStatus(err); {
	case errors.Is(err, errConfluencePageNotFound):
		return &ValidationError{Msg: fmt.Sprintf("Confluence page %s was not found on Jira account #%d (deleted, or not visible to this account)", pageID, accountID)}
	case errors.Is(err, jira.ErrAuthRevoked):
		return &ValidationError{Msg: fmt.Sprintf("Atlassian sign-in expired — run: watchtower jira login --account %d --with-confluence", accountID)}
	case st == 401 || (st == 403 && mentionsScope(err)):
		return &ValidationError{Msg: fmt.Sprintf("Confluence access not granted — run: watchtower jira login --account %d --with-confluence", accountID)}
	case st == 403:
		return &ValidationError{Msg: fmt.Sprintf("Confluence page %s is restricted for Jira account #%d", pageID, accountID)}
	}
	return fmt.Errorf("reading Confluence page %s: %w", pageID, err)
}

func mentionsScope(err error) bool {
	var he *jira.HTTPStatusError
	return errors.As(err, &he) && strings.Contains(strings.ToLower(he.Body), "scope")
}

// confluenceWriteScopeHint is the spec §2 message for a grant without the
// write scopes.
func confluenceWriteScopeHint(accountID int64) string {
	return fmt.Sprintf("Confluence editing not granted — run: watchtower jira login --account %d --with-confluence-write", accountID)
}

// ---- editable text: truncation and mention labels (R3) ---------------------

var (
	confluenceMentionTokenRE = regexp.MustCompile(`@\[~([^\]]+)\]`)
	markerOrdinalRE          = regexp.MustCompile(`⟦\d+:`)
)

// textCut returns the byte length of the part of text shown to the model:
// all of it when it fits confluenceMaxTextRunes, else the first
// confluenceMaxTextRunes runes, moved back to before a marker token the cut
// would split.
func textCut(text string) (int, bool) {
	if utf8.RuneCountInString(text) <= confluenceMaxTextRunes {
		return len(text), false
	}
	cut, n := 0, 0
	for i := range text {
		if n == confluenceMaxTextRunes {
			cut = i
			break
		}
		n++
	}
	head := text[:cut]
	if open := strings.LastIndex(head, "⟦"); open >= 0 && !strings.Contains(head[open:], "⟧") {
		cut = open
	}
	return cut, true
}

// tailUnchanged reports whether newText still ends with the tail the model
// was never shown. Marker ordinals are ignored: removing a marker in the
// visible part renumbers every later marker without touching the tail.
func tailUnchanged(newText, tail string) bool {
	return strings.HasSuffix(markerOrdinalRE.ReplaceAllString(newText, "⟦"), markerOrdinalRE.ReplaceAllString(tail, "⟦"))
}

// markerLabels translates mention markers between the package's
// ⟦k:@accountId⟧ form and the ⟦k:@Display Name⟧ form the model sees (R3).
type markerLabels struct {
	toDisplay *strings.Replacer
	toOrig    *strings.Replacer
}

func markerToken(ordinal int, label string) string {
	return "⟦" + strconv.Itoa(ordinal) + ":" + label + "⟧"
}

// mentionIDs lists the account ids behind the document's mention markers.
func mentionIDs(markers []confluenceedit.Marker) []string {
	var ids []string
	for _, m := range markers {
		if id, ok := strings.CutPrefix(m.Label, "@"); ok && id != "user" {
			ids = append(ids, id)
		}
	}
	return ids
}

// newMarkerLabels builds the translation for every mention marker whose id
// names resolved; an unresolved mention keeps its id label.
func newMarkerLabels(markers []confluenceedit.Marker, names map[string]string) markerLabels {
	var toDisplay, toOrig []string
	for _, m := range markers {
		id, ok := strings.CutPrefix(m.Label, "@")
		name := displayLabel(names[id])
		if !ok || name == "" {
			continue
		}
		orig, display := markerToken(m.Ordinal, m.Label), markerToken(m.Ordinal, "@"+name)
		if orig == display {
			continue
		}
		toDisplay = append(toDisplay, orig, display)
		toOrig = append(toOrig, display, orig)
	}
	return markerLabels{toDisplay: strings.NewReplacer(toDisplay...), toOrig: strings.NewReplacer(toOrig...)}
}

// displayLabel makes a display name safe inside ⟦k:label⟧: no marker
// brackets, one line, collapsed spaces, bounded.
func displayLabel(name string) string {
	name = strings.NewReplacer("⟦", " ", "⟧", " ", "\x00", " ").Replace(strings.ToValidUTF8(name, "�"))
	name = strings.Join(strings.Fields(name), " ")
	if r := []rune(name); len(r) > 60 {
		name = strings.TrimSpace(string(r[:59])) + "…"
	}
	return name
}

// resolveNames looks up display names best-effort: a failure leaves ids as
// they are and is reported as a note.
func resolveNames(ctx context.Context, client ConfluencePageClient, ids []string) (map[string]string, string) {
	ids = uniqueNonEmpty(ids)
	if len(ids) == 0 {
		return map[string]string{}, ""
	}
	names, err := client.Users(ctx, ids)
	if err != nil {
		return map[string]string{}, "user names unavailable (mentions show account ids): " + err.Error()
	}
	return names, ""
}

func uniqueNonEmpty(ids []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, id := range ids {
		if id != "" && !seen[id] {
			seen[id] = true
			out = append(out, id)
		}
	}
	return out
}

// ---- get_confluence_page ---------------------------------------------------

type getConfluencePageArgs struct {
	Page    string `json:"page" jsonschema:"the page id, a Confluence page URL, or its exact title (a title is looked up among synced spaces)"`
	Account int64  `json:"account,omitempty" jsonschema:"connected Jira account id; needed only when several Atlassian sites are connected"`
}

// confluencePageView is get_confluence_page's result.
type confluencePageView struct {
	AccountID         int64                    `json:"account_id"`
	ID                string                   `json:"id"`
	Kind              string                   `json:"kind"`
	Title             string                   `json:"title"`
	Space             string                   `json:"space,omitempty"`
	URL               string                   `json:"url,omitempty"`
	Version           int                      `json:"version"`
	Text              string                   `json:"text"`
	Truncated         bool                     `json:"truncated,omitempty"`
	TotalRunes        int                      `json:"total_runes,omitempty"`
	Comments          []*confluenceCommentView `json:"comments"`
	CommentsTruncated bool                     `json:"comments_truncated,omitempty"`
	Notes             []string                 `json:"notes,omitempty"`
}

// confluenceCommentView is one comment thread node.
type confluenceCommentView struct {
	Author     string                   `json:"author"`
	Created    string                   `json:"created"`
	Kind       string                   `json:"kind"`
	AnchorText string                   `json:"anchor_text,omitempty"`
	Resolved   bool                     `json:"resolved"`
	Body       string                   `json:"body"`
	Replies    []*confluenceCommentView `json:"replies,omitempty"`
}

// confluenceCandidatesView answers a title that matched several pages.
type confluenceCandidatesView struct {
	Ambiguous  bool                  `json:"ambiguous"`
	Message    string                `json:"message"`
	Candidates []confluenceCandidate `json:"candidates"`
}

// NewGetConfluencePage builds the get_confluence_page read tool: a LIVE
// read of one page with all its comments. It makes network calls, so it is
// registered only in buildToolRegistry (chat mode), never in ReadTools()
// (dev-mode MCP, DEV-01).
func NewGetConfluencePage(factory ConfluencePageClientFactory) *Tool {
	return &Tool{
		Name: "get_confluence_page",
		Description: "Read one Confluence page LIVE (current version) with all its comments: the editable text, " +
			"its version, and every footer and inline comment with replies. page is the page id, a Confluence " +
			"page URL, or an exact title (an ambiguous title returns candidates). Rich elements show as ⟦k:label⟧ " +
			"markers. Read a page with this tool before editing it with edit_confluence_page.",
		InputSchema: mustSchema[getConfluencePageArgs]("get_confluence_page"),
		Access:      AccessRead,
		Surfaces:    []string{"main", "target"},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a getConfluencePageArgs
			if err := decodeStrict(call.Args, &a); err != nil {
				return nil, err
			}
			target, err := resolveConfluencePage(ctx, d, a.Account, a.Page)
			if err != nil {
				return nil, err
			}
			if target.candidates != nil {
				return confluenceCandidatesView{Ambiguous: true, Candidates: target.candidates,
					Message: "several pages match; call get_confluence_page again with the page_id of the one you mean"}, nil
			}
			client, err := factory(target.account)
			if err != nil {
				return nil, err
			}
			return readConfluencePage(ctx, client, target.account.ID, target.pageID)
		},
	}
}

// readConfluencePage builds the page view: the live page, its editable
// text (mentions relabelled to names, capped), and its comment threads.
func readConfluencePage(ctx context.Context, client ConfluencePageClient, accountID int64, pageID string) (confluencePageView, error) {
	page, err := client.GetPage(ctx, pageID)
	if err != nil {
		return confluencePageView{}, confluenceReadErr(err, accountID, pageID)
	}
	doc, err := parseConfluenceStorage(page)
	if err != nil {
		return confluencePageView{}, err
	}
	view := confluencePageView{AccountID: accountID, ID: page.ID, Kind: page.Kind, Title: page.Title,
		Space: page.SpaceKey, URL: page.URL, Version: page.Version, Comments: []*confluenceCommentView{}}
	comments, cerr := client.Comments(ctx, page.ID)
	if cerr != nil {
		view.Notes = append(view.Notes, "comments unavailable: "+cerr.Error())
	}
	names, note := resolveNames(ctx, client, append(mentionIDs(doc.Markers()), commentUserIDs(comments)...))
	if note != "" {
		view.Notes = append(view.Notes, note)
	}
	text := doc.Text()
	cut, truncated := textCut(text)
	view.Text = newMarkerLabels(doc.Markers(), names).toDisplay.Replace(text[:cut])
	if truncated {
		view.Truncated, view.TotalRunes = true, utf8.RuneCountInString(text)
		view.Notes = append(view.Notes, fmt.Sprintf("text truncated at %d characters; edits must stay within the text shown", confluenceMaxTextRunes))
	}
	view.Comments, view.CommentsTruncated = commentThreads(comments, names)
	return view, nil
}

// parseConfluenceStorage parses a page's storage, refusing an oversized one.
func parseConfluenceStorage(page ConfluencePage) (*confluenceedit.Doc, error) {
	if len(page.Storage) > confluenceMaxStorageBytes {
		return nil, &ValidationError{Msg: fmt.Sprintf("Confluence page %s is too large to read or edit here (%d bytes of storage); use get_knowledge_document or edit it in Confluence", page.ID, len(page.Storage))}
	}
	doc, err := confluenceedit.Parse(page.Storage)
	if err != nil {
		return nil, &ValidationError{Msg: fmt.Sprintf("Confluence page %s cannot be read as editable text: %v", page.ID, err)}
	}
	return doc, nil
}

func commentUserIDs(comments []ConfluenceComment) []string {
	var ids []string
	for _, c := range comments {
		ids = append(ids, c.AuthorID)
		ids = append(ids, c.MentionedUserIDs...)
	}
	return ids
}

// commentThreads nests the first confluenceMaxComments comments by ReplyTo
// (the fetcher lists a thread depth-first, so a parent always precedes its
// replies and a cut never orphans a kept reply).
func commentThreads(comments []ConfluenceComment, names map[string]string) ([]*confluenceCommentView, bool) {
	truncated := len(comments) > confluenceMaxComments
	if truncated {
		comments = comments[:confluenceMaxComments]
	}
	roots := []*confluenceCommentView{}
	byID := make(map[string]*confluenceCommentView, len(comments))
	for _, c := range comments {
		v := commentView(c, names)
		byID[c.ID] = v
		if parent, ok := byID[c.ReplyTo]; ok && c.ReplyTo != "" {
			parent.Replies = append(parent.Replies, v)
			continue
		}
		roots = append(roots, v)
	}
	return roots, truncated
}

func commentView(c ConfluenceComment, names map[string]string) *confluenceCommentView {
	author := names[c.AuthorID]
	if author == "" {
		author = c.AuthorID
	}
	body := confluenceMentionTokenRE.ReplaceAllStringFunc(c.Body, func(tok string) string {
		id := confluenceMentionTokenRE.FindStringSubmatch(tok)[1]
		if n := names[id]; n != "" {
			return "@" + n
		}
		return "@" + id
	})
	if r := []rune(body); len(r) > confluenceMaxCommentRunes {
		body = string(r[:confluenceMaxCommentRunes]) + "…"
	}
	v := &confluenceCommentView{Author: author, Kind: c.Kind, AnchorText: c.AnchorText, Resolved: c.Resolved, Body: body}
	if !c.Created.IsZero() {
		v.Created = c.Created.UTC().Format("2006-01-02T15:04:05Z")
	}
	return v
}
