package chat

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// SummaryMaxRunes caps a tool_end summary (spec §1.1).
const SummaryMaxRunes = 300

// MaxSources caps the source chips one tool_end carries.
const MaxSources = 10

// SnippetMaxRunes caps a source's snippet (the panel shows two lines).
const SnippetMaxRunes = 160

// Groups a source is filed under when its source has no finer grouping
// (a mailbox or a meeting); an empty group is the Desktop's "Other".
const (
	mailGroup    = "Mail"
	meetingGroup = "Meetings"
)

// SummarizeToolResult turns a read tool's raw result into a one-line summary
// and the sources it cites (spec §3.4). name is the display name (no
// mcp__watchtower__ prefix). Known read tools get a structured summary and
// chips; an unknown tool, or a result that does not parse, falls back to the
// collapsed text and no chips. The summary is at most SummaryMaxRunes runes and
// there are at most MaxSources chips, deduplicated by URL (or ref).
func SummarizeToolResult(name, result string) (string, []Source) {
	extract, ok := sourceExtractors[name]
	var summary string
	var sources []Source
	if ok {
		summary, sources = extract([]byte(result))
	}
	if summary == "" {
		summary = collapseSpace(result)
	}
	return truncateRunes(summary, SummaryMaxRunes), capSources(sources)
}

// sourceExtractors maps a read tool to its parser. Each parser returns ("",
// nil) when the result does not match its shape. Struct fields without json
// tags match the tools' untagged db structs (encoding/json matches field
// names case-insensitively).
var sourceExtractors = map[string]func([]byte) (string, []Source){
	"search_knowledge":       knowledgeHitSources,
	"get_knowledge_document": knowledgeDocSource,
	"get_jira_issue":         jiraIssueSource,
	"list_jira_issues":       jiraIssueListSources,
	"list_messages":          slackMessageSources,
	"get_transcript":         transcriptSource,
	"get_person":             personSource,
	"get_digest":             digestSource,
	"get_target":             targetSource,
}

type kbDoc struct {
	Ref, Source, Title, Link, When string
	Snippets                       []string
	Anchor                         map[string]string
}

// kbKind maps a knowledge-index source onto a chip kind.
func kbKind(source string) string {
	switch source {
	case "slack":
		return "slack"
	case "gmail", "imap":
		return "email"
	case "jira":
		return "jira"
	case "calendar", "transcript", "recap":
		return "meeting"
	default:
		return "document"
	}
}

func (d kbDoc) source() Source {
	kind := kbKind(d.Source)
	s := Source{Kind: kind, Title: d.Title, URL: d.Link, Ref: d.Ref, Group: d.group(kind), Date: isoDay(d.When)}
	if len(d.Snippets) > 0 {
		s.Snippet = snippet(d.Snippets[0])
	}
	return s
}

// group files a knowledge document: a Slack document under its channel (the
// title's "#channel — …"/"#channel · day" prefix), a Jira one under its
// project, a Confluence page under its space, mail and meetings together.
func (d kbDoc) group(kind string) string {
	switch kind {
	case "slack":
		return slackTitleGroup(d.Title)
	case "jira":
		key := d.Anchor["key"]
		if key == "" {
			key = d.Ref[strings.LastIndex(d.Ref, ":")+1:]
		}
		return jiraProject(key)
	case "email":
		return mailGroup
	case "meeting":
		return meetingGroup
	}
	return d.Anchor["space"]
}

func knowledgeHitSources(raw []byte) (string, []Source) {
	var r struct{ Hits []kbDoc }
	if json.Unmarshal(raw, &r) != nil {
		return "", nil
	}
	sources := make([]Source, 0, len(r.Hits))
	titles := make([]string, 0, 3)
	for _, h := range r.Hits {
		sources = append(sources, h.source())
		if len(titles) < 3 && h.Title != "" {
			titles = append(titles, h.Title)
		}
	}
	summary := fmt.Sprintf("%d results", len(r.Hits))
	if len(titles) > 0 {
		summary += ": " + strings.Join(titles, "; ")
	}
	return summary, sources
}

func knowledgeDocSource(raw []byte) (string, []Source) {
	var d kbDoc
	if json.Unmarshal(raw, &d) != nil || d.Ref == "" {
		return "", nil
	}
	return "Opened " + d.Title, []Source{d.source()}
}

type jiraIssueView struct {
	Key, ProjectKey, Summary, Status, AssigneeDisplayName, UpdatedAt string
}

func (j jiraIssueView) source() Source {
	group := j.ProjectKey
	if group == "" {
		group = jiraProject(j.Key)
	}
	detail := j.Status
	if j.AssigneeDisplayName != "" {
		detail = strings.TrimPrefix(detail+" · "+j.AssigneeDisplayName, " · ")
	}
	return Source{Kind: "jira", Title: j.Key + ": " + j.Summary, Ref: "jira:" + j.Key,
		Group: group, Snippet: snippet(detail), Date: isoDay(j.UpdatedAt)}
}

func jiraIssueSource(raw []byte) (string, []Source) {
	var j jiraIssueView
	if json.Unmarshal(raw, &j) != nil || j.Key == "" {
		return "", nil
	}
	summary := "Opened " + j.Key + ": " + j.Summary
	if j.Status != "" {
		summary += " (" + j.Status + ")"
	}
	return summary, []Source{j.source()}
}

