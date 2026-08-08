package ideas

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// jiraIssuesPerAccountLimit bounds how many changed issues one pre-digest
// pass reads per account per run.
const jiraIssuesPerAccountLimit = 300

// jiraExcerptBytes caps each rendered description/comment excerpt.
const jiraExcerptBytes = 500

// jiraFloorInitBackoff biases the init floor a few seconds into the past, on
// top of db.FormatJiraTime matching Jira's own format, so an issue updated
// within a couple of seconds of initialization is never lost even accounting
// for clock skew between this process and whatever wrote the issue's
// updated_at.
const jiraFloorInitBackoff = 5 * time.Second

// maxCommentsPerIssue caps a hot issue at its newest N comments so one
// thousand-comment ticket cannot dominate the prompt (the
// maxMessagesPerThread precedent). ListJiraCommentsSince returns each issue's
// comments oldest-first, so the newest are the tail.
const maxCommentsPerIssue = 20

// renderJiraBlock groups issues per project ("=== PROJECT <KEY> ==="
// separators) and renders one numbered line per issue plus its comments —
// "[n] <KEY> <summary> — <status> — <description excerpt> — comments:"
// followed by one indented line per comment. Returns the block and the set
// of bare issue keys a candidate's ref must copy exactly to survive
// validateRefs. Issues are appended whole until maxChars is spent; an issue
// that doesn't fit is left out of BOTH the block and the tag set, so a
// candidate can never validate against material the model was never shown.
func renderJiraBlock(issues []db.JiraIssue, commentsByIssue map[string][]db.JiraComment, maxChars int) (string, map[string]bool) {
	var order []string
	byProject := make(map[string][]db.JiraIssue)
	for _, is := range issues {
		if _, ok := byProject[is.ProjectKey]; !ok {
			order = append(order, is.ProjectKey)
		}
		byProject[is.ProjectKey] = append(byProject[is.ProjectKey], is)
	}

	var b strings.Builder
	tags := make(map[string]bool, len(issues))
	budget := maxChars
	n := 0
	for _, project := range order {
		header := fmt.Sprintf("=== PROJECT %s ===\n", project)
		if len(header) > budget {
			break
		}

		var unit strings.Builder
		var unitKeys []string
		for _, is := range byProject[project] {
			n++
			desc := capBytes(oneLine(is.DescriptionText), jiraExcerptBytes)
			var issueBlock strings.Builder
			fmt.Fprintf(&issueBlock, "[%d] %s %s — %s — %s — comments:\n", n, is.Key, is.Summary, is.Status, desc)
			for _, c := range newestComments(commentsByIssue[is.Key]) {
				fmt.Fprintf(&issueBlock, "  - %s: %s\n", c.Author, capBytes(oneLine(c.BodyText), jiraExcerptBytes))
			}
			if len(header)+unit.Len()+issueBlock.Len() > budget {
				n--
				break
			}
			unit.WriteString(issueBlock.String())
			unitKeys = append(unitKeys, is.Key)
		}
		if unit.Len() == 0 {
			break // not even this project's first issue fits — stop entirely
		}

		b.WriteString(header)
		b.WriteString(unit.String())
		budget -= len(header) + unit.Len()
		for _, key := range unitKeys {
			tags[key] = true
		}
	}
	return b.String(), tags
}

// newestComments returns at most maxCommentsPerIssue comments, keeping the
// newest (the tail of the oldest-first slice ListJiraCommentsSince returns).
func newestComments(comments []db.JiraComment) []db.JiraComment {
	if len(comments) <= maxCommentsPerIssue {
		return comments
	}
	return comments[len(comments)-maxCommentsPerIssue:]
}

