package jira

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"watchtower/internal/db"
)

// changelogBatch is how many issues one bulk changelog (or bulk issue)
// request names: well under the API's 1000, so one request's history pages
// stay few.
const changelogBatch = 100

// maxChangelogPages guards one bulk changelog request against a server that
// keeps handing out page tokens. Hitting it stores nothing for the batch.
const maxChangelogPages = 50

// linkedIssuesPerPass caps how many linked issues (from other boards) one
// pass refreshes; the rest rotate in on later passes, oldest first.
const linkedIssuesPerPass = 200

// changelogFields are the fields whose history is kept.
var changelogFields = []string{"status", "assignee"}

// linkedIssueFields are the single-valued fields fetched for a linked issue.
var linkedIssueFields = []string{"summary", "issuetype", "status", "assignee", "created", "updated", "resolutiondate"}

// ChangeItem is one changed field of a change history.
type ChangeItem struct {
	Field      string `json:"field"`
	FieldID    string `json:"fieldId"`
	From       string `json:"from"`
	FromString string `json:"fromString"`
	To         string `json:"to"`
	ToString   string `json:"toString"`
}

// ChangeHistory is one change of an issue: who, when, which fields.
type ChangeHistory struct {
	ID      string       `json:"id"`
	Author  *User        `json:"author"`
	Created string       `json:"created"`
	Items   []ChangeItem `json:"items"`
}

// IssueChangelog is the change histories of one issue, keyed by issue id.
type IssueChangelog struct {
	IssueID         string          `json:"issueId"`
	ChangeHistories []ChangeHistory `json:"changeHistories"`
}

type bulkChangelogPage struct {
	IssueChangeLogs []IssueChangelog `json:"issueChangeLogs"`
	NextPageToken   string           `json:"nextPageToken"`
}

// BulkFetchChangelogs returns the change histories of the given issues (ids
// or keys, at most 1000), filtered to fieldIDs, via POST
// /rest/api/3/changelog/bulkfetch, following nextPageToken. The result is
// keyed by issue id. A request that is still handing out page tokens after
// maxChangelogPages pages is an error: a partial history must not be stored
// as the whole one.
func (c *Client) BulkFetchChangelogs(ctx context.Context, issueIDsOrKeys, fieldIDs []string) (map[string][]ChangeHistory, error) {
	out := map[string][]ChangeHistory{}
	token := ""
	for page := 0; page < maxChangelogPages; page++ {
		req := map[string]any{"issueIdsOrKeys": issueIDsOrKeys, "fieldIds": fieldIDs, "maxResults": 1000}
		if token != "" {
			req["nextPageToken"] = token
		}
		body, err := c.send(ctx, http.MethodPost, "/rest/api/3/changelog/bulkfetch", req, http.StatusOK)
		if err != nil {
			return nil, fmt.Errorf("bulk fetching changelogs (page %d): %w", page+1, err)
		}
		var resp bulkChangelogPage
		if err := json.Unmarshal(body, &resp); err != nil {
			return nil, fmt.Errorf("decoding bulk changelog page %d: %w", page+1, err)
		}
		for _, ic := range resp.IssueChangeLogs {
			out[ic.IssueID] = append(out[ic.IssueID], ic.ChangeHistories...)
		}
		if resp.NextPageToken == "" {
			return out, nil
		}
		token = resp.NextPageToken
	}
	return nil, fmt.Errorf("bulk changelog fetch still paging after %d pages", maxChangelogPages)
}

// BulkIssueError is an issue the bulk issue fetch could not return.
type BulkIssueError struct {
	ID           string `json:"id"`
	ErrorMessage string `json:"errorMessage"`
}

type bulkIssuesResponse struct {
	Issues      []Issue          `json:"issues"`
	IssueErrors []BulkIssueError `json:"issueErrors"`
}

