// Package inbox provides detection and AI prioritization of messages awaiting user response.
package inbox

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"log"
	"regexp"
	"strings"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

var (
	slackLinkRe     = regexp.MustCompile(`<(https?://[^|>]+)\|([^>]+)>`)
	slackURLRe      = regexp.MustCompile(`<(https?://[^>]+)>`)
	slackUserRe     = regexp.MustCompile(`<@([A-Z0-9]+)(?:\|([^>]+))?>`)
	slackChannelRe  = regexp.MustCompile(`<#[A-Z0-9]+\|([^>]+)>`)
	slackGroupRe    = regexp.MustCompile(`<!subteam\^[A-Z0-9]+(?:\|([^>]+))?>`)
	slackSpecialRe  = regexp.MustCompile(`<!([a-z_]+)(?:\|([^>]+))?>`)
	slackEmojiRe    = regexp.MustCompile(`:[a-z0-9_+-]+:`)
	slackMarkdownRe = regexp.MustCompile("(?s)```[^`]*```")

	// closingSignals is a set of short acknowledgment/closing phrases that don't need a reply.
	closingSignals = map[string]bool{
		// EN
		"thanks": true, "thank you": true, "thx": true, "ty": true,
		"got it": true, "ok": true, "okay": true, "cool": true,
		"great": true, "perfect": true, "awesome": true,
		"np": true, "no problem": true, "will do": true,
		"sounds good": true, "noted": true, "ack": true,
		// RU
		"спасибо": true, "спс": true, "ок": true,
		"понял": true, "понятно": true, "принял": true,
		"ясно": true, "хорошо": true, "отлично": true,
		"ладно": true, "круто": true, "пон": true,
		// Emoji-only
		"👍": true, "🙏": true, "🙌": true, "👌": true, "✅": true,
	}

	trailingPunctRe = regexp.MustCompile(`[.!?,;:…]+$`)
)

// isClosingSignal returns true if the message text is a short closing/acknowledgment phrase.
func isClosingSignal(text string) bool {
	s := strings.TrimSpace(text)
	if s == "" || len(s) > 80 {
		return false
	}
	// Strip trailing punctuation.
	s = trailingPunctRe.ReplaceAllString(s, "")
	s = strings.TrimSpace(s)
	s = strings.ToLower(s)
	return closingSignals[s]
}

// toWaitingJSON converts a list of user IDs to a JSON array string.
func toWaitingJSON(userIDs []string) string {
	if len(userIDs) == 0 {
		return ""
	}
	data, _ := json.Marshal(userIDs)
	return string(data)
}

// enrichSnippet strips Slack markup and resolves user mentions to real names.
func enrichSnippet(text string, database *db.DB) string {
	s := text
	s = slackMarkdownRe.ReplaceAllString(s, "")
	s = slackLinkRe.ReplaceAllString(s, "$2")
	s = slackURLRe.ReplaceAllString(s, "$1")
	// Resolve <@U123|Name> and <@U123> user mentions
	s = slackUserRe.ReplaceAllStringFunc(s, func(match string) string {
		groups := slackUserRe.FindStringSubmatch(match)
		// groups[1] = raw user ID as it appears in message text (never
		// namespaced — Slack writes it exactly as sent), groups[2] = display
		// name (may be empty)
		if groups[2] != "" {
			return "@" + groups[2]
		}
		if database != nil {
			if name, err := database.UserNameByRawID(groups[1]); err == nil && name != "" {
				return "@" + name
			}
		}
		// Unresolved (or no DB): keep the raw id rather than dropping the
		// mention — the downstream triage/compose/situation-card prompts
		// need to know someone was addressed even when the name is unknown.
		return "@" + groups[1]
	})
	// Resolve <#C123|channel-name> channel refs
	s = slackChannelRe.ReplaceAllString(s, "#$1")
	// Resolve <!subteam^S123|@team-name> group mentions
	s = slackGroupRe.ReplaceAllStringFunc(s, func(match string) string {
		groups := slackGroupRe.FindStringSubmatch(match)
		if groups[1] != "" {
			return groups[1]
		}
		return ""
	})
	// Resolve <!here|here>, <!channel|channel>, <!everyone|everyone>
	s = slackSpecialRe.ReplaceAllStringFunc(s, func(match string) string {
		groups := slackSpecialRe.FindStringSubmatch(match)
		if groups[2] != "" {
			return "@" + groups[2]
		}
		return "@" + groups[1]
	})
	s = slackEmojiRe.ReplaceAllString(s, "")
	s = html.UnescapeString(s)
	s = strings.Join(strings.Fields(s), " ")
	return strings.TrimSpace(s)
}

// DefaultLookbackDays is the default lookback for first-time inbox detection.
const DefaultLookbackDays = 7

