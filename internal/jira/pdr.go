package jira

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"time"
)

// ReportAccountsPath is Atlassian's Personal Data Reporting endpoint under
// the API root: https://api.atlassian.com/app/report-accounts/ (#1887 §6).
const ReportAccountsPath = "/app/report-accounts/"

// PDRScope is the OAuth scope the Personal Data Reporting call needs.
const PDRScope = "report:personal-data"

// ErrReportScopeMissing is returned when Atlassian refuses a report because
// the grant lacks PDRScope: the account needs a new sign-in through an app
// that has the permission ("Re-login to finish the setup").
var ErrReportScopeMissing = errors.New("atlassian: the grant lacks the " + PDRScope + " scope")

// ErrReportScopeNotGranted is a refused report on a grant whose sign-in
// already asked for PDRScope: Atlassian left it out (a known Atlassian
// behaviour) or the app lacks the permission, so a new sign-in cannot fix
// it and no "Re-login" hint is shown (spike S1.8).
var ErrReportScopeNotGranted = errors.New("atlassian: " + PDRScope + " was asked for at sign-in but not granted")

// reportScopeRefused wraps cause in the sentinel that fits the stored grant:
// ErrReportScopeNotGranted when its sign-in already asked for PDRScope,
// ErrReportScopeMissing otherwise (a re-login asks for it).
func (c *Client) reportScopeRefused(cause error) error {
	if tok, err := c.tokenStore.Load(); err == nil && slices.Contains(strings.Fields(tok.RequestedScope), PDRScope) {
		return fmt.Errorf("%w: %w", ErrReportScopeNotGranted, cause)
	}
	return fmt.Errorf("%w: %w", ErrReportScopeMissing, cause)
}

// ReportedAccount is one stored Atlassian account id and the time the
// personal data Watchtower holds about it was last fetched.
type ReportedAccount struct {
	AccountID string
	UpdatedAt time.Time
}

// UsersBulk fetches the current profiles of ids (at most 90 per call, the
// report's chunk) from GET /rest/api/3/user/bulk — the refetch of accounts
// a report answered "updated". An id Atlassian does not return is left out.
func (c *Client) UsersBulk(ctx context.Context, ids []string) ([]User, error) {
	return usersBulk[User](ctx, c, ids)
}

// BulkUser is a /user/bulk profile as the closed-account lookup reads it:
// Active is nil when Atlassian sent no "active" field, so an absent field is
// never read as an inactive account.
type BulkUser struct {
	AccountID   string `json:"accountId"`
	DisplayName string `json:"displayName"`
	AccountType string `json:"accountType"`
	Active      *bool  `json:"active"`
}

// UsersBulkStatus is UsersBulk for the closed-account lookup of an API-token
// account (#1887 D23).
func (c *Client) UsersBulkStatus(ctx context.Context, ids []string) ([]BulkUser, error) {
	return usersBulk[BulkUser](ctx, c, ids)
}

// usersBulk fetches GET /rest/api/3/user/bulk for ids, decoded as T.
func usersBulk[T any](ctx context.Context, c *Client, ids []string) ([]T, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	params := url.Values{"accountId": ids, "maxResults": {strconv.Itoa(len(ids))}}
	var page struct {
		Values []T `json:"values"`
	}
	if err := c.getWithQuery(ctx, "/rest/api/3/user/bulk", params, &page); err != nil {
		return nil, fmt.Errorf("fetching %d atlassian profiles: %w", len(ids), err)
	}
	return page.Values, nil
}

type reportAccountJSON struct {
	AccountID string `json:"accountId"`
	UpdatedAt string `json:"updatedAt,omitempty"`
	Status    string `json:"status,omitempty"`
}

type reportAccountsBody struct {
	Accounts []reportAccountJSON `json:"accounts"`
}

// ReportAccounts posts accounts to the Personal Data Reporting API and
// returns the status Atlassian answered for each account that needs an
// action ("closed" or "updated"); an account it does not list needs none.
// The caller keeps one call to at most 90 accounts. A refused scope (403, or
// a 401 naming a scope) wraps ErrReportScopeMissing, or
// ErrReportScopeNotGranted when the grant's sign-in already asked for it; any other non-2xx
// answer is an error. Token refresh and 429 backoff are doURL's.
func (c *Client) ReportAccounts(ctx context.Context, accounts []ReportedAccount) (map[string]string, error) {
	body := reportAccountsBody{Accounts: make([]reportAccountJSON, len(accounts))}
	for i, a := range accounts {
		body.Accounts[i] = reportAccountJSON{AccountID: a.AccountID}
		if !a.UpdatedAt.IsZero() {
			body.Accounts[i].UpdatedAt = a.UpdatedAt.UTC().Format("2006-01-02T15:04:05.000Z")
		}
	}
	payload, err := json.Marshal(body)
	if err != nil {
		return nil, fmt.Errorf("encoding the account report: %w", err)
	}
	resp, err := c.doURL(ctx, http.MethodPost, c.apiRoot+ReportAccountsPath, payload)
	if err != nil {
		var herr *HTTPStatusError
		if errors.As(err, &herr) && herr.Status == http.StatusUnauthorized && strings.Contains(strings.ToLower(herr.Body), "scope") {
			return nil, c.reportScopeRefused(err)
		}
		return nil, fmt.Errorf("reporting accounts: %w", err)
	}
	defer resp.Body.Close()
	switch {
	case resp.StatusCode == http.StatusNoContent:
		return map[string]string{}, nil
	case resp.StatusCode == http.StatusForbidden:
		return nil, c.reportScopeRefused(newHTTPStatusError(resp))
	case resp.StatusCode < 200 || resp.StatusCode > 299:
		return nil, fmt.Errorf("reporting accounts: %w", newHTTPStatusError(resp))
	}
	var out reportAccountsBody
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&out); err != nil && !errors.Is(err, io.EOF) {
		return nil, fmt.Errorf("decoding the account report answer: %w", err)
	}
	statuses := make(map[string]string, len(out.Accounts))
	for _, a := range out.Accounts {
		if a.AccountID != "" {
			statuses[a.AccountID] = a.Status
		}
	}
	return statuses, nil
}
