package cmd

import (
	"context"
	"fmt"
	"io"

	"watchtower/internal/db"
	"watchtower/internal/jira"
)

// myselfGetter is the one-method seam recordJiraOwner needs from a
// *jira.Client, so it is testable without a real OAuth connection.
type myselfGetter interface {
	GetMyself(context.Context) (jira.Myself, error)
}

// recordJiraOwner fetches the connecting person's own Atlassian identity
// (GET /rest/api/3/myself) and stores it on the account row. It is best
// effort: a revoked/401ing account, or any other /myself failure, must never
// fail jira add/login, so the error is written to w as a warning and
// swallowed — the caller (connect, or wireJiraSyncers' lazy fill) simply
// retries it on the next sync.
func recordJiraOwner(ctx context.Context, w io.Writer, database *db.DB, accountID int64, client myselfGetter) {
	me, err := client.GetMyself(ctx)
	if err != nil {
		fmt.Fprintf(w, "warning: could not read your Jira identity (/myself): %v; it will be retried on the next sync\n", err)
		return
	}
	if err := database.SetJiraAccountOwner(accountID, me.AccountID, me.EmailAddress, me.DisplayName); err != nil {
		fmt.Fprintf(w, "warning: could not save your Jira identity (/myself): %v; it will be retried on the next sync\n", err)
	}
}

// maybeRecordJiraOwner is wireJiraSyncers' lazy-fill guard: an account whose
// owner identity is already on file is never re-fetched, so the daemon makes
// at most one /myself attempt per account per daemon start rather than one
// per wiring pass.
func maybeRecordJiraOwner(ctx context.Context, w io.Writer, database *db.DB, acct db.JiraAccount, client myselfGetter) {
	if acct.OwnerAccountID != "" {
		return
	}
	recordJiraOwner(ctx, w, database, acct.ID, client)
}
