// Package digest provides digest generation and pipeline for summarizing workspace conversations.
package digest

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"runtime/debug"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/prompts"
	watchtowerslack "watchtower/internal/slack"
)

// Usage holds token metrics from an AI generation call.
type Usage struct {
	InputTokens    int     // Our prompt tokens (estimated from prompt size)
	OutputTokens   int     // AI response tokens
	CostUSD        float64 // Deprecated: always 0. Kept for struct compatibility.
	TotalAPITokens int     // Total tokens API processed (input + cache_read + cache_creation)
	Model          string  // Actual model used for this call
}

// Generator generates text responses from a system prompt and user message.
// The default implementation calls Claude CLI; tests can substitute a mock.
// sessionID may be empty for the first call; the returned sessionID should be
// passed to subsequent calls to reuse the same Claude session.
type Generator interface {
	Generate(ctx context.Context, systemPrompt, userMessage, sessionID string) (string, *Usage, string, error)
}

// DigestResult is the structured output from Claude for a digest.
type DigestResult struct {
	Summary        string          `json:"summary"`
	Topics         []Topic         `json:"topics"`
	RunningSummary json.RawMessage `json:"running_summary,omitempty"`
}

// Topic is a self-contained thematic unit within a digest.
// Each topic carries its own decisions, action items, situations, and key messages.
type Topic struct {
	Title       string          `json:"title"`
	Summary     string          `json:"summary"`
	Decisions   []Decision      `json:"decisions"`
	ActionItems []ActionItem    `json:"action_items"`
	Situations  []db.Situation  `json:"situations"`
	KeyMessages []string        `json:"key_messages"`
	Ideas       []IdeaCandidate `json:"ideas"`
}

// DigestSituationParticipant mirrors db.SituationParticipant for JSON parsing.
// Re-exported here for convenience in tests that build DigestResults.
type DigestSituationParticipant = db.SituationParticipant

// PersonSignals holds signals for one person in a channel digest.
type PersonSignals struct {
	UserID  string   `json:"user_id"`
	Signals []Signal `json:"signals"`
}

// Signal is a typed observation about a person in channel context.
type Signal struct {
	Type       string `json:"type"`
	Detail     string `json:"detail"`
	EvidenceTS string `json:"evidence_ts,omitempty"`
}

// Decision represents a decision extracted from messages.
type Decision struct {
	Text       string `json:"text"`
	By         string `json:"by"`
	MessageTS  string `json:"message_ts"`
	ChannelID  string `json:"channel_id,omitempty"` // source channel for cross-channel digests
	Importance string `json:"importance"`           // "high", "medium", "low"
}

// ActionItem represents an action item extracted from messages.
type ActionItem struct {
	Text     string `json:"text"`
	Assignee string `json:"assignee"`
	Status   string `json:"status"`
}

// IdeaCandidate represents a proposal — something new suggested but not (yet)
// decided — extracted from messages. Stage-1 material for the ideas registry.
type IdeaCandidate struct {
	Text      string `json:"text"`
	By        string `json:"by"`
	MessageTS string `json:"message_ts"`
}

// TrackLinker runs the tracks pipeline between channel digests and rollups.
// Defined as an interface to avoid import cycles (tracks imports digest).
type TrackLinker interface {
	Run(ctx context.Context) (int, int, error)
	FormatActiveTracksForPrompt() (string, error)
}

// ProgressFunc is called during digest generation to report progress.
type ProgressFunc func(done, total int, status string)

// learnedPrefs loads this pipeline's learned rules (derived from catch-up
// review feedback) and formats them for the prompt. Best-effort: returns "" on
// error so digest generation is never blocked by rule lookup failures.
func (p *Pipeline) learnedPrefs() string {
	rules, err := p.db.ListLearnedRulesByPipeline("digest", 20)
	if err != nil {
		if p.logger != nil {
			p.logger.Printf("digest: warning: load learned rules failed: %v", err)
		}
		return ""
	}
	return LearnedPreferencesBlock(rules)
}

// Pipeline generates and stores AI digests for Slack channels.
type Pipeline struct {
	db          *db.DB
	cfg         *config.Config
	generator   Generator
	logger      *log.Logger
	promptStore *prompts.Store

	// SinceOverride, if non-zero, overrides the automatic "since last digest"
	// window. Used by `digest generate --since` to force a custom time range.
	SinceOverride float64

	// OnProgress is called to report progress during digest generation.
	OnProgress ProgressFunc

	// TrackContext is injected by the daemon after tracks pipeline runs.
	// If non-empty, it's prepended to the daily/weekly rollup prompt to make
	// rollups track-aware (collapsing tracked topics instead of repeating them).
	TrackContext string

	// TrackLinker, if set, runs tracks pipeline between channel digests and rollups.
	// Used by `digest generate` to replicate the daemon's phased pipeline.
	TrackLinker TrackLinker

	// accumulated usage across all Generate calls (atomic for concurrent workers)
	totalInputTokens  atomic.Int64
	totalOutputTokens atomic.Int64
	totalAPITokens    atomic.Int64 // total API tokens (our content + CLI overhead)

	// accumulated stats across all channel digests (atomic for concurrent workers)
	totalMessageCount  atomic.Int64
	earliestPeriodFrom atomic.Int64 // unix timestamp
	latestPeriodTo     atomic.Int64 // unix timestamp

	// LastStep* fields are set before each OnProgress callback with the
	// current step's message count and time window. Read them in OnProgress.
	// Protected by lastStepMu for concurrent worker access.
	lastStepMu              sync.Mutex
	LastStepMessageCount    int
	LastStepPeriodFrom      time.Time
	LastStepPeriodTo        time.Time
	LastStepDurationSeconds float64
	LastStepInputTokens     int
	LastStepOutputTokens    int

	// caches populated during a run
	channelNames map[string]string
	channelTypes map[string]string // channel ID → type (public, private, dm, group_dm)
	userNames    map[string]string
	botUserIDs   map[string]bool // user IDs that are bots
	profile      *db.UserProfile // loaded once per Run, nil if not available

	// jiraKeyDetector, if set, detects Jira keys in digest decisions.
	jiraKeyDetector interface {
		ProcessDigestDecision(digestID int, channelID string, decisionText string) (int, error)
	}
}

// SetJiraKeyDetector sets an optional Jira key detector for linking digest decisions to Jira issues.
func (p *Pipeline) SetJiraKeyDetector(detector interface {
	ProcessDigestDecision(digestID int, channelID string, decisionText string) (int, error)
}) {
	p.jiraKeyDetector = detector
}

// AccumulatedUsage returns the total token usage accumulated across all Generate calls.
// Returns (inputTokens, outputTokens, costUSD, overheadTokens).
func (p *Pipeline) AccumulatedUsage() (int, int, float64, int) {
	return int(p.totalInputTokens.Load()), int(p.totalOutputTokens.Load()), 0, int(p.totalAPITokens.Load())
}

// AccumulatedStats returns (totalMessageCount, earliestPeriodFrom, latestPeriodTo)
// accumulated across all channel digest runs.
func (p *Pipeline) AccumulatedStats() (int, float64, float64) {
	return int(p.totalMessageCount.Load()), float64(p.earliestPeriodFrom.Load()), float64(p.latestPeriodTo.Load())
}

func (p *Pipeline) accumulateUsage(usage *Usage) {
	if usage == nil {
		return
	}
	p.totalInputTokens.Add(int64(usage.InputTokens))
	p.totalOutputTokens.Add(int64(usage.OutputTokens))
	p.totalAPITokens.Add(int64(usage.TotalAPITokens))
}

// New creates a new digest pipeline.
func New(database *db.DB, cfg *config.Config, gen Generator, logger *log.Logger) *Pipeline {
	return &Pipeline{
		db:        database,
		cfg:       cfg,
		generator: gen,
		logger:    logger,
	}
}

// SetPromptStore sets an optional prompt store for loading customized prompts.
// If not set, built-in defaults are used.
func (p *Pipeline) SetPromptStore(store *prompts.Store) {
	p.promptStore = store
}

// getPrompt loads a prompt template from the store (if set), falling back to the
// built-in const. Returns the template string and its version (0 = built-in).
// Includes role-specific instructions if available.
func (p *Pipeline) getPrompt(id, fallback string) (string, int) {
	role := ""
	if p.profile != nil {
		role = p.profile.Role
	}

	if p.promptStore != nil {
		tmpl, version, err := p.promptStore.GetForRole(id, role)
		if err == nil {
			// Prepend role instruction if available
			roleInstr := prompts.GetRoleInstruction(role)
			if roleInstr != "" {
				tmpl = roleInstr + "\n\n" + tmpl
			}
			return tmpl, version
		}
	}

	// Fallback to default
	tmpl := fallback
	roleInstr := prompts.GetRoleInstruction(role)
	if roleInstr != "" {
		tmpl = roleInstr + "\n\n" + tmpl
	}
	return tmpl, 0
}

// acquireDigestLock acquires an exclusive file lock to prevent concurrent digest runs.
// Returns the lock file (caller must defer Close) and unlock func, or error if already locked.
func (p *Pipeline) acquireDigestLock() (*os.File, func(), error) {
	lockPath := filepath.Join(p.cfg.WorkspaceDir(), "digest.lock")
	if err := os.MkdirAll(filepath.Dir(lockPath), 0o755); err != nil {
		return nil, nil, fmt.Errorf("creating lock dir: %w", err)
	}
	f, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, nil, fmt.Errorf("opening digest lock: %w", err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, nil, fmt.Errorf("another digest pipeline is already running")
	}
	unlock := func() {
		_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		f.Close()
	}
	return f, unlock, nil
}

// Run executes the full digest pipeline: channel digests, then daily rollup.
// Returns the number of channel digests generated and total token usage.
func (p *Pipeline) Run(ctx context.Context) (int, *Usage, error) {
	// Reset accumulated usage from previous run (pipeline is reused across daemon cycles).
	p.totalInputTokens.Store(0)
	p.totalOutputTokens.Store(0)
	p.totalAPITokens.Store(0)

	if !p.cfg.Digest.Enabled {
		return 0, nil, nil
	}

	_, unlock, err := p.acquireDigestLock()
	if err != nil {
		p.logger.Printf("digest: skipping — %v", err)
		return 0, nil, nil
	}
	defer unlock()

	// Clean up duplicate digests from near-simultaneous pipeline runs
	var totalDeduped int64
	if removed, err := p.db.DeduplicateChannelDigests(); err != nil {
		p.logger.Printf("digest: warning: channel dedup cleanup failed: %v", err)
	} else {
		totalDeduped += removed
	}
	if removed, err := p.db.DeduplicateDailyDigests(); err != nil {
		p.logger.Printf("digest: warning: dedup cleanup failed: %v", err)
	} else {
		totalDeduped += removed
	}
	if totalDeduped > 0 {
		p.logger.Printf("digest: cleaned up %d duplicate digests", totalDeduped)
	}

	p.loadCaches()

	n, totalUsage, err := p.RunChannelDigests(ctx)
	if err != nil {
		return n, totalUsage, err
	}

	if ctx.Err() != nil {
		return n, totalUsage, ctx.Err()
	}

	if p.OnProgress != nil {
		p.OnProgress(0, 0, "Creating tracks...")
	}
	p.runTrackLinker(ctx)

	if p.OnProgress != nil {
		p.OnProgress(0, 0, "Generating daily rollup...")
	}
	if err := p.RunDailyRollup(ctx); err != nil {
		p.logger.Printf("digest: daily rollup error: %v", err)
	}

	return n, totalUsage, nil
}

