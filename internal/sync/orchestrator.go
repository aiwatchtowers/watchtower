// Package sync provides Slack workspace synchronization orchestration and message syncing.
package sync

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"strings"

	"watchtower/internal/config"
	"watchtower/internal/db"
	watchtowerslack "watchtower/internal/slack"

	"github.com/slack-go/slack"
)

// SyncOptions configures how a sync run behaves.
type SyncOptions struct {
	Full     bool     // Re-fetch all history within the initial_history_days window
	Channels []string // Limit sync to specific channel names/IDs (empty = all)
	Workers  int      // Number of concurrent sync workers (0 = use config default)
	SkipDMs  bool     // Skip syncing DMs and group DMs
}

// Orchestrator coordinates the sync phases for one connected Slack account.
// Every channelID/userID string passed between its methods, stored on a
// SyncTask, or written to the DB is namespaced ("<accountID>:<rawID>"); only
// the literal Slack SDK calls need the raw id (stripped via
// watchtowerslack.SplitAccountID immediately before the call).
type Orchestrator struct {
	db                   *db.DB
	slackClient          *watchtowerslack.Client
	config               *config.Config
	accountID            int64
	account              db.SlackAccount
	logger               *log.Logger
	progress             *Progress
	channelNames         map[string]string // namespaced channel ID -> name, populated during message sync
	discoveredChannelIDs map[string]bool   // namespaced channel IDs found active by discovery phase
}

// NewOrchestrator creates a new sync orchestrator scoped to one connected
// Slack account (accountID, a slack_accounts.id).
func NewOrchestrator(database *db.DB, slackClient *watchtowerslack.Client, cfg *config.Config, accountID int64) *Orchestrator {
	return &Orchestrator{
		db:          database,
		slackClient: slackClient,
		config:      cfg,
		accountID:   accountID,
		logger:      log.Default(),
		progress:    NewProgress(),
	}
}

// SetLogger sets a custom logger for the orchestrator and its Slack client.
func (o *Orchestrator) SetLogger(l *log.Logger) {
	o.logger = l
	o.slackClient.SetLogger(l)
}

// Progress returns the progress tracker for this orchestrator.
func (o *Orchestrator) Progress() *Progress {
	return o.progress
}

// resolveWorkerCount clamps the requested worker count to a safe range,
// falling back to the config default or 1 if not specified.
func (o *Orchestrator) resolveWorkerCount(requested int) int {
	workers := requested
	if workers <= 0 {
		workers = o.config.Sync.Workers
	}
	if workers <= 0 {
		workers = 1
	}
	if workers > 100 {
		workers = 100
	}
	return workers
}

// Run executes the sync pipeline and records the resulting auth state on the
// account row (recordAuthResult) — the calendar.Syncer/gmail.Syncer precedent,
// so a revoked/broken token surfaces in Desktop instead of staying silently
// "ok" forever while the daemon log fills with the same error every cycle.
func (o *Orchestrator) Run(ctx context.Context, opts SyncOptions) error {
	err := o.run(ctx, opts)
	o.recordAuthResult(ctx, err)
	return err
}

// recordAuthResult persists the account's sync auth state. Pass err=nil to
// mark it healthy. Errors writing to the DB are logged but not returned —
// auth state is best-effort telemetry. A cancelled ctx means daemon shutdown,
// not an auth problem, so the state is left untouched (calendar.Syncer's
// recordAuthResult precedent).
func (o *Orchestrator) recordAuthResult(ctx context.Context, err error) {
	if o.db == nil {
		return
	}
	if err == nil {
		if dbErr := o.db.SetSlackAccountAuthState(o.accountID, "ok", ""); dbErr != nil {
			o.logger.Printf("slack: failed to clear auth state: %v", dbErr)
		}
		return
	}
	if ctx.Err() != nil {
		o.logger.Printf("slack: sync cancelled, leaving auth state untouched: %v", err)
		return
	}
	if dbErr := o.db.SetSlackAccountAuthState(o.accountID, "error", err.Error()); dbErr != nil {
		o.logger.Printf("slack: failed to record auth state: %v", dbErr)
	}
}

