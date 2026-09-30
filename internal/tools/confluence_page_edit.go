package tools

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"

	"watchtower/internal/confluenceedit"
	"watchtower/internal/db"
	"watchtower/internal/jira"
)

// Input caps of edit_confluence_page (carry (f)): one text field, and the
// whole call.
const (
	confluenceMaxEditFieldRunes = 60_000
	confluenceMaxEditTotalRunes = 120_000
	// confluenceEditMessage is the version message of every write.
	confluenceEditMessage = "Edited via Watchtower"
)

// confluenceEditSpec is one edit as the model sends it. Pointers tell a
// missing field from an empty one ("new": "" deletes the passage).
type confluenceEditSpec struct {
	Kind    string  `json:"kind" jsonschema:"replace_text or replace_section"`
	Old     *string `json:"old,omitempty" jsonschema:"replace_text: the exact passage to replace, copied from the page text (it must occur exactly once and lie within one paragraph, list item, table cell or heading)"`
	New     *string `json:"new,omitempty" jsonschema:"replace_text: the replacement (inline markdown; keep every marker you do not mean to delete; empty deletes the passage)"`
	Heading *string `json:"heading,omitempty" jsonschema:"replace_section: the text of the heading whose section body is replaced (the heading itself stays)"`
	NewBody *string `json:"new_body,omitempty" jsonschema:"replace_section: the new section body in markdown (paragraphs, lists, pipe tables, fenced code, markers)"`
}

type editConfluencePageArgs struct {
	AccountID   int64                `json:"account_id,omitempty" jsonschema:"the account_id get_confluence_page returned; needed only when several Atlassian sites are connected"`
	PageID      string               `json:"page_id" jsonschema:"the page id get_confluence_page returned"`
	BaseVersion int                  `json:"base_version" jsonschema:"the version get_confluence_page returned; the edit applies only if the page is still at this version"`
	Edits       []confluenceEditSpec `json:"edits" jsonschema:"1 to 20 edits, applied in order (each sees the text the previous ones produced)"`
	Reason      string               `json:"reason" jsonschema:"one sentence: why you propose this, shown to the owner"`
}

// confluenceChangeView is one pinned change, rendered on the approval card.
type confluenceChangeView struct {
	Kind    string   `json:"kind"`
	Locator string   `json:"locator"`
	Before  string   `json:"before"`
	After   string   `json:"after"`
	Removed []string `json:"removed"`
}

// editConfluencePinned is what Normalize adds to the stored args and what
// Execute reads back: the resolved page and the exact storage to write.
type editConfluencePinned struct {
	AccountID   int64                  `json:"account_id"`
	PageID      string                 `json:"page_id"`
	Kind        string                 `json:"kind"`
	Title       string                 `json:"title"`
	URL         string                 `json:"url"`
	BaseVersion int                    `json:"base_version"`
	NewStorage  string                 `json:"new_storage"`
	Changes     []confluenceChangeView `json:"changes"`
}

// NewEditConfluencePage builds the edit_confluence_page write tool (EXT-05):
// External, so it runs only after the owner approves the diff (AGENT-03).
// Normalize applies the edits to the live page at propose time and pins the
// result; Execute writes exactly that, and only if the page is still at the
// version the owner saw.
func NewEditConfluencePage(factory ConfluencePageClientFactory) *Tool {
	return &Tool{
		Name: "edit_confluence_page",
		Description: "Propose edits to a Confluence page. Read it with get_confluence_page first and pass its " +
			"page_id and version (base_version). Each edit is replace_text {old, new} for a passage (old must occur " +
			"exactly once, within one paragraph, list item, table cell or heading) or replace_section {heading, " +
			"new_body} to rewrite the body of the section under a heading; prefer replace_text for small edits. " +
			"Keep every ⟦k:label⟧ marker you do not mean to delete, verbatim — a marker left out is deleted, and " +
			"markers can never be invented. replace_section also drops any HTML comments inside the replaced " +
			"section. At most 20 edits per call. The owner approves a diff before anything is written; if the page " +
			"changed since you read it, re-read it and propose again.",
		InputSchema: mustWriteSchema[editConfluencePageArgs]("edit_confluence_page"),
		Access:      AccessWrite,
		External:    true,
		Surfaces:    []string{"main", "target"},
		Validate: func(_ context.Context, d *db.DB, raw json.RawMessage) error {
			_, _, _, err := openConfluenceEdit(d, factory, raw)
			return err
		},
		Normalize: func(ctx context.Context, d *db.DB, raw json.RawMessage) (json.RawMessage, error) {
			a, account, client, err := openConfluenceEdit(d, factory, raw)
			if err != nil {
				return nil, err
			}
			pinned, err := prepareConfluenceEdit(ctx, client, account.ID, a)
			if err != nil {
				return nil, err
			}
			return mergeJSON(raw, map[string]any{
				"account_id": pinned.AccountID, "page_id": pinned.PageID, "kind": pinned.Kind,
				"title": pinned.Title, "url": pinned.URL, "base_version": pinned.BaseVersion,
				"new_storage": pinned.NewStorage, "changes": pinned.Changes,
			})
		},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			return executeConfluenceEdit(ctx, d, factory, call.Args)
		},
	}
}