func jiraIssueListSources(raw []byte) (string, []Source) {
	var list []jiraIssueView
	if json.Unmarshal(raw, &list) != nil {
		return "", nil
	}
	keys := make([]string, 0, len(list))
	sources := make([]Source, 0, len(list))
	for _, j := range list {
		keys = append(keys, j.Key)
		sources = append(sources, j.source())
	}
	return fmt.Sprintf("%d issues: %s", len(list), strings.Join(keys, ", ")), sources
}

func slackMessageSources(raw []byte) (string, []Source) {
	var list []struct {
		TS                               string `json:"ts"`
		Channel, Sender, Text, Permalink string
	}
	if json.Unmarshal(raw, &list) != nil {
		return "", nil
	}
	sources := make([]Source, 0, len(list))
	for _, m := range list {
		ch := strings.TrimPrefix(m.Channel, "#")
		sources = append(sources, Source{Kind: "slack", Title: "#" + ch + " · " + m.Sender, URL: m.Permalink,
			Ref: "slack:" + ch + ":" + m.TS, Group: "#" + ch, Snippet: snippet(m.Text), Date: slackDay(m.TS)})
	}
	return fmt.Sprintf("%d messages", len(list)), sources
}

func transcriptSource(raw []byte) (string, []Source) {
	var tr struct {
		ID             int64
		Title, Summary string
		CreatedAt      string `json:"created_at"`
	}
	if json.Unmarshal(raw, &tr) != nil || tr.ID == 0 {
		return "", nil
	}
	return "Opened " + tr.Title, []Source{{Kind: "meeting", Title: tr.Title, Ref: fmt.Sprintf("transcript:%d", tr.ID),
		Group: meetingGroup, Snippet: snippet(tr.Summary), Date: isoDay(tr.CreatedAt)}}
}

func personSource(raw []byte) (string, []Source) {
	var p struct{ UserID string }
	if json.Unmarshal(raw, &p) != nil || p.UserID == "" {
		return "", nil
	}
	return "Opened person " + p.UserID, []Source{{Kind: "person", Title: p.UserID, Ref: "person:" + p.UserID}}
}

func digestSource(raw []byte) (string, []Source) {
	var d struct {
		ID   int64
		Type string
	}
	if json.Unmarshal(raw, &d) != nil || d.ID == 0 {
		return "", nil
	}
	title := fmt.Sprintf("%s digest #%d", d.Type, d.ID)
	return "Opened " + title, []Source{{Kind: "document", Title: title, Ref: fmt.Sprintf("digest:%d", d.ID)}}
}

func targetSource(raw []byte) (string, []Source) {
	var tg struct {
		ID   int64
		Text string
	}
	if json.Unmarshal(raw, &tg) != nil || tg.ID == 0 {
		return "", nil
	}
	return "Opened target: " + tg.Text, []Source{{Kind: "document", Title: tg.Text, Ref: fmt.Sprintf("target:%d", tg.ID)}}
}

// capSources drops duplicates (same URL, or same ref when there is no URL)
// and keeps at most MaxSources, in order. Returns nil for none.
func capSources(in []Source) []Source {
	var out []Source
	seen := map[string]bool{}
	for _, s := range in {
		key := s.URL
		if key == "" {
			key = "ref:" + s.Ref
		}
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, s)
		if len(out) == MaxSources {
			break
		}
	}
	return out
}

// slackTitleGroup is the channel part of a Slack knowledge title
// ("#channel — headline", "#channel · 2026-05-13", "DM with Ann — …").
func slackTitleGroup(title string) string {
	for _, sep := range []string{" — ", " · "} {
		if head, _, ok := strings.Cut(title, sep); ok {
			return head
		}
	}
	return ""
}

// jiraProject is an issue key's project ("PAY" of "PAY-7"), "" otherwise.
func jiraProject(key string) string {
	project, number, ok := strings.Cut(key, "-")
	if !ok || project == "" || number == "" {
		return ""
	}
	return project
}

// isoDay is the YYYY-MM-DD prefix of an ISO date/time, "" when s is not one.
func isoDay(s string) string {
	if len(s) < 10 {
		return ""
	}
	if _, err := time.Parse("2006-01-02", s[:10]); err != nil {
		return ""
	}
	return s[:10]
}

// slackDay is the UTC day of a Slack ts ("1715600000.000100"), "" if unparsable.
func slackDay(ts string) string {
	secs, _, _ := strings.Cut(ts, ".")
	n, err := strconv.ParseInt(secs, 10, 64)
	if err != nil || n <= 0 {
		return ""
	}
	return time.Unix(n, 0).UTC().Format("2006-01-02")
}

// snippet collapses whitespace and caps s at SnippetMaxRunes.
func snippet(s string) string { return truncateRunes(collapseSpace(s), SnippetMaxRunes) }

// collapseSpace folds every run of whitespace into one space and trims.
func collapseSpace(s string) string { return strings.Join(strings.Fields(s), " ") }

// truncateRunes cuts s to at most n runes, ending with "…" when cut.
func truncateRunes(s string, n int) string {
	if n <= 0 {
		return ""
	}
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	r := []rune(s)
	return string(r[:n-1]) + "…"
}
