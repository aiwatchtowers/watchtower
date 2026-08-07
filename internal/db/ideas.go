package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

// Idea is one row in the ideas registry — a durable, dedupable idea,
// decision, or note mined from Slack digests, meeting transcripts, Gmail,
// or Jira, plus owner-authored ones from chat. Distinct from a Target: an
// idea only becomes a target when the owner converts it.
type Idea struct {
	ID                int64
	Kind              string
	Title             string
	Essence           string
	Status            string
	Source            string
	SnoozeUntil       string
	NeedsReview       bool
	ReviewReason      string
	SimilarToID       sql.NullInt64
	MergedIntoID      sql.NullInt64
	SupersededByID    sql.NullInt64
	ConvertedTargetID sql.NullInt64
	OwnerRating       int
	RatingComment     string
	LastMentionAt     string
	CreatedAt         string
	UpdatedAt         string
}

// IdeaMention is a single sighting of an idea across sources — an idea
// accumulates one row per mention instead of being overwritten.
type IdeaMention struct {
	ID        int64
	IdeaID    int64
	Source    string
	Ref       string
	Quote     string
	Author    string
	SaidAt    string
	CreatedAt string
}

// IdeaFilter narrows ListIdeas. Zero values are unfiltered; Limit defaults
// to 200 when zero.
type IdeaFilter struct {
	Kind   string
	Status string
	Query  string
	Limit  int
}

const ideaSelectCols = `id, kind, title, essence, status, source, snooze_until,
	needs_review, review_reason, similar_to_id, merged_into_id, superseded_by_id,
	converted_target_id, owner_rating, rating_comment, last_mention_at, created_at, updated_at`

func scanIdea(row interface{ Scan(...any) error }) (*Idea, error) {
	var idea Idea
	var needsReview int
	if err := row.Scan(
		&idea.ID, &idea.Kind, &idea.Title, &idea.Essence, &idea.Status, &idea.Source, &idea.SnoozeUntil,
		&needsReview, &idea.ReviewReason, &idea.SimilarToID, &idea.MergedIntoID, &idea.SupersededByID,
		&idea.ConvertedTargetID, &idea.OwnerRating, &idea.RatingComment, &idea.LastMentionAt, &idea.CreatedAt, &idea.UpdatedAt,
	); err != nil {
		return nil, err
	}
	idea.NeedsReview = needsReview != 0
	return &idea, nil
}

// CreateIdeaTx inserts a new idea and returns its ID.
func (db *DB) CreateIdeaTx(tx *sql.Tx, idea Idea) (int64, error) {
	if idea.Status == "" {
		idea.Status = "proposed"
	}
	if idea.Source == "" {
		idea.Source = "mined"
	}
	now := "strftime('%Y-%m-%dT%H:%M:%SZ', 'now')"
	res, err := tx.Exec(`INSERT INTO ideas (kind, title, essence, status, source, snooze_until,
			needs_review, review_reason, similar_to_id, merged_into_id, superseded_by_id,
			converted_target_id, owner_rating, rating_comment, last_mention_at, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, `+now+`, `+now+`)`,
		idea.Kind, idea.Title, idea.Essence, idea.Status, idea.Source, idea.SnoozeUntil,
		boolToInt(idea.NeedsReview), idea.ReviewReason, idea.SimilarToID, idea.MergedIntoID, idea.SupersededByID,
		idea.ConvertedTargetID, idea.OwnerRating, idea.RatingComment, idea.LastMentionAt,
	)
	if err != nil {
		return 0, fmt.Errorf("creating idea: %w", err)
	}
	return res.LastInsertId()
}

// InsertIdeaMentionTx records a mention and bumps the parent idea's
// last_mention_at/updated_at to the mention's said_at.
func (db *DB) InsertIdeaMentionTx(tx *sql.Tx, m IdeaMention) error {
	_, err := tx.Exec(`INSERT INTO idea_mentions (idea_id, source, ref, quote, author, said_at)
		VALUES (?, ?, ?, ?, ?, ?)`,
		m.IdeaID, m.Source, m.Ref, m.Quote, m.Author, m.SaidAt)
	if err != nil {
		return fmt.Errorf("inserting idea mention: %w", err)
	}
	_, err = tx.Exec(`UPDATE ideas SET last_mention_at = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = ?`,
		m.SaidAt, m.IdeaID)
	if err != nil {
		return fmt.Errorf("bumping idea last_mention_at: %w", err)
	}
	return nil
}

