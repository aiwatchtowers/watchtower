package mcp

import (
	"context"
	"fmt"
	"math"
	"sort"
	"strings"
	"time"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

// Ranking weights, shipped verbatim in every response (DEV-03) so the caller
// can explain the order rather than trust it.
var expertWeights = map[string]float64{
	"messages": 1.0,
	"thread":   1.5,
	"jira":     2.0,
	"code":     2.5,
}

// expertRecencyHalfLifeDays decays evidence: a conversation from last week
// says more about who is in it now than one from last spring.
const expertRecencyHalfLifeDays = 45.0

const expertMessageScanLimit = 200

type findExpertsArgs struct {
	Topic    string   `json:"topic,omitempty" jsonschema:"free-text subject, e.g. 'payment retries'"`
	IssueKey string   `json:"issue_key,omitempty" jsonschema:"Jira issue key to find the people around"`
	Emails   []string `json:"emails,omitempty" jsonschema:"email addresses (e.g. git commit authors) to resolve to people"`
	Limit    int      `json:"limit,omitempty" jsonschema:"max candidates, 0 = default (10)"`
}

// expertEvidence is one countable, referenced reason a person is a candidate.
// It never asserts expertise — it states what happened, with a ref.
type expertEvidence struct {
	Kind     string `json:"kind"`
	Detail   string `json:"detail"`
	Count    int    `json:"count"`
	LastSeen string `json:"last_seen,omitempty"`
	Ref      string `json:"ref"`
}

type expertCandidate struct {
	UserID string  `json:"user_id"`
	Name   string  `json:"name"`
	Email  string  `json:"email,omitempty"`
	Score  float64 `json:"score"`

	Evidence []expertEvidence `json:"evidence"`

	// Straight from the person's people card: who decides, and how to
	// approach them. Absent when the person has no card yet.
	DecisionRole       string `json:"decision_role,omitempty"`
	CommunicationGuide string `json:"communication_guide,omitempty"`
	CommunicationStyle string `json:"communication_style,omitempty"`
	ActiveHours        string `json:"active_hours,omitempty"`
}

type expertsResult struct {
	Candidates      []expertCandidate  `json:"candidates"`
	Weights         map[string]float64 `json:"weights"`
	RecencyHalfLife string             `json:"recency_half_life"`
	UnmatchedEmails []string           `json:"unmatched_emails,omitempty"`
	Notes           []string           `json:"notes,omitempty"`
}

func registerExperts(s *mcpsdk.Server, database *db.DB) {
	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name: "find_experts",
		Description: "Find who to go to about a topic, a Jira issue, or a set of email addresses " +
			"(e.g. git commit authors). Returns ranked candidates with the evidence behind each " +
			"one — messages, thread participation, Jira roles — plus their decision role and " +
			"communication guide where known. Evidence, not verdicts: judge it yourself.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args findExpertsArgs) (*mcpsdk.CallToolResult, any, error) {
		if args.Topic == "" && args.IssueKey == "" && len(args.Emails) == 0 {
			return errResult("provide one of: topic, issue_key, emails"), nil, nil
		}
		limit := args.Limit
		if limit <= 0 {
			limit = 10
		}

		acc := newExpertAccumulator()
		result := expertsResult{
			Weights:         expertWeights,
			RecencyHalfLife: fmt.Sprintf("%.0f days", expertRecencyHalfLifeDays),
		}

		if args.Topic != "" {
			result.Notes = collectMessageEvidence(database, args.Topic, acc, result.Notes)
		}
		if args.IssueKey != "" {
			result.Notes = collectIssueEvidence(database, args.IssueKey, acc, result.Notes)
			result.Notes = collectLinkedThreadEvidence(database, args.IssueKey, acc, result.Notes)
		}
		if len(args.Emails) > 0 {
			result.UnmatchedEmails = collectCodeEvidence(database, args.Emails, acc)
		}

		result.Candidates = acc.rank(database, limit)
		return jsonResult(result)
	})
}

// expertAccumulator groups evidence by user id and computes the weighted,
// recency-decayed score.
type expertAccumulator struct {
	byUser map[string]*expertCandidate
	scores map[string]float64
}