// ProgressFunc is called during pipeline execution to report progress.
type ProgressFunc func(done, total int, status string)

// Pipeline detects and prioritizes inbox items from Slack messages.
type Pipeline struct {
	db          *db.DB
	cfg         *config.Config
	generator   digest.Generator
	logger      *log.Logger
	promptStore *prompts.Store
	OnProgress  ProgressFunc

	// Current user identity (set via SetCurrentUser or resolved from DB in Run).
	currentUserID    string
	currentUserEmail string

	// Step metrics (set before each OnProgress call).
	LastStepDurationSeconds float64
	LastStepInputTokens     int
	LastStepOutputTokens    int
	// Accumulated usage across all AI calls.
	totalInputTokens  int
	totalOutputTokens int
	totalAPITokens    int
}

// New creates a new inbox pipeline.
func New(database *db.DB, cfg *config.Config, gen digest.Generator, logger *log.Logger) *Pipeline {
	return &Pipeline{
		db:        database,
		cfg:       cfg,
		generator: gen,
		logger:    logger,
	}
}

// SetCurrentUser sets the current user identity used by the pipeline for
// per-source detectors (Jira, Calendar) and auto-resolve logic.
func (p *Pipeline) SetCurrentUser(id, email string) {
	p.currentUserID = id
	p.currentUserEmail = email
}

// SetPromptStore sets an optional prompt store for loading customized prompts.
func (p *Pipeline) SetPromptStore(store *prompts.Store) {
	p.promptStore = store
}

// AccumulatedUsage returns the total token usage accumulated across all Generate calls.
func (p *Pipeline) AccumulatedUsage() (int, int, float64, int) {
	return p.totalInputTokens, p.totalOutputTokens, 0, p.totalAPITokens
}

// accumulateUsage folds one Generate call's token usage into the pipeline's
// running totals and last-step metrics. usage may be nil (no-op).
func (p *Pipeline) accumulateUsage(usage *digest.Usage) {
	if usage == nil {
		return
	}
	p.totalInputTokens += usage.InputTokens
	p.totalOutputTokens += usage.OutputTokens
	p.totalAPITokens += usage.TotalAPITokens
	p.LastStepInputTokens = usage.InputTokens
	p.LastStepOutputTokens = usage.OutputTokens
}

// resolveCurrentUserID returns the pipeline's current user ID, preferring the
// explicitly-set identity (SetCurrentUser) and falling back to the
// DB-persisted identity.
func (p *Pipeline) resolveCurrentUserID() (string, error) {
	if p.currentUserID != "" {
		return p.currentUserID, nil
	}
	return p.db.GetCurrentUserID()
}

// resolveOwnerSlackUserIDs returns every connected, enabled Slack account's
// own user id, for excluding the owner's own messages from stream
// candidates. Distinct from resolveCurrentUserID, which stays pinned to
// account #1 for Jira/style/people-card purposes (Global Constraints #1).
func (p *Pipeline) resolveOwnerSlackUserIDs() ([]string, error) {
	return p.db.ListOwnerSlackUserIDs()
}

// resolveWatermarkWindow returns the last processed timestamp (falling back
// to now-lookbackDays for a fresh install) and the equivalent time.Time.
// logPrefix distinguishes Run's log lines from RunFastDetection's.
func (p *Pipeline) resolveWatermarkWindow(logPrefix string) (float64, time.Time) {
	lastTS, err := p.db.GetInboxLastProcessedTS()
	if err != nil {
		p.logger.Printf("%s: error getting last processed ts, using default: %v", logPrefix, err)
		lastTS = 0
	}
	lookbackDays := DefaultLookbackDays
	if p.cfg != nil && p.cfg.Inbox.InitialLookbackDays > 0 {
		lookbackDays = p.cfg.Inbox.InitialLookbackDays
	}
	if lastTS == 0 {
		lastTS = float64(time.Now().AddDate(0, 0, -lookbackDays).Unix())
	}
	return lastTS, time.Unix(int64(lastTS), 0)
}

// dedupThreadItems merges duplicate pending thread inbox items (cleanup from
// before thread-grouping). logPrefix distinguishes Run's log lines from
// RunFastDetection's.
func (p *Pipeline) dedupThreadItems(logPrefix string) {
	if deduped, err := p.db.DeduplicateThreadInboxItems(); err != nil {
		p.logger.Printf("%s: dedup error: %v", logPrefix, err)
	} else if deduped > 0 {
		p.logger.Printf("%s: merged %d duplicate thread items", logPrefix, deduped)
	}
}