// run is Run's actual pipeline. For incremental sync (default), it uses
// search.messages to directly save messages, avoiding per-channel API calls.
// For --full or --channels, it runs the full pipeline:
// 1. Workspace info (team.info, cached)
// 2. Metadata sync (conversations.list, users.list)
// 3. Messages (conversations.history per channel)
// 4. User profiles (users.info for unknown users)
// 5. Threads (conversations.replies)
func (o *Orchestrator) run(ctx context.Context, opts SyncOptions) error {
	o.logger.Println("starting sync")

	// Phase 1: workspace info
	o.progress.SetPhase(PhaseMetadata)

	// Ensure the connected account's team info is resolved (team.info, cached after first call)
	if err := o.ensureWorkspace(ctx); err != nil {
		return fmt.Errorf("workspace sync: %w", err)
	}
	// Retry syncCurrentUser if it failed on a previous run (e.g. auth.test error).
	// Required for action items pipeline which needs current_user_id.
	if o.account.CurrentUserID == "" {
		o.syncCurrentUser(ctx)
	}

	// Sync custom emojis (fast, single API call)
	if err := o.syncEmoji(ctx); err != nil {
		o.logger.Printf("warning: emoji sync failed: %v", err)
		// Non-fatal: continue with message sync
	}

	if opts.Full || len(opts.Channels) > 0 {
		return o.runFullSync(ctx, opts)
	}
	return o.runSearchSync(ctx, opts)
}

// runFullSync executes the full sync pipeline with per-channel conversations.history.
func (o *Orchestrator) runFullSync(ctx context.Context, opts SyncOptions) error {
	// Phase 2: full metadata sync
	o.logger.Println("phase 2: full metadata sync")
	if err := o.syncMetadata(ctx, opts); err != nil {
		return fmt.Errorf("metadata sync: %w", err)
	}

	// Phase 3: messages
	o.logger.Println("phase 3: syncing messages")
	o.progress.SetPhase(PhaseMessages)
	if err := o.syncMessages(ctx, opts); err != nil {
		return fmt.Errorf("message sync: %w", err)
	}

	// Phase 4: user profiles
	o.logger.Println("phase 4: syncing user profiles")
	o.progress.SetPhase(PhaseUsers)
	if err := o.syncUserProfiles(ctx); err != nil {
		return fmt.Errorf("user profile sync: %w", err)
	}

	// Sync reactions for pending inbox items so auto-resolve can detect them.
	o.syncInboxReactions(ctx)

	return o.finishSync()
}

// runSearchSync uses search.messages to save messages directly, then fetches
// profiles for any unknown users. Much fewer API calls than full sync.
func (o *Orchestrator) runSearchSync(ctx context.Context, opts SyncOptions) error {
	// Phase 2: search-based sync (messages saved directly from search results)
	o.progress.SetPhase(PhaseDiscovery)
	o.logger.Println("phase 2: search-based sync")
	if err := o.syncViaSearch(ctx); err != nil {
		if isNonFatalError(err) {
			o.logger.Printf("search sync failed, falling back to full sync: %v", err)
			return o.runFullSync(ctx, opts)
		}
		return fmt.Errorf("search sync: %w", err)
	}

	// Fallback: if search found 0 channels (e.g. missing search:read scope),
	// check if DB already has channels from a previous sync; if not, fall back
	// to full sync so we have something to work with.
	snap := o.progress.Snapshot()
	if snap.DiscoveryChannels == 0 {
		stats, err := o.db.GetStats()
		if err != nil || stats.ChannelCount == 0 {
			o.logger.Println("search found 0 channels, falling back to full sync")
			return o.runFullSync(ctx, opts)
		}
	}

	// Phase 3: sync channel read state (search sync doesn't call conversations.list)
	o.syncChannelReadState(ctx)

	// Phase 4: full user roster (users.list) — search sync only discovers users
	// from recent messages, so we always fetch the complete workspace roster here.
	o.logger.Println("phase 4: syncing all workspace users")
	o.progress.SetPhase(PhaseUsers)
	if err := o.fetchAllUserProfiles(ctx); err != nil {
		return fmt.Errorf("user roster sync: %w", err)
	}

	// Thread sync skipped in search path — search.messages already returns
	// both parent messages and thread replies within the search window.
	// Full thread sync only runs with --full flag (runFullSync).

	// Sync reactions for pending inbox items so auto-resolve can detect them.
	o.syncInboxReactions(ctx)

	return o.finishSync()
}

