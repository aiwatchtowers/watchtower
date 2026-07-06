package inbox

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// composeOp is one dashboard mutation the AI proposes for a compose cycle:
// fold new material into an existing open situation (merge), start a new one
// (create), or just re-score an existing one (rerank).
type composeOp struct {
	Op          string   `json:"op"` // create|merge|rerank
	SituationID int      `json:"situation_id"`
	Title       string   `json:"title"`
	Kind        string   `json:"kind"`
	Priority    string   `json:"priority"`
	Rank        float64  `json:"rank"`
	Rerank      float64  `json:"rerank"`
	Reason      string   `json:"reason"`
	Signals     []string `json:"signals"` // "sig:<inbox_item_id>" | "evt:<track_event_id>" | "tgt:<target_id>"
	TargetID    *int     `json:"target_id"`
	TrackID     *int     `json:"track_id"`
}

// composeResult is the structured AI response for a compose cycle.
type composeResult struct {
	Ops []composeOp `json:"ops"`
}

// recentSnippetsPerSituation caps how many member snippets are rendered per
// open situation in the prompt (chronology context, not the full history).
const recentSnippetsPerSituation = 3

// runCompose folds new material — triaged inbox signals, track events, and
// target updates since the last cycle — into dashboard situations: creating
// new ones, merging into open ones, or just reranking. See the task-4 brief
// for the full behavior contract (DASH-01 merge-dedup, DASH-02 parse-before-write).
//
// Deterministic auto-close always runs first, with no AI involved. If the
// remaining input (after mute-filtering) is empty, the cycle marks any muted
// signals composed and returns without an AI call.
//
// On success, every signal id sent this cycle (including muted-skipped ones)
// is marked composed and the watermark advances. On any failure (AI call,
// parse, or apply), nothing is marked and the watermark stays frozen so the
// same material is retried next cycle. The entire post-parse mutation block —
// applying the AI's ops, marking signals composed, and advancing the
// watermark — runs as a single transaction (applyComposeAndAdvance), so a
// DB error partway through an apply can never leave some situations
// half-persisted while the watermark and signal state disagree (DASH-02).
func (p *Pipeline) runCompose(ctx context.Context, currentUserID string) (created, merged int, err error) {
	if _, aerr := p.db.AutoCloseResolvedSituations(); aerr != nil {
		p.logger.Printf("inbox: compose auto-close error: %v", aerr)
	}

	now := time.Now()
	lastTS, err := p.db.GetComposeLastRunTS()
	if err != nil {
		return 0, 0, fmt.Errorf("getting compose watermark: %w", err)
	}
	// Fresh install (watermark 0): floor to now-lookbackDays, mirroring
	// resolveWatermarkWindow's fix for the inbox/triage watermark. Without
	// this, sinceISO falls back to the Unix epoch and the very first compose
	// pass pulls every track event and every active target ever created.
	if lastTS == 0 {
		lookbackDays := DefaultLookbackDays
		if p.cfg != nil && p.cfg.Inbox.InitialLookbackDays > 0 {
			lookbackDays = p.cfg.Inbox.InitialLookbackDays
		}
		lastTS = float64(now.AddDate(0, 0, -lookbackDays).Unix())
	}
	sinceISO := time.Unix(int64(lastTS), 0).UTC().Format("2006-01-02T15:04:05Z")

	signals, err := p.db.ListUncomposedSignals(p.cfg.Dashboard.MaxComposeSignals)
	if err != nil {
		return 0, 0, fmt.Errorf("listing uncomposed signals: %w", err)
	}
	events, err := p.db.ListTrackEventsSince(sinceISO)
	if err != nil {
		return 0, 0, fmt.Errorf("listing track events: %w", err)
	}
	targets, err := p.db.ListTargetsUpdatedSince(sinceISO)
	if err != nil {
		return 0, 0, fmt.Errorf("listing targets: %w", err)
	}

	mutes := loadMuteScopes(p.db)
	var kept []db.InboxItem
	var mutedIDs []int
	for _, sig := range signals {
		if mutes["sender:"+sig.SenderUserID] || mutes["channel:"+sig.ChannelID] {
			mutedIDs = append(mutedIDs, sig.ID)
			continue
		}
		kept = append(kept, sig)
	}

	if len(kept) == 0 && len(events) == 0 && len(targets) == 0 {
		if len(mutedIDs) > 0 {
			if err := p.db.MarkSignalsComposed(mutedIDs); err != nil {
				return 0, 0, fmt.Errorf("marking muted signals composed: %w", err)
			}
		}
		return 0, 0, nil
	}

	open, err := p.db.ListOpenSituations()
	if err != nil {
		return 0, 0, fmt.Errorf("listing open situations: %w", err)
	}

	brief := buildSecretaryBrief(p.db, currentUserID, now)
	tmpl, _ := p.getPrompt(prompts.InboxCompose)
	openBlock := p.buildOpenSituationsBlock(open)
	newBlock := buildNewMaterialBlock(p.db, kept, events, targets)
	system := fmt.Sprintf(tmpl, prompts.Directive(p.cfg.Digest.Language), brief, openBlock, newBlock)

	raw, usage, _, err := p.generator.Generate(digest.WithSource(ctx, "inbox.compose"), system, "Compose the dashboard.", "")
	if err != nil {
		return 0, 0, fmt.Errorf("compose AI call: %w", err)
	}
	p.accumulateUsage(usage)

	jsonStr, err := prompts.ExtractJSONObject(raw)
	if err != nil {
		return 0, 0, fmt.Errorf("compose response: %w", err)
	}
	var res composeResult
	if err := json.Unmarshal([]byte(jsonStr), &res); err != nil {
		return 0, 0, fmt.Errorf("compose response parse: %w", err)
	}

	// Parsing succeeded — only now do we start mutating (DASH-02).
	validSigIDs := make(map[int]bool, len(kept))
	for _, s := range kept {
		validSigIDs[s.ID] = true
	}
	openByID := make(map[int]db.DashboardSituation, len(open))
	for _, s := range open {
		openByID[s.ID] = s
	}

	allIDs := make([]int, 0, len(kept)+len(mutedIDs))
	for _, s := range kept {
		allIDs = append(allIDs, s.ID)
	}
	allIDs = append(allIDs, mutedIDs...)

	created, merged, err = applyComposeAndAdvance(p.db, res.Ops, validSigIDs, openByID, allIDs, float64(now.Unix()))
	if err != nil {
		// The whole pass rolled back — nothing was created/merged/marked/
		// advanced, regardless of how far the loop got before the error.
		return 0, 0, err
	}
	return created, merged, nil
}

