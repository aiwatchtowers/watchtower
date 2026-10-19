package tools

import (
	"watchtower/internal/db"
)

// linearTaskContext is get_task_context's dossier for a Linear issue (spec
// 2026-10-15-linear-integration-design §6): the issue from tracker_issues, its
// comments, the Slack threads linked under any key it has had
// (issue_slack_links, tracker 'linear'), meetings that mention its current
// key, registry decisions citing it (idea_mentions source 'linear'), and the
// people involved. There is no Confluence section: Confluence links point at
// Jira issues only. Mechanical, no AI (DEV-02).
func linearTaskContext(d *db.DB, lin *db.LinearIssueDossier) taskContext {
	out := taskContext{Issue: taskIssue{
		Key: lin.Key, Summary: lin.Title, Description: lin.Description, Status: lin.Status,
		Priority: lin.Priority, Assignee: lin.AssigneeName, Reporter: lin.ReporterName,
		SprintName: lin.IterationName, UpdatedAt: lin.UpdatedAt,
	}}
	people := newPersonSet()
	people.add(lin.AssigneeName)
	people.add(lin.ReporterName)

	out.Comments, out.Notes = collectLinearTaskComments(d, lin, people, out.Notes)
	if links, err := d.GetIssueSlackLinksByKeys("linear", lin.Keys()); err != nil {
		out.Notes = append(out.Notes, "linked slack threads unavailable: "+err.Error())
	} else {
		out.Threads, out.Notes = threadsFromLinks(d, links, people, out.Notes)
	}
	out.Meetings, out.Notes = collectLinearTaskMeetings(d, lin.Keys(), out.Notes)
	out.Decisions, out.Notes = collectTaskDecisions(d, "linear", lin.Keys(), out.Notes)
	out.People = people.list()
	return out
}

// collectLinearTaskMeetings searches the transcripts for every key the issue
// has had (a meeting before a team move names the old key), deduped by
// transcript and capped at taskContextMaxMeetings.
func collectLinearTaskMeetings(d *db.DB, keys []string, notes []string) ([]taskMeeting, []string) {
	var out []taskMeeting
	seen := map[int64]bool{}
	for _, key := range keys {
		hits, err := d.SearchTranscripts(key, taskContextMaxMeetings)
		if err != nil {
			return nil, append(notes, "meeting search unavailable: "+err.Error())
		}
		for _, h := range hits {
			if seen[h.ID] || len(out) >= taskContextMaxMeetings {
				continue
			}
			seen[h.ID] = true
			out = append(out, taskMeeting{TranscriptID: h.ID, Title: h.Title, CreatedAt: h.CreatedAt, Snippet: h.Snippet})
		}
	}
	return out, notes
}

// collectLinearTaskComments returns the issue's oldest taskContextMaxComments
// comments (the Jira section's order and cap).
func collectLinearTaskComments(d *db.DB, lin *db.LinearIssueDossier, people *personSet, notes []string) ([]taskComment, []string) {
	rows, err := d.ListLinearComments(lin.AccountID, lin.IssueID)
	if err != nil {
		return nil, append(notes, "linear comments unavailable: "+err.Error())
	}
	if len(rows) > taskContextMaxComments {
		rows = rows[:taskContextMaxComments]
	}
	var out []taskComment
	for _, c := range rows {
		people.add(c.AuthorDisplayName)
		out = append(out, taskComment{Author: c.AuthorDisplayName, Body: c.BodyText, UpdatedAt: c.UpdatedAt})
	}
	return out, notes
}
