package jira

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"time"

	"watchtower/internal/sourcediff"
)

const (
	deletionCheckEvery = 24 * time.Hour
	maxIssueConfirms   = 100 // per project per check; the rest wait for the next day
)

// CheckDeletedIssues removes the issues Jira no longer has, at most once per
// deletionCheckEvery per project. It returns how many rows were removed.
// ErrAuthRevoked is returned as is; any other per-project failure is logged
// and leaves that project unstamped, so the next cycle retries it.
//
// Per selected board's project with a completed sync, the stored keys are read
// first, then the project's keys are listed; a complete listing that
// sourcediff.Check accepts names the missing keys, and each one is confirmed
// with Jira (404, or now under another key) before it is deleted. See
// docs/features/source-deletions.md.
func (s *Syncer) CheckDeletedIssues(ctx context.Context, now time.Time) (removed int, err error) {
	boards, err := s.db.GetJiraSelectedBoards(s.accountID)
	if err != nil {
		return 0, fmt.Errorf("jira deletions: getting selected boards: %w", err)
	}
	var projects []string
	boardsOf := map[string][]int{}
	for _, b := range boards {
		if b.ProjectKey == "" || !validProjectKeyRe.MatchString(b.ProjectKey) {
			continue
		}
		if _, ok := boardsOf[b.ProjectKey]; !ok {
			projects = append(projects, b.ProjectKey)
		}
		boardsOf[b.ProjectKey] = append(boardsOf[b.ProjectKey], b.ID)
	}
	for _, project := range projects {
		if err := ctx.Err(); err != nil {
			return removed, err
		}
		if last, ok := s.deletionsCheckedAt[project]; ok && now.Sub(last) < deletionCheckEvery {
			continue
		}
		n, done, err := s.checkProjectDeletions(ctx, project, boardsOf[project])
		removed += n
		if errors.Is(err, ErrAuthRevoked) {
			return removed, err
		}
		if err != nil {
			s.logger.Printf("jira deletions: account %d project %s: %v", s.accountID, project, err)
			continue
		}
		if done {
			s.deletionsCheckedAt[project] = now
		}
	}
	return removed, nil
}

// checkProjectDeletions runs one project's diff. done reports whether the
// check finished and the project may be stamped; it is false (with a nil
// error) when the project has no completed sync yet or the listing was
// incomplete.
func (s *Syncer) checkProjectDeletions(ctx context.Context, project string, boardIDs []int) (removed int, done bool, err error) {
	state, err := s.db.GetJiraSyncState(s.accountID, project)
	if err != nil {
		return 0, false, fmt.Errorf("reading sync state: %w", err)
	}
	if state == nil || state.LastSyncedAt == "" {
		return 0, false, nil // no completed pass yet: nothing to judge
	}
	// The stored set is read before the listing, so an issue synced while the
	// listing is in flight is never judged against it.
	stored, err := s.db.JiraProjectIssueKeys(s.accountID, project)
	if err != nil {
		return 0, false, err
	}
	if len(stored) == 0 {
		return 0, true, nil
	}
	listed, complete, err := s.client.searchIssueKeys(ctx, "project = "+project+" ORDER BY key ASC")
	if err != nil {
		return 0, false, err
	}
	if !complete {
		s.logger.Printf("jira deletions: account %d project %s: listing incomplete, skipped", s.accountID, project)
		return 0, false, nil
	}
	inListing := make(map[string]bool, len(listed))
	for _, k := range listed {
		inListing[k] = true
	}
	var missing []string
	for _, k := range stored {
		if !inListing[k] {
			missing = append(missing, k)
		}
	}
	slices.Sort(missing)
	ok, reason := sourcediff.Check(len(stored), len(stored)-len(missing), len(missing), sourcediff.IssueFloors)
	if !ok {
		if reason != "" {
			s.logger.Printf("jira deletions: account %d project %s: %s, skipped", s.accountID, project, reason)
		}
		return 0, true, nil
	}

	if len(missing) > maxIssueConfirms {
		s.logger.Printf("jira deletions: account %d project %s: %d missing issues, confirming %d, the rest wait for the next check",
			s.accountID, project, len(missing), maxIssueConfirms)
		missing = missing[:maxIssueConfirms]
	}
	var confirmed []string
	kept := 0
	var confirmErr error
	for _, key := range missing {
		current, err := s.client.issueCurrentKey(ctx, key)
		if errors.Is(err, ErrAuthRevoked) {
			return 0, false, err
		}
		if err != nil {
			confirmErr = err
			break
		}
		switch current {
		case key:
			kept++
		case "":
			confirmed = append(confirmed, key)
		default:
			s.logger.Printf("jira deletions: account %d project %s: %s → %s (moved)", s.accountID, project, key, current)
			confirmed = append(confirmed, key)
		}
	}
	if kept > 0 {
		s.logger.Printf("jira deletions: account %d project %s: %d issues missing from the listing still exist, kept",
			s.accountID, project, kept)
	}

	n, err := s.db.DeleteJiraIssues(s.accountID, confirmed)
	if err != nil {
		return 0, false, errors.Join(err, confirmErr)
	}
	if n > 0 {
		for _, id := range boardIDs {
			if err := s.db.UpdateJiraBoardIssueCount(s.accountID, id); err != nil {
				s.logger.Printf("jira deletions: account %d project %s: %v", s.accountID, project, err)
			}
		}
		s.logger.Printf("jira deletions: account %d project %s: removed %d issues", s.accountID, project, n)
	}
	if confirmErr != nil {
		return n, false, fmt.Errorf("confirming missing issues: %w", confirmErr)
	}
	return n, true, nil
}