// runJiraDigests is the ideas registry's Jira pre-digest pass: one Generate
// call per enabled Jira account, over the issues (plus their new comments)
// updated since that account's jira_accounts.ideas_jira_floor. Mirrors
// runEmailDigests' nil-generator guard and per-account log-and-continue
// error handling.
func (p *Pipeline) runJiraDigests(ctx context.Context) error {
	if p.generator == nil {
		return nil
	}
	accounts, err := p.db.ListEnabledJiraAccounts()
	if err != nil {
		return fmt.Errorf("ideas: listing jira accounts: %w", err)
	}
	var firstErr error
	for _, acct := range accounts {
		if err := p.runJiraDigestAccount(ctx, acct); err != nil {
			p.logf("ideas: jira digest account %d: %v", acct.ID, err)
			if firstErr == nil {
				firstErr = err
			}
		}
	}
	return firstErr
}

// runJiraDigestAccount runs the jira pre-digest pass for one account. An
// empty floor (never initialized) initializes to now and skips extraction —
// no backfill, the runEmailDigestAccount precedent. Zero changed issues is a
// clean no-op: no AI call, no row, floor untouched.
func (p *Pipeline) runJiraDigestAccount(ctx context.Context, acct db.JiraAccount) error {
	floor, err := p.db.IdeasJiraFloor(acct.ID)
	if err != nil {
		return fmt.Errorf("getting ideas jira floor: %w", err)
	}
	if floor == "" {
		now := db.FormatJiraTime(time.Now().UTC().Add(-jiraFloorInitBackoff))
		if serr := p.db.SetIdeasJiraFloor(acct.ID, now); serr != nil {
			return fmt.Errorf("initializing ideas jira floor: %w", serr)
		}
		p.logf("ideas: jira account %d floor initialized at %s, no backfill", acct.ID, now)
		return nil
	}

	issues, err := p.db.ListJiraIssuesUpdatedSince(acct.ID, floor, jiraIssuesPerAccountLimit)
	if err != nil {
		return fmt.Errorf("listing jira issues: %w", err)
	}
	if len(issues) == 0 {
		return nil
	}

	keys := make([]string, len(issues))
	maxUpdated := issues[0].UpdatedAt
	for i, is := range issues {
		keys[i] = is.Key
		if is.UpdatedAt > maxUpdated {
			maxUpdated = is.UpdatedAt
		}
	}

	comments, err := p.db.ListJiraCommentsSince(acct.ID, keys, floor)
	if err != nil {
		return fmt.Errorf("listing jira comments: %w", err)
	}
	commentsByIssue := make(map[string][]db.JiraComment, len(keys))
	for _, c := range comments {
		commentsByIssue[c.IssueKey] = append(commentsByIssue[c.IssueKey], c)
	}

	block, tags := renderJiraBlock(issues, commentsByIssue, p.maxPromptChars())

	tmpl, _ := p.getPrompt("ideas.digest_jira")
	system := fmt.Sprintf(tmpl, prompts.Directive(p.language()))

	reply, usage, _, err := p.generator.Generate(digest.WithSource(ctx, "ideas.digest_jira"), system, block, "")
	p.accumulateUsage(usage)
	if err != nil {
		return fmt.Errorf("generating jira digest: %w", err)
	}

	raw, err := prompts.ExtractJSONObject(reply)
	if err != nil {
		return fmt.Errorf("extracting jira digest JSON: %w", err)
	}
	var parsed streamTopics
	if err := json.Unmarshal([]byte(raw), &parsed); err != nil {
		return fmt.Errorf("parsing jira digest JSON: %w", err)
	}
	if parsed.Topics == nil {
		return fmt.Errorf("jira digest reply has no \"topics\" key")
	}
	topics := validateRefs(*parsed.Topics, tags)
	topicsJSON, err := json.Marshal(topics)
	if err != nil {
		return fmt.Errorf("marshaling jira digest topics: %w", err)
	}

	_, err = p.db.InsertStreamDigest(db.StreamDigest{
		Source:     "jira",
		AccountID:  acct.ID,
		Scope:      "",
		PeriodFrom: floor,
		PeriodTo:   maxUpdated,
		TopicsJSON: string(topicsJSON),
	})
	if err != nil {
		return fmt.Errorf("inserting stream digest: %w", err)
	}

	if err := p.db.SetIdeasJiraFloor(acct.ID, maxUpdated); err != nil {
		return fmt.Errorf("advancing ideas jira floor: %w", err)
	}
	return nil
}
