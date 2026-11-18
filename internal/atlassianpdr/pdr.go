// Package atlassianpdr runs Atlassian Personal Data Reporting for one Jira
// account (#1887 §6, D6, D17): every 7 days it reports the Atlassian account
// ids Watchtower stores, in chunks of 90, erases what it got from Atlassian
// about a closed account and marks an updated one for a refetch. Memory and
// free-text derived texts are not touched (P6, ask #1518).
package atlassianpdr

import (
	"context"
	"errors"
	"fmt"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/jira"
)

const (
	// ChunkSize is the most account ids one report carries (Atlassian's cap).
	ChunkSize = 90
	// Every is how often an account reports.
	Every = 7 * 24 * time.Hour
)

// Status is Atlassian's answer for one account id.
type Status string

const (
	StatusClosed  Status = "closed"
	StatusUpdated Status = "updated"
	// StatusOK is an id Atlassian did not list: nothing to do.
	StatusOK Status = "ok"
)

// Reporter posts one chunk of account ids (each with the time its stored
// data was fetched) and returns the status of each id that needs an action;
// an id it leaves out is StatusOK. An error wrapping
// jira.ErrReportScopeMissing means the grant lacks the report scope.
type Reporter interface {
	Report(ctx context.Context, ids []string, updatedAt map[string]time.Time) (map[string]Status, error)
}

// ClientReporter reports through a Jira account's OAuth client.
type ClientReporter struct{ Client *jira.Client }

// Report implements Reporter.
func (r ClientReporter) Report(ctx context.Context, ids []string, updatedAt map[string]time.Time) (map[string]Status, error) {
	accts := make([]jira.ReportedAccount, len(ids))
	for i, id := range ids {
		accts[i] = jira.ReportedAccount{AccountID: id, UpdatedAt: updatedAt[id]}
	}
	got, err := r.Client.ReportAccounts(ctx, accts)
	if err != nil {
		return nil, err
	}
	out := make(map[string]Status, len(got))
	for id, s := range got {
		out[id] = Status(s)
	}
	return out, nil
}

// Result is what one Run did.
type Result struct {
	// NotDue: the account reported less than Every ago; nothing was sent.
	NotDue bool
	// Skipped: the account cannot report (an API-token account, Task 17).
	Skipped  bool
	Reported int
	Closed   int
	Updated  int
}

// Due reports whether an account last reported at lastPDRAt (RFC 3339, ""
// = never) must report at now.
func Due(lastPDRAt string, now time.Time) bool {
	if lastPDRAt == "" {
		return true
	}
	last, err := time.Parse(time.RFC3339, lastPDRAt)
	if err != nil {
		return true
	}
	return !now.Before(last.Add(Every))
}

// Run reports Jira account accountID's stored Atlassian ids when it is due,
// in chunks of ChunkSize, all before acting: any error (network, 401, 403, a
// missing scope) erases nothing and stamps nothing, so the next cycle tries
// again. A refused scope leaves the pdr_scope_missing hint on the account
// (status unchanged); a whole-account success clears it, erases the closed
// ids in one write transaction (EraseClosed), marks the updated ones stale
// and stamps last_pdr_at.
func Run(ctx context.Context, d *db.DB, accountID int64, r Reporter, now time.Time) (Result, error) {
	acct, err := d.GetJiraAccount(accountID)
	if err != nil {
		return Result{}, err
	}
	if acct.AuthKind == "api_token" {
		return Result{Skipped: true}, nil // the report API needs an app's token
	}
	if !Due(acct.LastPDRAt, now) {
		return Result{NotDue: true}, nil
	}
	people, err := d.AtlassianPeople(ctx, accountID)
	if err != nil {
		return Result{}, err
	}
	var res Result
	var closed, updated []string
	for start := 0; start < len(people); start += ChunkSize {
		chunk := people[start:min(start+ChunkSize, len(people))]
		ids := make([]string, len(chunk))
		at := make(map[string]time.Time, len(chunk))
		for i, p := range chunk {
			ids[i] = p.ID
			// Atlassian wants a time per id; with no fetch time on record the
			// data is as fresh as this report.
			at[p.ID] = p.UpdatedAt
			if p.UpdatedAt.IsZero() {
				at[p.ID] = now.UTC()
			}
		}
		statuses, err := r.Report(ctx, ids, at)
		if err != nil {
			if errors.Is(err, jira.ErrReportScopeMissing) {
				if hintErr := d.SetJiraPDRScopeHint(accountID, true); hintErr != nil {
					err = errors.Join(err, hintErr)
				}
			}
			return Result{}, fmt.Errorf("personal data report: %w", err)
		}
		for _, id := range ids {
			switch statuses[id] {
			case StatusClosed:
				closed = append(closed, id)
			case StatusUpdated:
				updated = append(updated, id)
			case StatusOK:
				// nothing to do (also any status Atlassian may add later)
			}
		}
		res.Reported += len(ids)
	}
	if err := EraseClosed(ctx, d, accountID, closed); err != nil {
		return Result{}, err
	}
	if err := d.MarkAtlassianPeopleStale(ctx, updated); err != nil {
		return Result{}, err
	}
	res.Closed, res.Updated = len(closed), len(updated)
	if len(people) > 0 {
		if err := d.SetJiraPDRScopeHint(accountID, false); err != nil {
			return res, err
		}
	}
	if err := d.SetJiraLastPDR(accountID, now.UTC().Format(time.RFC3339)); err != nil {
		return res, err
	}
	return res, nil
}