// loadUntriaged returns pending inbox items that have not yet been through
// triage (no AI reason recorded).
func (p *Pipeline) loadUntriaged() ([]db.InboxItem, error) {
	pendingItems, err := p.db.GetInboxItems(db.InboxFilter{Status: "pending"})
	if err != nil {
		return nil, fmt.Errorf("loading pending items for triage: %w", err)
	}
	var newItems []db.InboxItem
	for _, item := range pendingItems {
		if item.AIReason == "" {
			newItems = append(newItems, item)
		}
	}
	return newItems, nil
}

// runTriagePhase runs triage over newItems when a generator is configured,
// recording step timing/logging identically to the inline version it replaced.
func (p *Pipeline) runTriagePhase(ctx context.Context, currentUserID string, newItems []db.InboxItem, lastTS float64) (triageOutcome, error) {
	if p.generator == nil {
		return triageOutcome{}, nil
	}
	stepStart := time.Now()
	outcome, err := p.runTriage(ctx, currentUserID, newItems, lastTS)
	p.LastStepDurationSeconds = time.Since(stepStart).Seconds()
	if err != nil {
		p.logger.Printf("inbox: triage error: %v", err)
	}
	return outcome, err
}

// runComposePhase folds new material into dashboard situations when a
// generator is configured. It mirrors runTriagePhase's nil-generator guard:
// runCompose has no internal guard and would nil-deref on real input.
// Compose failures are logged and swallowed — they never fail Run and never
// touch the inbox watermark (compose owns its own watermark, DASH-02).
func (p *Pipeline) runComposePhase(ctx context.Context, currentUserID string) (created, merged int) {
	if p.generator == nil {
		return 0, 0
	}
	stepStart := time.Now()
	created, merged, err := p.runCompose(ctx, currentUserID)
	p.LastStepDurationSeconds = time.Since(stepStart).Seconds()
	if err != nil {
		p.logger.Printf("inbox: compose error: %v", err)
	}
	return created, merged
}

// runArchiveAndUnsnooze runs phase 6: auto-archive expired ambient / stale
// actionable items and unsnooze anything whose snooze has expired, then runs
// the dashboard situation lifecycle — unsnooze expired situations and mark
// inactive open ones stale. Returns the total number of inbox items archived.
func (p *Pipeline) runArchiveAndUnsnooze() int {
	var archived int
	if n, err := p.db.ArchiveExpiredAmbient(7 * 24 * time.Hour); err != nil {
		p.logger.Printf("inbox: archive ambient error: %v", err)
	} else {
		archived += n
	}
	if n, err := p.db.ArchiveStaleActionable(14 * 24 * time.Hour); err != nil {
		p.logger.Printf("inbox: archive stale error: %v", err)
	} else {
		archived += n
	}
	if _, err := p.db.UnsnoozeExpiredInboxItems(); err != nil {
		p.logger.Printf("inbox: unsnooze error: %v", err)
	}

	// Dashboard situation lifecycle (DASH-02): non-fatal, never touches the
	// inbox watermark.
	if _, err := p.db.UnsnoozeExpiredSituations(); err != nil {
		p.logger.Printf("inbox: unsnooze situations error: %v", err)
	}
	if p.cfg != nil && p.cfg.Dashboard.StaleAfterDays > 0 {
		staleAfter := time.Duration(p.cfg.Dashboard.StaleAfterDays) * 24 * time.Hour
		if _, err := p.db.MarkStaleSituations(staleAfter); err != nil {
			p.logger.Printf("inbox: mark stale situations error: %v", err)
		}
	}
	return archived
}

// decideWatermark computes the new watermark timestamp per INBOX-09 (see
// docs/inventory/inbox-pulse.md). A detector error ALWAYS freezes the
// watermark, even when triage capped or made partial progress: detectors and
// triage scan the same ts window, so advancing over triage's progress would
// still skip the mentions/DMs the failed detector never saw. Only when
// detection is clean may triage outcomes move the watermark — over exactly
// what was processed (capped scan, or the chunks completed before a triage
// failure), never below lastTS. ok is false when the watermark must stay
// frozen.
func decideWatermark(lastTS float64, detectErr, triageErr error, outcome triageOutcome) (ts float64, ok bool) {
	switch {
	case detectErr != nil:
		return 0, false
	case triageErr != nil:
		if outcome.MaxProcessedTS > lastTS {
			return outcome.MaxProcessedTS, true
		}
		return 0, false
	case outcome.Capped:
		return outcome.MaxProcessedTS, true
	default:
		// Use a 30-minute buffer instead of wall-clock time to account for
		// Slack search API indexing delays — messages may arrive in the DB
		// with ts_unix values behind wall-clock time.
		return float64(time.Now().Add(-30 * time.Minute).Unix()), true
	}
}

