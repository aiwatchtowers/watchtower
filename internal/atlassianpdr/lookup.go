package atlassianpdr

import (
	"context"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/jira"
)

// An API-token account cannot call the Personal Data Reporting API (it
// belongs to apps), so it learns of closed accounts another way (#1887 §4b,
// D23): the same 7-day phase looks the stored ids up with the token (GET
// /rest/api/3/user/bulk) and applies the same erase to every profile
// Atlassian shows as closed.

// UsersGetter fetches current profiles (jira.Client.UsersBulkStatus).
type UsersGetter interface {
	UsersBulkStatus(ctx context.Context, ids []string) ([]jira.BulkUser, error)
}

// LookupReporter is the Reporter of an API-token account: Report looks the
// ids up instead of reporting them. It never answers "updated".
type LookupReporter struct{ Users UsersGetter }

// Report implements Reporter: the ids Atlassian shows as closed.
func (r LookupReporter) Report(ctx context.Context, ids []string, _ map[string]time.Time) (map[string]Status, error) {
	return LookupClosed(ctx, r.Users, ids)
}

// Profiles implements Reporter; a lookup answers no "updated", so it is
// never asked.
func (LookupReporter) Profiles(context.Context, []string) ([]db.AtlassianProfile, error) {
	return nil, nil
}

// LookupClosed looks ids up and returns the ones Atlassian shows as closed,
// and as StatusUnknown the ones its answer leaves out. An error (403,
// network, anything) closes nothing: the caller erases nothing and tries
// again.
func LookupClosed(ctx context.Context, g UsersGetter, ids []string) (map[string]Status, error) {
	users, err := g.UsersBulkStatus(ctx, ids)
	if err != nil {
		return nil, err
	}
	return classifyBulkUsers(ids, users), nil
}

// closedDisplayName is the name Atlassian gives a closed account's
// anonymised profile.
const closedDisplayName = "Former user"

// classifyBulkUsers marks closed only an asked-for id whose profile is both
// explicitly inactive ("active": false, not an absent field) and anonymised
// (closedDisplayName). Spike S1.5 has not fixed Atlassian's closed-account
// marker yet, so anything less is ambiguous and erases nothing: an inactive
// profile with a name is a deactivated person, not a closed account. An id
// Atlassian leaves out may only be hidden from this token, or not found this
// time: it is StatusUnknown, never closed, and Run retries the account.
func classifyBulkUsers(ids []string, users []jira.BulkUser) map[string]Status {
	asked := make(map[string]bool, len(ids))
	for _, id := range ids {
		asked[id] = true
	}
	answered := make(map[string]bool, len(users))
	out := map[string]Status{}
	for _, u := range users {
		answered[u.AccountID] = true
		if asked[u.AccountID] && u.Active != nil && !*u.Active && strings.EqualFold(strings.TrimSpace(u.DisplayName), closedDisplayName) {
			out[u.AccountID] = StatusClosed
		}
	}
	for _, id := range ids {
		if !answered[id] {
			out[id] = StatusUnknown
		}
	}
	return out
}
