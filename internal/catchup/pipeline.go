package catchup

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// topUpFreshness is how close to now a window must end for the coverage top-up
// to be worth running: an older window is already covered by the digests the
// daemon wrote at the time.
const topUpFreshness = 5 * time.Minute

// catchupRulesLimit bounds the learned rules injected into the compose prompt.
const catchupRulesLimit = 20

// Recap statuses, mirroring catchup_recaps.status.
const (
	statusReady  = "ready"
	statusFailed = "failed"
)

// TopUp is the coverage top-up seam: the two digest pipelines that feed a recap
// window, refreshed just before it is read. The CLI wires the real pipelines;
// tests inject fakes.
type TopUp interface {
	ChannelDigests(ctx context.Context) error
	StreamDigests(ctx context.Context) error
}

// Pipeline builds one absence recap per window: top up the source digests,
// gather everything the window produced, compose it into a single document and
// persist it.
type Pipeline struct {
	db          *db.DB
	cfg         *config.Config
	gen         digest.Generator
	logger      *log.Logger
	promptStore *prompts.Store
	topUp       TopUp
	now         func() time.Time
}

// New constructs a catch-up Pipeline reading the wall clock.
func New(database *db.DB, cfg *config.Config, gen digest.Generator, logger *log.Logger) *Pipeline {
	return &Pipeline{db: database, cfg: cfg, gen: gen, logger: logger, now: time.Now}
}

// SetPromptStore wires the operator-customisable prompt store.
func (p *Pipeline) SetPromptStore(s *prompts.Store) { p.promptStore = s }

// SetTopUp wires the coverage top-up seam. Without it the top-up is skipped.
func (p *Pipeline) SetTopUp(t TopUp) { p.topUp = t }

// RunOptions asks for one recap. RegenOfID > 0 regenerates an existing recap's
// window with Correction applied over the model's own judgement.
type RunOptions struct {
	Spec       WindowSpec
	RegenOfID  int64
	Correction string
}

// RunResult reports what one Run produced. Status is the persisted recap status
// ("ready" | "failed"); Error carries the failure the row records.
type RunResult struct {
	RecapID      int64
	Status       string
	Window       Window
	Coverage     Coverage
	RefsRejected int
	Error        string
}

// Run builds and persists one recap.
//
// It returns an error only when nothing was recorded for the operator to see:
// an invalid window, a missing regen source, or a database write that failed —
// and then the result carries only the recap id, if a row was created. Every
// content failure (gather, AI call, unparseable output) is persisted on the row
// as status='failed' and returned with a nil error, so a failed recap is
// something the operator can look at and retry rather than a lost run.
func (p *Pipeline) Run(ctx context.Context, opts RunOptions) (RunResult, error) {
	w, err := p.resolveRunWindow(opts)
	if err != nil {
		return RunResult{}, err
	}
	from, to := float64(w.From.Unix()), float64(w.To.Unix())
	id, err := p.db.InsertCatchupRecap(from, to, opts.RegenOfID)
	if err != nil {
		return RunResult{}, err
	}
	// The row is now 'building'; every path below either finishes or fails it.
	res := RunResult{RecapID: id, Status: statusReady, Window: w}
	res.Coverage = p.runTopUp(ctx, opts, w)

	g, err := p.gather(from, to)
	if err != nil {
		return p.failRun(res, err)
	}
	// Coverage is how the recap admits what it could not see, so a failed read
	// fails the row rather than reporting a zero the UI would show as a real gap.
	res.Coverage.SlackTo, res.Coverage.StreamsTo, err = p.db.CatchupCoverage(from, to)
	if err != nil {
		return p.failRun(res, err)
	}
	// Counted before the prompt budget trims anything, so coverage reports the
	// window's real meeting count (meetings are never trimmed anyway).
	res.Coverage.Meetings = len(g.Meetings)

	// Nothing happened in the window: a real, empty recap and no AI call.
	if g.isEmpty() {
		return p.finish(res, "", Body{}, nil)
	}

	profile, err := p.db.GetSecretaryProfile()
	if err != nil {
		p.logf("catchup: reading the operator profile failed, composing without it: %v", err)
	}
	in := promptInput{Window: w, Profile: profile, Prefs: p.learnedPrefs(), Correction: opts.Correction}
	user, used := buildComposeUserMessage(in, g, p.cfg.Catchup.MaxPromptChars)
	system := fmt.Sprintf(p.getPrompt(prompts.CatchupCompose), prompts.Directive(p.cfg.Digest.Language))

	raw, usage, _, err := p.gen.Generate(digest.WithSource(ctx, "catchup.compose"), system, user, "")
	if err != nil {
		return p.failRun(res, fmt.Errorf("composing catch-up recap: %w", err))
	}
	parsed, err := parseCompose(raw)
	if err != nil {
		return p.failRun(res, err)
	}
	body, rejected := validateBody(parsed, used.byRef)
	res.RefsRejected = rejected
	return p.finish(res, parsed.TLDR, body, usage)
}

