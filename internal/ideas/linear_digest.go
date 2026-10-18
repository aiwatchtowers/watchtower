package ideas

import (
	"context"
	"fmt"
	"time"

	"watchtower/internal/db"
)

// The Linear stream (spec 2026-10-15-linear-integration-design §6 "ideas"):
// one stage-1 pass per enabled Linear workspace over the issues updated since
// linear_accounts.ideas_floor, with their new comments, into a
// stream_digests(source='linear') row. Linear behaves like Jira, so the pass
// runs the Jira stream's own render, floor and tie-drain code over the issues
// projected onto the db.JiraIssue/db.JiraComment fields that code reads (key,
// team key as the project, title, state, description, updated_at; comment
// author and body) — one implementation of IDEA-01's floor honesty, not two.
// A candidate's ref is the bare issue key, as for Jira; the consolidator mints
// its mention with source 'linear'.

// runLinearDigests is the Linear pre-digest pass: one Generate call per
// enabled Linear account, per-account errors logged and the loop continued
// (runJiraDigests' shape). bound is an optional upper bound on the issue
// window (zero = unbounded, the daemon path).
func (p *Pipeline) runLinearDigests(ctx context.Context, bound time.Time) error {
	if p.generator == nil {
		return nil
	}
	accounts, err := p.db.ListEnabledLinearAccounts()
	if err != nil {
		return fmt.Errorf("ideas: listing linear accounts: %w", err)
	}
	var firstErr error
	for _, acct := range accounts {
		if err := p.runLinearDigestAccount(ctx, acct.ID, bound); err != nil {
			p.logf("ideas: linear digest account %d: %v", acct.ID, err)
			if firstErr == nil {
				firstErr = err
			}
		}
	}
	return firstErr
}

// runLinearDigestAccount runs the Linear pass for one account. An empty floor
// initializes to now (minus jiraFloorInitBackoff) and mines nothing — no
// backfill, the Jira precedent. Zero changed issues is a clean no-op.
func (p *Pipeline) runLinearDigestAccount(ctx context.Context, accountID int64, bound time.Time) error {
	floor, err := p.db.IdeasLinearFloor(accountID)
	if err != nil {
		return fmt.Errorf("getting ideas linear floor: %w", err)
	}
	if floor == "" {
		now := db.FormatJiraTime(time.Now().UTC().Add(-jiraFloorInitBackoff))
		if err := p.db.SetIdeasLinearFloor(accountID, now); err != nil {
			return fmt.Errorf("initializing ideas linear floor: %w", err)
		}
		p.logf("ideas: linear account %d floor initialized at %s, no backfill", accountID, now)
		return nil
	}
	reached, err := p.linearDigestPass(ctx, accountID, floor, bound)
	if err != nil || reached == floor {
		return err
	}
	if err := p.db.SetIdeasLinearFloor(accountID, reached); err != nil {
		return fmt.Errorf("advancing ideas linear floor: %w", err)
	}
	return nil
}

// failingLinearTeamClamp is failingJiraProjectClamp for Linear: a selected
// team whose latest sync failed holds the account's floor at its last
// successful sync (the Linear syncer records the error and keeps going with
// the other teams, so their issues could otherwise carry the floor past the
// failing team's unsynced changes — IDEA-01).
func (p *Pipeline) failingLinearTeamClamp(accountID int64, now time.Time) (time.Time, bool, error) {
	lagging, err := p.db.OldestFailingLinearTeamSync(accountID)
	if err != nil {
		return time.Time{}, false, err
	}
	clamp, ok := p.laggingSyncClamp(linearStream, accountID, lagging, now)
	return clamp, ok, nil
}

// linearDigestPass mines one window of the account's issues above floor and
// returns the floor it reached (floor itself when there was nothing to mine).
// It reads and writes no stored floor.
func (p *Pipeline) linearDigestPass(ctx context.Context, accountID int64, floor string, bound time.Time) (string, error) {
	beforeISO, err := p.boundedBeforeISO(linearStream, accountID, bound, p.failingLinearTeamClamp)
	if err != nil {
		return floor, err
	}
	issues, err := p.db.ListLinearIssuesUpdatedSince(accountID, floor, beforeISO, jiraIssuesPerAccountLimit)
	if err != nil {
		return floor, fmt.Errorf("listing linear issues: %w", err)
	}
	if len(issues) == 0 {
		return floor, nil
	}

	units, commentsByIssue, err := p.linearUnits(accountID, issues, floor)
	if err != nil {
		return floor, err
	}

	what := fmt.Sprintf("linear account %d", accountID)
	block, tags, renderedTo := p.renderJiraWindow(what, units, commentsByIssue, p.maxPromptChars())
	if renderedTo == "" {
		// Unreachable for a non-empty window (see jiraDigestPass).
		return floor, fmt.Errorf("no issue rendered from %d linear issues", len(issues))
	}

	topics, err := p.mineStreamTopics(ctx, "ideas.digest_jira", what, block, "", tags)
	if err != nil {
		return floor, err
	}
	if err := p.insertStreamTopics(db.StreamDigest{
		Source:     "linear",
		AccountID:  accountID,
		PeriodFrom: normalizeJiraStreamPeriod(floor),
		PeriodTo:   normalizeJiraStreamPeriod(renderedTo),
	}, topics, what); err != nil {
		return floor, err
	}
	return renderedTo, nil
}

// linearUnits projects the window's issues and their comments (updated at or
// after floor) onto the shapes the Jira stream renderer reads, keyed by the
// issue's current key.
func (p *Pipeline) linearUnits(accountID int64, issues []db.LinearIssue, floor string) ([]db.JiraIssue, map[string][]db.JiraComment, error) {
	units := make([]db.JiraIssue, len(issues))
	ids := make([]string, len(issues))
	keyByID := make(map[string]string, len(issues))
	for i, is := range issues {
		units[i] = db.JiraIssue{
			AccountID: accountID, Key: is.Key, ProjectKey: is.TeamKey, Summary: is.Title,
			Status: is.StateName, StatusCategory: is.StatusCategory, DescriptionText: is.DescriptionText,
			UpdatedAt: is.UpdatedAt,
		}
		ids[i] = is.ID
		keyByID[is.ID] = is.Key
	}
	comments, err := p.db.ListLinearCommentsSince(accountID, ids, floor)
	if err != nil {
		return nil, nil, fmt.Errorf("listing linear comments: %w", err)
	}
	byIssue := make(map[string][]db.JiraComment, len(issues))
	for _, c := range comments {
		key := keyByID[c.IssueID]
		byIssue[key] = append(byIssue[key], db.JiraComment{
			AccountID: accountID, IssueKey: key, ID: c.ID, Author: c.AuthorDisplayName,
			AuthorAccountID: c.AuthorID, BodyText: c.BodyText, CreatedAt: c.CreatedAt, UpdatedAt: c.UpdatedAt,
		})
	}
	return units, byIssue, nil
}
