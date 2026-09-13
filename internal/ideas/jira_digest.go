package ideas

import (
	"context"
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
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
//
// The OLDEST issue (issues[0], which is also the first project's first) is
// always rendered, even when it alone exceeds maxChars — the renderEmailBlock
// rule: a pass that rendered nothing could advance no floor (IDEA-01) and
// would re-read the same un-renderable issue forever, mining nothing. A
// bounded single-issue overshoot is the lesser evil, and the caller logs it —
// a returned block longer than maxChars is exactly that signal.
func renderJiraBlock(issues []db.JiraIssue, commentsByIssue map[string][]db.JiraComment, maxChars int) (string, map[string]bool) {
	order, byProject := groupIssuesByProject(issues)

	var b strings.Builder
	tags := make(map[string]bool, len(issues))
	budget := maxChars
	n := 0
	for _, project := range order {
		header := fmt.Sprintf("=== PROJECT %s ===\n", project)
		if len(header) > budget && len(tags) > 0 {
			break
		}

		var unit strings.Builder
		var unitKeys []string
		for _, is := range byProject[project] {
			n++
			issueBlock := renderJiraIssue(n, is, commentsByIssue[is.Key])
			rendered := len(tags) > 0 || len(unitKeys) > 0
			if len(header)+unit.Len()+len(issueBlock) > budget && rendered {
				n-- // the very first issue renders regardless; see the doc comment
				break
			}
			unit.WriteString(issueBlock)
			unitKeys = append(unitKeys, is.Key)
		}
		if unit.Len() == 0 {
			// A later project whose first issue does not fit — the first
			// project always renders at least one, so this can only be a
			// project with budget already spent. Stop entirely.
			break
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

// groupIssuesByProject buckets issues by project key, returning the projects
// in first-seen order (which, since issues arrive oldest-first, is order of
// oldest issue) alongside the buckets.
func groupIssuesByProject(issues []db.JiraIssue) ([]string, map[string][]db.JiraIssue) {
	var order []string
	byProject := make(map[string][]db.JiraIssue)
	for _, is := range issues {
		if _, ok := byProject[is.ProjectKey]; !ok {
			order = append(order, is.ProjectKey)
		}
		byProject[is.ProjectKey] = append(byProject[is.ProjectKey], is)
	}
	return order, byProject
}

// renderJiraIssue renders one issue as the numbered line plus one indented
// line per surviving comment — renderJiraBlock's indivisible unit.
func renderJiraIssue(n int, is db.JiraIssue, comments []db.JiraComment) string {
	var b strings.Builder
	fmt.Fprintf(&b, "[%d] %s %s — %s — %s — comments:\n", n, is.Key, is.Summary, is.Status,
		capBytes(oneLine(is.DescriptionText), jiraExcerptBytes))
	for _, c := range newestComments(comments) {
		fmt.Fprintf(&b, "  - %s: %s\n", c.Author, capBytes(oneLine(c.BodyText), jiraExcerptBytes))
	}
	return b.String()
}

// renderedJiraFloor returns the furthest updated_at one Jira pass may claim —
// the value its floor advances to and its stream_digests row ends at.
// renderedTags is renderJiraBlock's key set, i.e. exactly the issues put in
// front of the model (and so exactly what a candidate may cite, IDEA-02).
//
// issues arrives ordered by updated_at ascending, so the scan stops at the
// first issue the prompt budget dropped: everything below that point was
// rendered, everything from it on must stay unclaimed. A plain max over
// rendered issues would not do — renderJiraBlock groups by project rather than
// by time, so a dropped issue in a later project can carry an updated_at lower
// than a rendered one's, and the floor would bury it (IDEA-01).
//
// An empty return means not even the oldest issue was rendered: nothing was
// mined, so the floor must not move at all.
func renderedJiraFloor(issues []db.JiraIssue, renderedTags map[string]bool) string {
	last := ""
	for _, is := range issues {
		if !renderedTags[is.Key] {
			break
		}
		last = is.UpdatedAt
	}
	return last
}

// newestComments returns at most maxCommentsPerIssue comments, keeping the
// newest (the tail of the oldest-first slice ListJiraCommentsSince returns).
func newestComments(comments []db.JiraComment) []db.JiraComment {
	if len(comments) <= maxCommentsPerIssue {
		return comments
	}
	return comments[len(comments)-maxCommentsPerIssue:]
}

// normalizeJiraStreamPeriod converts a Jira-format timestamp (raw
// updated_at, which can carry any offset the API returned, e.g. "+0300") to
// RFC3339 UTC for storage in stream_digests.period_from/period_to — the
// email pre-digest pass already writes RFC3339 UTC there, and
// ListStreamDigestsAfter/HasStreamDigestCovering compare both sources'
// periods with plain string ordering, which is only offset-safe when every
// row shares one format (GB4). An unparseable input (should not happen for a
// value this pipeline itself produced) is stored verbatim rather than
// blocking the whole pass — the worst case is one wrong coverage/window skip
// for that single row, not a dropped digest. Pre-existing rows written before
// this normalization may still carry a raw Jira offset; see
// docs/inventory/ideas.md.
func normalizeJiraStreamPeriod(raw string) string {
	unix, ok := db.ParseJiraTime(raw)
	if !ok {
		return raw
	}
	return time.Unix(unix, 0).UTC().Format(time.RFC3339)
}

// runJiraDigests is the ideas registry's Jira pre-digest pass: one Generate
// call per enabled Jira account, over the issues (plus their new comments)
// updated since that account's jira_accounts.ideas_jira_floor. Mirrors
// runEmailDigests' nil-generator guard and per-account log-and-continue
// error handling. bound is an optional upper bound on the issue window (the
// zero value is unbounded — Run's ordinary daemon/incremental path passes
// time.Time{}); a non-zero bound is how a backfill run scopes one pass to a
// slice of history.
func (p *Pipeline) runJiraDigests(ctx context.Context, bound time.Time) error {
	if p.generator == nil {
		return nil
	}
	accounts, err := p.db.ListEnabledJiraAccounts()
	if err != nil {
		return fmt.Errorf("ideas: listing jira accounts: %w", err)
	}
	var firstErr error
	for _, acct := range accounts {
		if err := p.runJiraDigestAccount(ctx, acct, bound); err != nil {
			p.logf("ideas: jira digest account %d: %v", acct.ID, err)
			if firstErr == nil {
				firstErr = err
			}
		}
	}
	return firstErr
}

// initJiraFloor stamps a never-initialized account's ideas floor at now
// (minus jiraFloorInitBackoff) and mines nothing — no backfill, the
// initEmailFloor precedent.
func (p *Pipeline) initJiraFloor(acct db.JiraAccount) error {
	now := db.FormatJiraTime(time.Now().UTC().Add(-jiraFloorInitBackoff))
	if err := p.db.SetIdeasJiraFloor(acct.ID, now); err != nil {
		return fmt.Errorf("initializing ideas jira floor: %w", err)
	}
	p.logf("ideas: jira account %d floor initialized at %s, no backfill", acct.ID, now)
	return nil
}

// gatherJiraComments loads the comments added to issues since floor, grouped
// by issue key for renderJiraBlock.
func (p *Pipeline) gatherJiraComments(accountID int64, issues []db.JiraIssue, floor string) (map[string][]db.JiraComment, error) {
	keys := make([]string, len(issues))
	for i, is := range issues {
		keys[i] = is.Key
	}
	comments, err := p.db.ListJiraCommentsSince(accountID, keys, floor)
	if err != nil {
		return nil, fmt.Errorf("listing jira comments: %w", err)
	}
	byIssue := make(map[string][]db.JiraComment, len(keys))
	for _, c := range comments {
		byIssue[c.IssueKey] = append(byIssue[c.IssueKey], c)
	}
	return byIssue, nil
}

// runJiraDigestAccount runs the jira pre-digest pass for one account. An
// empty floor (never initialized) initializes to now and skips extraction —
// no backfill, the runEmailDigestAccount precedent. Zero changed issues is a
// clean no-op: no AI call, no row, floor untouched. A floor may only advance
// over issues the model actually saw (IDEA-01), which is why an issue too big
// for the whole prompt budget is rendered anyway rather than leaving the pass
// with nothing to claim and no way forward.
func (p *Pipeline) runJiraDigestAccount(ctx context.Context, acct db.JiraAccount, bound time.Time) error {
	floor, err := p.db.IdeasJiraFloor(acct.ID)
	if err != nil {
		return fmt.Errorf("getting ideas jira floor: %w", err)
	}
	if floor == "" {
		return p.initJiraFloor(acct)
	}

	var beforeISO string
	if !bound.IsZero() {
		beforeISO = db.FormatJiraTime(bound)
	}
	issues, err := p.db.ListJiraIssuesUpdatedSince(acct.ID, floor, beforeISO, jiraIssuesPerAccountLimit)
	if err != nil {
		return fmt.Errorf("listing jira issues: %w", err)
	}
	if len(issues) == 0 {
		return nil
	}

	commentsByIssue, err := p.gatherJiraComments(acct.ID, issues, floor)
	if err != nil {
		return err
	}

	budget := p.maxPromptChars()
	block, tags := renderJiraBlock(issues, commentsByIssue, budget)
	if len(block) > budget {
		p.logf("ideas: jira account %d: issue %s alone renders %d chars, over the %d-char ideas.max_prompt_chars cap — rendered anyway so this window is mined instead of stalling",
			acct.ID, issues[0].Key, len(block), budget)
	}
	renderedTo := renderedJiraFloor(issues, tags)
	if renderedTo == "" {
		// Unreachable: renderJiraBlock always renders its oldest issue, so a
		// non-empty issues always yields a floor. Fail loudly rather than
		// claim an empty floor if that contract is ever broken.
		return fmt.Errorf("no issue rendered from %d jira issues", len(issues))
	}

	topics, err := p.mineStreamTopics(ctx, "ideas.digest_jira", block, tags)
	if err != nil {
		return err
	}

	if err := p.insertStreamTopics(db.StreamDigest{
		Source:     "jira",
		AccountID:  acct.ID,
		Scope:      "",
		PeriodFrom: normalizeJiraStreamPeriod(floor),
		PeriodTo:   normalizeJiraStreamPeriod(renderedTo),
	}, topics, fmt.Sprintf("jira account %d", acct.ID)); err != nil {
		return err
	}

	// renderedTo is the newest RENDERED issue's updated_at, never the newest
	// loaded one: an issue the budget dropped stays above the floor and is
	// mined next run. ListJiraIssuesUpdatedSince reloads with a strict >, so
	// the boundary issue itself is not re-read; IDEA-05 covers the rest.
	if err := p.db.SetIdeasJiraFloor(acct.ID, renderedTo); err != nil {
		return fmt.Errorf("advancing ideas jira floor: %w", err)
	}
	return nil
}
