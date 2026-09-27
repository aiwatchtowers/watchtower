package chat

import (
	"encoding/json"
	"fmt"
	"strings"
	"unicode/utf8"
)

// SummaryMaxRunes caps a tool_end summary (spec §1.1).
const SummaryMaxRunes = 300

// MaxSources caps the source chips one tool_end carries.
const MaxSources = 10

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
	Ref, Source, Title, Link string
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
	return Source{Kind: kbKind(d.Source), Title: d.Title, URL: d.Link, Ref: d.Ref}
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

type jiraIssueView struct{ Key, Summary, Status string }

func (j jiraIssueView) source() Source {
	return Source{Kind: "jira", Title: j.Key + ": " + j.Summary, Ref: "jira:" + j.Key}
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
		TS                         string `json:"ts"`
		Channel, Sender, Permalink string
	}
	if json.Unmarshal(raw, &list) != nil {
		return "", nil
	}
	sources := make([]Source, 0, len(list))
	for _, m := range list {
		ch := strings.TrimPrefix(m.Channel, "#")
		sources = append(sources, Source{Kind: "slack", Title: "#" + ch + " · " + m.Sender, URL: m.Permalink,
			Ref: "slack:" + ch + ":" + m.TS})
	}
	return fmt.Sprintf("%d messages", len(list)), sources
}

func transcriptSource(raw []byte) (string, []Source) {
	var tr struct {
		ID    int64
		Title string
	}
	if json.Unmarshal(raw, &tr) != nil || tr.ID == 0 {
		return "", nil
	}
	return "Opened " + tr.Title, []Source{{Kind: "meeting", Title: tr.Title, Ref: fmt.Sprintf("transcript:%d", tr.ID)}}
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