func newExpertAccumulator() *expertAccumulator {
	return &expertAccumulator{byUser: map[string]*expertCandidate{}, scores: map[string]float64{}}
}

// add records one evidence entry for a user. tsUnix is the evidence's time
// (0 = unknown, which scores as fully decayed-neutral: weight × 1).
func (a *expertAccumulator) add(userID string, e expertEvidence, tsUnix float64) {
	if userID == "" {
		return
	}
	c, ok := a.byUser[userID]
	if !ok {
		c = &expertCandidate{UserID: userID}
		a.byUser[userID] = c
	}
	c.Evidence = append(c.Evidence, e)

	decay := 1.0
	if tsUnix > 0 {
		ageDays := time.Since(time.Unix(int64(tsUnix), 0)).Hours() / 24
		if ageDays > 0 {
			decay = math.Pow(0.5, ageDays/expertRecencyHalfLifeDays)
		}
	}
	a.scores[userID] += expertWeights[e.Kind] * float64(max(e.Count, 1)) * decay
}

// rank resolves names and people-card enrichments, then orders by score.
func (a *expertAccumulator) rank(database *db.DB, limit int) []expertCandidate {
	out := make([]expertCandidate, 0, len(a.byUser))
	for id, c := range a.byUser {
		c.Score = a.scores[id]
		if u, err := database.GetUserByID(id); err == nil && u != nil {
			c.Name = u.Name
			c.Email = u.Email
		}
		if c.Name == "" {
			c.Name = id
		}
		if card, err := database.GetLatestPeopleCard(id); err == nil && card != nil {
			c.DecisionRole = card.DecisionRole
			c.CommunicationGuide = card.CommunicationGuide
			c.CommunicationStyle = card.CommunicationStyle
			c.ActiveHours = card.ActiveHoursJSON
		}
		out = append(out, *c)
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Score > out[j].Score })
	if len(out) > limit {
		out = out[:limit]
	}
	return out
}

func collectMessageEvidence(database *db.DB, topic string, acc *expertAccumulator, notes []string) []string {
	msgs, err := database.SearchMessages(topic, db.SearchOpts{Limit: expertMessageScanLimit})
	if err != nil {
		return append(notes, "message search unavailable: "+err.Error())
	}
	type agg struct {
		count   int
		lastTS  string
		lastTSU float64
		channel string
	}
	byUser := map[string]*agg{}
	for _, m := range msgs {
		if m.UserID == "" {
			continue
		}
		a, ok := byUser[m.UserID]
		if !ok {
			a = &agg{}
			byUser[m.UserID] = a
		}
		a.count++
		if m.TSUnix > a.lastTSU {
			a.lastTSU, a.lastTS, a.channel = m.TSUnix, m.TS, m.ChannelID
		}
	}
	for userID, a := range byUser {
		channelName := a.channel
		if ch, err := database.GetChannelByID(a.channel); err == nil && ch != nil {
			channelName = "#" + ch.Name
		}
		acc.add(userID, expertEvidence{
			Kind:     "messages",
			Detail:   fmt.Sprintf("%d messages matching %q, most recently in %s", a.count, topic, channelName),
			Count:    a.count,
			LastSeen: time.Unix(int64(a.lastTSU), 0).UTC().Format("2006-01-02"),
			Ref:      a.channel + "|" + a.lastTS,
		}, a.lastTSU)
	}
	if len(msgs) == expertMessageScanLimit {
		notes = append(notes, fmt.Sprintf(
			"message evidence capped at the %d most relevant matches", expertMessageScanLimit))
	}
	return notes
}