// BulkFetchIssues returns the given issues (ids or keys, at most 100) with
// the named fields via POST /rest/api/3/issue/bulkfetch, plus the ones the
// site reported it could not return.
func (c *Client) BulkFetchIssues(ctx context.Context, issueIDsOrKeys, fields []string) ([]Issue, []BulkIssueError, error) {
	body, err := c.send(ctx, http.MethodPost, "/rest/api/3/issue/bulkfetch",
		map[string]any{"issueIdsOrKeys": issueIDsOrKeys, "fields": fields}, http.StatusOK)
	if err != nil {
		return nil, nil, fmt.Errorf("bulk fetching issues: %w", err)
	}
	var resp bulkIssuesResponse
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, nil, fmt.Errorf("decoding bulk issues: %w", err)
	}
	return resp.Issues, resp.IssueErrors, nil
}

// SetChangelogLimit bounds how many issues get their status/assignee history
// fetched per sync pass (0, the default, disables changelog and linked-issue
// sync entirely).
func (s *Syncer) SetChangelogLimit(n int) {
	s.changelogLimit = n
}

// syncHistory is the changelog step of a pass: refresh the linked issues
// from other boards, then fetch the history of every due issue, under the
// per-pass caps. Only a revoked grant (or a cancelled ctx) is returned; any
// other failure is logged and leaves the cursors, so the next pass retries.
func (s *Syncer) syncHistory(ctx context.Context) error {
	if s.changelogLimit <= 0 {
		return nil
	}
	if err := s.syncLinkedIssues(ctx); err != nil {
		if errors.Is(err, ErrAuthRevoked) || ctx.Err() != nil {
			return err
		}
		s.logger.Printf("linked issue sync: %v", err)
	}
	if err := s.syncChangelogs(ctx); err != nil {
		if errors.Is(err, ErrAuthRevoked) || ctx.Err() != nil {
			return err
		}
		s.logger.Printf("changelog sync: %v", err)
	}
	return nil
}