// syncChannelReadState fetches channel read cursors from Slack and updates them in the DB.
// Uses conversations.info per channel because conversations.list does not reliably return
// last_read for most channel types.
//
// Two modes:
//   - Normal: only fetches for channels with unread digests (minimal API calls).
//   - First run: if no digests exist yet, fetches for all member channels that lack
//     a last_read cursor. This ensures AutoMarkReadFromSlack works immediately after
//     the first digest generation (without waiting for a second sync cycle).
func (o *Orchestrator) syncChannelReadState(ctx context.Context) {
	o.logger.Println("syncing channel read state")

	// UnreadDigestChannelIDs/ChannelIDsWithoutLastRead are account-unscoped —
	// they return every connected account's channels — so filter to this
	// orchestrator's own account before calling the Slack API with them; a
	// raw channel id can collide across two workspaces (the exact scenario
	// namespacing exists to prevent), and this orchestrator only holds a
	// token for its own account.
	channelIDs, err := o.db.UnreadDigestChannelIDs()
	if err != nil {
		o.logger.Printf("warning: failed to get unread digest channels: %v", err)
		return
	}
	channelIDs = o.filterOwnAccountIDs(channelIDs)

	// First-run path: no digests yet, pre-fetch last_read for channels without it.
	if len(channelIDs) == 0 {
		channelIDs, err = o.db.ChannelIDsWithoutLastRead()
		if err != nil {
			o.logger.Printf("warning: failed to get channels without last_read: %v", err)
			return
		}
		channelIDs = o.filterOwnAccountIDs(channelIDs)
		if len(channelIDs) == 0 {
			o.logger.Println("channel read state: all channels up to date, skipping")
			return
		}
		o.logger.Printf("channel read state: first run, fetching last_read for %d member channels", len(channelIDs))
	}

	var updated int
	for _, chID := range channelIDs {
		_, rawID, _ := watchtowerslack.SplitAccountID(chID)
		lastRead, err := o.slackClient.GetChannelReadCursor(ctx, rawID)
		if err != nil {
			o.logger.Printf("warning: failed to get read cursor for %s: %v", chID, err)
			continue
		}
		if lastRead == "" {
			continue
		}
		if err := o.db.UpdateChannelLastRead(chID, lastRead); err != nil {
			o.logger.Printf("warning: failed to update last_read for %s: %v", chID, err)
			continue
		}
		updated++
	}
	o.logger.Printf("channel read state: %d/%d channels updated (via conversations.info)", updated, len(channelIDs))
}

// filterOwnAccountIDs keeps only the namespaced ids that belong to this
// orchestrator's own account, dropping every other connected Slack account's
// ids plus any non-Slack-namespaced id (gmail:/imap: prefixed, or a bare
// Jira/watchtower id with no namespace at all) — none of those are ever
// valid input to this orchestrator's single-account Slack client.
func (o *Orchestrator) filterOwnAccountIDs(ids []string) []string {
	out := ids[:0:0]
	for _, id := range ids {
		if acctID, _, ok := watchtowerslack.SplitAccountID(id); ok && acctID == o.accountID {
			out = append(out, id)
		}
	}
	return out
}