// Run executes the inbox pipeline: dedup, detect new items, triage (trigger
// items plus a stream scan), learn, auto-resolve, compose dashboard situations
// from the new signals, prepare situation cards, auto-archive, then unsnooze.
// Returns (created count, resolved count, error). Compose and situation-card
// failures are logged but never fail Run and never affect the inbox watermark
// (INBOX-09 stays keyed to detect/triage only; feed stability is DASH-02).
func (p *Pipeline) Run(ctx context.Context) (int, int, error) {
	// Reset accumulated usage from previous run (pipeline is reused across daemon cycles).
	p.totalInputTokens = 0
	p.totalOutputTokens = 0
	p.totalAPITokens = 0

	if p.cfg != nil && !p.cfg.Inbox.Enabled {
		return 0, 0, nil
	}

	currentUserID, err := p.resolveCurrentUserID()
	if err != nil {
		return 0, 0, fmt.Errorf("getting current user: %w", err)
	}
	if currentUserID == "" {
		p.logger.Println("inbox: no current user set, skipping")
		return 0, 0, nil
	}

	lastTS, sinceTime := p.resolveWatermarkWindow("inbox")

	const totalSteps = 7

	// Phase 0: Deduplicate existing thread inbox items (cleanup from before thread-grouping).
	p.dedupThreadItems("inbox")

	// Phase 1: Detection — Slack + external sources (individually non-fatal, but a
	// failure freezes/partially advances the watermark below so no window is skipped).
	p.progress(1, totalSteps, "detecting")
	stepStart := time.Now()
	createdSlack, createdJira, createdCalendar, createdGmail, createdImap, createdWatchtower, detectErr := p.detectAll(ctx, currentUserID, lastTS, sinceTime, true)
	created := createdSlack + createdJira + createdCalendar + createdGmail + createdImap + createdWatchtower
	p.LastStepDurationSeconds = time.Since(stepStart).Seconds()

	// Phase 2: Triage — the secretary reviews every new trigger item plus a
	// full scan of ordinary channel traffic (INBOX-01/INBOX-03).
	p.progress(2, totalSteps, "triaging")
	newItems, err := p.loadUntriaged()
	if err != nil {
		return created, 0, err
	}
	outcome, triageErr := p.runTriagePhase(ctx, currentUserID, newItems, lastTS)
	created += outcome.Created

	// Phase 3: Implicit learning — update mute rules from dismiss patterns.
	p.progress(3, totalSteps, "learning")
	var learnedRuleUpdates int
	if n, err := RunImplicitLearner(ctx, p.db, 30*24*time.Hour); err != nil {
		p.logger.Printf("inbox: learner error: %v", err)
	} else {
		learnedRuleUpdates = n
	}

	// Phase 4: Auto-resolve — rule-based resolution for all source types.
	p.progress(4, totalSteps, "auto-resolving")
	stepStart = time.Now()
	resolved := p.autoResolveByRules(ctx, currentUserID)
	p.LastStepDurationSeconds = time.Since(stepStart).Seconds()

	// Phase 5: Compose — fold new triaged signals, track events, and target
	// updates into dashboard situations (create / merge / rerank), then write a
	// secretary card (summary / why-it-matters / chronology) for each situation
	// that needs one. Both stages are non-fatal: per-situation card failures are
	// recorded and retried next cycle, and neither stage touches the inbox
	// watermark (DASH-02). Situation cards share this progress slot with compose.
	p.progress(5, totalSteps, "composing")
	composeCreated, composeMerged := p.runComposePhase(ctx, currentUserID)
	cardsGenerated, cardErr := p.runSituationCards(ctx, currentUserID)
	if cardErr != nil {
		p.logger.Printf("inbox: situation cards error: %v", cardErr)
	}

	// Phase 6: Auto-archive expired/stale items, unsnooze expired snoozes, and
	// run the dashboard situation lifecycle (unsnooze / mark-stale).
	p.progress(6, totalSteps, "archiving")
	archived := p.runArchiveAndUnsnooze()

	// Watermark decision — see docs/inventory/inbox-pulse.md INBOX-09.
	if ts, ok := decideWatermark(lastTS, detectErr, triageErr, outcome); ok {
		p.advanceWatermark(ts, lastTS)
	} else {
		p.logger.Printf("inbox: detector/triage error, leaving watermark unchanged to avoid losing the skipped window (detectErr=%v triageErr=%v)", detectErr, triageErr)
	}

	p.progress(totalSteps, totalSteps, "done")

	p.logger.Printf("inbox: +%d new (S%d J%d C%d G%d M%d I%d T%d), %d auto-resolved, situations +%d/~%d, %d cards, %d auto-archived, %d learned-rule-updates",
		created, createdSlack, createdJira, createdCalendar, createdGmail, createdImap, createdWatchtower, outcome.Created,
		resolved, composeCreated, composeMerged, cardsGenerated, archived, learnedRuleUpdates)

	// detectErr is logged but non-fatal (existing behavior, guarded by
	// TestInbox09_WatermarkFrozenOnDetectorError); triageErr is surfaced to
	// the caller, joined with detectErr when both occurred.
	var runErr error
	if triageErr != nil {
		runErr = errors.Join(detectErr, triageErr)
	}
	return created, resolved, runErr
}