// syncLinkedIssues prunes linked-issue rows nothing needs any more, then
// fetches up to linkedIssuesPerPass link targets that are not board issues.
// Every requested key has its row stamped: a key the site does not return
// keeps a row with fetch_error, so it rotates to the back instead of being
// asked again every pass.
func (s *Syncer) syncLinkedIssues(ctx context.Context) error {
	if n, err := s.db.PruneJiraLinkedIssues(s.accountID); err != nil {
		s.logger.Printf("linked issue sync: pruning: %v", err)
	} else if n > 0 {
		s.logger.Printf("linked issue sync: pruned %d linked issues no longer needed", n)
	}
	keys, err := s.db.ListJiraLinkedCandidates(s.accountID, linkedIssuesPerPass)
	if err != nil {
		return err
	}
	var firstErr error
	for start := 0; start < len(keys); start += changelogBatch {
		batch := keys[start:min(start+changelogBatch, len(keys))]
		issues, issueErrs, err := s.client.BulkFetchIssues(ctx, batch, linkedIssueFields)
		if err != nil {
			if errors.Is(err, ErrAuthRevoked) || ctx.Err() != nil {
				return err
			}
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		if err := s.db.UpsertJiraLinkedIssues(s.linkedRows(batch, issues, issueErrs)); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}

// linkedRows turns one bulk issue response into rows: one per returned issue
// (under its own key — a moved issue comes back under its new one) and one
// fetch_error row per requested key that did not come back.
func (s *Syncer) linkedRows(requested []string, issues []Issue, issueErrs []BulkIssueError) []db.JiraLinkedIssue {
	now := db.FormatJiraTime(time.Now())
	errByID := map[string]string{}
	for _, e := range issueErrs {
		errByID[e.ID] = e.ErrorMessage
	}
	returned := map[string]bool{}
	rows := make([]db.JiraLinkedIssue, 0, len(requested))
	for _, is := range issues {
		returned[is.Key] = true
		f := is.Fields
		row := db.JiraLinkedIssue{
			AccountID:      s.accountID,
			Key:            is.Key,
			ID:             is.ID,
			ProjectKey:     projectKeyOf(is.Key),
			Summary:        f.Summary,
			IssueType:      f.IssueType.Name,
			Status:         f.Status.Name,
			StatusCategory: NormalizeStatusCategory(f.Status.StatusCategory.Key),
			CreatedAt:      s.normalizeTime(is.Key, "created", f.Created),
			UpdatedAt:      s.normalizeTime(is.Key, "updated", f.Updated),
			SyncedAt:       now,
		}
		if f.Assignee != nil {
			row.AssigneeAccountID = f.Assignee.AccountID
			row.AssigneeDisplayName = f.Assignee.DisplayName
		}
		if f.Resolved != nil {
			row.ResolvedAt = s.normalizeTime(is.Key, "resolutiondate", *f.Resolved)
		}
		rows = append(rows, row)
	}
	for _, key := range requested {
		if returned[key] {
			continue
		}
		msg := errByID[key]
		if msg == "" {
			msg = "not returned by the site (no access, deleted or moved)"
		}
		rows = append(rows, db.JiraLinkedIssue{AccountID: s.accountID, Key: key, FetchError: msg, SyncedAt: now})
	}
	return rows
}

// projectKeyOf is the project part of an issue key ("ABC" of "ABC-12").
func projectKeyOf(key string) string {
	if i := strings.LastIndex(key, "-"); i > 0 {
		return key[:i]
	}
	return ""
}

// syncChangelogs fetches the status/assignee history of up to changelogLimit
// due issues, newest change first, changelogBatch issues per request and per
// write, replacing each issue's stored history. A failed batch is skipped
// (its issues stay due); the first failure is returned after the rest ran.
func (s *Syncer) syncChangelogs(ctx context.Context) error {
	due, err := s.db.ListJiraChangelogDue(s.accountID, s.changelogLimit)
	if err != nil {
		return err
	}
	var firstErr error
	stored := 0
	for start := 0; start < len(due); start += changelogBatch {
		batch := due[start:min(start+changelogBatch, len(due))]
		n, err := s.syncChangelogBatch(ctx, batch)
		stored += n
		if err != nil {
			if errors.Is(err, ErrAuthRevoked) || ctx.Err() != nil {
				return err
			}
			if firstErr == nil {
				firstErr = err
			}
		}
	}
	if stored > 0 {
		s.logger.Printf("changelog sync: stored the history of %d of %d due issues", stored, len(due))
	}
	return firstErr
}

// syncChangelogBatch fetches and stores one batch in one write; it returns
// how many issues' histories were stored. An issue the response does not
// mention has no status/assignee changes and is stored with an empty history.
func (s *Syncer) syncChangelogBatch(ctx context.Context, batch []db.JiraChangelogDue) (int, error) {
	ids := make([]string, len(batch))
	for i, d := range batch {
		ids[i] = d.ID
	}
	histories, err := s.client.BulkFetchChangelogs(ctx, ids, changelogFields)
	if err != nil {
		return 0, err
	}
	writes := make([]db.JiraIssueHistory, len(batch))
	for i, d := range batch {
		writes[i] = db.JiraIssueHistory{Key: d.Key, UpdatedAt: d.UpdatedAt, Items: s.changelogItems(d.Key, histories[d.ID])}
	}
	if err := s.db.ReplaceJiraIssueChangelogs(s.accountID, writes); err != nil {
		return 0, err
	}
	return len(batch), nil
}

// changelogItems flattens one issue's histories into the kept fields' rows.
func (s *Syncer) changelogItems(key string, histories []ChangeHistory) []db.JiraChangelogItem {
	var items []db.JiraChangelogItem
	for _, h := range histories {
		changedAt := s.normalizeTime(key, "changelog created", h.Created)
		authorID, authorName := "", ""
		if h.Author != nil {
			authorID, authorName = h.Author.AccountID, h.Author.DisplayName
		}
		for _, it := range h.Items {
			field := it.FieldID
			if field == "" {
				field = it.Field
			}
			if field != "status" && field != "assignee" {
				continue
			}
			items = append(items, db.JiraChangelogItem{
				AccountID: s.accountID, IssueKey: key, HistoryID: h.ID, Field: field,
				FromValue: it.From, FromString: it.FromString, ToValue: it.To, ToString: it.ToString,
				AuthorAccountID: authorID, AuthorDisplayName: authorName, ChangedAt: changedAt,
			})
		}
	}
	return items
}
