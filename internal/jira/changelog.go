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

// linkedRows turns one bulk issue response into rows: one per requested key
// that came back, and one fetch_error row per requested key that did not. An
// issue returned under a key nobody asked for (Jira follows a moved issue to
// its new key) is dropped: no link names that key, so the next prune would
// delete it and the fetch would repeat every rotation. It shows up once the
// linking issue is re-synced and its link carries the new key.
func (s *Syncer) linkedRows(requested []string, issues []Issue, issueErrs []BulkIssueError) []db.JiraLinkedIssue {
	now := db.FormatJiraTime(time.Now())
	errByID := map[string]string{}
	for _, e := range issueErrs {
		errByID[e.ID] = e.ErrorMessage
	}
	returned := map[string]bool{}
	rows := make([]db.JiraLinkedIssue, 0, len(requested))
	asked := make(map[string]bool, len(requested))
	for _, key := range requested {
		asked[key] = true
	}
	for _, is := range issues {
		if !asked[is.Key] {
			continue
		}
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
			msg = "not returned under this key (no access, deleted, or moved to another key)"
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
// write, replacing each issue's stored history. A failed batch does not stop
// the next one (see syncChangelogBatch); the first failure is returned after
// the rest ran.
func (s *Syncer) syncChangelogs(ctx context.Context) error {
	due, err := s.db.ListJiraChangelogDue(s.accountID, s.changelogLimit)
	if err != nil {
		return err
	}
	var firstErr error
	var tally changelogTally
	for start := 0; start < len(due); start += changelogBatch {
		if err := s.syncChangelogBatch(ctx, due[start:min(start+changelogBatch, len(due))], &tally); err != nil {
			if errors.Is(err, ErrAuthRevoked) || ctx.Err() != nil {
				return err
			}
			if firstErr == nil {
				firstErr = err
			}
		}
	}
	if tally.stored > 0 {
		s.logger.Printf("changelog sync: stored the history of %d of %d due issues (%d had no status/assignee change in the response)",
			tally.stored, len(due), tally.unchanged)
	}
	return firstErr
}

// changelogTally counts what one pass stored.
type changelogTally struct {
	stored    int // issues whose history was written
	unchanged int // of those, issues the response did not mention
}

// syncChangelogBatch fetches and stores one batch in one write. An issue the
// response does not mention has no status/assignee changes and is stored with
// an empty history (counted in tally.unchanged, so a site that omits issues
// for another reason shows up in the log). A rejected request (a 4xx other
// than 429: the site refused what was asked) is split in half and retried,
// down to single issues, so one issue the API refuses cannot keep the rest of
// its batch without history pass after pass; the issue that still fails alone
// is logged by key and stays due.
func (s *Syncer) syncChangelogBatch(ctx context.Context, batch []db.JiraChangelogDue, tally *changelogTally) error {
	ids := make([]string, len(batch))
	for i, d := range batch {
		ids[i] = d.ID
	}
	histories, err := s.client.BulkFetchChangelogs(ctx, ids, changelogFields)
	if err != nil {
		if errors.Is(err, ErrAuthRevoked) || ctx.Err() != nil {
			return err
		}
		if !isRequestRejected(err) {
			return err // an outage is not split: it would only multiply the calls
		}
		if len(batch) == 1 {
			s.logger.Printf("changelog sync: %s: %v", batch[0].Key, err)
			return err
		}
		half := len(batch) / 2
		errLeft := s.syncChangelogBatch(ctx, batch[:half], tally)
		if errors.Is(errLeft, ErrAuthRevoked) || ctx.Err() != nil {
			return errLeft
		}
		return errors.Join(errLeft, s.syncChangelogBatch(ctx, batch[half:], tally))
	}
	writes := make([]db.JiraIssueHistory, len(batch))
	unchanged := 0
	for i, d := range batch {
		h, ok := histories[d.ID]
		if !ok {
			unchanged++
		}
		writes[i] = db.JiraIssueHistory{Key: d.Key, UpdatedAt: d.UpdatedAt, Items: s.changelogItems(d.Key, h)}
	}
	if err := s.db.ReplaceJiraIssueChangelogs(s.accountID, writes); err != nil {
		return err
	}
	tally.stored += len(batch)
	tally.unchanged += unchanged
	return nil
}

// isRequestRejected reports whether err is the site refusing the request
// itself (4xx other than 429), as opposed to an outage or a rate limit.
func isRequestRejected(err error) bool {
	var apiErr *APIError
	return errors.As(err, &apiErr) && apiErr.Status >= 400 && apiErr.Status < 500 && apiErr.Status != http.StatusTooManyRequests
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