// RunChannelDigestsOnly runs only channel-level digests (no rollups).
// Used by daemon to split channel digests from rollups with chains in between.
func (p *Pipeline) RunChannelDigestsOnly(ctx context.Context) (int, *Usage, error) {
	// Reset accumulated usage from previous run (pipeline is reused across daemon cycles).
	p.totalInputTokens.Store(0)
	p.totalOutputTokens.Store(0)
	p.totalAPITokens.Store(0)

	if !p.cfg.Digest.Enabled {
		return 0, nil, nil
	}

	_, unlock, err := p.acquireDigestLock()
	if err != nil {
		p.logger.Printf("digest: skipping — %v", err)
		return 0, nil, nil
	}
	defer unlock()

	var totalDeduped int64
	if removed, err := p.db.DeduplicateChannelDigests(); err != nil {
		p.logger.Printf("digest: warning: channel dedup cleanup failed: %v", err)
	} else {
		totalDeduped += removed
	}
	if removed, err := p.db.DeduplicateDailyDigests(); err != nil {
		p.logger.Printf("digest: warning: dedup cleanup failed: %v", err)
	} else {
		totalDeduped += removed
	}
	if totalDeduped > 0 {
		p.logger.Printf("digest: cleaned up %d duplicate digests", totalDeduped)
	}

	p.loadCaches()

	return p.RunChannelDigests(ctx)
}

// runTrackLinker runs the tracks pipeline (if configured) and injects track context for rollups.
func (p *Pipeline) runTrackLinker(ctx context.Context) {
	if p.TrackLinker == nil || ctx.Err() != nil {
		return
	}
	p.lastStepMu.Lock()
	p.LastStepMessageCount = 0
	p.LastStepInputTokens = 0
	p.LastStepOutputTokens = 0
	p.LastStepDurationSeconds = 0
	p.lastStepMu.Unlock()

	var trackErr error
	func() {
		defer func() {
			if r := recover(); r != nil {
				trackErr = fmt.Errorf("tracks pipeline panicked: %v\n%s", r, debug.Stack())
			}
		}()
		created, updated, err := p.TrackLinker.Run(ctx)
		if err != nil {
			trackErr = err
		} else if created > 0 || updated > 0 {
			p.logger.Printf("digest: tracks created=%d updated=%d", created, updated)
		}
	}()

	if trackErr != nil {
		p.logger.Printf("digest: tracks error: %v", trackErr)
		return
	}

	if trackCtx, err := p.TrackLinker.FormatActiveTracksForPrompt(); err == nil && trackCtx != "" {
		p.TrackContext = trackCtx
	}
}

// RunRollups generates daily/weekly rollups. Used by daemon after tracks pipeline has created tracks.
func (p *Pipeline) RunRollups(ctx context.Context) error {
	if !p.cfg.Digest.Enabled {
		return nil
	}

	_, unlock, err := p.acquireDigestLock()
	if err != nil {
		p.logger.Printf("digest: skipping rollups — %v", err)
		return nil
	}
	defer unlock()

	p.loadCaches()

	if err := p.RunDailyRollup(ctx); err != nil {
		return fmt.Errorf("daily rollup: %w", err)
	}

	return nil
}

// channelWindow pairs a channel with the start of its own digest window.
type channelWindow struct {
	channelID string
	since     float64
}

// RunChannelDigests generates digests for every channel holding messages its
// own digests have not covered yet. Returns the count and accumulated token
// usage. Channels are processed in parallel using digest.workers
// (default: config.DefaultDigestWorkers).
func (p *Pipeline) RunChannelDigests(ctx context.Context) (int, *Usage, error) {
	nowUnix := float64(time.Now().Unix())

	// `digest generate --since` is the operator escape hatch: it overrides every
	// channel's own high-water mark with one uniform window.
	if p.SinceOverride != 0 {
		// Truncate to nearest minute to prevent near-duplicate digests when
		// the pipeline runs twice within seconds (same period_from key).
		sinceUnix := float64(int64(p.SinceOverride) / 60 * 60)
		p.logger.Printf("digest: window override: since=%s now=%s",
			time.Unix(int64(sinceUnix), 0).Format("2006-01-02 15:04"),
			time.Unix(int64(nowUnix), 0).Format("2006-01-02 15:04"))
		return p.runChannelDigestsForWindow(ctx, sinceUnix, nowUnix)
	}

	windows, err := p.resolveChannelWindows(nowUnix)
	if err != nil {
		return 0, nil, err
	}
	return p.runChannelWindows(ctx, windows, nowUnix)
}

// runChannelDigestsForWindow generates channel digests over one uniform window
// for every channel with new messages in it.
func (p *Pipeline) runChannelDigestsForWindow(ctx context.Context, sinceUnix, nowUnix float64) (int, *Usage, error) {
	channels, err := p.db.ChannelsWithNewMessages(sinceUnix)
	if err != nil {
		return 0, nil, fmt.Errorf("finding channels with new messages: %w", err)
	}
	p.logger.Printf("digest: found %d channels with new messages", len(channels))

	windows := make([]channelWindow, 0, len(channels))
	for _, channelID := range channels {
		windows = append(windows, channelWindow{channelID: channelID, since: sinceUnix})
	}
	return p.runChannelWindows(ctx, windows, nowUnix)
}

// resolveChannelWindows returns one window per channel that holds messages
// newer than that channel's own digest high-water mark. Each window starts
// where that channel's last digest ended, so a channel whose digest failed, was
// capped out by the per-run batch budget or was skipped by the cooldown is
// offered again with its undigested messages still inside the window — no
// other channel's success can move it past them.
func (p *Pipeline) resolveChannelWindows(nowUnix float64) ([]channelWindow, error) {
	firstRunSince := p.initialHistorySince(nowUnix)
	fastForwardTS, err := p.db.GetDigestFastForwardTS()
	if err != nil {
		p.logger.Printf("digest: reading fast-forward ts: %v", err)
		fastForwardTS = 0
	}

	candidates, err := p.db.ChannelsWithUndigestedMessages(firstRunSince)
	if err != nil {
		return nil, fmt.Errorf("finding channels with undigested messages: %w", err)
	}

	windows := make([]channelWindow, 0, len(candidates))
	skippedByFloor := 0
	for _, c := range candidates {
		since := channelDigestSince(c, firstRunSince, fastForwardTS)
		if c.NewestMessageTS <= since {
			// The fast-forward floor sits past this channel's newest message:
			// the backlog it accrued while the feature was off stays undigested
			// (FEAT-03).
			skippedByFloor++
			continue
		}
		windows = append(windows, channelWindow{channelID: c.ChannelID, since: since})
	}
	p.logger.Printf("digest: %d channel(s) with undigested messages, %d skipped (below fast-forward floor)",
		len(windows), skippedByFloor)
	return windows, nil
}

// stampConsidered records that msgs has been considered for this channel, so
// its next window starts after them even though they produced no digest. Two
// things count as considered: material the model saw and chose not to write
// about, and material code mechanically decided there was nothing to ask about
// (no visible text, bot-only, or too few to judge — see batchEntryStatus). A
// failed AI call and a failed load are neither — they decided nothing — and
// never reach here.
//
// msgs must be exactly what the decision covered, never what was merely
// available: the accepted path passes its rendered set (trimmed to the row cap,
// or only the extracted human context for a bot-heavy channel), the mechanical
// skips pass the whole load their decision read.
//
// Best-effort: a failed stamp costs a re-render next cycle, never data, so it
// must not fail the channel's digest.
func (p *Pipeline) stampConsidered(channelID string, msgs []db.Message) {
	var newest float64
	for _, m := range msgs {
		if m.TSUnix > newest {
			newest = m.TSUnix
		}
	}
	if newest <= 0 {
		return
	}
	if err := p.db.SetChannelDigestConsideredTS(channelID, newest); err != nil {
		p.logger.Printf("digest: warning: stamping considered mark for #%s: %v", p.channelName(channelID), err)
	}
}

// channelDigestSince is the window start for one channel: the later of what it
// was digested through (digests.period_to) and what it was merely considered
// through (channels.digest_considered_ts — material the model saw and chose not
// to write a digest about), falling back to the first-run lookback when it has
// neither, and raised to the global FEAT-03 fast-forward floor when that floor
// is later.
//
// Both marks are needed. Without period_to a digested channel would re-digest
// itself; without digest_considered_ts a channel the model keeps declining
// never advances at all, and once its widening backlog outgrows the per-channel
// message cap the part that no longer fits can never reach a prompt again.
func channelDigestSince(c db.ChannelDigestCandidate, firstRunSince, fastForwardTS float64) float64 {
	since := max(c.LastDigestTo, c.ConsideredTS)
	if since <= 0 {
		since = firstRunSince
	}
	if fastForwardTS > since {
		return fastForwardTS
	}
	return since
}

// initialHistorySince is the window start a channel that has never been
// digested falls back to: initial_history_days before now (set during
// onboarding).
func (p *Pipeline) initialHistorySince(nowUnix float64) float64 {
	days := p.cfg.Sync.InitialHistoryDays
	if days <= 0 {
		days = config.DefaultInitialHistDays
	}
	return float64(time.Unix(int64(nowUnix), 0).AddDate(0, 0, -days).Unix())
}

// runChannelWindows digests each channel over its own window, up to nowUnix.
func (p *Pipeline) runChannelWindows(ctx context.Context, windows []channelWindow, nowUnix float64) (int, *Usage, error) {
	// Ensure caches are populated (lazy init for direct RunChannelDigests calls).
	if p.channelTypes == nil {
		p.loadCaches()
	}

	if p.OnProgress != nil {
		p.OnProgress(0, 0, "Finding channels with new messages...")
	}

	windows = p.filterDigestableChannels(windows)
	if len(windows) == 0 {
		p.logger.Println("digest: no channels with new messages")
		return 0, nil, nil
	}

	entries := p.buildBatchEntries(windows, nowUnix)
	entries = p.applyDigestCooldown(entries)
	if len(entries) == 0 {
		p.logger.Println("digest: no channels with visible messages")
		return 0, nil, nil
	}

	batches := p.planChannelBatches(entries)

	total := len(entries)
	workers := p.cfg.AI.Workers
	if workers <= 0 {
		workers = config.DefaultAIWorkers
	}
	p.logger.Printf("digest: processing %d channels in %d batches with %d workers", total, len(batches), workers)
	if p.OnProgress != nil {
		p.OnProgress(0, total, fmt.Sprintf("Processing %d channels in %d batches...", total, len(batches)))
	}

	return p.dispatchChannelBatches(ctx, batches, total, workers, nowUnix)
}

