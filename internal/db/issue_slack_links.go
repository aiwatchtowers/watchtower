package db

import (
	"database/sql"
	"fmt"
)

// Slack <-> issue links (issue_slack_links, migration 00144; was
// jira_slack_links). The tracker-neutral key detector (internal/issuekey)
// writes them; a key prefix known to both Jira and Linear writes one link per
// tracker, so every reader names the tracker it wants.

// IssueSlackLink is one detected issue-key mention in Slack: a message
// mention, a track link or a digest-decision link.
type IssueSlackLink struct {
	ID         int
	Tracker    string // "jira" | "linear"; "" is written as "jira"
	IssueKey   string
	ChannelID  string
	MessageTS  string
	TrackID    *int
	DigestID   *int
	LinkType   string
	DetectedAt string
}

// Each link kind has its own identity and therefore its own conflict target,
// one per partial unique index (00067, tracker added by 00144): a mention is
// identified by the message it was found in, a track link by its track, a
// decision link by its digest — each per tracker. A single shared target made
// a track link and a decision link for the same issue key and channel the same
// physical row, because neither of them writes a message_ts.
const (
	upsertIssueSlackLinkMention = `INSERT INTO issue_slack_links (tracker, issue_key, channel_id, message_ts, track_id, digest_id, link_type)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(tracker, issue_key, channel_id, message_ts) WHERE link_type = 'mention' DO UPDATE SET
			track_id=COALESCE(excluded.track_id, issue_slack_links.track_id),
			digest_id=COALESCE(excluded.digest_id, issue_slack_links.digest_id),
			link_type=COALESCE(excluded.link_type, issue_slack_links.link_type)`

	upsertIssueSlackLinkTrack = `INSERT INTO issue_slack_links (tracker, issue_key, channel_id, message_ts, track_id, digest_id, link_type)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(tracker, issue_key, track_id) WHERE link_type = 'track' DO UPDATE SET
			track_id=COALESCE(excluded.track_id, issue_slack_links.track_id),
			digest_id=COALESCE(excluded.digest_id, issue_slack_links.digest_id),
			link_type=COALESCE(excluded.link_type, issue_slack_links.link_type)`

	upsertIssueSlackLinkDecision = `INSERT INTO issue_slack_links (tracker, issue_key, channel_id, message_ts, track_id, digest_id, link_type)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(tracker, issue_key, digest_id) WHERE link_type = 'decision' DO UPDATE SET
			track_id=COALESCE(excluded.track_id, issue_slack_links.track_id),
			digest_id=COALESCE(excluded.digest_id, issue_slack_links.digest_id),
			link_type=COALESCE(excluded.link_type, issue_slack_links.link_type)`
)

// issueSlackLinkUpsert resolves a link to the statement matching its kind's own
// partial unique index, returning the link with its kind and tracker
// normalised.
//
// A kind with no identity has no dedup: its rows match no partial index, so
// every write inserts. An empty LinkType is therefore normalised to "mention"
// (the column's own default) rather than written through — it is what a caller
// gets by forgetting a field — and any other value is refused outright instead
// of growing the table without bound. An empty Tracker is "jira" (the column's
// default); an unknown one is refused before the CHECK would fail the batch.
func issueSlackLinkUpsert(link IssueSlackLink) (IssueSlackLink, string, error) {
	switch link.Tracker {
	case "":
		link.Tracker = "jira"
	case "jira", "linear":
	default:
		return link, "", fmt.Errorf("upserting issue slack link %s: unknown tracker %q", link.IssueKey, link.Tracker)
	}
	switch link.LinkType {
	case "", "mention":
		link.LinkType = "mention"
		return link, upsertIssueSlackLinkMention, nil
	case "track":
		return link, upsertIssueSlackLinkTrack, nil
	case "decision":
		return link, upsertIssueSlackLinkDecision, nil
	default:
		return link, "", fmt.Errorf("upserting issue slack link %s: unknown link_type %q", link.IssueKey, link.LinkType)
	}
}

// UpsertIssueSlackLink inserts or updates an issue-Slack link, conflicting on
// the identity of the link's own kind and tracker.
func (db *DB) UpsertIssueSlackLink(link IssueSlackLink) error {
	link, query, err := issueSlackLinkUpsert(link)
	if err != nil {
		return err
	}
	if _, err := db.Exec(query,
		link.Tracker, link.IssueKey, link.ChannelID, link.MessageTS, link.TrackID, link.DigestID, link.LinkType); err != nil {
		return fmt.Errorf("upserting issue slack link %s: %w", link.IssueKey, err)
	}
	return nil
}