// advanceWatermark sets the inbox watermark to ts, clamped so it never moves
// backwards past lastTS.
func (p *Pipeline) advanceWatermark(ts, lastTS float64) {
	if ts < lastTS {
		ts = lastTS
	}
	if err := p.db.SetInboxLastProcessedTS(ts); err != nil {
		p.logger.Printf("inbox: error updating last processed ts: %v", err)
	}
}

// RunFastDetection runs a lightweight subset of the pipeline: dedup, Slack/Jira/
// Calendar detection and rule-based auto-resolve. It skips the digest-dependent
// decision_made/briefing_ready detector, the implicit learner, triage, compose
// and situation cards, archival, and the watermark advance — all of which the
// full Run still performs afterwards. Fast-detected items surface as actionable/medium (the
// CreateInboxItem default) until the next full Run triages them.
//
// This lets the daemon surface DMs/mentions in the UI immediately after a Slack
// sync, instead of waiting for the LLM-heavy digest+tracks phases to finish.
func (p *Pipeline) RunFastDetection(ctx context.Context) error {
	if p.cfg != nil && !p.cfg.Inbox.Enabled {
		return nil
	}

	currentUserID, err := p.resolveCurrentUserID()
	if err != nil {
		return fmt.Errorf("getting current user: %w", err)
	}
	if currentUserID == "" {
		return nil
	}

	lastTS, sinceTime := p.resolveWatermarkWindow("inbox fast")

	p.dedupThreadItems("inbox fast")

	// RunFastDetection never advances the watermark (the full Run owns that), so
	// a detector error is already surfaced via the per-detector logs inside
	// detectAll; no watermark gating is needed here.
	createdSlack, createdJira, createdCalendar, createdGmail, createdImap, _, _ := p.detectAll(ctx, currentUserID, lastTS, sinceTime, false)
	created := createdSlack + createdJira + createdCalendar + createdGmail + createdImap

	resolved := p.autoResolveByRules(ctx, currentUserID)

	p.logger.Printf("inbox fast: +%d new (S%d J%d C%d G%d M%d), %d auto-resolved",
		created, createdSlack, createdJira, createdCalendar, createdGmail, createdImap, resolved)

	return nil
}

// detectAll runs the per-source detectors and returns counts. When
// includeWatchtower is false, the watchtower-internal detector
// (decision_made / briefing_ready, depends on digests + briefings) is skipped —
// used by RunFastDetection so it can run before the digest pipeline.
// The returned error is non-nil if any detector failed; callers use it to gate
// the watermark advance so a failed pass does not skip its message window.
func (p *Pipeline) detectAll(ctx context.Context, currentUserID string, lastTS float64, sinceTime time.Time, includeWatchtower bool) (slack, jira, cal, gmail, imapCount, wt int, err error) {
	var errs []error
	if n, e := p.detectSlackTriggers(ctx, currentUserID, lastTS); e != nil {
		p.logger.Printf("inbox: slack detect error: %v", e)
		errs = append(errs, fmt.Errorf("slack: %w", e))
	} else {
		slack = n
	}
	if n, e := DetectJira(ctx, p.db, currentUserID, sinceTime); e != nil {
		p.logger.Printf("inbox: jira detect error: %v", e)
		errs = append(errs, fmt.Errorf("jira: %w", e))
	} else {
		jira = n
	}
	if n, e := DetectCalendar(ctx, p.db, p.currentUserEmail, sinceTime); e != nil {
		p.logger.Printf("inbox: calendar detect error: %v", e)
		errs = append(errs, fmt.Errorf("calendar: %w", e))
	} else {
		cal = n
	}
	if n, e := DetectGmailAccounts(ctx, p.db, sinceTime); e != nil {
		p.logger.Printf("inbox: gmail detect error: %v", e)
		errs = append(errs, fmt.Errorf("gmail: %w", e))
	} else {
		gmail = n
	}
	if n, e := DetectImapAccounts(ctx, p.db, sinceTime); e != nil {
		p.logger.Printf("inbox: imap detect error: %v", e)
		errs = append(errs, fmt.Errorf("imap: %w", e))
	} else {
		imapCount = n
	}
	if includeWatchtower {
		if n, e := DetectWatchtowerInternal(ctx, p.db, sinceTime); e != nil {
			p.logger.Printf("inbox: watchtower detect error: %v", e)
			errs = append(errs, fmt.Errorf("watchtower: %w", e))
		} else {
			wt = n
		}
		// Memory dispute reader ("the arguing secretary"): dispute_pending
		// beliefs become ordinary decision_made items, gated dark by default.
		// An error here freezes the watermark exactly like any other detector
		// (INBOX-09) — it is joined into errs.
		disputesEnabled := p.cfg != nil && p.cfg.Memory.Surfaces.Disputes
		if n, e := detectMemoryDisputes(p.db, disputesEnabled); e != nil {
			p.logger.Printf("inbox: memory dispute detect error: %v", e)
			errs = append(errs, fmt.Errorf("memory-dispute: %w", e))
		} else {
			wt += n
		}
	}
	return slack, jira, cal, gmail, imapCount, wt, errors.Join(errs...)
}