// filterDigestableChannels drops muted channels and 1:1 DMs from the candidate
// windows.
func (p *Pipeline) filterDigestableChannels(windows []channelWindow) []channelWindow {
	mutedIDs, err := p.db.GetMutedChannelIDs()
	if err != nil {
		p.logger.Printf("digest: warning: failed to load muted channels: %v", err)
	} else if len(mutedIDs) > 0 {
		muted := make(map[string]bool, len(mutedIDs))
		for _, id := range mutedIDs {
			muted[id] = true
		}
		var filtered []channelWindow
		for _, w := range windows {
			if !muted[w.channelID] {
				filtered = append(filtered, w)
			}
		}
		if skipped := len(windows) - len(filtered); skipped > 0 {
			p.logger.Printf("digest: skipped %d muted channel(s)", skipped)
		}
		windows = filtered
	}

	// Filter out 1:1 DMs — private conversations are not useful in digests.
	// Group DMs are kept (they often contain team discussions).
	var filtered []channelWindow
	skippedDM := 0
	for _, w := range windows {
		if p.channelTypes[w.channelID] == "dm" {
			skippedDM++
			continue
		}
		filtered = append(filtered, w)
	}
	if skippedDM > 0 {
		p.logger.Printf("digest: skipped %d DM channel(s)", skippedDM)
	}
	return filtered
}

// buildBatchEntries loads messages for each channel, classifies bots, and
// returns entries with visible-message counts. Bot-heavy channels are
// reduced to human-context-only messages; channels with no visible content
// are dropped.
func (p *Pipeline) buildBatchEntries(windows []channelWindow, nowUnix float64) []batchEntry {
	var entries []batchEntry
	skippedNoVisible := 0
	skippedBotOnly := 0
	skippedBelowMin := 0
	for _, w := range windows {
		entry, status := p.buildBatchEntry(w, nowUnix)
		switch status {
		case batchEntryAccepted:
			entries = append(entries, entry)
		case batchEntrySkipNoVisible:
			skippedNoVisible++
		case batchEntrySkipBotOnly:
			skippedBotOnly++
		case batchEntrySkipBelowMin:
			skippedBelowMin++
		case batchEntrySkipError:
			// already logged in buildBatchEntry
		}
	}
	p.logger.Printf("digest: %d channels with visible messages, %d skipped (no visible text), %d skipped (bot-only), %d skipped (below min messages)",
		len(entries), skippedNoVisible, skippedBotOnly, skippedBelowMin)
	return entries
}

// trimPartialBoundarySecond splits a capped, oldest-first load into the part
// that may be rendered and whether a whole-second overshoot is needed.
// messages.ts_unix has whole-second resolution, so a considered-through mark
// stamped from these messages cannot distinguish "up to and including second N"
// from "part of second N": without the trim, siblings of the last message that
// did not fit would be skipped when the next window starts at N.
//
// ok is false when the cap landed entirely inside one second and trimming would
// leave nothing to render. That case cannot make progress by trimming — the
// next window would reload exactly these rows forever — so the caller must
// reload the whole second instead, overshooting the cap.
func trimPartialBoundarySecond(msgs []db.Message) (trimmed []db.Message, ok bool) {
	last := msgs[len(msgs)-1].TSUnix
	cut := len(msgs)
	for cut > 0 && msgs[cut-1].TSUnix == last {
		cut--
	}
	if cut == 0 {
		return nil, false
	}
	return msgs[:cut], true
}

type batchEntryStatus int

const (
	batchEntryAccepted batchEntryStatus = iota
	// All three mechanical skips are decisions code makes over a window it
	// fully loaded — every loaded message is empty, deleted, or bot noise — so
	// re-deciding next cycle over a superset of the same messages returns the
	// same verdict. All three therefore stamp the considered-through mark; the
	// statuses stay distinct only to keep the skip counters readable.
	//
	// Stamping SkipBelowMin matters beyond tidiness: digest.min_messages has no
	// upper clamp, so a value above db.DefaultTimeRangeLimit would otherwise
	// pin the window at the head of an all-invisible backlog forever and never
	// load the visible message behind it.
	batchEntrySkipNoVisible
	batchEntrySkipBotOnly
	batchEntrySkipBelowMin
	// batchEntrySkipError is a load failure: nothing was decided, so nothing
	// may be stamped.
	batchEntrySkipError
)

func (p *Pipeline) buildBatchEntry(w channelWindow, nowUnix float64) (batchEntry, batchEntryStatus) {
	channelID := w.channelID
	msgs, err := p.loadWindowMessages(w, nowUnix)
	if err != nil {
		p.logger.Printf("digest: error getting messages for %s: %v", channelID, err)
		return batchEntry{}, batchEntrySkipError
	}
	// Every mechanical skip below covers this whole load, so that is what its
	// mark records — the accepted path stamps its own (possibly narrower)
	// rendered set instead.
	loaded := msgs

	visible, botVisible := p.countVisibleMessages(msgs)
	if visible == 0 {
		p.stampConsidered(channelID, loaded)
		if len(msgs) >= p.cfg.Digest.MinMessages {
			return batchEntry{}, batchEntrySkipNoVisible
		}
		return batchEntry{}, batchEntrySkipBelowMin
	}
	humanVisible := visible - botVisible

	// Bot-heavy channel: ≥90% visible messages from bots.
	if float64(botVisible)/float64(visible) >= 0.9 {
		if humanVisible == 0 {
			p.stampConsidered(channelID, loaded)
			return batchEntry{}, batchEntrySkipBotOnly
		}
		msgs = p.extractHumanContext(msgs)
		visible = 0
		for _, m := range msgs {
			if m.Text != "" && !m.IsDeleted {
				visible++
			}
		}
		if visible == 0 {
			p.stampConsidered(channelID, loaded)
			return batchEntry{}, batchEntrySkipBotOnly
		}
		p.logger.Printf("digest: #%s is bot-heavy, extracted %d context messages around human replies",
			p.channelName(channelID), visible)
	}

	return batchEntry{
		channelID:    channelID,
		channelName:  p.channelName(channelID),
		since:        w.since,
		msgs:         msgs,
		visibleCount: visible,
	}, batchEntryAccepted
}

// loadWindowMessages loads a channel's window oldest-first, capped, and cut
// back to a whole number of seconds so the considered-through mark can never
// land inside a partially-loaded second.
func (p *Pipeline) loadWindowMessages(w channelWindow, nowUnix float64) ([]db.Message, error) {
	msgs, err := p.db.GetOldestMessagesByTimeRange(w.channelID, w.since, nowUnix, db.DefaultTimeRangeLimit)
	if err != nil || len(msgs) < db.DefaultTimeRangeLimit {
		return msgs, err
	}

	if trimmed, ok := trimPartialBoundarySecond(msgs); ok {
		p.logger.Printf("digest: #%s hit the message limit (%d): digesting its oldest %d message(s), the rest follows next cycle",
			p.channelName(w.channelID), db.DefaultTimeRangeLimit, len(trimmed))
		return trimmed, nil
	}

	// The whole capped load sits inside one second, so trimming would leave
	// nothing to render — and since the next window starts AT that second, the
	// load would refill with exactly these rows every cycle and never reach
	// anything after them. Reload with a far higher ceiling so the load gets
	// past that second: a bounded overshoot of the cap beats a channel that can
	// never move.
	msgs, err = p.db.GetOldestMessagesByTimeRange(w.channelID, w.since, nowUnix, db.BoundarySecondRowLimit)
	if err != nil {
		return nil, err
	}
	if len(msgs) == db.BoundarySecondRowLimit {
		if trimmed, ok := trimPartialBoundarySecond(msgs); ok {
			msgs = trimmed
		}
	}
	p.logger.Printf("digest: #%s holds more than %d message(s) in a single second: digesting %d message(s) over the limit",
		p.channelName(w.channelID), db.DefaultTimeRangeLimit, len(msgs))
	return msgs, nil
}

// countVisibleMessages returns (visible, bot-authored visible). Messages with
// empty user_id (webhooks/integrations) count as bots.
func (p *Pipeline) countVisibleMessages(msgs []db.Message) (visible, botVisible int) {
	for _, m := range msgs {
		if m.Text == "" || m.IsDeleted {
			continue
		}
		visible++
		if m.UserID == "" || p.botUserIDs[m.UserID] {
			botVisible++
		}
	}
	return visible, botVisible
}

// applyDigestCooldown removes channels digested recently with low activity to
// avoid frequent small AI calls for trickle channels.
func (p *Pipeline) applyDigestCooldown(entries []batchEntry) []batchEntry {
	cooldownMins := config.DefaultDigestCooldownMins
	minMsgs := p.cfg.Digest.MinMessages
	if minMsgs <= 0 {
		minMsgs = config.DefaultDigestMinMsgs
	}

	now := time.Now()
	skipped := 0
	var filtered []batchEntry
	for _, e := range entries {
		latest, err := p.db.GetLatestDigest(e.channelID, "channel")
		if err == nil && latest != nil {
			if created, perr := time.Parse("2006-01-02T15:04:05Z", latest.CreatedAt); perr == nil {
				if now.Sub(created) < time.Duration(cooldownMins)*time.Minute && e.visibleCount < minMsgs {
					skipped++
					continue
				}
			}
		}
		filtered = append(filtered, e)
	}
	if skipped > 0 {
		p.logger.Printf("digest: skipped %d channel(s) (cooldown: digested <%d min ago with <%d messages)", skipped, cooldownMins, minMsgs)
	}
	return filtered
}

// planChannelBatches groups entries into AI-call batches using tiered activity
// (high → individual, medium → standard groups, low → aggressive groups), then
// caps the total number of batches per run.
func (p *Pipeline) planChannelBatches(entries []batchEntry) [][]batchEntry {
	maxCh := p.cfg.Digest.BatchMaxChannels
	if maxCh <= 0 {
		maxCh = config.DefaultBatchMaxChannels
	}
	maxMsg := p.cfg.Digest.BatchMaxMessages
	if maxMsg <= 0 {
		maxMsg = config.DefaultBatchMaxMessages
	}

	var highEntries, medEntries, lowEntries []batchEntry
	for _, e := range entries {
		switch {
		case e.visibleCount > config.DefaultBatchHighActivityThreshold:
			highEntries = append(highEntries, e)
		case e.visibleCount >= config.DefaultBatchLowActivityThreshold:
			medEntries = append(medEntries, e)
		default:
			lowEntries = append(lowEntries, e)
		}
	}

	var batches [][]batchEntry
	for _, e := range highEntries {
		batches = append(batches, []batchEntry{e})
	}
	batches = append(batches, groupIntoBatches(medEntries, maxCh, maxMsg)...)
	batches = append(batches, groupIntoBatches(lowEntries, maxCh*3, maxMsg)...)

	p.logger.Printf("digest: tiered grouping: %d high, %d medium, %d low activity channels",
		len(highEntries), len(medEntries), len(lowEntries))

	maxBatches := config.DefaultMaxBatchesPerRun
	if len(batches) > maxBatches {
		sort.Slice(batches, func(i, j int) bool {
			iMsgs, jMsgs := 0, 0
			for _, e := range batches[i] {
				iMsgs += e.visibleCount
			}
			for _, e := range batches[j] {
				jMsgs += e.visibleCount
			}
			return iMsgs > jMsgs
		})
		dropped := 0
		for _, b := range batches[maxBatches:] {
			dropped += len(b)
		}
		p.logger.Printf("digest: budget cap: keeping %d of %d batches (%d channels deferred)", maxBatches, len(batches), dropped)
		batches = batches[:maxBatches]
	}
	return batches
}