// UpsertIssueSlackLinkBatch writes a batch of issue-Slack links within an
// existing transaction, preparing one statement per link kind present (the
// UpsertMessageBatch shape). Semantics per link are identical to
// UpsertIssueSlackLink; the difference is that a whole page of links costs one
// commit instead of one per link. That matters on the message-sync path, where
// SetMaxOpenConns(1) makes every separate write serialise against the sync's
// own.
//
// Every link is resolved to its kind's statement BEFORE any of them executes,
// so a batch carrying one unknown link_type or tracker is refused whole rather
// than leaving the links ahead of it written into the caller's transaction.
func (db *DB) UpsertIssueSlackLinkBatch(tx *sql.Tx, links []IssueSlackLink) error {
	if tx == nil {
		return fmt.Errorf("UpsertIssueSlackLinkBatch: nil transaction")
	}

	type resolved struct {
		link  IssueSlackLink
		query string
	}
	pending := make([]resolved, 0, len(links))
	for _, link := range links {
		link, query, err := issueSlackLinkUpsert(link)
		if err != nil {
			return err
		}
		pending = append(pending, resolved{link: link, query: query})
	}

	stmts := make(map[string]*sql.Stmt, 3)
	defer func() {
		for _, stmt := range stmts {
			stmt.Close()
		}
	}()

	for _, p := range pending {
		link, query := p.link, p.query
		stmt, ok := stmts[query]
		if !ok {
			prepared, err := tx.Prepare(query)
			if err != nil {
				return fmt.Errorf("preparing issue slack link upsert: %w", err)
			}
			stmt = prepared
			stmts[query] = stmt
		}
		if _, err := stmt.Exec(
			link.Tracker, link.IssueKey, link.ChannelID, link.MessageTS, link.TrackID, link.DigestID, link.LinkType); err != nil {
			return fmt.Errorf("upserting issue slack link %s: %w", link.IssueKey, err)
		}
	}
	return nil
}

const issueSlackLinkColumns = `id, tracker, issue_key, channel_id, message_ts, track_id, digest_id, link_type, detected_at`

// queryIssueSlackLinks runs a SELECT of issueSlackLinkColumns and scans every
// row; what names the read in errors.
func (db *DB) queryIssueSlackLinks(what, where string, args ...any) ([]IssueSlackLink, error) {
	rows, err := db.Query(`SELECT `+issueSlackLinkColumns+` FROM issue_slack_links WHERE `+where+
		` ORDER BY detected_at DESC`, args...)
	if err != nil {
		return nil, fmt.Errorf("querying issue slack links %s: %w", what, err)
	}
	defer rows.Close()

	var links []IssueSlackLink
	for rows.Next() {
		var l IssueSlackLink
		if err := rows.Scan(&l.ID, &l.Tracker, &l.IssueKey, &l.ChannelID, &l.MessageTS, &l.TrackID, &l.DigestID, &l.LinkType, &l.DetectedAt); err != nil {
			return nil, fmt.Errorf("scanning issue slack link %s: %w", what, err)
		}
		links = append(links, l)
	}
	return links, rows.Err()
}

// keyArgs returns the placeholders for keys and the keys as query args.
func keyArgs(keys []string) (string, []any) {
	args := make([]any, len(keys))
	for i, k := range keys {
		args[i] = k
	}
	return sqlPlaceholders(len(keys)), args
}

// GetIssueSlackLinksByKeys returns the tracker's Slack links for any of keys
// (a Linear issue's current key plus its previous ones, so a link written
// before a team move still resolves), newest first.
func (db *DB) GetIssueSlackLinksByKeys(tracker string, keys []string) ([]IssueSlackLink, error) {
	if len(keys) == 0 {
		return nil, nil
	}
	ph, args := keyArgs(keys)
	return db.queryIssueSlackLinks("by "+tracker+" issue keys",
		`tracker = ? AND issue_key IN (`+ph+`)`, append([]any{tracker}, args...)...)
}

// GetJiraSlackLinksByIssue returns all Slack links for a given Jira issue key.
func (db *DB) GetJiraSlackLinksByIssue(issueKey string) ([]IssueSlackLink, error) {
	return db.GetIssueSlackLinksByKeys("jira", []string{issueKey})
}

// GetJiraSlackLinksByIssueKeys returns all Jira Slack links for a set of issue keys.
func (db *DB) GetJiraSlackLinksByIssueKeys(keys []string) ([]IssueSlackLink, error) {
	return db.GetIssueSlackLinksByKeys("jira", keys)
}

// GetJiraSlackLinksByMessage returns all Jira links for a specific Slack message.
func (db *DB) GetJiraSlackLinksByMessage(channelID, messageTS string) ([]IssueSlackLink, error) {
	return db.queryIssueSlackLinks("by message",
		`tracker = 'jira' AND channel_id = ? AND message_ts = ?`, channelID, messageTS)
}

// GetJiraSlackLinksByTrackID returns all Jira-Slack links for a given track ID.
func (db *DB) GetJiraSlackLinksByTrackID(trackID int) ([]IssueSlackLink, error) {
	return db.queryIssueSlackLinks(fmt.Sprintf("by track %d", trackID),
		`tracker = 'jira' AND track_id = ?`, trackID)
}

// GetJiraDecisionCountByIssueKeys returns the number of Jira slack links with
// link_type='decision' for the given issue keys.
func (db *DB) GetJiraDecisionCountByIssueKeys(keys []string) (int, error) {
	if len(keys) == 0 {
		return 0, nil
	}
	ph, args := keyArgs(keys)
	var count int
	err := db.QueryRow(`SELECT COUNT(*) FROM issue_slack_links
		WHERE tracker = 'jira' AND issue_key IN (`+ph+`) AND link_type = 'decision'`, args...).Scan(&count)
	if err != nil {
		return 0, fmt.Errorf("counting jira decisions by issue keys: %w", err)
	}
	return count, nil
}