// SetIdeaNeedsReviewTx flags an idea for owner review with a reason.
func (db *DB) SetIdeaNeedsReviewTx(tx *sql.Tx, id int64, reason string) error {
	_, err := tx.Exec(`UPDATE ideas SET needs_review = 1, review_reason = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = ?`,
		reason, id)
	if err != nil {
		return fmt.Errorf("setting idea needs_review: %w", err)
	}
	return nil
}

// ListIdeas returns ideas matching the filter, newest-updated first.
func (db *DB) ListIdeas(f IdeaFilter) ([]Idea, error) {
	limit := f.Limit
	if limit <= 0 {
		limit = 200
	}

	var where []string
	var args []any
	if f.Kind != "" {
		where = append(where, "kind = ?")
		args = append(args, f.Kind)
	}
	if f.Status != "" {
		where = append(where, "status = ?")
		args = append(args, f.Status)
	}
	if f.Query != "" {
		like := "%" + f.Query + "%"
		where = append(where, `(title LIKE ? OR essence LIKE ? OR EXISTS (
			SELECT 1 FROM idea_mentions m WHERE m.idea_id = ideas.id AND m.quote LIKE ?))`)
		args = append(args, like, like, like)
	}

	query := `SELECT ` + ideaSelectCols + ` FROM ideas`
	if len(where) > 0 {
		query += ` WHERE ` + strings.Join(where, " AND ")
	}
	query += ` ORDER BY updated_at DESC LIMIT ?`
	args = append(args, limit)

	rows, err := db.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("listing ideas: %w", err)
	}
	defer rows.Close()

	var out []Idea
	for rows.Next() {
		idea, err := scanIdea(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning idea: %w", err)
		}
		out = append(out, *idea)
	}
	return out, rows.Err()
}

// GetIdea returns a single idea by ID, or (nil, nil) if no row exists.
func (db *DB) GetIdea(id int64) (*Idea, error) {
	row := db.QueryRow(`SELECT `+ideaSelectCols+` FROM ideas WHERE id = ?`, id)
	idea, err := scanIdea(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("getting idea %d: %w", id, err)
	}
	return idea, nil
}