// batchAggregator carries the per-window mutable accounting state shared
// between worker goroutines in dispatchChannelBatches.
type batchAggregator struct {
	completed   atomic.Int32
	generated   atomic.Int32
	errCount    atomic.Int32
	totalInput  atomic.Int64
	totalOutput atomic.Int64
	lastErrMu   sync.Mutex
	lastErr     error
}

func (a *batchAggregator) recordError(err error) {
	a.errCount.Add(1)
	a.lastErrMu.Lock()
	a.lastErr = err
	a.lastErrMu.Unlock()
}

// dispatchChannelBatches runs worker goroutines over batches and aggregates
// per-window results into a single Usage + count.
func (p *Pipeline) dispatchChannelBatches(ctx context.Context, batches [][]batchEntry, total, workers int, nowUnix float64) (int, *Usage, error) {
	batchCh := make(chan []batchEntry, len(batches))
	for _, b := range batches {
		batchCh <- b
	}
	close(batchCh)

	agg := &batchAggregator{}
	var wg sync.WaitGroup
	for range min(workers, len(batches)) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for batch := range batchCh {
				if ctx.Err() != nil {
					return
				}
				if len(batch) == 1 {
					p.processSingleEntry(ctx, batch[0], total, agg, nowUnix)
				} else {
					p.processBatchEntry(ctx, batch, total, agg, nowUnix)
				}
			}
		}()
	}
	wg.Wait()

	_, _, _, accAPITokens := p.AccumulatedUsage()
	totalUsage := &Usage{
		InputTokens:    int(agg.totalInput.Load()),
		OutputTokens:   int(agg.totalOutput.Load()),
		CostUSD:        0,
		TotalAPITokens: accAPITokens,
	}

	gen := int(agg.generated.Load())
	errs := int(agg.errCount.Load())
	// If we found channels to process but ALL of them failed, report the error
	// so the caller shows a meaningful message instead of "No new digests needed".
	if gen == 0 && errs > 0 {
		return 0, totalUsage, fmt.Errorf("all %d channel digest(s) failed, last error: %w", errs, agg.lastErr)
	}
	return gen, totalUsage, nil
}

// processSingleEntry handles a 1-channel batch: individual prompt for better quality.
func (p *Pipeline) processSingleEntry(ctx context.Context, e batchEntry, total int, agg *batchAggregator, nowUnix float64) {
	sinceUnix := e.since
	p.lastStepMu.Lock()
	p.LastStepMessageCount = len(e.msgs)
	p.LastStepPeriodFrom = time.Unix(int64(sinceUnix), 0)
	p.LastStepPeriodTo = time.Unix(int64(nowUnix), 0)
	p.LastStepDurationSeconds = 0
	p.LastStepInputTokens = 0
	p.LastStepOutputTokens = 0
	if p.OnProgress != nil {
		p.OnProgress(int(agg.completed.Load()), total, fmt.Sprintf("#%s (%d msgs)", e.channelName, len(e.msgs)))
	}
	p.lastStepMu.Unlock()

	stepStart := time.Now()
	result, usage, pv, err := p.generateChannelDigest(ctx, e.channelID, e.channelName, e.msgs, sinceUnix, nowUnix)
	if err != nil {
		p.logger.Printf("digest: error generating digest for #%s: %v", e.channelName, err)
		agg.recordError(err)
		done := int(agg.completed.Add(1))
		if p.OnProgress != nil {
			p.OnProgress(done, total, fmt.Sprintf("#%s error: %v", e.channelName, err))
		}
		return
	}

	lastMsgTS := sinceUnix
	for _, m := range e.msgs {
		if m.TSUnix > lastMsgTS {
			lastMsgTS = m.TSUnix
		}
	}

	if err := p.storeDigest(e.channelID, "channel", sinceUnix, lastMsgTS, result, len(e.msgs), usage, pv); err != nil {
		p.logger.Printf("digest: error storing digest for #%s: %v", e.channelName, err)
		agg.recordError(err)
		done := int(agg.completed.Add(1))
		if p.OnProgress != nil {
			p.OnProgress(done, total, fmt.Sprintf("#%s store error: %v", e.channelName, err))
		}
		return
	}

	agg.generated.Add(1)
	p.totalMessageCount.Add(int64(len(e.msgs)))
	p.updatePeriodBounds(sinceUnix, lastMsgTS)
	p.stampConsidered(e.channelID, e.msgs)

	p.lastStepMu.Lock()
	p.LastStepMessageCount = len(e.msgs)
	p.LastStepPeriodFrom = time.Unix(int64(sinceUnix), 0)
	p.LastStepPeriodTo = time.Unix(int64(lastMsgTS), 0)
	p.LastStepDurationSeconds = time.Since(stepStart).Seconds()
	if usage != nil {
		p.LastStepInputTokens = usage.InputTokens
		p.LastStepOutputTokens = usage.OutputTokens
		agg.totalInput.Add(int64(usage.InputTokens))
		agg.totalOutput.Add(int64(usage.OutputTokens))
		p.accumulateUsage(usage)
	} else {
		p.LastStepInputTokens = 0
		p.LastStepOutputTokens = 0
	}
	done := int(agg.completed.Add(1))
	if p.OnProgress != nil {
		p.OnProgress(done, total, fmt.Sprintf("#%s done", e.channelName))
	}
	p.lastStepMu.Unlock()
	if usage != nil {
		p.logger.Printf("digest: generated for #%s (%d messages, %d+%d tokens)",
			e.channelName, len(e.msgs), usage.InputTokens, usage.OutputTokens)
	} else {
		p.logger.Printf("digest: generated for #%s (%d messages)", e.channelName, len(e.msgs))
	}
}

// processBatchEntry handles a multi-channel batch via the batch prompt.
func (p *Pipeline) processBatchEntry(ctx context.Context, batch []batchEntry, total int, agg *batchAggregator, nowUnix float64) {
	batchMsgCount := 0
	for _, e := range batch {
		batchMsgCount += len(e.msgs)
	}
	// Entries in one batch may carry different window starts; the batch's own
	// reported period covers all of them.
	sinceUnix := earliestSince(batch)

	p.lastStepMu.Lock()
	p.LastStepMessageCount = batchMsgCount
	p.LastStepPeriodFrom = time.Unix(int64(sinceUnix), 0)
	p.LastStepPeriodTo = time.Unix(int64(nowUnix), 0)
	p.LastStepDurationSeconds = 0
	p.LastStepInputTokens = 0
	p.LastStepOutputTokens = 0
	if p.OnProgress != nil {
		p.OnProgress(int(agg.completed.Load()), total, fmt.Sprintf("Batch (%d channels, %d msgs)...", len(batch), batchMsgCount))
	}
	p.lastStepMu.Unlock()

	stepStart := time.Now()
	out, err := p.generateBatchDigest(ctx, batch, nowUnix)
	if err != nil {
		p.logger.Printf("digest: error generating batch (%d channels): %v", len(batch), err)
		agg.recordError(err)
		agg.completed.Add(int32(len(batch)))
		return
	}
	usage := out.usage

	saved, storeFailed := p.persistBatchResults(batch, out.results, usage, out.promptVersion, agg)

	// The call returned, so every channel it rendered was considered — including
	// the ones the model chose to write nothing about, which is the whole point
	// of the mark. A channel whose own digest failed to store is left alone so
	// the next cycle retries it.
	for _, e := range out.rendered {
		if !storeFailed[e.channelID] {
			p.stampConsidered(e.channelID, e.msgs)
		}
	}

	if usage != nil {
		agg.totalInput.Add(int64(usage.InputTokens))
		agg.totalOutput.Add(int64(usage.OutputTokens))
		p.accumulateUsage(usage)
	}

	agg.completed.Add(int32(len(batch)))

	p.lastStepMu.Lock()
	p.LastStepMessageCount = batchMsgCount
	p.LastStepPeriodFrom = time.Unix(int64(sinceUnix), 0)
	p.LastStepPeriodTo = time.Unix(int64(nowUnix), 0)
	p.LastStepDurationSeconds = time.Since(stepStart).Seconds()
	if usage != nil {
		p.LastStepInputTokens = usage.InputTokens
		p.LastStepOutputTokens = usage.OutputTokens
	}
	if p.OnProgress != nil {
		p.OnProgress(int(agg.completed.Load()), total, fmt.Sprintf("Batch done (%d channels, %d saved)", len(batch), saved))
	}
	p.lastStepMu.Unlock()

	p.logger.Printf("digest: batch: %d channels, %d results from AI, %d saved",
		len(batch), len(out.results), saved)
}

// persistBatchResults stores AI batch results back to the DB and returns the
// number successfully saved plus the channels whose store failed. The first
// result carries the batch-level usage; subsequent results pass nil to avoid
// double-counting tokens.
func (p *Pipeline) persistBatchResults(batch []batchEntry, results []BatchChannelResult, usage *Usage, promptVersion int, agg *batchAggregator) (saved int, storeFailed map[string]bool) {
	lookup := newBatchEntryLookup(batch)
	storeFailed = make(map[string]bool)

	for rIdx, r := range results {
		entry, ambiguous := lookup.resolve(r.ChannelID)
		if entry == nil {
			if ambiguous {
				p.logger.Printf("digest: batch result channel id %s is ambiguous across accounts, skipping", r.ChannelID)
			} else {
				p.logger.Printf("digest: batch result for unknown channel %s, skipping", r.ChannelID)
			}
			continue
		}

		var resultUsage *Usage
		if rIdx == 0 {
			resultUsage = usage
		}
		if p.persistOneBatchResult(entry, r, resultUsage, promptVersion, agg) {
			saved++
		} else {
			storeFailed[entry.channelID] = true
		}
	}
	return saved, storeFailed
}

// batchEntryLookup resolves an AI batch result's channel id back to the
// batch entry it belongs to. The model is prompted with the namespaced
// channelID in each channel block's header, but its own JSON example shows a
// bare id, and it sometimes echoes that bare form back (C1, audit finding),
// so a result is resolved against BOTH forms: exact namespaced match first,
// then the raw form. A raw id shared by two entries (two accounts in the same
// batch) is ambiguous and must not be guessed at — it's removed from the
// raw-form map entirely, and resolve reports it as ambiguous only if a result
// actually collides with it, so a collision that no result ever echoes back
// stays silent.
type batchEntryLookup struct {
	entryMap     map[string]*batchEntry
	rawMap       map[string]*batchEntry
	ambiguousRaw map[string]bool
}

func newBatchEntryLookup(batch []batchEntry) *batchEntryLookup {
	l := &batchEntryLookup{
		entryMap:     make(map[string]*batchEntry, len(batch)),
		rawMap:       make(map[string]*batchEntry, len(batch)),
		ambiguousRaw: make(map[string]bool),
	}
	for i := range batch {
		entry := &batch[i]
		l.entryMap[entry.channelID] = entry
		_, rawID, _ := watchtowerslack.SplitAccountID(entry.channelID)
		if rawID == "" {
			continue
		}
		if _, exists := l.rawMap[rawID]; exists {
			l.ambiguousRaw[rawID] = true
			continue
		}
		l.rawMap[rawID] = entry
	}
	for rawID := range l.ambiguousRaw {
		delete(l.rawMap, rawID)
	}
	return l
}