// openConfluenceEdit decodes and shape-checks the args, resolves the
// account and builds its client, refusing a grant without write scopes.
func openConfluenceEdit(d *db.DB, factory ConfluencePageClientFactory, raw json.RawMessage) (editConfluencePageArgs, db.JiraAccount, ConfluencePageClient, error) {
	var a editConfluencePageArgs
	if err := decodeStrict(raw, &a); err != nil {
		return a, db.JiraAccount{}, nil, err
	}
	if err := validateConfluenceEditArgs(a); err != nil {
		return a, db.JiraAccount{}, nil, err
	}
	account, err := ResolveJiraAccount(d, a.AccountID)
	if err != nil {
		return a, db.JiraAccount{}, nil, err
	}
	client, err := factory(account)
	if err != nil {
		return a, db.JiraAccount{}, nil, err
	}
	if !canEdit(client) {
		return a, db.JiraAccount{}, nil, &ValidationError{Msg: confluenceWriteScopeHint(account.ID)}
	}
	return a, account, client, nil
}

// canEdit reports whether the grant can read and write Confluence pages.
// --with-confluence-write implies the read scopes, so a grant missing either
// gets the write hint.
func canEdit(client ConfluencePageClient) bool {
	return client.HasReadScopes() && client.HasWriteScopes()
}

func validateConfluenceEditArgs(a editConfluencePageArgs) error {
	switch {
	case !isNumericPageID(a.PageID):
		return &ValidationError{Msg: "page_id must be the numeric page id get_confluence_page returned"}
	case a.BaseVersion < 1:
		return &ValidationError{Msg: "base_version must be the version get_confluence_page returned"}
	case len(a.Edits) == 0 || len(a.Edits) > confluenceedit.MaxEdits:
		return &ValidationError{Msg: fmt.Sprintf("edits must hold 1 to %d edits (got %d)", confluenceedit.MaxEdits, len(a.Edits))}
	}
	total := 0
	for i, e := range a.Edits {
		if err := confluenceEditShapeErr(i, e); err != nil {
			return err
		}
		for _, f := range []*string{e.Old, e.New, e.Heading, e.NewBody} {
			n := fieldRunes(f)
			if n > confluenceMaxEditFieldRunes {
				return &ValidationError{Msg: fmt.Sprintf("edits[%d]: a field is %d characters; at most %d per field", i, n, confluenceMaxEditFieldRunes)}
			}
			total += n
		}
	}
	if total > confluenceMaxEditTotalRunes {
		return &ValidationError{Msg: fmt.Sprintf("the edits carry %d characters; at most %d per call — split the work into several proposals", total, confluenceMaxEditTotalRunes)}
	}
	return nil
}

func fieldRunes(f *string) int {
	if f == nil {
		return 0
	}
	return utf8.RuneCountInString(*f)
}

func isBlank(f *string) bool {
	return f == nil || strings.TrimSpace(*f) == ""
}

