package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"sort"
	"strings"
	"time"

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

// expertRecencyHalfLifeDays decays evidence: a conversation from last week says
// more about who is in it now than one from last spring.
const expertRecencyHalfLifeDays = 45.0

const expertMessageScanLimit = 200

type findExpertsArgs struct {
	Topic    string   `json:"topic,omitempty" jsonschema:"free-text subject, e.g. 'payment retries'"`
	IssueKey string   `json:"issue_key,omitempty" jsonschema:"Jira issue key to find the people around"`
	Emails   []string `json:"emails,omitempty" jsonschema:"email addresses (e.g. git commit authors) to resolve to people"`
	Limit    int      `json:"limit,omitempty" jsonschema:"max candidates, 0 = default (10)"`
}

// expertEvidence is one countable, referenced reason a person is a candidate. It
// never asserts expertise — it states what happened, with a ref.
type expertEvidence struct {
	Kind     string `json:"kind"`
	Detail   string `json:"detail"`
	Count    int    `json:"count"`
	LastSeen string `json:"last_seen,omitempty"`
	Ref      string `json:"ref"`
	// Undated is true when this evidence genuinely has no timestamp (e.g. a
	// supplied email — there is no "when" for code authorship) and therefore
	// never decays, unlike every other entry the response's RecencyHalfLife
	// claims to apply to. Made explicit rather than silently exempted.
	Undated bool `json:"undated,omitempty"`
}