// resolve returns the batch entry channelID refers to, or nil when it
// matches neither form; ambiguous is true only in that nil case, when
// channelID is a raw id two batch entries share.
func (l *batchEntryLookup) resolve(channelID string) (entry *batchEntry, ambiguous bool) {
	if e, ok := l.entryMap[channelID]; ok {
		return e, false
	}
	if e, ok := l.rawMap[channelID]; ok {
		return e, false
	}
	return nil, l.ambiguousRaw[channelID]
}

// persistOneBatchResult stores one resolved AI batch result, returning
// whether it saved. resultUsage is non-nil only for the batch's first
// result — the batch-level usage must not be counted once per channel.
func (p *Pipeline) persistOneBatchResult(entry *batchEntry, r BatchChannelResult, resultUsage *Usage, promptVersion int, agg *batchAggregator) bool {
	sinceUnix := entry.since
	dr := &DigestResult{
		Summary:        r.Summary,
		Topics:         r.Topics,
		RunningSummary: r.RunningSummary,
	}
	if n := blankInventedMessageRefs(dr.Topics, entry.msgs); n > 0 {
		p.logger.Printf("digest: blanked %d invented message_ts ref(s) in #%s", n, entry.channelName)
	}

	lastMsgTS := sinceUnix
	for _, m := range entry.msgs {
		if m.TSUnix > lastMsgTS {
			lastMsgTS = m.TSUnix
		}
	}

	if err := p.storeDigest(entry.channelID, "channel", sinceUnix, lastMsgTS, dr, len(entry.msgs), resultUsage, promptVersion); err != nil {
		p.logger.Printf("digest: error storing batch digest for #%s: %v", entry.channelName, err)
		agg.recordError(err)
		return false
	}

	agg.generated.Add(1)
	p.totalMessageCount.Add(int64(len(entry.msgs)))
	return true
}

// RunDailyRollup generates a cross-channel daily digest from today's channel digests.
// M12 fix: use UTC for consistent timezone-independent digest deduplication.
func (p *Pipeline) RunDailyRollup(ctx context.Context) error {
	now := time.Now().UTC()
	dayStart := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	return p.runDailyRollupForDate(ctx, dayStart)
}

// runDailyRollupForDate generates a daily rollup for the given date.
func (p *Pipeline) runDailyRollupForDate(ctx context.Context, dayStart time.Time) error {
	dayEnd := dayStart.Add(24*time.Hour - time.Second)
	fromUnix := float64(dayStart.Unix())
	toUnix := float64(dayEnd.Unix())

	channelDigests, err := p.db.GetDigests(db.DigestFilter{
		Type:     "channel",
		FromUnix: fromUnix,
		ToUnix:   toUnix,
	})
	if err != nil {
		return fmt.Errorf("getting channel digests for %s: %w", dayStart.Format("2006-01-02"), err)
	}

	if len(channelDigests) < 2 {
		return nil // not enough data for a rollup
	}

	var sb strings.Builder
	for _, d := range channelDigests {
		name := p.channelName(d.ChannelID)
		// Sanitize AI-generated values to prevent prompt injection via prior AI output
		summary := sanitizePromptValue(d.Summary)
		fmt.Fprintf(&sb, "### #%s [channel_id=%s] (%d messages)\nSummary: %s\n", name, d.ChannelID, d.MessageCount, summary)
		// Include topics with their decisions for the rollup
		topics, _ := p.db.GetDigestTopics(d.ID)
		if len(topics) > 0 {
			fmt.Fprintf(&sb, "Topics:\n")
			for _, t := range topics {
				fmt.Fprintf(&sb, "- %s: %s\n", sanitizePromptValue(t.Title), sanitizePromptValue(t.Summary))
				if t.Decisions != "" && t.Decisions != "[]" {
					fmt.Fprintf(&sb, "  Decisions: %s\n", sanitizePromptValue(t.Decisions))
				}
			}
		} else if d.Decisions != "" && d.Decisions != "[]" {
			// Fallback for old digests without topics
			fmt.Fprintf(&sb, "Decisions: %s\n", sanitizePromptValue(d.Decisions))
		}
		sb.WriteString("\n")
	}

	// Prepend chain context if available (decisions grouped into chains are shown
	// as chain updates rather than repeated individually).
	channelInput := sb.String()
	if p.TrackContext != "" {
		channelInput = p.TrackContext + "\n" + channelInput
	}

	previousContext := p.loadPreviousContext("", "daily")

	dateStr := dayStart.Format("2006-01-02")
	tmpl, pv := p.getPrompt(prompts.DigestDaily, dailyRollupPrompt)
	fullPrompt := fmt.Sprintf(tmpl, dateStr, p.formatProfileContext(), p.languageInstruction(), previousContext, channelInput)
	if prefs := p.learnedPrefs(); prefs != "" {
		fullPrompt = prefs + "\n\n" + fullPrompt
	}
	systemPrompt, userMessage := SplitPromptAtData(fullPrompt)

	raw, usage, _, err := p.generator.Generate(WithSource(ctx, "digest.daily"), systemPrompt, userMessage, "")
	if err != nil {
		return fmt.Errorf("generating daily rollup: %w", err)
	}
	p.accumulateUsage(usage)

	result, err := parseDigestResult(raw)
	if err != nil {
		return fmt.Errorf("parsing daily rollup: %w", err)
	}

	totalMsgs := 0
	for _, d := range channelDigests {
		totalMsgs += d.MessageCount
	}

	return p.storeDigest("", "daily", fromUnix, toUnix, result, totalMsgs, usage, pv)
}

// RunWeeklyTrends generates a weekly trends digest from daily rollups.
func (p *Pipeline) RunWeeklyTrends(ctx context.Context) error {
	now := time.Now()
	weekStart := now.AddDate(0, 0, -7)

	dailies, err := p.db.GetDigests(db.DigestFilter{
		Type:     "daily",
		FromUnix: float64(weekStart.Unix()),
	})
	if err != nil {
		return fmt.Errorf("getting weekly dailies: %w", err)
	}

	if len(dailies) < 2 {
		return nil
	}

	var sb strings.Builder
	for _, d := range dailies {
		date := time.Unix(int64(d.PeriodFrom), 0).Local().Format("2006-01-02")
		summary := sanitizePromptValue(d.Summary)
		fmt.Fprintf(&sb, "### %s (%d messages)\nSummary: %s\n", date, d.MessageCount, summary)
		topics, _ := p.db.GetDigestTopics(d.ID)
		if len(topics) > 0 {
			fmt.Fprintf(&sb, "Topics:\n")
			for _, t := range topics {
				fmt.Fprintf(&sb, "- %s: %s\n", sanitizePromptValue(t.Title), sanitizePromptValue(t.Summary))
				if t.Decisions != "" && t.Decisions != "[]" {
					fmt.Fprintf(&sb, "  Decisions: %s\n", sanitizePromptValue(t.Decisions))
				}
			}
		} else if d.Decisions != "" && d.Decisions != "[]" {
			fmt.Fprintf(&sb, "Decisions: %s\n", sanitizePromptValue(d.Decisions))
		}
		sb.WriteString("\n")
	}

	previousContext := p.loadPreviousContext("", "weekly")

	fromStr := weekStart.Format("2006-01-02")
	toStr := now.Format("2006-01-02")
	tmpl, pv := p.getPrompt(prompts.DigestWeekly, weeklyTrendsPrompt)
	fullPrompt := fmt.Sprintf(tmpl, now.Format("2006-01-02"), fromStr, toStr, p.formatProfileContext(), p.languageInstruction(), previousContext, sb.String())
	if prefs := p.learnedPrefs(); prefs != "" {
		fullPrompt = prefs + "\n\n" + fullPrompt
	}
	systemPrompt, userMessage := SplitPromptAtData(fullPrompt)

	raw, usage, _, err := p.generator.Generate(WithSource(ctx, "digest.weekly"), systemPrompt, userMessage, "")
	if err != nil {
		return fmt.Errorf("generating weekly trends: %w", err)
	}
	p.accumulateUsage(usage)

	result, err := parseDigestResult(raw)
	if err != nil {
		return fmt.Errorf("parsing weekly trends: %w", err)
	}

	// Normalize weekStart to midnight for consistent upsert key
	weekStartNorm := time.Date(weekStart.Year(), weekStart.Month(), weekStart.Day(), 0, 0, 0, 0, time.UTC)
	dayEnd := time.Date(now.Year(), now.Month(), now.Day(), 23, 59, 59, 0, time.UTC)
	fromUnix := float64(weekStartNorm.Unix())
	toUnix := float64(dayEnd.Unix())
	totalMsgs := 0
	for _, d := range dailies {
		totalMsgs += d.MessageCount
	}

	return p.storeDigest("", "weekly", fromUnix, toUnix, result, totalMsgs, usage, pv)
}

// RunPeriodSummary generates a summary across all digests in the given time range.
// Unlike other Run* methods, it returns the result directly instead of storing it,
// so it can be printed immediately by the CLI.
func (p *Pipeline) RunPeriodSummary(ctx context.Context, from, to time.Time) (*DigestResult, *Usage, error) {
	p.loadCaches()

	fromUnix := float64(from.Unix())
	toUnix := float64(to.Unix())

	digests, err := p.db.GetDigests(db.DigestFilter{
		FromUnix: fromUnix,
		ToUnix:   toUnix,
	})
	if err != nil {
		return nil, nil, fmt.Errorf("querying digests: %w", err)
	}

	if len(digests) == 0 {
		return nil, nil, fmt.Errorf("no digests found for %s to %s", from.Format("2006-01-02"), to.Format("2006-01-02"))
	}

	var sb strings.Builder
	for _, d := range digests {
		var label string
		switch d.Type {
		case "channel":
			label = "#" + p.channelName(d.ChannelID)
		case "daily":
			label = "Daily rollup"
		case "weekly":
			label = "Weekly trends"
		}
		date := time.Unix(int64(d.PeriodFrom), 0).Local().Format("2006-01-02")
		fmt.Fprintf(&sb, "### %s — %s (%d messages)\n%s\n", date, label, d.MessageCount, sanitizePromptValue(d.Summary))
		topics, _ := p.db.GetDigestTopics(d.ID)
		if len(topics) > 0 {
			for _, t := range topics {
				fmt.Fprintf(&sb, "- %s: %s\n", sanitizePromptValue(t.Title), sanitizePromptValue(t.Summary))
			}
		}
		sb.WriteString("\n")
	}

	fromStr := from.Format("2006-01-02")
	toStr := to.Format("2006-01-02")
	tmpl, _ := p.getPrompt(prompts.DigestPeriod, periodSummaryPrompt)
	fullPrompt := fmt.Sprintf(tmpl, fromStr, toStr, p.formatProfileContext(), p.languageInstruction(), sb.String())
	if prefs := p.learnedPrefs(); prefs != "" {
		fullPrompt = prefs + "\n\n" + fullPrompt
	}
	systemPrompt, userMessage := SplitPromptAtData(fullPrompt)

	raw, usage, _, err := p.generator.Generate(WithSource(ctx, "digest.period"), systemPrompt, userMessage, "")
	if err != nil {
		return nil, nil, fmt.Errorf("generating period summary: %w", err)
	}

	result, err := parseDigestResult(raw)
	if err != nil {
		return nil, nil, fmt.Errorf("parsing period summary: %w", err)
	}

	return result, usage, nil
}