// confluenceEditShapeErr checks that an edit carries exactly its kind's
// fields.
func confluenceEditShapeErr(i int, e confluenceEditSpec) error {
	var msg string
	switch e.Kind {
	case confluenceedit.KindReplaceText:
		switch {
		case isBlank(e.Old):
			msg = "replace_text needs old: the passage to replace, copied from the page text"
		case e.New == nil:
			msg = `replace_text needs new (use "" to delete the passage)`
		case e.Heading != nil || e.NewBody != nil:
			msg = "replace_text takes only old and new"
		}
	case confluenceedit.KindReplaceSection:
		switch {
		case isBlank(e.Heading):
			msg = "replace_section needs heading: the text of the section's heading"
		case e.NewBody == nil:
			msg = "replace_section needs new_body: the section's new body in markdown"
		case e.Old != nil || e.New != nil:
			msg = "replace_section takes only heading and new_body"
		}
	default:
		msg = fmt.Sprintf("kind %q must be replace_text or replace_section", e.Kind)
	}
	if msg == "" {
		return nil
	}
	return &ValidationError{Msg: fmt.Sprintf("edits[%d]: %s", i, msg)}
}

// prepareConfluenceEdit fetches the live page, checks its version, applies
// the edits and returns what Execute will write. Every refusal is a
// *ValidationError the model can act on (spec §7).
func prepareConfluenceEdit(ctx context.Context, client ConfluencePageClient, accountID int64, a editConfluencePageArgs) (editConfluencePinned, error) {
	page, err := client.GetPage(ctx, a.PageID)
	if err != nil {
		return editConfluencePinned{}, confluenceReadErr(err, accountID, a.PageID)
	}
	if page.Version != a.BaseVersion {
		return editConfluencePinned{}, &ValidationError{Msg: fmt.Sprintf("page changed since you read it (now v%d) — re-read with get_confluence_page", page.Version)}
	}
	doc, err := parseConfluenceStorage(page)
	if err != nil {
		return editConfluencePinned{}, err
	}
	names, namesNote := resolveNames(ctx, client, mentionIDs(doc.Markers()))
	labels := newMarkerLabels(doc.Markers(), names)
	storage, changes, err := confluenceedit.Apply(doc, toEdits(a.Edits, labels))
	if err != nil {
		return editConfluencePinned{}, confluenceApplyErr(err, labels, namesNote)
	}
	if err := checkVisibleOnly(doc.Text(), storage); err != nil {
		return editConfluencePinned{}, err
	}
	return editConfluencePinned{AccountID: accountID, PageID: page.ID, Kind: page.Kind, Title: page.Title,
		URL: page.URL, BaseVersion: page.Version, NewStorage: storage, Changes: changeViews(changes, labels)}, nil
}

// toEdits maps the model's edits onto confluenceedit's, translating mention
// markers back from display names to account ids.
func toEdits(specs []confluenceEditSpec, labels markerLabels) []confluenceedit.Edit {
	deref := func(s *string) string {
		if s == nil {
			return ""
		}
		return labels.toOrig.Replace(*s)
	}
	out := make([]confluenceedit.Edit, 0, len(specs))
	for _, e := range specs {
		out = append(out, confluenceedit.Edit{Kind: e.Kind, Old: deref(e.Old), New: deref(e.New),
			Heading: deref(e.Heading), NewBody: deref(e.NewBody)})
	}
	return out
}

// confluenceApplyErr turns a refused edit into the model-facing message
// (markers named as the model saw them).
// namesNote is set when the user-name lookup failed: markers the model sent
// with display names could then not be matched, and it must learn why.
func confluenceApplyErr(err error, labels markerLabels, namesNote string) error {
	var ee *confluenceedit.EditError
	if errors.As(err, &ee) {
		msg := labels.toDisplay.Replace(ee.Error())
		if namesNote != "" {
			msg += " (couldn't resolve user names — " + namesNote + "; re-read with get_confluence_page and keep the markers as shown)"
		}
		return &ValidationError{Msg: msg}
	}
	return fmt.Errorf("applying the edits: %w", err)
}

// checkVisibleOnly enforces that edits stay inside the text
// get_confluence_page showed: on a truncated page, the hidden tail must be
// unchanged.
func checkVisibleOnly(text, newStorage string) error {
	cut, truncated := textCut(text)
	if !truncated {
		return nil
	}
	after, err := confluenceedit.Parse(newStorage)
	if err != nil {
		return fmt.Errorf("re-reading the edited page: %w", err)
	}
	if !tailUnchanged(after.Text(), text[cut:]) {
		return &ValidationError{Msg: fmt.Sprintf("the edits touch the part of the page after the first %d characters, which get_confluence_page did not show; edit only the text you were shown", confluenceMaxTextRunes)}
	}
	return nil
}