// syncInboxReactions fetches fresh reactions from Slack for pending inbox items.
// This ensures CheckUserReplied() can detect user reactions even though
// search.messages doesn't return reactions and conversations.history only
// captures reactions at the time of the sync.
func (o *Orchestrator) syncInboxReactions(ctx context.Context) {
	// GetInboxItems is account-unscoped — it returns every source's pending
	// items (every connected Slack account, plus Gmail/Jira/Watchtower) — so
	// filter to this orchestrator's own account before calling the Slack API;
	// a raw channel id can collide across two workspaces, and this
	// orchestrator only holds a token for its own account.
	pendingItems, err := o.db.GetInboxItems(db.InboxFilter{Status: "pending"})
	if err != nil {
		o.logger.Printf("warning: failed to load pending inbox items for reaction sync: %v", err)
		return
	}
	if len(pendingItems) == 0 {
		return
	}

	// Deduplicate by (channel_id, message_ts) since multiple inbox items can
	// reference the same message.
	type key struct{ ch, ts string }
	seen := make(map[key]bool, len(pendingItems))
	var targets []key
	for _, item := range pendingItems {
		acctID, _, ok := watchtowerslack.SplitAccountID(item.ChannelID)
		if !ok || acctID != o.accountID {
			continue
		}
		k := key{item.ChannelID, item.MessageTS}
		if !seen[k] {
			seen[k] = true
			targets = append(targets, k)
		}
	}

	var synced int
	for _, t := range targets {
		_, rawCh, _ := watchtowerslack.SplitAccountID(t.ch)
		reactions, err := o.slackClient.GetMessageReactions(ctx, rawCh, t.ts)
		if err != nil {
			// Non-fatal: channel might be archived, message deleted, etc.
			if !isNonFatalError(err) {
				o.logger.Printf("warning: reactions.get channel=%s ts=%s: %v", t.ch, t.ts, err)
			}
			continue
		}

		if len(reactions) == 0 {
			continue
		}

		// Convert to db.Reaction and upsert.
		var dbReactions []db.Reaction
		for _, r := range reactions {
			for _, uid := range r.Users {
				dbReactions = append(dbReactions, db.Reaction{
					ChannelID: t.ch,
					MessageTS: t.ts,
					UserID:    watchtowerslack.Namespace(o.accountID, uid),
					Emoji:     r.Name,
				})
			}
		}

		tx, err := o.db.Begin()
		if err != nil {
			o.logger.Printf("warning: begin tx for inbox reactions: %v", err)
			continue
		}
		if err := o.db.UpsertReactionBatch(tx, dbReactions); err != nil {
			tx.Rollback()
			o.logger.Printf("warning: upsert inbox reactions: %v", err)
			continue
		}
		if err := tx.Commit(); err != nil {
			o.logger.Printf("warning: commit inbox reactions: %v", err)
			continue
		}
		synced++
	}

	if synced > 0 {
		o.logger.Printf("synced reactions for %d/%d pending inbox messages", synced, len(targets))
	}
}

// finishSync logs API stats, updates the sync timestamp, and marks sync as done.
func (o *Orchestrator) finishSync() error {
	o.progress.SetPhase(PhaseDone)
	counts, retries := o.slackClient.APIStats()
	total := 0
	for _, v := range counts {
		total += v
	}
	o.logger.Printf("sync complete: %d API calls (tier2: %d, tier3: %d, tier4: %d), %d retries",
		total, counts[watchtowerslack.Tier2], counts[watchtowerslack.Tier3], counts[watchtowerslack.Tier4], retries)
	o.slackClient.ResetAPIStats()

	// Auto-mark digests and tracks as read based on Slack read cursors.
	digestsMarked, tracksMarked, err := o.db.AutoMarkReadFromSlack()
	if err != nil {
		o.logger.Printf("warning: auto-mark read failed: %v", err)
	} else if digestsMarked > 0 || tracksMarked > 0 {
		o.logger.Printf("auto-marked %d digests, %d tracks as read (based on Slack read state)", digestsMarked, tracksMarked)
	}

	// Update workspace synced_at so the desktop app shows accurate "last synced" time.
	if err := o.db.TouchSyncedAt(); err != nil {
		o.logger.Printf("warning: failed to update synced_at: %v", err)
	}
	return nil
}

// ensureWorkspace loads (and, on first run, resolves via team.info) the
// connected account's team info. Skips the API call if already cached on
// the slack_accounts row.
func (o *Orchestrator) ensureWorkspace(ctx context.Context) error {
	acct, err := o.db.GetSlackAccount(o.accountID)
	if err != nil {
		return fmt.Errorf("loading slack account %d: %w", o.accountID, err)
	}
	if acct.TeamID != "" {
		o.logger.Printf("workspace: %s (%s) [cached]", acct.TeamName, acct.TeamID)
		o.account = acct
		return nil
	}

	info, err := o.slackClient.GetTeamInfo(ctx)
	if err != nil {
		return fmt.Errorf("fetching team info: %w", err)
	}
	if err := o.db.UpdateSlackAccountConnection(o.accountID, info.ID, info.Name, info.Domain, acct.CurrentUserID); err != nil {
		return fmt.Errorf("updating slack account %d: %w", o.accountID, err)
	}
	acct.TeamID, acct.TeamName, acct.TeamDomain = info.ID, info.Name, info.Domain
	o.account = acct
	o.logger.Printf("workspace: %s (%s)", acct.TeamName, acct.TeamID)
	return nil
}