// loadPreviousContext loads the running summary from the latest digest for the
// given channel/type and formats it as a prompt section. Returns empty string
// if no previous context exists, if the context is too old (>30 days), or on error.
// Context older than 7 days is included with an "(outdated)" warning.
func (p *Pipeline) loadPreviousContext(channelID, digestType string) string {
	result, err := p.db.GetLatestRunningSummaryWithAge(channelID, digestType)
	if err != nil {
		p.logger.Printf("digest: warning: failed to load running summary for %s/%s: %v", channelID, digestType, err)
		return ""
	}
	if result == nil || result.Summary == "" {
		return ""
	}

	// TTL: >30 days — don't use at all
	if result.AgeDays > 30 {
		return ""
	}

	var section strings.Builder
	section.WriteString("\n=== PREVIOUS CONTEXT ===\n")

	// TTL: >7 days — mark as outdated
	if result.AgeDays > 7 {
		fmt.Fprintf(&section, "(outdated, from %.0f days ago)\n", result.AgeDays)
	}

	section.WriteString(result.Summary)
	section.WriteString("\n\nRules for PREVIOUS CONTEXT:\n")
	section.WriteString("- Use PREVIOUS CONTEXT to detect continuity: evolving topics, resolved questions, changed decisions.\n")
	section.WriteString("- Say \"continues from [date]\" for ongoing topics, \"resolved since [date]\" for closed ones.\n")
	section.WriteString("- Do NOT repeat decisions/topics from PREVIOUS CONTEXT unless their status changed.\n")
	section.WriteString("- Generate an updated running_summary reflecting the current state after this analysis.\n")

	return section.String()
}

// generateChannelDigest returns the parsed result, usage, prompt version, and error.
func (p *Pipeline) generateChannelDigest(ctx context.Context, channelID, channelName string, msgs []db.Message, from, to float64) (*DigestResult, *Usage, int, error) {
	// Sort messages chronologically (oldest first) for natural reading
	sort.Slice(msgs, func(i, j int) bool { return msgs[i].TSUnix < msgs[j].TSUnix })

	// Load reactions for these messages.
	tss := make([]string, len(msgs))
	for i, m := range msgs {
		tss[i] = m.TS
	}
	reactionMap, _ := p.db.GetReactionsForMessages(channelID, tss)

	formatted := p.formatMessages(msgs, reactionMap)
	if strings.TrimSpace(formatted) == "" {
		return nil, nil, 0, fmt.Errorf("no visible messages after filtering (all empty or deleted)")
	}

	fromStr := time.Unix(int64(from), 0).Local().Format("2006-01-02 15:04")
	toStr := time.Unix(int64(to), 0).Local().Format("2006-01-02 15:04")

	// Skip running context for low-activity channels — context often outweighs messages.
	previousContext := ""
	visible := 0
	for _, m := range msgs {
		if m.Text != "" && !m.IsDeleted {
			visible++
		}
	}
	if visible >= config.DefaultBatchLowActivityThreshold {
		previousContext = p.loadPreviousContext(channelID, "channel")
	}

	tmpl, pv := p.getPrompt(prompts.DigestChannel, channelDigestPrompt)
	fullPrompt := fmt.Sprintf(tmpl, channelName, fromStr, toStr, p.formatProfileContext(), p.languageInstruction(), previousContext, formatted)
	if prefs := p.learnedPrefs(); prefs != "" {
		fullPrompt = prefs + "\n\n" + fullPrompt
	}

	// Split into system prompt (instructions) and user message (data).
	// This enables Claude API prompt caching for the instruction part.
	systemPrompt, userMessage := SplitPromptAtData(fullPrompt)

	raw, usage, _, err := p.generator.Generate(WithSource(ctx, "digest.channel"), systemPrompt, userMessage, "")
	if err != nil {
		return nil, nil, 0, fmt.Errorf("claude call failed: %w", err)
	}

	result, err := parseDigestResult(raw)
	if err != nil {
		return nil, usage, pv, err
	}
	if n := blankInventedMessageRefs(result.Topics, msgs); n > 0 {
		p.logger.Printf("digest: blanked %d invented message_ts ref(s) in #%s", n, channelName)
	}
	return result, usage, pv, nil
}

func (p *Pipeline) storeDigest(channelID, digestType string, from, to float64, result *DigestResult, msgCount int, usage *Usage, promptVersion int) error {
	// Aggregate topics into flat arrays for legacy columns (backward compat).
	var allTopicTitles []string
	var allDecisions []Decision
	var allActionItems []ActionItem
	var allSituations []db.Situation
	for _, t := range result.Topics {
		allTopicTitles = append(allTopicTitles, t.Title)
		allDecisions = append(allDecisions, t.Decisions...)
		allActionItems = append(allActionItems, t.ActionItems...)
		allSituations = append(allSituations, t.Situations...)
	}

	topics, _ := json.Marshal(allTopicTitles)
	decisions, _ := json.Marshal(allDecisions)
	actionItems, _ := json.Marshal(allActionItems)
	situations, _ := json.Marshal(allSituations)

	// Store running_summary as-is (json.RawMessage → string)
	runningSummary := ""
	if len(result.RunningSummary) > 0 {
		runningSummary = string(result.RunningSummary)
	}

	d := db.Digest{
		ChannelID:      channelID,
		Type:           digestType,
		PeriodFrom:     from,
		PeriodTo:       to,
		Summary:        result.Summary,
		Topics:         string(topics),
		Decisions:      string(decisions),
		ActionItems:    string(actionItems),
		PeopleSignals:  "[]",
		Situations:     string(situations),
		RunningSummary: runningSummary,
		MessageCount:   msgCount,
		Model:          "auto",
		PromptVersion:  promptVersion,
	}
	if usage != nil {
		d.Model = usage.Model
		d.InputTokens = usage.InputTokens
		d.OutputTokens = usage.OutputTokens
		d.CostUSD = 0
	}

	digestID, err := p.db.UpsertDigest(d)
	if err != nil {
		return err
	}

	// Store structured topics in digest_topics table.
	if len(result.Topics) > 0 {
		var dbTopics []db.DigestTopic
		for i, t := range result.Topics {
			ai, _ := json.Marshal(t.ActionItems)
			sit, _ := json.Marshal(t.Situations)
			km, _ := json.Marshal(filterValidTimestamps(t.KeyMessages))
			dbTopics = append(dbTopics, db.DigestTopic{
				Idx:         i,
				Title:       t.Title,
				Summary:     t.Summary,
				Decisions:   marshalArray(t.Decisions),
				ActionItems: string(ai),
				Situations:  string(sit),
				KeyMessages: string(km),
				Ideas:       marshalArray(t.Ideas),
			})
		}
		if err := p.db.InsertDigestTopics(digestID, dbTopics); err != nil {
			p.logger.Printf("warning: failed to store digest topics: %v", err)
		}
	}

	// Detect Jira keys in digest decisions.
	if p.jiraKeyDetector != nil {
		for _, t := range result.Topics {
			for _, dec := range t.Decisions {
				if _, err := p.jiraKeyDetector.ProcessDigestDecision(int(digestID), channelID, dec.Text); err != nil {
					p.logger.Printf("warning: jira key detection in decision failed: %v", err)
				}
			}
		}
	}

	return nil
}

// marshalArray renders a slice as JSON, emitting "[]" — never "null" — for an
// empty or nil one. digest_topics.ideas/decisions are read back by the ideas
// registry's ListDigestTopicIdeasAfter, whose "carries candidates" filter is a
// literal `!= '[]'` string compare: a "null" would sail past it and hand the
// consolidator an inert unit for every topic ever written.
func marshalArray[T any](items []T) string {
	if len(items) == 0 {
		return "[]"
	}
	raw, err := json.Marshal(items)
	if err != nil {
		return "[]"
	}
	return string(raw)
}

// updatePeriodBounds atomically updates the earliest/latest period bounds.
func (p *Pipeline) updatePeriodBounds(sinceUnix, lastMsgTS float64) {
	sinceTS := int64(sinceUnix)
	for {
		old := p.earliestPeriodFrom.Load()
		if old != 0 && old <= sinceTS {
			break
		}
		if p.earliestPeriodFrom.CompareAndSwap(old, sinceTS) {
			break
		}
	}
	lastTS := int64(lastMsgTS)
	for {
		old := p.latestPeriodTo.Load()
		if old >= lastTS {
			break
		}
		if p.latestPeriodTo.CompareAndSwap(old, lastTS) {
			break
		}
	}
}

// batchEntry holds a channel with its messages for batch processing. since is
// that channel's own window start — entries inside one batch may carry
// different windows.
type batchEntry struct {
	channelID    string
	channelName  string
	since        float64
	msgs         []db.Message
	visibleCount int
}

// earliestSince returns the earliest window start in a batch — the batch's
// overall coverage, used for the batch prompt header and step reporting.
func earliestSince(batch []batchEntry) float64 {
	var earliest float64
	for i, e := range batch {
		if i == 0 || e.since < earliest {
			earliest = e.since
		}
	}
	return earliest
}

// BatchChannelResult is the per-channel result from a batch digest LLM call.
type BatchChannelResult struct {
	ChannelID      string          `json:"channel_id"`
	Summary        string          `json:"summary"`
	Topics         []Topic         `json:"topics"`
	RunningSummary json.RawMessage `json:"running_summary,omitempty"`
}

