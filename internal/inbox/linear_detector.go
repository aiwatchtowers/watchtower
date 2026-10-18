package inbox

import (
	"context"
	"errors"
	"fmt"
	"time"

	"watchtower/internal/db"
)

// Linear inbox trigger types (migration 00143).
const (
	triggerLinearAssigned       = "linear_assigned"
	triggerLinearCommentMention = "linear_comment_mention"
)

// newOwnLinearComments is the cycle's view of the owner's own Linear comments:
// the Linear twin of newOwnJiraComments, shared by detectLinear and
// autoResolveLinear. ids are every Linear user id that is the owner
// (db.OwnerLinearIDs); a failed identity read is kept in err and fails the
// detector (INBOX-09), never read as "no identity".
func newOwnLinearComments(database *db.DB, owner db.Owner) *ownJiraComments {
	o := &ownJiraComments{database: database, cached: map[string]ownComment{}, loaded: map[string]bool{}, linear: true}
	o.ids, o.err = database.OwnerLinearIDs(owner)
	return o
}

// loadLinear reads the owner's comments on keys from linear_comments.
func (o *ownJiraComments) loadLinear(keys []string) error {
	comments, err := o.database.LinearOwnComments(keys, o.ids)
	if err != nil {
		return fmt.Errorf("own linear comment query: %w", err)
	}
	for _, c := range comments {
		o.note(c.IssueKey, c.CreatedAt, c.UpdatedAt)
	}
	return nil
}

// detectLinear mints Linear inbox items from tracker_issues and
// tracker_comments with the same rules as the Jira detector (spec §6):
//   - linear_assigned: issues assigned to the owner (their Linear ids, else
//     their Slack id through assignee_slack_id) updated after sinceTS, minus
//     the owner's own comment bumps, one pending item per issue.
//   - linear_comment_mention: comments created after sinceTS whose
//     mentioned_ids name the owner.
//
// An owner with no Linear id and no Slack id is a graceful no-op. Both
// signals run even when one fails; any read or insert failure is returned and
// freezes the watermark (INBOX-09).
func detectLinear(_ context.Context, database *db.DB, owner db.Owner, own *ownJiraComments, sinceTS time.Time) (int, error) {
	if own.err != nil {
		return 0, own.err
	}
	// Linear's timestamps share db.FormatJiraTime's fixed-width UTC form, so
	// the bound compares as a string against them.
	sinceISO := db.FormatJiraTime(sinceTS)
	assigned, assignedErr := detectLinearAssigned(database, owner, own, sinceISO)
	mentions, mentionsErr := detectLinearMentions(database, own.ids, sinceISO)
	return assigned + mentions, errors.Join(assignedErr, mentionsErr)
}

func detectLinearAssigned(database *db.DB, owner db.Owner, own *ownJiraComments, sinceISO string) (int, error) {
	f := db.TrackerIssueFilter{Tracker: db.TrackerLinear, UpdatedAfter: sinceISO, NewestFirst: true}
	switch {
	case len(own.ids) > 0:
		f.AssigneeIDs = own.ids
	case owner.SlackUserID != "":
		f.AssigneeSlackID = owner.SlackUserID
	default:
		return 0, nil
	}
	issues, err := database.ListTrackerIssues(f)
	if err != nil {
		return 0, fmt.Errorf("linear detector: %w", err)
	}
	keys := make([]string, len(issues))
	for i, is := range issues {
		keys[i] = is.Key
	}
	ownComments, err := own.latestFor(keys)
	if err != nil {
		return 0, fmt.Errorf("linear detector: %w", err)
	}
	created := 0
	var errs []error
	for _, is := range issues {
		if isOwnCommentBump(is.UpdatedAt, ownComments[is.Key].touched) {
			continue
		}
		if jiraInboxExists(database, is.Key, is.UpdatedAt, triggerLinearAssigned) ||
			jiraPendingExists(database, is.Key, triggerLinearAssigned) {
			continue
		}
		if err := createJiraItem(database, trackerItem(is.Key, is.UpdatedAt, triggerLinearAssigned, is.Title)); err != nil {
			errs = append(errs, err)
			continue
		}
		created++
	}
	return created, errors.Join(errs...)
}

func detectLinearMentions(database *db.DB, ownerIDs []string, sinceISO string) (int, error) {
	comments, err := database.LinearCommentsMentioning(ownerIDs, sinceISO)
	if err != nil {
		return 0, fmt.Errorf("linear detector: %w", err)
	}
	created := 0
	var errs []error
	for _, c := range comments {
		if jiraInboxExists(database, c.IssueKey, c.CreatedAt, triggerLinearCommentMention) {
			continue
		}
		if err := createJiraItem(database, trackerItem(c.IssueKey, c.CreatedAt, triggerLinearCommentMention, c.BodyText)); err != nil {
			errs = append(errs, err)
			continue
		}
		created++
	}
	return created, errors.Join(errs...)
}

// trackerItem is a pending issue-tracker inbox item: the issue key is its
// channel and "sender" (routing/display, the Jira detector's shape).
func trackerItem(key, ts, trigger, snippet string) db.InboxItem {
	return db.InboxItem{
		ChannelID:    key,
		MessageTS:    ts,
		SenderUserID: key,
		TriggerType:  trigger,
		Snippet:      snippet,
		ItemClass:    DefaultItemClass(trigger),
		Status:       "pending",
		Priority:     "medium",
	}
}