func collectIssueEvidence(database *db.DB, key string, acc *expertAccumulator, notes []string) []string {
	issue, err := database.GetJiraIssueByKey(key)
	if err != nil {
		return append(notes, "issue lookup unavailable: "+err.Error())
	}
	if issue == nil {
		return append(notes, "no issue with key "+key)
	}
	if issue.AssigneeSlackID != "" {
		acc.add(issue.AssigneeSlackID, expertEvidence{
			Kind: "jira", Detail: "assignee of " + key, Count: 1, Ref: key,
		}, 0)
	}
	if issue.ReporterSlackID != "" {
		acc.add(issue.ReporterSlackID, expertEvidence{
			Kind: "jira", Detail: "reporter of " + key, Count: 1, Ref: key,
		}, 0)
	}

	comments, err := database.GetJiraCommentsByIssueKey(key, 100)
	if err != nil {
		return append(notes, "issue comments unavailable: "+err.Error())
	}
	byAuthor := map[string]int{}
	for _, c := range comments {
		if c.AuthorAccountID == "" {
			continue
		}
		byAuthor[c.AuthorAccountID]++
	}
	for atlassianID, n := range byAuthor {
		m, err := database.GetJiraUserMapByAccountID(atlassianID)
		if err != nil || m == nil || m.SlackUserID == "" {
			continue
		}
		acc.add(m.SlackUserID, expertEvidence{
			Kind:   "jira",
			Detail: fmt.Sprintf("%d comments on %s", n, key),
			Count:  n,
			Ref:    key,
		}, 0)
	}
	return notes
}

func collectLinkedThreadEvidence(database *db.DB, key string, acc *expertAccumulator, notes []string) []string {
	links, err := database.GetJiraSlackLinksByIssue(key)
	if err != nil {
		return append(notes, "linked threads unavailable: "+err.Error())
	}
	seen := map[string]bool{}
	for _, l := range links {
		if l.ChannelID == "" || l.MessageTS == "" {
			continue
		}
		anchors, err := database.GetMessagesByTS(l.ChannelID, []string{l.MessageTS})
		if err != nil || len(anchors) == 0 {
			continue
		}
		threadTS := anchors[0].TS
		if anchors[0].ThreadTS.Valid && anchors[0].ThreadTS.String != "" {
			threadTS = anchors[0].ThreadTS.String
		}
		if seen[l.ChannelID+"|"+threadTS] {
			continue
		}
		seen[l.ChannelID+"|"+threadTS] = true

		msgs := append([]db.Message{anchors[0]}, mustReplies(database, l.ChannelID, threadTS)...)
		byUser := map[string]int{}
		latest := map[string]float64{}
		for _, m := range msgs {
			if m.UserID == "" {
				continue
			}
			byUser[m.UserID]++
			if m.TSUnix > latest[m.UserID] {
				latest[m.UserID] = m.TSUnix
			}
		}
		for userID, n := range byUser {
			acc.add(userID, expertEvidence{
				Kind:     "thread",
				Detail:   fmt.Sprintf("%d messages in the thread discussing %s", n, key),
				Count:    n,
				LastSeen: time.Unix(int64(latest[userID]), 0).UTC().Format("2006-01-02"),
				Ref:      l.ChannelID + "|" + threadTS,
			}, latest[userID])
		}
	}
	return notes
}

// mustReplies returns thread replies, treating a read failure as "no replies"
// — the anchor message alone is still usable evidence.
func mustReplies(database *db.DB, channelID, threadTS string) []db.Message {
	replies, err := database.GetThreadReplies(channelID, threadTS)
	if err != nil {
		return nil
	}
	return replies
}

// collectCodeEvidence resolves email addresses (typically git commit authors)
// to people. Matching is case-folded because git authorship carries mixed
// case; an address that resolves to nobody is RETURNED as unmatched, never
// dropped, so the caller can see the code signal was incomplete.
func collectCodeEvidence(database *db.DB, emails []string, acc *expertAccumulator) []string {
	var unmatched []string
	for _, raw := range emails {
		email := strings.ToLower(strings.TrimSpace(raw))
		if email == "" {
			continue
		}
		userID := ""
		if u, err := database.GetUserByEmailFold(email); err == nil && u != nil {
			userID = u.ID
		}
		if userID == "" {
			if id, err := database.GetSlackUserIDByEmail(email); err == nil && id != "" {
				userID = id
			}
		}
		if userID == "" {
			unmatched = append(unmatched, raw)
			continue
		}
		acc.add(userID, expertEvidence{
			Kind: "code", Detail: "authored code as " + email, Count: 1, Ref: email,
		}, 0)
	}
	return unmatched
}
