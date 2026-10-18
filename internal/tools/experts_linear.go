package tools

import (
	"fmt"

	"watchtower/internal/db"
)

// collectIssueKeyEvidence is find_experts' issue_key branch: a Jira issue
// keeps its evidence exactly as before (a key both trackers carry resolves to
// Jira); otherwise a Linear issue found by its current or a previous key
// contributes the same three kinds of evidence (spec
// 2026-10-15-linear-integration-design §6), cited by kind "linear".
func collectIssueKeyEvidence(d *db.DB, key string, acc *expertAccumulator, notes []string) []string {
	issue, err := d.GetJiraIssueByKey(key)
	if err == nil && issue == nil {
		lin, lerr := d.GetLinearIssueDossier(key)
		if lerr != nil {
			return append(notes, "issue lookup unavailable: "+lerr.Error())
		}
		if lin != nil {
			return collectLinearIssueEvidence(d, lin, acc, notes)
		}
	}
	notes = collectIssueEvidence(d, key, acc, notes)
	return collectLinkedThreadEvidence(d, key, acc, notes)
}

// collectLinearIssueEvidence scores the Linear issue's assignee and creator,
// its commenters (mapped to Slack through tracker_people), and the people in
// the Slack threads linked under any key the issue has had. Every entry cites
// the issue's current key.
func collectLinearIssueEvidence(d *db.DB, lin *db.LinearIssueDossier, acc *expertAccumulator, notes []string) []string {
	key := lin.Key
	ts, lastSeen, dated := jiraEvidenceTime(lin.UpdatedAt)
	if lin.AssigneeSlackID != "" {
		acc.add(lin.AssigneeSlackID, expertEvidence{
			Kind: "linear", Detail: "assignee of " + key, Count: 1, Ref: key, LastSeen: lastSeen, Undated: !dated,
		}, ts)
	}
	if lin.ReporterSlackID != "" {
		acc.add(lin.ReporterSlackID, expertEvidence{
			Kind: "linear", Detail: "creator of " + key, Count: 1, Ref: key, LastSeen: lastSeen, Undated: !dated,
		}, ts)
	}

	comments, err := d.ListLinearComments(lin.AccountID, lin.IssueID)
	if err != nil {
		notes = append(notes, "issue comments unavailable: "+err.Error())
	} else {
		asJira := make([]db.JiraComment, len(comments))
		for i, c := range comments {
			asJira[i] = db.JiraComment{AuthorAccountID: c.AuthorID, CreatedAt: c.CreatedAt}
		}
		for userID, a := range aggregateCommentAuthors(asJira) {
			slackID, err := d.GetTrackerPersonSlackID("linear", userID)
			if err != nil {
				notes = append(notes, fmt.Sprintf("user map unavailable for linear user %s: %v", userID, err))
				continue
			}
			if slackID == "" {
				continue // genuinely unmapped — not a failure, so no note
			}
			acc.add(slackID, expertEvidence{
				Kind: "linear", Detail: fmt.Sprintf("%d comments on %s", a.count, key), Count: a.count,
				Ref: key, LastSeen: a.lastSeen, Undated: !a.dated,
			}, a.lastTS)
		}
	}

	links, err := d.GetIssueSlackLinksByKeys("linear", lin.Keys())
	if err != nil {
		return append(notes, "linked threads unavailable: "+err.Error())
	}
	return threadEvidenceFromLinks(d, key, links, acc, notes)
}
