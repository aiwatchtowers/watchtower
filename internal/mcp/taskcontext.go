package mcp

import (
	"context"
	"strings"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

// Per-section caps keep the dossier context-window-sized. A dossier that
// blows the window is worse than a partial one: the agent silently loses the
// tail, usually the recent material.
const (
	taskContextMaxComments = 30
	taskContextMaxThreads  = 8
	taskContextMaxReplies  = 25
	taskContextMaxMeetings = 5
	taskContextMaxIdeas    = 15
)

type getTaskContextArgs struct {
	Key string `json:"key" jsonschema:"Jira issue key, e.g. PROJ-123"`
}

type taskIssue struct {
	Key         string `json:"key"`
	Summary     string `json:"summary"`
	Description string `json:"description,omitempty"`
	Status      string `json:"status"`
	IssueType   string `json:"issue_type,omitempty"`
	Priority    string `json:"priority,omitempty"`
	Assignee    string `json:"assignee,omitempty"`
	Reporter    string `json:"reporter,omitempty"`
	SprintName  string `json:"sprint,omitempty"`
	UpdatedAt   string `json:"updated_at,omitempty"`
}

type taskComment struct {
	Author    string `json:"author"`
	Body      string `json:"body"`
	UpdatedAt string `json:"updated_at"`
}

type taskMessage struct {
	Sender    string `json:"sender"`
	Text      string `json:"text"`
	TS        string `json:"ts"`
	Permalink string `json:"permalink,omitempty"`
}

// taskThread is a linked Slack conversation. jira_slack_links names one
// message; the value is the discussion around it, so the tool resolves the
// message to its thread and returns the replies.
type taskThread struct {
	ChannelID   string        `json:"channel_id"`
	ChannelName string        `json:"channel,omitempty"`
	Messages    []taskMessage `json:"messages"`
}

type taskMeeting struct {
	TranscriptID int64  `json:"transcript_id"`
	Title        string `json:"title"`
	CreatedAt    string `json:"created_at"`
	Snippet      string `json:"snippet"`
}

type taskDecision struct {
	ID      int64  `json:"id"`
	Kind    string `json:"kind"`
	Title   string `json:"title"`
	Essence string `json:"essence,omitempty"`
	Status  string `json:"status"`
}

// taskContext is the dossier. Every section but the issue is omitempty: a
// section with nothing in it is absent, never an empty array, so the agent
// can tell "nothing found" from "not looked for".
type taskContext struct {
	Issue     taskIssue      `json:"issue"`
	Comments  []taskComment  `json:"comments,omitempty"`
	Threads   []taskThread   `json:"threads,omitempty"`
	Meetings  []taskMeeting  `json:"meetings,omitempty"`
	Decisions []taskDecision `json:"decisions,omitempty"`
	People    []string       `json:"people,omitempty"`
	Notes     []string       `json:"notes,omitempty"`
}

func registerTaskContext(s *mcpsdk.Server, database *db.DB) {
	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name: "get_task_context",
		Description: "Assemble everything Watchtower knows about a Jira issue: the ticket and its " +
			"comments, the Slack threads where it was discussed, meetings that mentioned it, " +
			"recorded decisions, and the people involved. Use before starting work on a ticket — " +
			"it carries the context the ticket text does not.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args getTaskContextArgs) (*mcpsdk.CallToolResult, any, error) {
		key := strings.TrimSpace(args.Key)
		if key == "" {
			return errResult("key is required, e.g. PROJ-123"), nil, nil
		}

		issue, err := database.GetJiraIssueByKey(key)
		if err != nil {
			return errResult("loading issue: " + err.Error()), nil, nil
		}
		if issue == nil {
			return errResult("no issue with key " + key), nil, nil
		}

		out := taskContext{Issue: taskIssue{
			Key:         issue.Key,
			Summary:     issue.Summary,
			Description: issue.DescriptionText,
			Status:      issue.Status,
			IssueType:   issue.IssueType,
			Priority:    issue.Priority,
			Assignee:    issue.AssigneeDisplayName,
			Reporter:    issue.ReporterDisplayName,
			SprintName:  issue.SprintName,
			UpdatedAt:   issue.UpdatedAt,
		}}
		people := newPersonSet()
		people.add(issue.AssigneeDisplayName)
		people.add(issue.ReporterDisplayName)

		out.Comments, out.Notes = collectTaskComments(database, key, people, out.Notes)
		out.Threads, out.Notes = collectTaskThreads(database, key, people, out.Notes)
		out.Meetings, out.Notes = collectTaskMeetings(database, key, out.Notes)
		out.Decisions, out.Notes = collectTaskDecisions(database, key, out.Notes)
		out.People = people.list()

		return jsonResult(out)
	})
}