// syncCurrentUser calls auth.test to identify the token owner and stores
// the namespaced user_id on slack_accounts. Errors are logged but non-fatal.
func (o *Orchestrator) syncCurrentUser(ctx context.Context) {
	authResp, err := o.slackClient.AuthTest(ctx)
	if err != nil {
		o.logger.Printf("warning: auth.test failed: %v", err)
		return
	}
	namespaced := watchtowerslack.Namespace(o.accountID, authResp.UserID)
	if err := o.db.UpdateSlackAccountConnection(o.accountID, o.account.TeamID, o.account.TeamName, o.account.TeamDomain, namespaced); err != nil {
		o.logger.Printf("warning: saving current user: %v", err)
		return
	}
	o.account.CurrentUserID = namespaced
	o.logger.Printf("current user: @%s (%s)", authResp.User, authResp.UserID)
}

// syncMetadata fetches workspace info, users, and channels from Slack and upserts into DB.
func (o *Orchestrator) syncMetadata(ctx context.Context, opts SyncOptions) error {
	// Workspace info
	teamInfo, err := o.slackClient.GetTeamInfo(ctx)
	if err != nil {
		return fmt.Errorf("fetching team info: %w", err)
	}
	if err := o.db.UpdateSlackAccountConnection(o.accountID, teamInfo.ID, teamInfo.Name, teamInfo.Domain, o.account.CurrentUserID); err != nil {
		return fmt.Errorf("updating slack account %d: %w", o.accountID, err)
	}
	o.account.TeamID, o.account.TeamName, o.account.TeamDomain = teamInfo.ID, teamInfo.Name, teamInfo.Domain
	o.logger.Printf("workspace: %s (%s)", teamInfo.Name, teamInfo.ID)

	// Identify the current user
	o.syncCurrentUser(ctx)

	// Users
	o.logger.Println("fetching users from Slack API...")
	users, err := o.slackClient.GetUsers(ctx, func(fetched int) {
		o.progress.SetMetadataUsers(fetched, 0)
	})
	if err != nil {
		return fmt.Errorf("fetching users: %w", err)
	}
	o.logger.Printf("fetched %d users, saving to DB...", len(users))
	// Filter: skip deleted and deactivated users
	var activeUsers []slack.User
	var skippedDeleted int
	for _, u := range users {
		if u.Deleted {
			skippedDeleted++
			continue
		}
		activeUsers = append(activeUsers, u)
	}
	o.logger.Printf("users: %d active, %d deleted (skipped)", len(activeUsers), skippedDeleted)

	apiUserIDs := make(map[string]bool, len(activeUsers))
	o.progress.SetMetadataUsers(len(activeUsers), 0)
	for i, u := range activeUsers {
		apiUserIDs[u.ID] = true
		tag := ""
		if u.IsBot {
			tag = " [bot]"
		}
		o.logger.Printf("  user %d/%d: @%s (%s)%s", i+1, len(activeUsers), u.Name, u.RealName, tag)
		profileJSON, err := json.Marshal(u.Profile)
		if err != nil {
			o.logger.Printf("warning: failed to marshal profile for user %s: %v", u.ID, err)
			profileJSON = []byte("{}")
		}
		if err := o.db.UpsertUser(db.User{
			ID:          watchtowerslack.Namespace(o.accountID, u.ID),
			Name:        u.Name,
			DisplayName: u.Profile.DisplayName,
			RealName:    u.RealName,
			Email:       u.Profile.Email,
			IsBot:       u.IsBot,
			IsDeleted:   false,
			ProfileJSON: string(profileJSON),
		}); err != nil {
			return fmt.Errorf("upserting user %s: %w", u.ID, err)
		}
		o.progress.SetMetadataUsers(len(activeUsers), i+1)
	}
	o.logger.Printf("users: %d saved to DB", len(activeUsers))

	// Channels — include DMs by default, skip only if --skip-dms is set
	channelTypes := []string{"public_channel", "private_channel"}
	if !opts.SkipDMs {
		channelTypes = append(channelTypes, "im", "mpim")
	}
	o.logger.Printf("fetching channels from Slack API (types: %s)...", strings.Join(channelTypes, ", "))
	channels, err := o.slackClient.GetChannels(ctx, channelTypes, func(fetched int) {
		o.progress.SetMetadataChannels(fetched, 0)
	})
	if err != nil {
		return fmt.Errorf("fetching channels: %w", err)
	}
	o.logger.Printf("fetched %d channels, saving to DB...", len(channels))

	o.progress.SetMetadataChannels(len(channels), 0)
	for i, ch := range channels {
		chType := slackChannelType(ch)
		flags := []string{chType}
		if ch.IsArchived {
			flags = append(flags, "archived")
		}
		if ch.IsMember {
			flags = append(flags, "member")
		}
		name := ch.Name
		if name == "" {
			name = ch.ID
		}
		o.logger.Printf("  channel %d/%d: #%s [%s] %d members", i+1, len(channels), name, strings.Join(flags, ","), ch.NumMembers)
		dmUserID := ch.User
		if dmUserID != "" {
			dmUserID = watchtowerslack.Namespace(o.accountID, dmUserID)
		}
		if err := o.db.UpsertChannel(db.Channel{
			ID:         watchtowerslack.Namespace(o.accountID, ch.ID),
			Name:       ch.Name,
			Type:       chType,
			Topic:      ch.Topic.Value,
			Purpose:    ch.Purpose.Value,
			IsArchived: ch.IsArchived,
			IsMember:   ch.IsMember,
			DMUserID:   sql.NullString{String: dmUserID, Valid: dmUserID != ""},
			NumMembers: ch.NumMembers,
			LastRead:   ch.LastRead,
		}); err != nil {
			return fmt.Errorf("upserting channel %s: %w", ch.ID, err)
		}
		o.progress.SetMetadataChannels(len(channels), i+1)
	}
	o.logger.Printf("channels: %d synced", len(channels))

	return nil
}