// detectSlackTriggers detects @mentions, DMs, thread replies and reactions from Slack messages.
// Returns the count of newly created inbox items.
func (p *Pipeline) detectSlackTriggers(ctx context.Context, currentUserID string, lastTS float64) (int, error) {
	mentions, err := p.db.FindPendingMentions(currentUserID, lastTS)
	if err != nil {
		return 0, fmt.Errorf("finding mentions: %w", err)
	}

	dms, err := p.db.FindPendingDMs(currentUserID, lastTS)
	if err != nil {
		return 0, fmt.Errorf("finding DMs: %w", err)
	}

	threadReplies, err := p.db.FindThreadRepliesToUser(currentUserID, lastTS)
	if err != nil {
		p.logger.Printf("inbox: error finding thread replies: %v", err)
	}

	reactions, err := p.db.FindReactionRequests(currentUserID, lastTS)
	if err != nil {
		p.logger.Printf("inbox: error finding reaction requests: %v", err)
	}

	candidates := append(mentions, dms...)
	candidates = append(candidates, threadReplies...)
	candidates = append(candidates, reactions...)

	// Group by (channel, thread): keep latest message + collect all unique senders.
	// Non-threaded messages (ThreadTS="") are grouped by channel using key (channelID, "").
	type threadKey struct{ channelID, threadTS string }
	type threadGroup struct {
		latest  db.InboxCandidate
		senders map[string]bool
	}
	threadGroups := make(map[threadKey]*threadGroup)
	for _, c := range candidates {
		key := threadKey{c.ChannelID, c.ThreadTS}
		grp, ok := threadGroups[key]
		if !ok {
			grp = &threadGroup{latest: c, senders: map[string]bool{c.SenderUserID: true}}
			threadGroups[key] = grp
		} else {
			grp.senders[c.SenderUserID] = true
			if c.TSUnix > grp.latest.TSUnix {
				grp.latest = c
			}
		}
	}

	created := 0
	for _, grp := range threadGroups {
		c := grp.latest
		snippet := enrichSnippet(c.Text, p.db)
		if snippet == "" {
			continue
		}

		// Pre-filter: skip closing signals ("thanks", "ok", etc.) when user already replied before.
		if isClosingSignal(c.Text) {
			repliedBefore, _ := p.db.CheckUserRepliedBefore(currentUserID, c.ChannelID, c.MessageTS, c.ThreadTS)
			if repliedBefore {
				continue
			}
		}

		if len(snippet) > 500 {
			snippet = snippet[:500] + "..."
		}
		itemCtx := p.loadContext(c.ChannelID, c.MessageTS, c.ThreadTS)

		var senderList []string
		for uid := range grp.senders {
			senderList = append(senderList, uid)
		}
		waitingJSON := toWaitingJSON(senderList)

		existingID, _ := p.db.FindPendingInboxByThread(c.ChannelID, c.ThreadTS)
		if existingID > 0 {
			if err := p.db.UpdateInboxItemSnippet(existingID, c.MessageTS, c.SenderUserID, snippet, itemCtx, c.Text, c.Permalink); err != nil {
				p.logger.Printf("inbox: error updating thread item %d: %v", existingID, err)
			}
			if err := p.db.MergeWaitingUserIDs(existingID, senderList); err != nil {
				p.logger.Printf("inbox: error merging waiting users for item %d: %v", existingID, err)
			}
			continue
		}

		_, err := p.db.CreateInboxItem(db.InboxItem{
			ChannelID:      c.ChannelID,
			MessageTS:      c.MessageTS,
			ThreadTS:       c.ThreadTS,
			SenderUserID:   c.SenderUserID,
			TriggerType:    c.TriggerType,
			Snippet:        snippet,
			Context:        itemCtx,
			RawText:        c.Text,
			Permalink:      c.Permalink,
			WaitingUserIDs: waitingJSON,
		})
		if err != nil {
			if strings.Contains(err.Error(), "UNIQUE") {
				continue
			}
			p.logger.Printf("inbox: error creating item: %v", err)
			continue
		}
		created++
	}

	p.logger.Printf("inbox: slack detected %d mentions, %d DMs, %d thread replies, %d reactions → %d created",
		len(mentions), len(dms), len(threadReplies), len(reactions), created)
	return created, nil
}