// UnmarshalJSON handles both structured topics ([]Topic) and flat topics ([]string).
func (b *BatchChannelResult) UnmarshalJSON(data []byte) error {
	type Alias BatchChannelResult
	var raw struct {
		Alias
		Topics json.RawMessage `json:"topics"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	*b = BatchChannelResult(raw.Alias)
	// Try structured topics first.
	if err := json.Unmarshal(raw.Topics, &b.Topics); err != nil {
		// Fall back to string topics.
		var titles []string
		if err2 := json.Unmarshal(raw.Topics, &titles); err2 == nil {
			for _, t := range titles {
				b.Topics = append(b.Topics, Topic{Title: t})
			}
		}
	}
	return nil
}

// groupIntoBatches groups entries into batches not exceeding maxChannels and maxMessages.
// If maxChannels <= 0, all entries go into a single batch (no limit).
func groupIntoBatches(entries []batchEntry, maxChannels, maxMessages int) [][]batchEntry {
	if len(entries) == 0 {
		return nil
	}
	if maxChannels <= 0 {
		return [][]batchEntry{entries}
	}

	var batches [][]batchEntry
	var current []batchEntry
	currentMsgs := 0

	for _, e := range entries {
		// Start a new batch if adding this entry would exceed limits.
		if len(current) > 0 && (len(current) >= maxChannels || (maxMessages > 0 && currentMsgs+e.visibleCount > maxMessages)) {
			batches = append(batches, current)
			current = nil
			currentMsgs = 0
		}
		current = append(current, e)
		currentMsgs += e.visibleCount
	}
	if len(current) > 0 {
		batches = append(batches, current)
	}
	return batches
}

// parseBatchDigestResult parses the JSON array returned by a batch digest LLM call.
// Filters out entries with empty ChannelID or Summary.
func parseBatchDigestResult(raw string) ([]BatchChannelResult, error) {
	cleaned := raw
	if idx := strings.Index(raw, "```json"); idx >= 0 {
		cleaned = raw[idx+7:]
		if end := strings.Index(cleaned, "```"); end >= 0 {
			cleaned = cleaned[:end]
		}
	} else if idx := strings.Index(raw, "```"); idx >= 0 {
		cleaned = raw[idx+3:]
		if end := strings.Index(cleaned, "```"); end >= 0 {
			cleaned = cleaned[:end]
		}
	}

	cleaned = strings.TrimSpace(cleaned)

	// Find JSON array boundaries
	if start := strings.Index(cleaned, "["); start >= 0 {
		if end := strings.LastIndex(cleaned, "]"); end > start {
			cleaned = cleaned[start : end+1]
		}
	}

	var results []BatchChannelResult
	if err := json.Unmarshal([]byte(cleaned), &results); err != nil {
		return nil, fmt.Errorf("parsing batch digest JSON: %w (raw: %.200s)", err, raw)
	}

	// Filter out entries with missing required fields.
	var filtered []BatchChannelResult
	for _, r := range results {
		if r.ChannelID != "" && r.Summary != "" {
			filtered = append(filtered, r)
		}
	}
	return filtered, nil
}

// batchDigestOutput is one batch AI call's outcome. rendered names the entries
// whose messages actually reached the prompt — the set the considered-through
// mark may be stamped for, which is not the same as the set the model chose to
// answer about.
type batchDigestOutput struct {
	results       []BatchChannelResult
	rendered      []*batchEntry
	usage         *Usage
	promptVersion int
}

// renderBatchChannelBlocks formats one channel block per entry and reports the
// entries that produced one. An entry whose messages all filter out renders
// nothing and is therefore never reported as considered.
func (p *Pipeline) renderBatchChannelBlocks(entries []batchEntry, toStr string) (blocks string, rendered []*batchEntry) {
	var channelBlocks strings.Builder

	for i := range entries {
		e := &entries[i]
		// Sort messages chronologically
		sort.Slice(e.msgs, func(i, j int) bool { return e.msgs[i].TSUnix < e.msgs[j].TSUnix })

		// Load reactions
		tss := make([]string, len(e.msgs))
		for j, m := range e.msgs {
			tss[j] = m.TS
		}
		reactionMap, _ := p.db.GetReactionsForMessages(e.channelID, tss)

		formatted := p.formatMessages(e.msgs, reactionMap)
		if strings.TrimSpace(formatted) == "" {
			continue
		}

		// Skip running context for low-activity channels — context often outweighs messages.
		prevCtx := ""
		if e.visibleCount >= config.DefaultBatchLowActivityThreshold {
			prevCtx = p.loadPreviousContext(e.channelID, "channel")
		}

		fmt.Fprintf(&channelBlocks, "--- #%s (%s) ---\n", e.channelName, e.channelID)
		fmt.Fprintf(&channelBlocks, "[Covers %s to %s]\n",
			time.Unix(int64(e.since), 0).Local().Format("2006-01-02 15:04"), toStr)
		if prevCtx != "" {
			// Strip the leading "=== PREVIOUS CONTEXT ===" header since we embed it differently
			prevCtx = strings.TrimPrefix(prevCtx, "\n=== PREVIOUS CONTEXT ===\n")
			fmt.Fprintf(&channelBlocks, "[Previous context]\n%s\n", prevCtx)
		}
		channelBlocks.WriteString(formatted)
		channelBlocks.WriteString("\n")
		rendered = append(rendered, e)
	}

	return channelBlocks.String(), rendered
}

// generateBatchDigest generates a single LLM call for multiple low-activity channels.
func (p *Pipeline) generateBatchDigest(ctx context.Context, entries []batchEntry, to float64) (*batchDigestOutput, error) {
	// Each entry carries its own window start, so the batch header states the
	// widest one and every channel block states its own.
	fromStr := time.Unix(int64(earliestSince(entries)), 0).Local().Format("2006-01-02 15:04")
	toStr := time.Unix(int64(to), 0).Local().Format("2006-01-02 15:04")

	channelBlocks, rendered := p.renderBatchChannelBlocks(entries, toStr)
	if len(rendered) == 0 {
		return nil, fmt.Errorf("no visible messages in batch")
	}

	tmpl, pv := p.getPrompt(prompts.DigestChannelBatch, channelBatchDigestPrompt)
	// The 5th slot is the batch-level previous-context note; per-channel
	// context is embedded in each channel block instead, so it is always empty.
	fullPrompt := fmt.Sprintf(tmpl, fromStr, toStr, p.formatProfileContext(), p.languageInstruction(), "", channelBlocks)
	if prefs := p.learnedPrefs(); prefs != "" {
		fullPrompt = prefs + "\n\n" + fullPrompt
	}

	systemPrompt, userMessage := SplitPromptAtData(fullPrompt)

	raw, usage, _, err := p.generator.Generate(WithSource(ctx, "digest.channel_batch"), systemPrompt, userMessage, "")
	if err != nil {
		return nil, fmt.Errorf("claude batch call failed: %w", err)
	}

	results, err := parseBatchDigestResult(raw)
	if err != nil {
		return nil, err
	}
	return &batchDigestOutput{results: results, rendered: rendered, usage: usage, promptVersion: pv}, nil
}

// isFirstRun checks if there are any existing channel digests in the DB.
func (p *Pipeline) isFirstRun() bool {
	digests, err := p.db.GetDigests(db.DigestFilter{Type: "channel", Limit: 1})
	return err != nil || len(digests) == 0
}

// formatMessages renders messages for a digest prompt. Every line carries the
// raw Slack ts ("ts=") next to the human-readable HH:MM: the prompts ask the
// model to copy message_ts exactly from the messages it is shown, so the ref it
// cites must be present verbatim — HH:MM alone leaves it constructing one.
func (p *Pipeline) formatMessages(msgs []db.Message, reactions map[string][]db.ReactionSummary) string {
	truncateLimit := config.DefaultMessageTruncateLen

	sanitizeText := func(text string) string {
		if strings.Contains(text, "===") || strings.Contains(text, "---") {
			text = strings.ReplaceAll(text, "===", "= = =")
			text = strings.ReplaceAll(text, "---", "- - -")
		}
		// Truncate very long messages to save input tokens.
		if truncateLimit > 0 && len(text) > truncateLimit {
			text = text[:truncateLimit] + "... [truncated]"
		}
		return text
	}

	// Build thread index: parentTS → replies (only actual replies, not self-referencing parents).
	threadReplies := map[string][]db.Message{}
	parentInBatch := map[string]bool{}
	for i := range msgs {
		m := &msgs[i]
		if m.Text == "" || m.IsDeleted {
			continue
		}
		if m.ThreadTS.Valid && m.ThreadTS.String != m.TS {
			threadReplies[m.ThreadTS.String] = append(threadReplies[m.ThreadTS.String], *m)
		}
	}
	// Identify parents present in this batch.
	for _, m := range msgs {
		if m.Text == "" || m.IsDeleted {
			continue
		}
		if !m.ThreadTS.Valid || m.ThreadTS.String == m.TS {
			if _, ok := threadReplies[m.TS]; ok {
				parentInBatch[m.TS] = true
			}
		}
	}

	var sb strings.Builder
	emitted := map[string]bool{}
	for _, m := range msgs {
		if m.Text == "" || m.IsDeleted {
			continue
		}
		// Thread reply — skip if parent is in batch (will be emitted with parent).
		if m.ThreadTS.Valid && m.ThreadTS.String != m.TS {
			parentTS := m.ThreadTS.String
			if emitted[parentTS] || parentInBatch[parentTS] {
				continue
			}
			// Orphan replies: parent not in batch — emit group once.
			emitted[parentTS] = true
			for _, r := range threadReplies[parentTS] {
				userName := p.userName(r.UserID)
				ts := time.Unix(int64(r.TSUnix), 0).Local().Format("15:04")
				reactStr := db.FormatReactions(reactions[r.TS])
				fmt.Fprintf(&sb, "  ↳ [%s ts=%s @%s (%s)] %s%s\n", ts, r.TS, userName, r.UserID, sanitizeText(r.Text), reactStr)
			}
			continue
		}
		// Top-level or thread parent.
		userName := p.userName(m.UserID)
		ts := time.Unix(int64(m.TSUnix), 0).Local().Format("15:04")
		reactStr := db.FormatReactions(reactions[m.TS])
		fmt.Fprintf(&sb, "[%s ts=%s @%s (%s)] %s%s\n", ts, m.TS, userName, m.UserID, sanitizeText(m.Text), reactStr)
		// Emit grouped replies if this is a thread parent.
		if replies, ok := threadReplies[m.TS]; ok {
			emitted[m.TS] = true
			for _, r := range replies {
				rUserName := p.userName(r.UserID)
				rTS := time.Unix(int64(r.TSUnix), 0).Local().Format("15:04")
				rReactStr := db.FormatReactions(reactions[r.TS])
				fmt.Fprintf(&sb, "  ↳ [%s ts=%s @%s (%s)] %s%s\n", rTS, r.TS, rUserName, r.UserID, sanitizeText(r.Text), rReactStr)
			}
		}
	}
	return sb.String()
}

// SplitPromptAtData splits a formatted prompt into system prompt (instructions)
// and user message (data) at the "=== " delimiter. This enables API-level prompt
// caching for the instruction part. If no delimiter is found, everything goes as
// user message with an empty system prompt.
func SplitPromptAtData(prompt string) (systemPrompt, userMessage string) {
	// Look for the data section delimiter (=== MESSAGES ===, === CHANNEL DIGESTS ===, etc.)
	markers := []string{"=== MESSAGES ===", "=== CHANNELS ===", "=== CHANNEL DIGESTS ===", "=== DAILY DIGESTS ===", "=== DIGESTS ==="}
	for _, marker := range markers {
		if idx := strings.LastIndex(prompt, marker); idx > 0 {
			return strings.TrimSpace(prompt[:idx]), prompt[idx:]
		}
	}
	return "", prompt
}