// syncMessages is implemented in message_sync.go.

// syncEmoji fetches custom workspace emojis and stores them in the database.
func (o *Orchestrator) syncEmoji(ctx context.Context) error {
	o.logger.Println("syncing custom emojis")
	emojiMap, err := o.slackClient.GetEmoji(ctx)
	if err != nil {
		return fmt.Errorf("fetching emojis: %w", err)
	}

	emojis := make([]db.CustomEmoji, 0, len(emojiMap))
	for name, value := range emojiMap {
		e := db.CustomEmoji{Name: name, URL: value}
		if target, ok := strings.CutPrefix(value, "alias:"); ok {
			e.AliasFor = target
		}
		emojis = append(emojis, e)
	}

	if err := o.db.BulkUpsertCustomEmojis(emojis); err != nil {
		return fmt.Errorf("saving emojis: %w", err)
	}

	o.logger.Printf("emojis: %d custom emojis synced", len(emojis))
	return nil
}

// nonFatalSlackErrors are Slack API error codes that should be logged but not stop the sync.
var nonFatalSlackErrors = map[string]bool{
	"channel_not_found": true,
	"account_inactive":  true,
	"is_archived":       true,
	"not_in_channel":    true,
	"missing_scope":     true,
	"access_denied":     true,
	"user_not_found":    true,
}

// isNonFatalError returns true for Slack errors that should be logged but not stop the sync.
func isNonFatalError(err error) bool {
	if err == nil {
		return false
	}
	// Rate limit errors are non-fatal; the next sync run will resume via cursor.
	var rlErr *slack.RateLimitedError
	if errors.As(err, &rlErr) {
		return true
	}
	// Check for structured Slack API errors first.
	var slackErr slack.SlackErrorResponse
	if errors.As(err, &slackErr) {
		return nonFatalSlackErrors[slackErr.Err]
	}
	// Fallback: string matching for wrapped or non-typed errors.
	// These Slack error codes are specific enough that false positives are unlikely.
	msg := err.Error()
	for code := range nonFatalSlackErrors {
		if strings.Contains(msg, code) {
			return true
		}
	}
	return false
}

// channelName returns a human-readable channel identifier for logging.
func (o *Orchestrator) channelName(id string) string {
	if name, ok := o.channelNames[id]; ok && name != "" {
		return fmt.Sprintf("#%s (%s)", name, id)
	}
	return id
}

// slackChannelType maps a Slack channel object to our type string.
func slackChannelType(ch slack.Channel) string {
	if ch.IsIM {
		return "dm"
	}
	if ch.IsMpIM {
		return "group_dm"
	}
	if ch.IsPrivate {
		return "private"
	}
	return "public"
}