type expertCandidate struct {
	UserID string  `json:"user_id"`
	Name   string  `json:"name"`
	Email  string  `json:"email,omitempty"`
	Score  float64 `json:"score"`

	Evidence []expertEvidence `json:"evidence"`

	// Straight from the person's people card: who decides, and how to approach
	// them. Absent when the person has no card yet.
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

// NewFindExperts finds who to go to about a topic, a Jira issue, or a set of
// email addresses, returning ranked candidates with the evidence behind each.
func NewFindExperts() *Tool {
	return &Tool{
		Name: "find_experts",
		Description: "Find who to go to about a topic, a Jira issue, or a set of email addresses " +
			"(e.g. git commit authors). Returns ranked candidates with the evidence behind each " +
			"one — messages, thread participation, Jira roles — plus their decision role and " +
			"communication guide where known. Evidence, not verdicts: judge it yourself.",
		InputSchema: mustSchema[findExpertsArgs]("find_experts"),
		Access:      AccessRead,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var args findExpertsArgs
			if err := json.Unmarshal(call.Args, &args); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			if args.Topic == "" && args.IssueKey == "" && len(args.Emails) == 0 {
				return nil, &ValidationError{Msg: "provide one of: topic, issue_key, emails"}
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
				result.Notes = collectMessageEvidence(d, args.Topic, acc, result.Notes)
			}
			if args.IssueKey != "" {
				result.Notes = collectIssueEvidence(d, args.IssueKey, acc, result.Notes)
				result.Notes = collectLinkedThreadEvidence(d, args.IssueKey, acc, result.Notes)
			}
			if len(args.Emails) > 0 {
				result.UnmatchedEmails, result.Notes = collectCodeEvidence(d, args.Emails, acc, result.Notes)
			}

			result.Candidates = acc.rank(d, limit)
			return result, nil
		},
	}
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
func (a *expertAccumulator) rank(d *db.DB, limit int) []expertCandidate {
	out := make([]expertCandidate, 0, len(a.byUser))
	for id, c := range a.byUser {
		c.Score = a.scores[id]
		if u, err := d.GetUserByID(id); err == nil && u != nil {
			c.Name = u.Name
			c.Email = u.Email
		}
		if c.Name == "" {
			c.Name = id
		}
		if card, err := d.GetLatestPeopleCard(id); err == nil && card != nil {
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

// evidenceRef returns permalink when it resolves to something the caller can
// actually open, or an explicit statement that none is available — never the
// bare namespaced channelID|ts pair that used to stand in for it.
func evidenceRef(permalink string) string {
	if permalink != "" {
		return permalink
	}
	return "no permalink available for this message"
}

func collectMessageEvidence(d *db.DB, topic string, acc *expertAccumulator, notes []string) []string {
	msgs, err := d.SearchMessages(topic, db.SearchOpts{Limit: expertMessageScanLimit})
	if err != nil {
		return append(notes, "message search unavailable: "+err.Error())
	}
	type agg struct {
		count     int
		lastTSU   float64
		channel   string
		permalink string
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
			a.lastTSU, a.channel, a.permalink = m.TSUnix, m.ChannelID, m.Permalink
		}
	}
	for userID, a := range byUser {
		channelName := a.channel
		if ch, err := d.GetChannelByID(a.channel); err == nil && ch != nil {
			channelName = "#" + ch.Name
		}
		acc.add(userID, expertEvidence{
			Kind:     "messages",
			Detail:   fmt.Sprintf("%d messages matching %q, most recently in %s", a.count, topic, channelName),
			Count:    a.count,
			LastSeen: time.Unix(int64(a.lastTSU), 0).UTC().Format("2006-01-02"),
			Ref:      evidenceRef(a.permalink),
		}, a.lastTSU)
	}
	if len(msgs) == expertMessageScanLimit {
		notes = append(notes, fmt.Sprintf(
			"message evidence capped at the %d most relevant matches", expertMessageScanLimit))
	}
	return notes
}

// jiraEvidenceTime converts a Jira Cloud timestamp into the (tsUnix, lastSeen)
// pair expertAccumulator.add and expertEvidence.LastSeen need. ok is false when
// raw cannot be parsed — the caller must mark that evidence Undated rather than
// silently letting it decay-as-if-fresh (tsUnix=0) or pretending it has a date.
func jiraEvidenceTime(raw string) (tsUnix float64, lastSeen string, ok bool) {
	u, parsed := db.ParseJiraTime(raw)
	if !parsed {
		return 0, "", false
	}
	return float64(u), time.Unix(u, 0).UTC().Format("2006-01-02"), true
}

// commentAgg is one Atlassian account's comment activity on an issue.
type commentAgg struct {
	count    int
	lastTS   float64
	lastSeen string
	dated    bool
}

// aggregateCommentAuthors groups comments by Atlassian account id, tracking each
// author's count and most recent comment time (by CreatedAt).
func aggregateCommentAuthors(comments []db.JiraComment) map[string]*commentAgg {
	byAuthor := map[string]*commentAgg{}
	for _, c := range comments {
		if c.AuthorAccountID == "" {
			continue
		}
		a, ok := byAuthor[c.AuthorAccountID]
		if !ok {
			a = &commentAgg{}
			byAuthor[c.AuthorAccountID] = a
		}
		a.count++
		ts, lastSeen, dated := jiraEvidenceTime(c.CreatedAt)
		if ts > a.lastTS {
			a.lastTS, a.lastSeen, a.dated = ts, lastSeen, dated
		}
	}
	return byAuthor
}

func collectIssueEvidence(d *db.DB, key string, acc *expertAccumulator, notes []string) []string {
	issue, err := d.GetJiraIssueByKey(key)
	if err != nil {
		return append(notes, "issue lookup unavailable: "+err.Error())
	}
	if issue == nil {
		return append(notes, "no issue with key "+key)
	}
	issueTS, issueLastSeen, issueDated := jiraEvidenceTime(issue.UpdatedAt)
	if issue.AssigneeSlackID != "" {
		acc.add(issue.AssigneeSlackID, expertEvidence{
			Kind: "jira", Detail: "assignee of " + key, Count: 1, Ref: key,
			LastSeen: issueLastSeen, Undated: !issueDated,
		}, issueTS)
	}
	if issue.ReporterSlackID != "" {
		acc.add(issue.ReporterSlackID, expertEvidence{
			Kind: "jira", Detail: "reporter of " + key, Count: 1, Ref: key,
			LastSeen: issueLastSeen, Undated: !issueDated,
		}, issueTS)
	}

	comments, err := d.GetJiraCommentsByIssueKey(key, 100)
	if err != nil {
		return append(notes, "issue comments unavailable: "+err.Error())
	}
	for atlassianID, a := range aggregateCommentAuthors(comments) {
		m, err := d.GetJiraUserMapByAccountID(atlassianID)
		if err != nil {
			notes = append(notes, fmt.Sprintf("user map unavailable for jira account %s: %v", atlassianID, err))
			continue
		}
		if m == nil || m.SlackUserID == "" {
			// Genuinely no Slack mapping — not a failure, so no note.
			continue
		}
		acc.add(m.SlackUserID, expertEvidence{
			Kind:     "jira",
			Detail:   fmt.Sprintf("%d comments on %s", a.count, key),
			Count:    a.count,
			Ref:      key,
			LastSeen: a.lastSeen,
			Undated:  !a.dated,
		}, a.lastTS)
	}
	return notes
}

// threadAgg is one user's participation in a linked Slack thread.
type threadAgg struct {
	count     int
	lastTS    float64
	permalink string
}

// aggregateThreadAuthors groups a thread's messages by author.
func aggregateThreadAuthors(msgs []db.Message) map[string]*threadAgg {
	byUser := map[string]*threadAgg{}
	for _, m := range msgs {
		if m.UserID == "" {
			continue
		}
		a, ok := byUser[m.UserID]
		if !ok {
			a = &threadAgg{}
			byUser[m.UserID] = a
		}
		a.count++
		if m.TSUnix > a.lastTS {
			a.lastTS, a.permalink = m.TSUnix, m.Permalink
		}
	}
	return byUser
}

func collectLinkedThreadEvidence(d *db.DB, key string, acc *expertAccumulator, notes []string) []string {
	links, err := d.GetJiraSlackLinksByIssue(key)
	if err != nil {
		return append(notes, "linked threads unavailable: "+err.Error())
	}
	seen := map[string]bool{}
	for _, l := range links {
		if l.ChannelID == "" || l.MessageTS == "" {
			continue
		}
		anchors, err := d.GetMessagesByTS(l.ChannelID, []string{l.MessageTS})
		if err != nil {
			notes = append(notes, fmt.Sprintf("linked message unavailable for %s|%s: %v", l.ChannelID, l.MessageTS, err))
			continue
		}
		if len(anchors) == 0 {
			// The linked message was never synced (or was since deleted). Not a
			// failure, so no note.
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

		// GetThreadReplies is parent-inclusive — on success it already carries
		// the anchor exactly once; prepending it again would double-count that
		// author's evidence. Only on a read failure do we fall back to the
		// anchor alone, which is still usable evidence.
		replies, err := d.GetThreadReplies(l.ChannelID, threadTS)
		var msgs []db.Message
		if err != nil {
			notes = append(notes, fmt.Sprintf("thread replies unavailable for %s|%s: %v", l.ChannelID, threadTS, err))
			msgs = []db.Message{anchors[0]}
		} else {
			msgs = replies
		}
		for userID, a := range aggregateThreadAuthors(msgs) {
			acc.add(userID, expertEvidence{
				Kind:     "thread",
				Detail:   fmt.Sprintf("%d messages in the thread discussing %s", a.count, key),
				Count:    a.count,
				LastSeen: time.Unix(int64(a.lastTS), 0).UTC().Format("2006-01-02"),
				Ref:      evidenceRef(a.permalink),
			}, a.lastTS)
		}
	}
	return notes
}

// resolveEmailToUserID resolves one email to a Slack user id via
// GetUserByEmailFold then GetSlackUserIDByEmail. failNote is non-empty only on a
// genuine DB failure — not-found (nil,nil / sql.ErrNoRows) is an ordinary
// "nobody has this email" (DEV-03), which must not be folded into "unmatched".
func resolveEmailToUserID(d *db.DB, raw string) (userID, failNote string) {
	email := strings.ToLower(strings.TrimSpace(raw))
	u, err := d.GetUserByEmailFold(email)
	if err != nil {
		return "", fmt.Sprintf("user lookup unavailable for %s: %v", raw, err)
	}
	if u != nil {
		return u.ID, ""
	}
	id, err := d.GetSlackUserIDByEmail(email)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return "", fmt.Sprintf("slack user lookup unavailable for %s: %v", raw, err)
	}
	return id, ""
}

// collectCodeEvidence resolves email addresses (typically git commit authors) to
// people. An address that resolves to nobody is RETURNED as unmatched, never
// dropped; an address whose lookup genuinely failed is noted instead and left
// out of both.
func collectCodeEvidence(d *db.DB, emails []string, acc *expertAccumulator, notes []string) ([]string, []string) {
	var unmatched []string
	for _, raw := range emails {
		email := strings.ToLower(strings.TrimSpace(raw))
		if email == "" {
			continue
		}
		userID, failNote := resolveEmailToUserID(d, raw)
		if failNote != "" {
			notes = append(notes, failNote)
			continue
		}
		if userID == "" {
			unmatched = append(unmatched, raw)
			continue
		}
		acc.add(userID, expertEvidence{
			// A supplied email carries no "when" — genuinely undated, not merely
			// unresolved, so it is marked rather than left to decay as if today.
			Kind: "code", Detail: "authored code as " + email, Count: 1, Ref: email, Undated: true,
		}, 0)
	}
	return unmatched, notes
}
