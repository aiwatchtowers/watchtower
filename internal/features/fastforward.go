package features

import (
	"fmt"
	"time"

	"watchtower/internal/db"
)

// FastForward stamps id's watermarks/floors to now so its next daemon cycle
// resumes from "now" instead of processing the backlog that accumulated
// while the feature was off (spec "Re-enable semantics", FEAT-03). It
// dispatches on id and runs OUTSIDE any pipeline's own Run — an explicit
// owner action triggered by re-enabling a feature in the manager, never
// pipeline logic itself. A feature with no hook is a deliberate no-op (nil,
// no writes): digests/tracks/people-cards are cap-bounded per daemon cycle
// already and simply resume where their own watermark left off.
//
// Every hook below reuses an existing internal/db setter — the same one its
// owning pipeline calls to advance its own watermark — rather than writing
// SQL of its own; FastForward reproduces what a fresh self-init already
// does, it does not invent new watermark semantics.
func FastForward(id string, database *db.DB, now time.Time) error {
	switch id {
	case "secretary-inbox":
		return fastForwardSecretaryInbox(database, now)
	case "ideas":
		return fastForwardIdeas(database, now)
	case "stream-digests":
		return fastForwardStreamFloors(database, now)
	case "slack-digests":
		return fastForwardSlackDigests(database, now)
	case "memory":
		return fastForwardMemory(database, now)
	default:
		return nil
	}
}

// fastForwardSecretaryInbox stamps both watermarks the inbox pipeline's own
// Run advances: detection/triage's inbox_last_processed_ts (INBOX-09) and
// the composer's compose_last_run_ts (DASH-02) — re-enabling the pillar
// must skip both stages' backlog, not just detection's.
func fastForwardSecretaryInbox(database *db.DB, now time.Time) error {
	ts := float64(now.Unix())
	if err := database.SetInboxLastProcessedTS(ts); err != nil {
		return fmt.Errorf("fast-forwarding inbox watermark: %w", err)
	}
	if err := database.SetComposeLastRunTS(ts); err != nil {
		return fmt.Errorf("fast-forwarding compose watermark: %w", err)
	}
	return nil
}

// fastForwardIdeas stamps the three workspace-level consolidator floors to
// the current top of the source tables they track — exactly migration
// 00050's install-time seeding semantics (digest_topics/stream_digests/
// meeting_transcripts). Those three are the whole of it: they are what
// ideas.enabled actually gates (stage 2, the consolidator), and stamping
// them is what stops the accumulated backlog from being mined on the next
// cycle.
//
// The per-account Gmail/Jira stage-1 floors are deliberately NOT touched
// here. They belong to Stream Digests (streams.enabled), a feature that
// toggles independently and may well have been running the whole time
// Ideas was off; advancing its floors from an Ideas enable would skip a
// window of email/Jira digest generation the owner never asked to skip.
// See fastForwardStreamFloors, the hook that does own them.
func fastForwardIdeas(database *db.DB, now time.Time) error {
	digestTop, streamTop, transcriptTop, err := database.IdeasFloorTops()
	if err != nil {
		return fmt.Errorf("fast-forwarding ideas floors: reading table tops: %w", err)
	}
	if err := database.SetIdeasFloors(digestTop, streamTop, transcriptTop); err != nil {
		return fmt.Errorf("fast-forwarding ideas floors: %w", err)
	}
	return nil
}

