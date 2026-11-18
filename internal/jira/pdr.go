package jira

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
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

// ReportedAccount is one stored Atlassian account id and the time the
// personal data Watchtower holds about it was last fetched.
type ReportedAccount struct {
	AccountID string
	UpdatedAt time.Time
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
// a 401 naming a scope) wraps ErrReportScopeMissing; any other non-2xx
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
	resp, err := c.doURL(ctx, http.MethodPost, c.apiRoot+ReportAccountsPath, payload, jsonAccept)
	if err != nil {
		var herr *HTTPStatusError
		if errors.As(err, &herr) && herr.Status == http.StatusUnauthorized && strings.Contains(strings.ToLower(herr.Body), "scope") {
			return nil, fmt.Errorf("%w: %w", ErrReportScopeMissing, err)
		}
		return nil, fmt.Errorf("reporting accounts: %w", err)
	}
	defer resp.Body.Close()
	switch {
	case resp.StatusCode == http.StatusNoContent:
		return map[string]string{}, nil
	case resp.StatusCode == http.StatusForbidden:
		return nil, fmt.Errorf("%w: %w", ErrReportScopeMissing, newHTTPStatusError(resp))
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