func changeViews(changes []confluenceedit.Change, labels markerLabels) []confluenceChangeView {
	out := make([]confluenceChangeView, 0, len(changes))
	for _, c := range changes {
		removed := make([]string, 0, len(c.Removed))
		for _, tok := range c.Removed {
			removed = append(removed, labels.toDisplay.Replace(tok))
		}
		out = append(out, confluenceChangeView{Kind: c.Kind, Locator: labels.toDisplay.Replace(c.Locator),
			Before: labels.toDisplay.Replace(c.Before), After: labels.toDisplay.Replace(c.After), Removed: removed})
	}
	return out
}

// executeConfluenceEdit writes the approved storage — only if the live page
// is still at the version the owner saw (EXT-05) — as version+1.
func executeConfluenceEdit(ctx context.Context, d *db.DB, factory ConfluencePageClientFactory, args json.RawMessage) (any, error) {
	var p editConfluencePinned
	if err := json.Unmarshal(args, &p); err != nil {
		return nil, fmt.Errorf("decoding edit_confluence_page args: %w", err)
	}
	if p.NewStorage == "" || p.BaseVersion < 1 || p.AccountID < 1 || !isNumericPageID(p.PageID) {
		return nil, errors.New("the proposal carries no prepared edit; propose it again")
	}
	account, err := ResolveJiraAccount(d, p.AccountID)
	if err != nil {
		return nil, err
	}
	client, err := factory(account)
	if err != nil {
		return nil, err
	}
	if !canEdit(client) {
		return nil, errors.New(confluenceWriteScopeHint(account.ID))
	}
	live, err := client.GetPage(ctx, p.PageID)
	if err != nil {
		return nil, confluenceWriteFailed(d, account.ID, confluenceReadErr(err, account.ID, p.PageID), err)
	}
	if live.Version != p.BaseVersion {
		return nil, confluenceConflict(live.Version)
	}
	body := ConfluencePutBody{ID: p.PageID, Status: "current", Title: p.Title,
		Body:    ConfluencePutStorage{Representation: "storage", Value: p.NewStorage},
		Version: ConfluencePutVersionInfo{Number: p.BaseVersion + 1, Message: confluenceEditMessage}}
	version, err := client.PutPage(ctx, p.PageID, p.Kind, body)
	if err != nil {
		return nil, confluenceWriteFailed(d, account.ID, confluencePutErr(ctx, client, err, account.ID, p.PageID), err)
	}
	return map[string]any{"page_id": p.PageID, "title": p.Title, "url": p.URL, "version": version}, nil
}

func confluenceConflict(now int) error {
	return fmt.Errorf("conflict: the page was edited after the preview (now v%d); nothing was written", now)
}

// confluencePutErr maps a failed PUT (spec §7): 409 is a conflict, 403 a
// missing write scope.
func confluencePutErr(ctx context.Context, client ConfluencePageClient, err error, accountID int64, pageID string) error {
	switch httpStatus(err) {
	case 409:
		if live, gerr := client.GetPage(ctx, pageID); gerr == nil {
			return confluenceConflict(live.Version)
		}
		return errors.New("conflict: the page was edited after the preview; nothing was written")
	case 401:
		return fmt.Errorf("%s (%w)", confluenceWriteScopeHint(accountID), err)
	case 403:
		// A 403 naming a scope is a grant problem; any other 403 is a page
		// restriction, which a re-login cannot fix.
		if mentionsScope(err) {
			return fmt.Errorf("%s (%w)", confluenceWriteScopeHint(accountID), err)
		}
		return fmt.Errorf("you don't have permission to edit this page in Confluence (%w)", err)
	}
	return fmt.Errorf("updating Confluence page %s: %w", pageID, err)
}

// confluenceWriteFailed returns mapped, marking the account revoked first
// when cause is a revoked grant (Execute only — Validate and Normalize
// never write).
func confluenceWriteFailed(d *db.DB, accountID int64, mapped, cause error) error {
	if !errors.Is(cause, jira.ErrAuthRevoked) {
		return mapped
	}
	if dbErr := recordRevokedGrant(d, accountID, cause); dbErr != nil {
		return fmt.Errorf("%w (and recording the revoked state failed: %v)", mapped, dbErr)
	}
	return mapped
}