// ListIdeaMentions returns every mention of an idea, oldest first.
func (db *DB) ListIdeaMentions(ideaID int64) ([]IdeaMention, error) {
	rows, err := db.Query(`SELECT id, idea_id, source, ref, quote, author, said_at, created_at
		FROM idea_mentions WHERE idea_id = ? ORDER BY said_at, id`, ideaID)
	if err != nil {
		return nil, fmt.Errorf("listing idea mentions: %w", err)
	}
	defer rows.Close()

	var out []IdeaMention
	for rows.Next() {
		var m IdeaMention
		if err := rows.Scan(&m.ID, &m.IdeaID, &m.Source, &m.Ref, &m.Quote, &m.Author, &m.SaidAt, &m.CreatedAt); err != nil {
			return nil, fmt.Errorf("scanning idea mention: %w", err)
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// ListIdeasForPrompt returns the ideas fed into the consolidator prompt for
// dedup/merge context: everything still open (proposed/active/not_now)
// regardless of age, plus anything touched in the last 60 days so a recent
// verdict stays visible for a little while after it lands.
func (db *DB) ListIdeasForPrompt() ([]Idea, error) {
	rows, err := db.Query(`SELECT ` + ideaSelectCols + ` FROM ideas
		WHERE status IN ('proposed','active','not_now')
		   OR updated_at >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-60 days')
		ORDER BY updated_at DESC`)
	if err != nil {
		return nil, fmt.Errorf("listing ideas for prompt: %w", err)
	}
	defer rows.Close()

	var out []Idea
	for rows.Next() {
		idea, err := scanIdea(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning idea: %w", err)
		}
		out = append(out, *idea)
	}
	return out, rows.Err()
}

// ListIdeaVerdictExamples returns owner-rated or terminally-dispositioned
// ideas (rejected/dropped/active), newest first — few-shot examples of past
// owner verdicts for the consolidator prompt.
func (db *DB) ListIdeaVerdictExamples(limit int) ([]Idea, error) {
	if limit <= 0 {
		limit = 20
	}
	rows, err := db.Query(`SELECT `+ideaSelectCols+` FROM ideas
		WHERE owner_rating != 0 OR status IN ('rejected','dropped','active')
		ORDER BY updated_at DESC LIMIT ?`, limit)
	if err != nil {
		return nil, fmt.Errorf("listing idea verdict examples: %w", err)
	}
	defer rows.Close()

	var out []Idea
	for rows.Next() {
		idea, err := scanIdea(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning idea: %w", err)
		}
		out = append(out, *idea)
	}
	return out, rows.Err()
}

// GetIdeasFloors returns the three registry watermarks: the highest
// digests/stream_digests/meeting_transcripts id already folded into the
// registry by the consolidator. A fresh workspace without its singleton row
// reads as zeros (the MemoryWatermark precedent).
func (db *DB) GetIdeasFloors() (digest, stream, transcript int64, err error) {
	err = db.QueryRow(`SELECT COALESCE(ideas_digest_floor, 0), COALESCE(ideas_stream_digest_floor, 0), COALESCE(ideas_transcript_floor, 0)
		FROM workspace LIMIT 1`).Scan(&digest, &stream, &transcript)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, 0, 0, nil
	}
	if err != nil {
		return 0, 0, 0, fmt.Errorf("getting ideas floors: %w", err)
	}
	return digest, stream, transcript, nil
}

// SetIdeasFloorsTx updates the three registry watermarks.
func (db *DB) SetIdeasFloorsTx(tx *sql.Tx, digest, stream, transcript int64) error {
	_, err := tx.Exec(`UPDATE workspace SET ideas_digest_floor = ?, ideas_stream_digest_floor = ?, ideas_transcript_floor = ?`,
		digest, stream, transcript)
	if err != nil {
		return fmt.Errorf("setting ideas floors: %w", err)
	}
	return nil
}

// StreamDigest is a stage-1 pre-digest for a stream with no existing digest
// pipeline (Gmail, Jira) — a lightweight per-account topic summary the
// stage-2 consolidator reads alongside Slack digests and meeting recaps.
type StreamDigest struct {
	ID         int64
	Source     string
	AccountID  int64
	Scope      string
	PeriodFrom string
	PeriodTo   string
	TopicsJSON string
	CreatedAt  string
}

// InsertStreamDigest stores a stream pre-digest and returns its ID.
func (db *DB) InsertStreamDigest(d StreamDigest) (int64, error) {
	if d.TopicsJSON == "" {
		d.TopicsJSON = "[]"
	}
	res, err := db.Exec(`INSERT INTO stream_digests (source, account_id, scope, period_from, period_to, topics_json)
		VALUES (?, ?, ?, ?, ?, ?)`,
		d.Source, d.AccountID, d.Scope, d.PeriodFrom, d.PeriodTo, d.TopicsJSON)
	if err != nil {
		return 0, fmt.Errorf("inserting stream digest: %w", err)
	}
	return res.LastInsertId()
}

// ListStreamDigestsAfter returns stream pre-digests with id above the given
// floor, ordered by id.
func (db *DB) ListStreamDigestsAfter(floor int64) ([]StreamDigest, error) {
	rows, err := db.Query(`SELECT id, source, account_id, scope, period_from, period_to, topics_json, created_at
		FROM stream_digests WHERE id > ? ORDER BY id`, floor)
	if err != nil {
		return nil, fmt.Errorf("listing stream digests: %w", err)
	}
	defer rows.Close()

	var out []StreamDigest
	for rows.Next() {
		var d StreamDigest
		if err := rows.Scan(&d.ID, &d.Source, &d.AccountID, &d.Scope, &d.PeriodFrom, &d.PeriodTo, &d.TopicsJSON, &d.CreatedAt); err != nil {
			return nil, fmt.Errorf("scanning stream digest: %w", err)
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

// JiraComment is a bounded, locally-cached Jira comment feeding the Jira
// stream digest — not a full Jira-comment mirror. AuthorAccountID is the
// commenter's Atlassian account id (distinct from Author, the display name);
// it is what the inbox dormant comment-mention/auto-resolve code matches
// against, since Atlassian ids — not Slack ids — are what a Jira [~mention]
// and jira_comments.author_account_id actually carry.
type JiraComment struct {
	AccountID       int64
	IssueKey        string
	ID              string
	Author          string
	AuthorAccountID string
	BodyText        string
	CreatedAt       string
	UpdatedAt       string
}

// UpsertJiraComments inserts or updates comments keyed on (account_id, id).
func (db *DB) UpsertJiraComments(comments []JiraComment) error {
	if len(comments) == 0 {
		return nil
	}
	for _, c := range comments {
		_, err := db.Exec(`INSERT INTO jira_comments (account_id, issue_key, id, author, author_account_id, body_text, created_at, updated_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT(account_id, id) DO UPDATE SET
				issue_key = excluded.issue_key,
				author = excluded.author,
				author_account_id = excluded.author_account_id,
				body_text = excluded.body_text,
				created_at = excluded.created_at,
				updated_at = excluded.updated_at,
				synced_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')`,
			c.AccountID, c.IssueKey, c.ID, c.Author, c.AuthorAccountID, c.BodyText, c.CreatedAt, c.UpdatedAt)
		if err != nil {
			return fmt.Errorf("upserting jira comment %s/%s: %w", c.IssueKey, c.ID, err)
		}
	}
	return nil
}

// ListJiraCommentsSince returns comments for the given account and issue
// keys updated at or after sinceISO.
func (db *DB) ListJiraCommentsSince(accountID int64, issueKeys []string, sinceISO string) ([]JiraComment, error) {
	if len(issueKeys) == 0 {
		return nil, nil
	}
	placeholders := make([]string, len(issueKeys))
	args := make([]any, 0, len(issueKeys)+2)
	args = append(args, accountID)
	for i, key := range issueKeys {
		placeholders[i] = "?"
		args = append(args, key)
	}
	args = append(args, sinceISO)

	query := fmt.Sprintf(`SELECT account_id, issue_key, id, author, author_account_id, body_text, created_at, updated_at
		FROM jira_comments WHERE account_id = ? AND issue_key IN (%s) AND updated_at >= ?
		ORDER BY issue_key, updated_at`, strings.Join(placeholders, ","))
	rows, err := db.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("listing jira comments: %w", err)
	}
	defer rows.Close()

	var out []JiraComment
	for rows.Next() {
		var c JiraComment
		if err := rows.Scan(&c.AccountID, &c.IssueKey, &c.ID, &c.Author, &c.AuthorAccountID, &c.BodyText, &c.CreatedAt, &c.UpdatedAt); err != nil {
			return nil, fmt.Errorf("scanning jira comment: %w", err)
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// DigestTopicForIdeas is a digest_topics row carrying idea/decision
// candidates, joined with its parent digest and channel for display.
type DigestTopicForIdeas struct {
	TopicID     int64
	ChannelID   string
	ChannelName string
	PeriodTo    float64
	Ideas       string // JSON
	Decisions   string // JSON
}

// ListDigestTopicIdeasAfter returns channel-digest topics with id above the
// given floor that carry ideas and/or decisions, ordered by id.
func (db *DB) ListDigestTopicIdeasAfter(floor int64) ([]DigestTopicForIdeas, error) {
	rows, err := db.Query(`SELECT dt.id, d.channel_id, COALESCE(c.name, ''), d.period_to, dt.ideas, dt.decisions
		FROM digest_topics dt
		JOIN digests d ON dt.digest_id = d.id
		LEFT JOIN channels c ON d.channel_id = c.id
		WHERE dt.id > ? AND (dt.ideas != '[]' OR dt.decisions != '[]') AND d.type = 'channel'
		ORDER BY dt.id`, floor)
	if err != nil {
		return nil, fmt.Errorf("listing digest topic ideas: %w", err)
	}
	defer rows.Close()

	var out []DigestTopicForIdeas
	for rows.Next() {
		var t DigestTopicForIdeas
		if err := rows.Scan(&t.TopicID, &t.ChannelID, &t.ChannelName, &t.PeriodTo, &t.Ideas, &t.Decisions); err != nil {
			return nil, fmt.Errorf("scanning digest topic idea row: %w", err)
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// TranscriptForIdeas is a meeting_transcripts row with its recap resolved
// for the ideas consolidator: an event-linked transcript's meeting_recaps
// row wins over its own summary_json (the collision-guard precedent), an
// ad-hoc transcript falls back to summary_json.
type TranscriptForIdeas struct {
	ID        int64
	EventID   string
	Title     string
	RecapJSON string
	CreatedAt string
}

// ListTranscriptsForIdeasAfter returns meeting transcripts with id above the
// given floor, ordered by id.
func (db *DB) ListTranscriptsForIdeasAfter(floor int64) ([]TranscriptForIdeas, error) {
	rows, err := db.Query(`SELECT mt.id, COALESCE(mt.event_id, ''), mt.title,
			COALESCE(mr.recap_json, mt.summary_json, ''), mt.created_at
		FROM meeting_transcripts mt
		LEFT JOIN meeting_recaps mr ON mr.event_id = mt.event_id
		WHERE mt.id > ?
		ORDER BY mt.id`, floor)
	if err != nil {
		return nil, fmt.Errorf("listing transcripts for ideas: %w", err)
	}
	defer rows.Close()

	var out []TranscriptForIdeas
	for rows.Next() {
		var t TranscriptForIdeas
		if err := rows.Scan(&t.ID, &t.EventID, &t.Title, &t.RecapJSON, &t.CreatedAt); err != nil {
			return nil, fmt.Errorf("scanning transcript for ideas: %w", err)
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// CountIdeasForReview returns the number of ideas awaiting owner attention:
// freshly proposed, or explicitly flagged needs_review.
func (db *DB) CountIdeasForReview() (int, error) {
	var count int
	err := db.QueryRow(`SELECT COUNT(*) FROM ideas WHERE status = 'proposed' OR needs_review = 1`).Scan(&count)
	if err != nil {
		return 0, fmt.Errorf("counting ideas for review: %w", err)
	}
	return count, nil
}

// IdeasEmailFloor returns the ideas registry's per-account Gmail pre-digest
// watermark (unix seconds, google_accounts.ideas_email_floor) — deliberately
// separate from memory_gmail_last_extracted_ts (memory extraction) and
// gmail_last_internal_date (Gmail sync): a THIRD independent Gmail watermark,
// the MemoryGmailWatermark precedent. A missing account reads as 0.
func (db *DB) IdeasEmailFloor(accountID int64) (float64, error) {
	var ts float64
	err := db.QueryRow(`SELECT ideas_email_floor FROM google_accounts WHERE id = ?`, accountID).Scan(&ts)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("getting ideas email floor for account %d: %w", accountID, err)
	}
	return ts, nil
}

// SetIdeasEmailFloor advances the ideas registry's Gmail pre-digest watermark
// for accountID (see IdeasEmailFloor). The email pre-digest pass only moves
// this behind a successfully-inserted stream_digests row.
func (db *DB) SetIdeasEmailFloor(accountID int64, ts float64) error {
	res, err := db.Exec(`UPDATE google_accounts SET ideas_email_floor = ? WHERE id = ?`, ts, accountID)
	if err != nil {
		return fmt.Errorf("setting ideas email floor for account %d: %w", accountID, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("setting ideas email floor: no google_accounts row %d", accountID)
	}
	return nil
}

// IdeasJiraFloor returns the ideas registry's per-account Jira pre-digest
// watermark (RFC3339, jira_accounts.ideas_jira_floor) — deliberately separate
// from memory_jira_last_extracted_ts (memory extraction), the
// IdeasEmailFloor precedent. A missing account reads as "".
func (db *DB) IdeasJiraFloor(accountID int64) (string, error) {
	var ts string
	err := db.QueryRow(`SELECT ideas_jira_floor FROM jira_accounts WHERE id = ?`, accountID).Scan(&ts)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("getting ideas jira floor for account %d: %w", accountID, err)
	}
	return ts, nil
}

// SetIdeasJiraFloor advances the ideas registry's Jira pre-digest watermark
// for accountID (see IdeasJiraFloor). The jira pre-digest pass only moves
// this behind a successfully-inserted stream_digests row.
func (db *DB) SetIdeasJiraFloor(accountID int64, ts string) error {
	res, err := db.Exec(`UPDATE jira_accounts SET ideas_jira_floor = ? WHERE id = ?`, ts, accountID)
	if err != nil {
		return fmt.Errorf("setting ideas jira floor for account %d: %w", accountID, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("setting ideas jira floor: no jira_accounts row %d", accountID)
	}
	return nil
}

// ListJiraIssuesUpdatedSince returns accountID's non-deleted Jira issues with
// updated_at strictly above sinceISO, ascending by updated_at, capped at
// limit — the raw input the ideas Jira pre-digest pass groups per project.
// A plain string comparison against the raw Jira timestamp (unlike
// ListJiraIssuesForExtract's parsed-in-Go approach): sinceISO is always the
// account's own ideas_jira_floor, itself copied verbatim from a prior row's
// updated_at, so the comparison is self-consistent within one account even
// though the stored format is not a normalized unix value.
func (db *DB) ListJiraIssuesUpdatedSince(accountID int64, sinceISO string, limit int) ([]JiraIssue, error) {
	if limit <= 0 {
		limit = 300
	}
	rows, err := db.Query(`SELECT `+jiraIssueColumns+` FROM jira_issues
		WHERE account_id = ? AND is_deleted = 0 AND updated_at > ?
		ORDER BY updated_at ASC LIMIT ?`, accountID, sinceISO, limit)
	if err != nil {
		return nil, fmt.Errorf("listing jira issues updated since: %w", err)
	}
	defer rows.Close()

	var out []JiraIssue
	for rows.Next() {
		issue, err := scanJiraIssue(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning jira issue: %w", err)
		}
		out = append(out, issue)
	}
	return out, rows.Err()
}