// loadContext loads thread or channel context for an inbox item.
func (p *Pipeline) loadContext(channelID, messageTS, threadTS string) string {
	var msgs []struct {
		UserID string
		Text   string
	}
	var err error

	if threadTS != "" {
		msgs, err = p.db.GetThreadContext(channelID, threadTS, 10)
	} else {
		msgs, err = p.db.GetChannelContextBefore(channelID, messageTS, 5)
	}
	if err != nil || len(msgs) == 0 {
		return ""
	}

	var sb strings.Builder
	for _, m := range msgs {
		name, _ := p.db.UserNameByID(m.UserID)
		if name == "" {
			name = m.UserID
		}
		line := enrichSnippet(m.Text, p.db)
		if line == "" {
			continue
		}
		if len(line) > 200 {
			line = line[:200] + "..."
		}
		sb.WriteString(fmt.Sprintf("[%s] %s\n", name, line))
	}
	result := strings.TrimSpace(sb.String())
	if len(result) > 2000 {
		result = result[:2000] + "..."
	}
	return result
}

// progress is a helper that calls OnProgress if set.
func (p *Pipeline) progress(done, total int, status string) {
	if p.OnProgress != nil {
		p.OnProgress(done, total, status)
	}
}

func (p *Pipeline) getPrompt(id string) (string, int) {
	if p.promptStore != nil {
		tmpl, version, err := p.promptStore.Get(id)
		if err == nil {
			return tmpl, version
		}
	}
	return prompts.Defaults[id], 0
}

// autoResolveByRules runs all rule-based auto-resolve checks across Slack,
// Jira, and Calendar sources. Returns the total number of items resolved.
func (p *Pipeline) autoResolveByRules(ctx context.Context, currentUserID string) int {
	resolved := 0
	resolved += p.autoResolveSlack(ctx, currentUserID)
	resolved += p.autoResolveJira(ctx)
	resolved += p.autoResolveCalendar(ctx)
	return resolved
}

// autoResolveSlack resolves pending Slack inbox items where the current user
// has already replied in the thread or channel.
func (p *Pipeline) autoResolveSlack(ctx context.Context, currentUserID string) int {
	items, err := p.db.GetInboxItems(db.InboxFilter{Status: "pending"})
	if err != nil {
		p.logger.Printf("inbox: autoResolveSlack: loading items: %v", err)
		return 0
	}
	resolved := 0
	for _, item := range items {
		// Only Slack-sourced items: trigger types that come from Slack messages.
		switch item.TriggerType {
		case "mention", "dm", "thread_reply", "reaction_request":
		default:
			continue
		}
		replied, err := p.db.CheckUserReplied(currentUserID, item.ChannelID, item.MessageTS, item.ThreadTS)
		if err != nil {
			p.logger.Printf("inbox: error checking reply for item %d: %v", item.ID, err)
			continue
		}
		if replied {
			if err := p.db.ResolveInboxItem(item.ID, "User replied"); err != nil {
				p.logger.Printf("inbox: error resolving item %d: %v", item.ID, err)
				continue
			}
			resolved++
		}
	}
	return resolved
}

// autoResolveJira resolves pending jira_comment_mention and jira_assigned items
// when the current user has authored a comment on the issue after the item was created.
// If the jira_comments table does not exist, or the current user has no
// mapped Atlassian account id (jira_user_map), this method is a no-op.
func (p *Pipeline) autoResolveJira(_ context.Context) int {
	if !jiraCommentsTableExists(p.db) {
		return 0
	}
	if p.currentUserID == "" {
		return 0
	}
	atlassianIDs := atlassianIDsForUser(p.db, p.currentUserID)
	if len(atlassianIDs) == 0 {
		return 0
	}

	// Drain cursor before any secondary queries (SQLite single-connection deadlock).
	rows, err := p.db.Query(`SELECT id, channel_id, created_at FROM inbox_items
		WHERE trigger_type IN ('jira_comment_mention','jira_assigned') AND status='pending'`)
	if err != nil {
		p.logger.Printf("inbox: autoResolveJira: query: %v", err)
		return 0
	}
	defer rows.Close()
	type candidate struct {
		id        int64
		issueKey  string
		createdAt string
	}
	var candidates []candidate
	for rows.Next() {
		var c candidate
		if err := rows.Scan(&c.id, &c.issueKey, &c.createdAt); err != nil {
			p.logger.Printf("inbox: autoResolveJira: scan: %v", err)
			return 0
		}
		candidates = append(candidates, c)
	}

	// The two timestamps being compared come from different writers in
	// different formats: jira_comments.created_at is Jira Cloud's own dotted
	// -millisecond shape ("...T10:00:00.000+0000"), inbox_items.created_at is
	// RFC3339 ("...T10:00:00Z"). A SQL string compare between them is
	// meaningless — '.' (0x2E) sorts below 'Z' (0x5A), so a comment would
	// have to be a whole second newer to register at all, and one in the same
	// second never would. Both sides are parsed in Go instead
	// (db.ParseJiraTime accepts either format).
	latestByIssue := p.latestOwnJiraCommentPerIssue(atlassianIDs)

	resolved := 0
	for _, c := range candidates {
		itemTS, ok := db.ParseJiraTime(c.createdAt)
		if !ok {
			continue
		}
		if commentTS, found := latestByIssue[c.issueKey]; !found || commentTS < itemTS {
			continue
		}
		if _, err := p.db.Exec(`UPDATE inbox_items SET status='resolved', resolved_reason='User commented on issue', updated_at=? WHERE id=?`,
			time.Now().UTC().Format(time.RFC3339), c.id); err != nil {
			p.logger.Printf("inbox: autoResolveJira: update item %d: %v", c.id, err)
			continue
		}
		resolved++
	}
	return resolved
}

