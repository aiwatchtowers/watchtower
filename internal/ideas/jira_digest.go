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

// renderJiraBlock groups issues per project ("=== PROJECT <KEY> ==="
// separators) and renders one numbered line per issue plus its comments —
// "[n] <KEY> <summary> — <status> — <description excerpt> — comments:"
// followed by one indented line per comment. Returns the block and the set
// of bare issue keys a candidate's ref must copy exactly to survive
// validateRefs.
func renderJiraBlock(issues []db.JiraIssue, commentsByIssue map[string][]db.JiraComment) (string, map[string]bool) {
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
	n := 0
	for _, project := range order {
		fmt.Fprintf(&b, "=== PROJECT %s ===\n", project)
		for _, is := range byProject[project] {
			n++
			tags[is.Key] = true
			desc := capBytes(oneLine(is.DescriptionText), jiraExcerptBytes)
			fmt.Fprintf(&b, "[%d] %s %s — %s — %s — comments:\n", n, is.Key, is.Summary, is.Status, desc)
			for _, c := range commentsByIssue[is.Key] {
				fmt.Fprintf(&b, "  - %s: %s\n", c.Author, capBytes(oneLine(c.BodyText), jiraExcerptBytes))
			}
		}
	}
	return b.String(), tags
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
			p.logger.Printf("ideas: jira digest account %d: %v", acct.ID, err)
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
		now := time.Now().UTC().Format(time.RFC3339)
		if serr := p.db.SetIdeasJiraFloor(acct.ID, now); serr != nil {
			return fmt.Errorf("initializing ideas jira floor: %w", serr)
		}
		p.logger.Printf("ideas: jira account %d floor initialized at %s, no backfill", acct.ID, now)
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

	block, tags := renderJiraBlock(issues, commentsByIssue)

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
	topics := validateRefs(parsed.Topics, tags)
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