// applyComposeAndAdvance runs the entire post-parse mutation block for one
// compose cycle — applying the AI's ops, marking this cycle's signals
// composed, and advancing the compose watermark — as a single transaction.
// A genuine DB error at any point (a bad op, or the mark/advance writes)
// rolls back every mutation from this pass: no situation is left
// half-created, no signal is marked composed, and the watermark stays frozen
// (DASH-02).
func applyComposeAndAdvance(database *db.DB, ops []composeOp, validSigIDs map[int]bool,
	openByID map[int]db.DashboardSituation, allIDs []int, nowUnix float64) (created, merged int, err error) {
	tx, err := database.Begin()
	if err != nil {
		return 0, 0, fmt.Errorf("beginning compose apply tx: %w", err)
	}
	defer func() { _ = tx.Rollback() }() // no-op once committed

	created, merged, err = applyComposeOps(database, tx, ops, validSigIDs, openByID)
	if err != nil {
		return created, merged, err
	}
	if err := database.MarkSignalsComposedTx(tx, allIDs); err != nil {
		return created, merged, fmt.Errorf("marking signals composed: %w", err)
	}
	if err := database.SetComposeLastRunTSTx(tx, nowUnix); err != nil {
		return created, merged, fmt.Errorf("advancing compose watermark: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return created, merged, fmt.Errorf("committing compose apply: %w", err)
	}
	return created, merged, nil
}

// applyComposeOps applies each op returned by the AI within tx. Ops
// referencing a situation id that isn't open (hallucinated, or since
// resolved) are skipped silently; "sig:" signal keys not among validSigIDs
// (hallucinated) are dropped from membership without failing the op. Only a
// genuine DB error aborts the loop.
func applyComposeOps(database *db.DB, tx *sql.Tx, ops []composeOp, validSigIDs map[int]bool, openByID map[int]db.DashboardSituation) (created, merged int, err error) {
	for _, op := range ops {
		switch op.Op {
		case "create":
			id, cerr := database.CreateSituationTx(tx, db.DashboardSituation{
				Title:    op.Title,
				Kind:     normalizeSituationKind(op.Kind),
				Priority: normalizeSituationPriority(op.Priority),
				Rank:     clampRank(op.Rank),
				AIReason: op.Reason,
				TargetID: op.TargetID,
				TrackID:  op.TrackID,
			})
			if cerr != nil {
				return created, merged, fmt.Errorf("creating situation %q: %w", op.Title, cerr)
			}
			if memberIDs := signalMemberIDs(op.Signals, validSigIDs); len(memberIDs) > 0 {
				if aerr := database.AddSituationSignalsTx(tx, int(id), memberIDs); aerr != nil {
					return created, merged, fmt.Errorf("attaching signals to situation %d: %w", id, aerr)
				}
			}
			created++

		case "merge":
			sit, ok := openByID[op.SituationID]
			if !ok {
				continue // hallucinated situation id, or not open — skip
			}
			if memberIDs := signalMemberIDs(op.Signals, validSigIDs); len(memberIDs) > 0 {
				if aerr := database.AddSituationSignalsTx(tx, sit.ID, memberIDs); aerr != nil {
					return created, merged, fmt.Errorf("merging signals into situation %d: %w", sit.ID, aerr)
				}
			}
			if rerr := database.ResetSituationCardTx(tx, sit.ID); rerr != nil {
				return created, merged, fmt.Errorf("resetting card for situation %d: %w", sit.ID, rerr)
			}
			if op.Rerank > 0 || op.Reason != "" {
				if uerr := rerankSituation(database, tx, sit, op.Rerank, op.Priority, op.Reason); uerr != nil {
					return created, merged, uerr
				}
			}
			merged++

		case "rerank":
			sit, ok := openByID[op.SituationID]
			if !ok {
				continue // hallucinated situation id, or not open — skip
			}
			if uerr := rerankSituation(database, tx, sit, op.Rank, op.Priority, op.Reason); uerr != nil {
				return created, merged, uerr
			}
		}
	}
	return created, merged, nil
}

// rerankSituation updates a situation's rank/priority/reason, falling back to
// the situation's current value for any field the op left blank/zero.
func rerankSituation(database *db.DB, tx *sql.Tx, sit db.DashboardSituation, rank float64, priority, reason string) error {
	if rank <= 0 {
		rank = sit.Rank
	}
	prio := sit.Priority
	if priority != "" {
		prio = normalizeSituationPriority(priority)
	}
	if reason == "" {
		reason = sit.AIReason
	}
	if err := database.UpdateSituationRankTx(tx, sit.ID, clampRank(rank), prio, reason); err != nil {
		return fmt.Errorf("reranking situation %d: %w", sit.ID, err)
	}
	return nil
}

// signalMemberIDs extracts inbox_item IDs from an op's Signals list, keeping
// only "sig:<id>" entries whose id was actually sent to the AI this cycle.
// "evt:"/"tgt:" entries justify a situation but never become membership
// links; unrecognized or hallucinated sig ids are silently dropped.
func signalMemberIDs(keys []string, validSigIDs map[int]bool) []int {
	var out []int
	for _, k := range keys {
		rest, ok := strings.CutPrefix(k, "sig:")
		if !ok {
			continue
		}
		id, err := strconv.Atoi(rest)
		if err != nil || !validSigIDs[id] {
			continue
		}
		out = append(out, id)
	}
	return out
}

// normalizeSituationKind coerces an AI-returned kind to one of the known
// values, defaulting to "external".
func normalizeSituationKind(kind string) string {
	switch kind {
	case "external", "target_update", "track_update", "mixed":
		return kind
	default:
		return "external"
	}
}

// normalizeSituationPriority coerces an AI-returned priority to one of the
// known values, defaulting to "medium".
func normalizeSituationPriority(priority string) string {
	switch priority {
	case "high", "medium", "low":
		return priority
	default:
		return "medium"
	}
}

// clampRank clamps a rank to the valid [0, 1] range.
func clampRank(rank float64) float64 {
	switch {
	case rank < 0:
		return 0
	case rank > 1:
		return 1
	default:
		return rank
	}
}

// buildOpenSituationsBlock renders the "OPEN SITUATIONS" prompt section: one
// line per open situation with its id/kind/title/reason plus the last few
// member signal snippets for context.
func (p *Pipeline) buildOpenSituationsBlock(open []db.DashboardSituation) string {
	if len(open) == 0 {
		return "(none)"
	}
	var b strings.Builder
	for _, s := range open {
		members, _ := p.db.ListSituationSignals(s.ID)
		b.WriteString(fmt.Sprintf("id=%d [%s] %s :: %s :: recent: %s\n",
			s.ID, s.Kind, s.Title, s.AIReason, recentMemberSnippets(members)))
	}
	return b.String()
}

// recentMemberSnippets renders up to the last recentSnippetsPerSituation
// member signal snippets, oldest-of-the-recent-set first.
func recentMemberSnippets(members []db.InboxItem) string {
	if len(members) == 0 {
		return "(no signals yet)"
	}
	start := 0
	if len(members) > recentSnippetsPerSituation {
		start = len(members) - recentSnippetsPerSituation
	}
	parts := make([]string, 0, len(members)-start)
	for _, it := range members[start:] {
		parts = append(parts, cleanSnippet(it.Snippet))
	}
	return strings.Join(parts, "; ")
}

// buildNewMaterialBlock renders the "new material" prompt section: pending
// signals plus track events and target updates since the last compose cycle.
func buildNewMaterialBlock(database *db.DB, signals []db.InboxItem, events []db.TrackEvent, targets []db.Target) string {
	if len(signals) == 0 && len(events) == 0 && len(targets) == 0 {
		return "(none)"
	}
	var b strings.Builder
	for _, s := range signals {
		b.WriteString(fmt.Sprintf("sig:%d [%s] from=%s channel=%s :: %s\n",
			s.ID, s.TriggerType, s.SenderUserID, s.ChannelID, cleanSnippet(s.Snippet)))
	}
	for _, e := range events {
		b.WriteString(fmt.Sprintf("evt:%d [track:%s] :: %s\n", e.ID, trackTitle(database, e.TrackID), e.Summary))
	}
	for _, t := range targets {
		b.WriteString(fmt.Sprintf("tgt:%d [target:%s] :: %s\n", t.ID, t.Status, t.Text))
	}
	return b.String()
}

// trackTitle resolves a track's display text for the prompt, falling back to
// a bare id reference if the track can't be loaded.
func trackTitle(database *db.DB, trackID int) string {
	t, err := database.GetTrackByID(trackID)
	if err != nil || t == nil {
		return fmt.Sprintf("#%d", trackID)
	}
	return cleanSnippet(t.Text)
}