func collectTaskComments(database *db.DB, key string, people *personSet, notes []string) ([]taskComment, []string) {
	rows, err := database.GetJiraCommentsByIssueKey(key, taskContextMaxComments)
	if err != nil {
		return nil, append(notes, "jira comments unavailable: "+err.Error())
	}
	out := make([]taskComment, 0, len(rows))
	for _, c := range rows {
		people.add(c.Author)
		out = append(out, taskComment{Author: c.Author, Body: c.BodyText, UpdatedAt: c.UpdatedAt})
	}
	if len(out) == 0 {
		return nil, notes
	}
	return out, notes
}

func collectTaskThreads(database *db.DB, key string, people *personSet, notes []string) ([]taskThread, []string) {
	links, err := database.GetJiraSlackLinksByIssue(key)
	if err != nil {
		return nil, append(notes, "linked slack threads unavailable: "+err.Error())
	}
	var out []taskThread
	seen := map[string]bool{}
	for _, l := range links {
		if len(out) >= taskContextMaxThreads {
			break
		}
		// link_type 'track'/'decision' rows carry no message_ts — nothing to
		// resolve to a thread, so they contribute no conversation here.
		if l.ChannelID == "" || l.MessageTS == "" {
			continue
		}
		anchors, err := database.GetMessagesByTS(l.ChannelID, []string{l.MessageTS})
		if err != nil || len(anchors) == 0 {
			continue
		}
		anchor := anchors[0]
		threadTS := anchor.TS
		if anchor.ThreadTS.Valid && anchor.ThreadTS.String != "" {
			threadTS = anchor.ThreadTS.String
		}
		dedupeKey := l.ChannelID + "|" + threadTS
		if seen[dedupeKey] {
			continue
		}
		seen[dedupeKey] = true

		msgs := []db.Message{anchor}
		replies, err := database.GetThreadReplies(l.ChannelID, threadTS)
		if err == nil {
			msgs = append(msgs, replies...)
		}
		if len(msgs) > taskContextMaxReplies {
			msgs = msgs[:taskContextMaxReplies]
		}

		thread := taskThread{ChannelID: l.ChannelID}
		if ch, err := database.GetChannelByID(l.ChannelID); err == nil && ch != nil {
			thread.ChannelName = ch.Name
		}
		for _, m := range msgs {
			name, err := database.UserNameByID(m.UserID)
			if err != nil || name == "" {
				name = m.UserID
			}
			people.add(name)
			thread.Messages = append(thread.Messages, taskMessage{
				Sender: name, Text: m.Text, TS: m.TS, Permalink: m.Permalink,
			})
		}
		out = append(out, thread)
	}
	return out, notes
}

func collectTaskMeetings(database *db.DB, key string, notes []string) ([]taskMeeting, []string) {
	hits, err := database.SearchTranscripts(key, taskContextMaxMeetings)
	if err != nil {
		return nil, append(notes, "meeting search unavailable: "+err.Error())
	}
	out := make([]taskMeeting, 0, len(hits))
	for _, h := range hits {
		out = append(out, taskMeeting{
			TranscriptID: h.ID, Title: h.Title, CreatedAt: h.CreatedAt, Snippet: h.Snippet,
		})
	}
	if len(out) == 0 {
		return nil, notes
	}
	return out, notes
}

func collectTaskDecisions(database *db.DB, key string, notes []string) ([]taskDecision, []string) {
	// idea_mentions stores a bare issue key as the ref for source='jira'
	// (see the consolidate prompt's mention shape in internal/prompts/defaults.go),
	// and (source, ref) is indexed — so this is an exact lookup, not a search.
	//
	// Bounded N+1: at most 200 ideas × their mentions. The registry is
	// owner-triaged and small; if it ever grows, replace this with a single
	// join over idea_mentions(source, ref) — the index already exists.
	ideas, err := database.ListIdeas(db.IdeaFilter{Limit: 200})
	if err != nil {
		return nil, append(notes, "registry unavailable: "+err.Error())
	}
	var out []taskDecision
	for i := range ideas {
		if len(out) >= taskContextMaxIdeas {
			break
		}
		mentions, err := database.ListIdeaMentions(ideas[i].ID)
		if err != nil {
			continue
		}
		for _, m := range mentions {
			if m.Source == "jira" && strings.EqualFold(m.Ref, key) {
				out = append(out, taskDecision{
					ID: ideas[i].ID, Kind: ideas[i].Kind, Title: ideas[i].Title,
					Essence: ideas[i].Essence, Status: ideas[i].Status,
				})
				break
			}
		}
	}
	if len(out) == 0 {
		return nil, notes
	}
	return out, notes
}

// personSet collects display names in first-seen order without duplicates.
type personSet struct {
	seen  map[string]bool
	order []string
}

func newPersonSet() *personSet { return &personSet{seen: map[string]bool{}} }

func (p *personSet) add(name string) {
	name = strings.TrimSpace(name)
	if name == "" || p.seen[name] {
		return
	}
	p.seen[name] = true
	p.order = append(p.order, name)
}

func (p *personSet) list() []string { return p.order }
