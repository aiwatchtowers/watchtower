package jira

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	"watchtower/internal/sourcediff"
)

const (
	deletionCheckEvery = 24 * time.Hour
	deletionRetryAfter = time.Hour // after a failed or incomplete check
	maxIssueConfirms   = 100       // per project per check; the rest wait for the next day
)

// CheckDeletedIssues removes the issues Jira no longer has, at most once per
// deletionCheckEvery per project. It returns how many rows were removed.
// ErrAuthRevoked is returned as is; any other per-project failure (a listing
// error, an incomplete listing, a failed lookup) is logged and the project is
// retried after deletionRetryAfter. A project with no completed sync yet is
// not stamped and is looked at again on the next call.
//
// Per selected board's project with a completed sync, the stored keys are read
// first, then the project's keys are listed; a complete listing that
// sourcediff.Check accepts names the missing keys, and each one is confirmed
// with Jira (404, or now under another key) before it is deleted. Keys Jira
// still returns under the same key are remembered for the daemon run and
// looked up only after the not-yet-checked ones, so they never hold real
// deletions behind maxIssueConfirms. See docs/features/source-deletions.md.
func (s *Syncer) CheckDeletedIssues(ctx context.Context, now time.Time) (removed int, err error) {
	boards, err := s.db.GetJiraSelectedBoards(s.accountID)
	if err != nil {
		return 0, fmt.Errorf("jira deletions: getting selected boards: %w", err)
	}
	var projects []string
	boardsOf := map[string][]int{}
	for _, b := range boards {
		if b.ProjectKey == "" {
			continue
		}
		if !validProjectKeyRe.MatchString(b.ProjectKey) {
			s.logger.Printf("jira deletions: account %d board %d: project key %q is not valid, skipped",
				s.accountID, b.ID, b.ProjectKey)
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
		if due, ok := s.deletionsDueAt[project]; ok && now.Before(due) {
			continue
		}
		n, done, err := s.checkProjectDeletions(ctx, project, boardsOf[project], now)
		removed += n
		switch {
		case errors.Is(err, ErrAuthRevoked):
			return removed, err
		case err != nil:
			s.logger.Printf("jira deletions: account %d project %s: %v, retrying in %s",
				s.accountID, project, err, deletionRetryAfter)
			s.deletionsDueAt[project] = now.Add(deletionRetryAfter)
		case done:
			s.deletionsDueAt[project] = now.Add(deletionCheckEvery)
		}
	}
	return removed, nil
}

// checkProjectDeletions runs one project's diff. done reports whether the
// check finished and the project may be stamped for the day; it is false with
// a nil error only when the project has no completed sync yet. An incomplete
// listing is an error, so the caller backs off.
func (s *Syncer) checkProjectDeletions(ctx context.Context, project string, boardIDs []int, now time.Time) (removed int, done bool, err error) {
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
		delete(s.deletionsKept, project)
		return 0, true, nil
	}
	listed, complete, err := s.client.searchIssueKeys(ctx, "project = "+project+" ORDER BY key ASC")
	if err != nil {
		return 0, false, err
	}
	if !complete {
		return 0, false, errors.New("listing incomplete")
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
	// A remembered key the listing returns again (or that is no longer
	// stored) is forgotten.
	prev := s.deletionsKept[project]
	kept := map[string]time.Time{}
	for _, k := range missing {
		if at, ok := prev[k]; ok {
			kept[k] = at
		}
	}
	s.setKept(project, kept)

	ok, reason := sourcediff.Check(len(stored), len(stored)-len(missing), len(missing), sourcediff.IssueFloors)
	if !ok {
		if reason != "" {
			s.logger.Printf("jira deletions: account %d project %s: %s, skipped", s.accountID, project, reason)
		}
		return 0, true, nil
	}

	// Keys not yet seen kept go first, in key order; remembered kept keys
	// follow, the longest-unchecked first, so they still get rechecked when
	// the cap leaves room.
	slices.SortFunc(missing, func(a, b string) int {
		ta, ka := kept[a]
		tb, kb := kept[b]
		switch {
		case ka != kb:
			if ka {
				return 1
			}
			return -1
		case ka && !ta.Equal(tb):
			return ta.Compare(tb)
		}
		return strings.Compare(a, b)
	})
	if len(missing) > maxIssueConfirms {
		s.logger.Printf("jira deletions: account %d project %s: %d missing issues, confirming %d, the rest wait for the next check",
			s.accountID, project, len(missing), maxIssueConfirms)
		missing = missing[:maxIssueConfirms]
	}
	var confirmed []string
	stillThere := 0
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
			kept[key] = now
			stillThere++
		case "":
			confirmed = append(confirmed, key)
		default:
			s.logger.Printf("jira deletions: account %d project %s: %s → %s (moved)", s.accountID, project, key, current)
			confirmed = append(confirmed, key)
		}
	}
	for _, key := range confirmed {
		delete(kept, key)
	}
	s.setKept(project, kept)
	if stillThere > 0 {
		s.logger.Printf("jira deletions: account %d project %s: %d issues missing from the listing still exist, kept",
			s.accountID, project, stillThere)
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

// setKept stores a project's remembered kept keys, dropping an empty set.
func (s *Syncer) setKept(project string, kept map[string]time.Time) {
	if len(kept) == 0 {
		delete(s.deletionsKept, project)
		return
	}
	s.deletionsKept[project] = kept
}