// extractHumanContext filters messages from a bot-heavy channel to keep only
// human messages and their surrounding context (thread siblings, nearby bot messages).
// This avoids sending hundreds of bot alerts to AI while preserving human interactions.
func (p *Pipeline) extractHumanContext(msgs []db.Message) []db.Message {
	const contextWindow = 3 // bot messages before/after each human message

	// Index messages by position and build thread groups.
	type indexedMsg struct {
		idx int
		msg db.Message
	}
	threadMsgs := make(map[string][]indexedMsg) // threadTS → messages in that thread
	keep := make(map[int]bool)                  // indices to keep

	for i, m := range msgs {
		if m.ThreadTS.Valid && m.ThreadTS.String != "" {
			threadMsgs[m.ThreadTS.String] = append(threadMsgs[m.ThreadTS.String], indexedMsg{i, m})
		}
	}

	for i, m := range msgs {
		if m.Text == "" || m.IsDeleted {
			continue
		}
		if m.UserID == "" || p.botUserIDs[m.UserID] {
			continue
		}
		// Human message found. Keep it.
		keep[i] = true

		// If it's in a thread — keep all messages in that thread (parent + replies).
		threadKey := ""
		if m.ThreadTS.Valid && m.ThreadTS.String != "" {
			threadKey = m.ThreadTS.String
		} else if m.ReplyCount > 0 {
			// This is a thread parent.
			threadKey = m.TS
		}
		if threadKey != "" {
			// Keep thread parent.
			for j, other := range msgs {
				if other.TS == threadKey {
					keep[j] = true
					break
				}
			}
			// Keep all thread messages.
			for _, tm := range threadMsgs[threadKey] {
				keep[tm.idx] = true
			}
		}

		// Keep surrounding messages for context (contextWindow before, contextWindow after).
		for d := 1; d <= contextWindow; d++ {
			if i-d >= 0 {
				keep[i-d] = true
			}
			if i+d < len(msgs) {
				keep[i+d] = true
			}
		}
	}

	result := make([]db.Message, 0, len(keep))
	for i, m := range msgs {
		if keep[i] {
			result = append(result, m)
		}
	}
	return result
}

func (p *Pipeline) loadCaches() {
	p.channelNames = make(map[string]string)
	p.channelTypes = make(map[string]string)
	p.userNames = make(map[string]string)
	p.botUserIDs = make(map[string]bool)

	// Load user profile for personalized digests.
	if userID, err := p.db.GetCurrentUserID(); err == nil && userID != "" {
		if profile, err := p.db.GetUserProfile(userID); err == nil {
			p.profile = profile
		}
	}

	users, err := p.db.GetUsers(db.UserFilter{})
	if err != nil {
		p.logger.Printf("warning: failed to load user names: %v", err)
	} else {
		for _, u := range users {
			name := u.DisplayName
			if name == "" {
				name = u.Name
			}
			p.userNames[u.ID] = name
			if u.IsBot {
				p.botUserIDs[u.ID] = true
			}
		}
	}

	// Also treat muted users as bots — their messages are excluded from AI analysis.
	mutedUserIDs, err := p.db.GetMutedUserIDs()
	if err != nil {
		p.logger.Printf("warning: failed to load muted users: %v", err)
	} else {
		for _, id := range mutedUserIDs {
			p.botUserIDs[id] = true
		}
		if len(mutedUserIDs) > 0 {
			p.logger.Printf("digest: %d muted user(s) excluded from analysis", len(mutedUserIDs))
		}
	}

	channels, err := p.db.GetChannels(db.ChannelFilter{})
	if err != nil {
		p.logger.Printf("warning: failed to load channel names: %v", err)
	} else {
		for _, ch := range channels {
			name := ch.Name
			p.channelTypes[ch.ID] = ch.Type
			// For DMs, show the other user's display name instead of raw ID
			if ch.Type == "dm" || ch.Type == "im" {
				uid := ""
				if ch.DMUserID.Valid {
					uid = ch.DMUserID.String
				} else {
					uid = ch.Name // name is often the user ID for DMs
				}
				if userName, ok := p.userNames[uid]; ok {
					name = "DM: " + userName
				}
			}
			p.channelNames[ch.ID] = name
		}
	}
}

// formatProfileContext builds the profile context section for digest prompts.
// Returns personalization hints so the AI focuses on what matters to the user.
func (p *Pipeline) formatProfileContext() string {
	if p.profile == nil || p.profile.CustomPromptContext == "" {
		return ""
	}

	var sb strings.Builder
	sb.WriteString("=== USER PROFILE CONTEXT ===\n")
	sb.WriteString(sanitizePromptValue(p.profile.CustomPromptContext))
	sb.WriteString("\n\nPERSONALIZATION RULES:\n")
	sb.WriteString("- Prioritize decisions and action items relevant to this user's role and responsibilities\n")
	sb.WriteString("- Highlight topics that fall within the user's area of focus\n")

	// Rendered in raw-id form (SplitAccountID via RawIDsJSON): the model matches
	// these ids against message text, which carries raw Slack ids regardless of
	// how the id blob itself is namespaced.
	if p.profile.StarredChannels != "" && p.profile.StarredChannels != "[]" {
		sb.WriteString(fmt.Sprintf("\nSTARRED CHANNELS: %s — provide more detail for these channels, lower threshold for including topics\n", sanitizePromptValue(watchtowerslack.RawIDsJSON(p.profile.StarredChannels))))
	}
	if p.profile.StarredPeople != "" && p.profile.StarredPeople != "[]" {
		sb.WriteString(fmt.Sprintf("\nSTARRED PEOPLE: %s — highlight decisions and actions by these people\n", sanitizePromptValue(watchtowerslack.RawIDsJSON(p.profile.StarredPeople))))
	}
	if p.profile.Reports != "" && p.profile.Reports != "[]" {
		sb.WriteString(fmt.Sprintf("\nMY REPORTS: %s — flag action items assigned to these people\n", sanitizePromptValue(watchtowerslack.RawIDsJSON(p.profile.Reports))))
	}

	return sb.String()
}

func (p *Pipeline) languageInstruction() string {
	return prompts.Directive(p.cfg.Digest.Language)
}

func (p *Pipeline) channelName(id string) string {
	if p.channelNames != nil {
		if name, ok := p.channelNames[id]; ok {
			return sanitizePromptValue(name)
		}
	}
	return id
}

func (p *Pipeline) userName(id string) string {
	if p.userNames != nil {
		if name, ok := p.userNames[id]; ok {
			return sanitizePromptValue(name)
		}
	}
	return id
}

// sanitizePromptValue prevents prompt injection via delimiter spoofing in names.
func sanitizePromptValue(text string) string {
	// Strip newlines to prevent prompt structure injection via display names.
	text = strings.ReplaceAll(text, "\n", " ")
	text = strings.ReplaceAll(text, "\r", " ")
	if !strings.Contains(text, "===") && !strings.Contains(text, "---") {
		return text
	}
	text = strings.ReplaceAll(text, "===", "= = =")
	text = strings.ReplaceAll(text, "---", "- - -")
	return text
}

// reSlackTS matches a valid Slack message timestamp (e.g. "1774788718.201299").
var reSlackTS = regexp.MustCompile(`^\d{10}\.\d{6}$`)

// filterValidTimestamps removes entries from key_messages that are not valid
// Slack timestamps. AI sometimes returns human-readable text instead.
func filterValidTimestamps(msgs []string) []string {
	filtered := msgs[:0]
	for _, m := range msgs {
		if reSlackTS.MatchString(m) {
			filtered = append(filtered, m)
		}
	}
	return filtered
}

// blankInventedMessageRefs clears every decision/idea message_ts that does not
// match a message actually rendered into the prompt (formatMessages skips empty
// and deleted ones, so a ts the model never saw is not citable either). The item
// itself is kept — digest content is user-visible and a fabricated ref is no
// reason to lose it; only the ref dies, leaving the candidate uncitable
// downstream instead of pointing at a message that does not exist. Returns the
// number of refs blanked.
func blankInventedMessageRefs(topics []Topic, msgs []db.Message) int {
	rendered := make(map[string]bool, len(msgs))
	for _, m := range msgs {
		if m.Text == "" || m.IsDeleted {
			continue
		}
		rendered[m.TS] = true
	}

	blanked := 0
	for i := range topics {
		t := &topics[i]
		for j := range t.Decisions {
			if ts := t.Decisions[j].MessageTS; ts != "" && !rendered[ts] {
				t.Decisions[j].MessageTS = ""
				blanked++
			}
		}
		for j := range t.Ideas {
			if ts := t.Ideas[j].MessageTS; ts != "" && !rendered[ts] {
				t.Ideas[j].MessageTS = ""
				blanked++
			}
		}
	}
	return blanked
}

// parseDigestResult extracts a DigestResult from Claude's response.
// Handles cases where JSON may be wrapped in markdown fences.
func parseDigestResult(raw string) (*DigestResult, error) {
	// Try to extract JSON from markdown fences
	cleaned := raw
	if idx := strings.Index(raw, "```json"); idx >= 0 {
		cleaned = raw[idx+7:]
		if end := strings.Index(cleaned, "```"); end >= 0 {
			cleaned = cleaned[:end]
		}
	} else if idx := strings.Index(raw, "```"); idx >= 0 {
		cleaned = raw[idx+3:]
		if end := strings.Index(cleaned, "```"); end >= 0 {
			cleaned = cleaned[:end]
		}
	}

	cleaned = strings.TrimSpace(cleaned)

	// Try to find JSON object boundaries
	if start := strings.Index(cleaned, "{"); start >= 0 {
		if end := strings.LastIndex(cleaned, "}"); end > start {
			cleaned = cleaned[start : end+1]
		}
	}

	// Use a lenient intermediate format that won't fail on mixed topic types.
	var lenient struct {
		Summary        string          `json:"summary"`
		Topics         json.RawMessage `json:"topics"`
		Decisions      json.RawMessage `json:"decisions"`
		ActionItems    json.RawMessage `json:"action_items"`
		Situations     json.RawMessage `json:"situations"`
		KeyMessages    json.RawMessage `json:"key_messages"`
		RunningSummary json.RawMessage `json:"running_summary,omitempty"`
	}
	if err := json.Unmarshal([]byte(cleaned), &lenient); err != nil {
		return nil, fmt.Errorf("parsing digest JSON: %w (raw: %.500s)", err, raw)
	}

	result := DigestResult{
		Summary:        lenient.Summary,
		RunningSummary: lenient.RunningSummary,
	}

	// Try topics as structured []Topic first, fall back to []string.
	var structuredTopics []Topic
	if err := json.Unmarshal(lenient.Topics, &structuredTopics); err == nil {
		result.Topics = structuredTopics
	} else {
		var stringTopics []string
		if err2 := json.Unmarshal(lenient.Topics, &stringTopics); err2 == nil {
			// Flat format: topics are strings, decisions/action_items/situations at top level.
			var decisions []Decision
			var actionItems []ActionItem
			var situations []db.Situation
			var keyMessages []string
			_ = json.Unmarshal(lenient.Decisions, &decisions)
			_ = json.Unmarshal(lenient.ActionItems, &actionItems)
			_ = json.Unmarshal(lenient.Situations, &situations)
			_ = json.Unmarshal(lenient.KeyMessages, &keyMessages)

			for i, title := range stringTopics {
				t := Topic{Title: title}
				if i == 0 {
					t.Summary = result.Summary
					t.Decisions = decisions
					t.ActionItems = actionItems
					t.Situations = situations
					t.KeyMessages = keyMessages
				}
				result.Topics = append(result.Topics, t)
			}
		}
		// If both fail, proceed with empty topics — summary is still valuable.
	}

	return &result, nil
}
