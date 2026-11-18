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

// Reporter is an Atlassian account's side of Personal Data Reporting.
type Reporter interface {
	// Report posts one chunk of account ids (each with the time its stored
	// data was fetched) and returns the status of each id that needs an
	// action; an id it leaves out is StatusOK. An error wrapping
	// jira.ErrReportScopeMissing means the grant lacks the report scope.
	Report(ctx context.Context, ids []string, updatedAt map[string]time.Time) (map[string]Status, error)
	// Profiles fetches the current profiles of ids (an "updated" answer).
	Profiles(ctx context.Context, ids []string) ([]db.AtlassianProfile, error)
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

// Profiles implements Reporter.
func (r ClientReporter) Profiles(ctx context.Context, ids []string) ([]db.AtlassianProfile, error) {
	users, err := r.Client.UsersBulk(ctx, ids)
	if err != nil {
		return nil, err
	}
	out := make([]db.AtlassianProfile, len(users))
	for i, u := range users {
		out[i] = db.AtlassianProfile{ID: u.AccountID, DisplayName: u.DisplayName, Email: u.EmailAddress}
	}
	return out, nil
}

// Result is what one Run did.
type Result struct {
	// NotDue: the account reported less than Every ago; nothing was sent.
	NotDue bool
	// Skipped: an API-token account, which cannot call the report API (it
	// needs an app's token).
	Skipped  bool
	Reported int
	Closed   int
	Updated  int
}

// Due reports whether an account last reported at lastPDRAt (RFC 3339, ""
// = never) must report at now.
func Due(lastPDRAt string, now time.Time) bool {
	last, ok := parseTime(lastPDRAt)
	return !ok || !now.Before(last.Add(Every))
}

// parseTime reads an RFC 3339 time or SQLite's "YYYY-MM-DD HH:MM:SS".
func parseTime(s string) (time.Time, bool) {
	for _, layout := range []string{time.RFC3339Nano, time.DateTime} {
		if t, err := time.Parse(layout, s); err == nil {
			return t.UTC(), true
		}
	}
	return time.Time{}, false
}

// Run reports Jira account accountID's stored Atlassian ids when it is due,
// in chunks of ChunkSize, and fetches the profiles answered "updated" — all
// network before any write: any error (network, 401, 403, a missing scope)
// erases nothing and stamps nothing, so a later cycle tries again. A refused
// scope on a company's account leaves the pdr_scope_missing hint (status
// unchanged; "Re-login to finish the setup" requests the scope); a
// whole-account success clears it, erases the closed ids in one write
// transaction (EraseClosed), writes the refetched profiles and stamps
// last_pdr_at.
func Run(ctx context.Context, d *db.DB, accountID int64, r Reporter, now time.Time) (Result, error) {
	acct, err := d.GetJiraAccount(accountID)
	if err != nil {
		return Result{}, err
	}
	if acct.AuthKind == "api_token" {
		return Result{Skipped: true}, nil
	}
	if !Due(acct.LastPDRAt, now) {
		return Result{NotDue: true}, nil
	}
	people, err := d.AtlassianPeople(ctx, accountID)
	if err != nil {
		return Result{}, err
	}
	// An id with no fetch time on record is dated as old as can be known —
	// the last report, else the account's creation — so a profile change
	// since then is still answered "updated".
	unknownAge, ok := parseTime(acct.LastPDRAt)
	if !ok {
		if unknownAge, ok = parseTime(acct.CreatedAt); !ok {
			unknownAge = now.UTC()
		}
	}
	var res Result
	var closed, updated []string
	for start := 0; start < len(people); start += ChunkSize {
		chunk := people[start:min(start+ChunkSize, len(people))]
		ids := make([]string, len(chunk))
		at := make(map[string]time.Time, len(chunk))
		for i, p := range chunk {
			ids[i] = p.ID
			at[p.ID] = p.UpdatedAt
			if p.UpdatedAt.IsZero() {
				at[p.ID] = unknownAge
			}
		}
		statuses, err := r.Report(ctx, ids, at)
		if err != nil {
			if errors.Is(err, jira.ErrReportScopeMissing) && acct.CompanySlug != "" {
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
	var profiles []db.AtlassianProfile
	for start := 0; start < len(updated); start += ChunkSize {
		got, err := r.Profiles(ctx, updated[start:min(start+ChunkSize, len(updated))])
		if err != nil {
			return Result{}, fmt.Errorf("refetching updated atlassian profiles: %w", err)
		}
		profiles = append(profiles, got...)
	}
	if err := EraseClosed(ctx, d, accountID, closed); err != nil {
		return Result{}, err
	}
	if err := d.RefreshAtlassianProfiles(ctx, profiles, now); err != nil {
		return Result{}, err
	}
	res.Closed, res.Updated = len(closed), len(updated)
	if err := d.SetJiraPDRScopeHint(accountID, false); err != nil {
		return res, err
	}
	if err := d.SetJiraLastPDR(accountID, now.UTC().Format(time.RFC3339)); err != nil {
		return res, err
	}
	return res, nil
}