// Acknowledge marks the recap's whole window read across every source surface
// and stamps the recap itself acknowledged (CATCHUP-01).
func (p *Pipeline) Acknowledge(recapID int64) error {
	r, err := p.db.GetCatchupRecap(recapID)
	if err != nil {
		return err
	}
	return p.db.AcknowledgeCatchupWindow(recapID, r.PeriodFrom, r.PeriodTo)
}

// resolveRunWindow picks the window this run covers. A regen reuses its source
// recap's window verbatim so the correction is applied to the same material.
func (p *Pipeline) resolveRunWindow(opts RunOptions) (Window, error) {
	if opts.RegenOfID > 0 {
		// Mirrors the preset/custom exclusivity: a window the caller asked for
		// would be silently ignored, so it is rejected instead.
		if opts.Spec.Preset != "" || !opts.Spec.From.IsZero() || !opts.Spec.To.IsZero() {
			return Window{}, fmt.Errorf("%w: a regen reuses its source recap's window; --preset/--from/--to are not allowed", ErrWindow)
		}
		src, err := p.db.GetCatchupRecap(opts.RegenOfID)
		if err != nil {
			return Window{}, err
		}
		return Window{
			From:   time.Unix(int64(src.PeriodFrom), 0),
			To:     time.Unix(int64(src.PeriodTo), 0),
			Source: "regen",
		}, nil
	}
	lastAck, err := p.db.LastAcknowledgedCatchupTo()
	if err != nil {
		p.logf("catchup: reading the last acknowledged window failed, falling back to the default start: %v", err)
	}
	return ResolveWindow(opts.Spec, p.now(), lastAck)
}

// runTopUp refreshes the digests feeding a still-open window so a recap asked
// for right now sees what happened minutes ago. It never blocks the recap: a
// failure is recorded in the coverage and the run continues (CATCHUP-03). A
// regen, a window that already ended, and an unwired seam all skip it.
func (p *Pipeline) runTopUp(ctx context.Context, opts RunOptions, w Window) Coverage {
	cov := Coverage{Topup: "skipped"}
	if opts.RegenOfID > 0 || p.topUp == nil || w.To.Before(p.now().Add(-topUpFreshness)) {
		return cov
	}
	ran := false
	var firstErr error
	record := func(name string, err error) {
		ran = true
		if err == nil {
			return
		}
		p.logf("catchup: %s top-up failed, recapping with the coverage on hand: %v", name, err)
		if firstErr == nil {
			firstErr = err
		}
	}
	// Both gates are independent: the stream top-up is attempted even when the
	// channel one just failed.
	if p.cfg.Digest.Enabled {
		record("channel digest", p.topUp.ChannelDigests(ctx))
	}
	if p.cfg.Streams.Enabled {
		record("stream digest", p.topUp.StreamDigests(ctx))
	}
	switch {
	case firstErr != nil:
		cov.Topup, cov.TopupError = "failed", firstErr.Error()
	case ran:
		cov.Topup = "ok"
	}
	return cov
}