// latestOwnJiraCommentPerIssue returns, per issue key, the unix time of the
// newest comment authored by any of the given Atlassian account ids. One
// fully-drained query up front, so the caller's loop issues no reads at all
// (the MaxOpenConns(1) SQLite deadlock rule). An unparseable timestamp is
// skipped, matching ParseJiraTime's defensive-skip contract.
func (p *Pipeline) latestOwnJiraCommentPerIssue(atlassianIDs []string) map[string]int64 {
	placeholders := make([]string, len(atlassianIDs))
	args := make([]any, len(atlassianIDs))
	for i, id := range atlassianIDs {
		placeholders[i] = "?"
		args[i] = id
	}

	rows, err := p.db.Query(fmt.Sprintf(`SELECT issue_key, created_at FROM jira_comments
		WHERE author_account_id IN (%s)`, strings.Join(placeholders, ",")), args...)
	if err != nil {
		p.logger.Printf("inbox: autoResolveJira: comment query: %v", err)
		return nil
	}
	defer rows.Close()

	latest := map[string]int64{}
	for rows.Next() {
		var issueKey, createdAt string
		if err := rows.Scan(&issueKey, &createdAt); err != nil {
			p.logger.Printf("inbox: autoResolveJira: comment scan: %v", err)
			return latest
		}
		ts, ok := db.ParseJiraTime(createdAt)
		if !ok {
			continue
		}
		if cur, seen := latest[issueKey]; !seen || ts > cur {
			latest[issueKey] = ts
		}
	}
	return latest
}

// autoResolveCalendar resolves pending calendar_invite and calendar_time_change
// items when the current user's RSVP status is no longer 'needsAction'.
func (p *Pipeline) autoResolveCalendar(_ context.Context) int {
	if p.currentUserEmail == "" {
		return 0
	}

	// Drain cursor before any secondary queries (SQLite single-connection deadlock).
	rows, err := p.db.Query(`SELECT id, channel_id FROM inbox_items
		WHERE trigger_type IN ('calendar_invite','calendar_time_change') AND status='pending'`)
	if err != nil {
		p.logger.Printf("inbox: autoResolveCalendar: query: %v", err)
		return 0
	}
	defer rows.Close()
	type candidate struct {
		id      int64
		eventID string
	}
	var candidates []candidate
	for rows.Next() {
		var c candidate
		if err := rows.Scan(&c.id, &c.eventID); err != nil {
			p.logger.Printf("inbox: autoResolveCalendar: scan: %v", err)
			return 0
		}
		candidates = append(candidates, c)
	}

	resolved := 0
	for _, c := range candidates {
		var att string
		p.db.QueryRow(`SELECT attendees FROM calendar_events WHERE id=?`, c.eventID).Scan(&att) //nolint:errcheck
		var list []calAttendee
		_ = json.Unmarshal([]byte(att), &list)
		for _, a := range list {
			if a.Email == p.currentUserEmail && a.RSVPStatus != "needsAction" && a.RSVPStatus != "" {
				if _, err := p.db.Exec(`UPDATE inbox_items SET status='resolved', resolved_reason='User responded to invite', updated_at=? WHERE id=?`,
					time.Now().UTC().Format(time.RFC3339), c.id); err != nil {
					p.logger.Printf("inbox: autoResolveCalendar: update item %d: %v", c.id, err)
				} else {
					resolved++
				}
				break
			}
		}
	}
	return resolved
}