// fastForwardStreamFloors stamps the per-account Gmail/Jira stage-1 floors
// (google_accounts.ideas_email_floor / jira_accounts.ideas_jira_floor) to
// the same value each account's own stage-1 self-init would pick on a fresh
// connection — see runEmailDigestAccount/runJiraDigestAccount in
// internal/ideas. It is the Stream Digests hook (streams.enabled) and its
// sole owner: enabling Ideas does not run it (see fastForwardIdeas).
//
// Gmail mirrors self-init exactly: the floor becomes the account's own
// Gmail sync watermark (gmail_last_internal_date, already on the row
// ListGoogleAccounts returns — the same "current max internal_date"
// self-init reads via GetGmailAccountWatermark). An account with no synced
// mail yet (watermark still 0) is left untouched, same as self-init's
// "retry initialization next run" — writing 0 would be a no-op regardless,
// since that is the column's own default.
//
// Jira does not mirror self-init byte for byte: self-init backs off a few
// seconds from wall-clock time purely for clock-skew tolerance on an
// unattended background init (jiraFloorInitBackoff, internal/ideas — not
// exported, and not worth importing the ideas pipeline package for). This
// is an explicit owner action, not a background init, so the floor is
// stamped to now directly; missing an issue updated in the few seconds
// around the owner's own click is not a real loss.
func fastForwardStreamFloors(database *db.DB, now time.Time) error {
	googleAccounts, err := database.ListGoogleAccounts()
	if err != nil {
		return fmt.Errorf("fast-forwarding stream floors: listing google accounts: %w", err)
	}
	for _, acct := range googleAccounts {
		if !acct.GmailEnabled || acct.GmailLastInternalDate == 0 {
			continue
		}
		if err := database.SetIdeasEmailFloor(acct.ID, acct.GmailLastInternalDate); err != nil {
			return fmt.Errorf("fast-forwarding email floor for account %d: %w", acct.ID, err)
		}
	}

	jiraAccounts, err := database.ListEnabledJiraAccounts()
	if err != nil {
		return fmt.Errorf("fast-forwarding stream floors: listing jira accounts: %w", err)
	}
	nowJira := db.FormatJiraTime(now.UTC())
	for _, acct := range jiraAccounts {
		if err := database.SetIdeasJiraFloor(acct.ID, nowJira); err != nil {
			return fmt.Errorf("fast-forwarding jira floor for account %d: %w", acct.ID, err)
		}
	}
	return nil
}

// fastForwardSlackDigests stamps workspace.digest_fastforward_ts to now. Slack
// digests have no advancing watermark of their own — the pipeline derives the
// next window's start from MAX(digests.period_to) — so this persisted floor is
// what lets a re-enable resume from "now" instead of re-digesting the backlog
// that accrued while the feature was off. lastDigestTime returns
// max(derived, this floor).
func fastForwardSlackDigests(database *db.DB, now time.Time) error {
	if err := database.SetDigestFastForwardTS(float64(now.Unix())); err != nil {
		return fmt.Errorf("fast-forwarding slack digest watermark: %w", err)
	}
	return nil
}

// fastForwardMemory stamps every extraction watermark the memory pipeline
// owns to now: the core Slack/situations watermark, the per-account
// Gmail/Jira watermarks, and the workspace-level calendar watermark. Unlike
// the ideas floors, these are ordinary "processed up to this instant"
// watermarks — memory's own self-init mirrors a source table top too (see
// runGmailExtractAccount/runJiraIngestAccount), but a re-enabling owner is
// deliberately stamping "start fresh from now", not "catch up to what's
// already synced".
func fastForwardMemory(database *db.DB, now time.Time) error {
	ts := float64(now.Unix())
	if err := database.SetMemoryWatermark(ts); err != nil {
		return fmt.Errorf("fast-forwarding memory watermark: %w", err)
	}

	googleAccounts, err := database.ListGoogleAccounts()
	if err != nil {
		return fmt.Errorf("fast-forwarding memory watermark: listing google accounts: %w", err)
	}
	for _, acct := range googleAccounts {
		if !acct.GmailEnabled {
			continue
		}
		if err := database.SetMemoryGmailWatermark(acct.ID, ts); err != nil {
			return fmt.Errorf("fast-forwarding memory gmail watermark for account %d: %w", acct.ID, err)
		}
	}

	jiraAccounts, err := database.ListEnabledJiraAccounts()
	if err != nil {
		return fmt.Errorf("fast-forwarding memory watermark: listing jira accounts: %w", err)
	}
	for _, acct := range jiraAccounts {
		if err := database.SetMemoryJiraWatermark(acct.ID, ts); err != nil {
			return fmt.Errorf("fast-forwarding memory jira watermark for account %d: %w", acct.ID, err)
		}
	}

	if err := database.SetMemoryCalendarWatermark(ts); err != nil {
		return fmt.Errorf("fast-forwarding memory calendar watermark: %w", err)
	}
	return nil
}