// gather reads every source area for the window, capped per area.
func (p *Pipeline) gather(from, to float64) (gathered, error) {
	limits := p.cfg.Catchup.Caps
	var g gathered
	areas := []struct {
		name  string
		limit int
		list  func(from, to float64, limit int) ([]db.CatchupItem, error)
		dst   *[]db.CatchupItem
	}{
		{"digests", limits.Digests, p.db.ListCatchupDigests, &g.Digests},
		{"streams", limits.Streams, p.db.ListCatchupStreams, &g.Streams},
		{"meetings", limits.Meetings, p.db.ListCatchupMeetings, &g.Meetings},
		{"decisions", limits.Decisions, p.db.ListCatchupDecisions, &g.Decisions},
		{"inbox", limits.Inbox, p.db.ListCatchupInbox, &g.Inbox},
		{"tracks", limits.Tracks, p.db.ListCatchupTracks, &g.Tracks},
		{"targets", limits.Targets, p.db.ListCatchupTargets, &g.Targets},
	}
	for _, a := range areas {
		items, err := a.list(from, to, a.limit)
		if err != nil {
			return gathered{}, fmt.Errorf("gathering %s: %w", a.name, err)
		}
		*a.dst = items
	}
	return g, nil
}

// finish persists a composed recap and flips the row to 'ready'. A write
// failure is a Run error, never a "ready" result: nothing was recorded.
func (p *Pipeline) finish(res RunResult, tldr string, body Body, u *digest.Usage) (RunResult, error) {
	model, inTok, outTok, cost := usageFields(u)
	if err := p.db.FinishCatchupRecap(res.RecapID, tldr, jsonString(body), jsonString(res.Coverage), model, inTok, outTok, cost); err != nil {
		return RunResult{RecapID: res.RecapID, Window: res.Window}, err
	}
	return res, nil
}

// failRun records a content failure on the recap row. Whatever coverage was
// computed before the failure is kept so the UI can explain the gap.
//
// If that write itself fails the row is stuck at 'building' with no error on
// it, so — the rule finish upholds — the caller is told with a Go error rather
// than handed a "failed" result nothing backs.
func (p *Pipeline) failRun(res RunResult, cause error) (RunResult, error) {
	res.Status, res.Error = statusFailed, cause.Error()
	if err := p.db.FailCatchupRecap(res.RecapID, jsonString(res.Coverage), cause.Error()); err != nil {
		return RunResult{RecapID: res.RecapID, Window: res.Window},
			fmt.Errorf("recording catch-up recap %d as failed (%v): %w", res.RecapID, cause, err)
	}
	return res, nil
}

// learnedPrefs renders the operator's catch-up learned rules for the compose
// prompt. Best-effort: a read failure costs personalisation, not the recap.
func (p *Pipeline) learnedPrefs() string {
	rules, err := p.db.ListLearnedRulesByPipeline("catchup", catchupRulesLimit)
	if err != nil {
		p.logf("catchup: reading learned preferences failed, composing without them: %v", err)
		return ""
	}
	return digest.LearnedPreferencesBlock(rules)
}

// getPrompt returns the operator-customised template when a prompt store is
// wired, falling back to the built-in default.
func (p *Pipeline) getPrompt(id string) string {
	if p.promptStore != nil {
		tmpl, _, err := p.promptStore.Get(id)
		if err == nil {
			return tmpl
		}
		p.logf("catchup: loading prompt %q failed, using the built-in default: %v", id, err)
	}
	return prompts.Defaults[id]
}

func (p *Pipeline) logf(format string, args ...any) {
	if p.logger != nil {
		p.logger.Printf(format, args...)
	}
}

// usageFields unpacks one Generate call's usage; a nil usage means zeros.
func usageFields(u *digest.Usage) (model string, inTok, outTok int, cost float64) {
	if u == nil {
		return "", 0, 0, 0
	}
	return u.Model, u.InputTokens, u.OutputTokens, u.CostUSD
}

// jsonString marshals a recap body or coverage record. Both are plain structs
// of strings, numbers and slices thereof, so marshalling cannot fail — the
// briefing pipeline's json.Marshal precedent.
func jsonString(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}
