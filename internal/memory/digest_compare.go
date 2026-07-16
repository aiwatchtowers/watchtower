package memory

// This file is the Phase-5 slice-3 dark digest-compare runner: the tail sub-step
// of the memory phase (behind memory.renders.digest_compare) that renders each
// recently legacy-digested Slack channel window from the memory episodes
// overlapping it, writes the render to the memory-owned memory_digest_shadow
// side table, and computes a mechanical field-by-field diff against the legacy
// digest for the owner's hand-review.
//
// It is a PURE READER of the legacy pipeline: it reads digests/digest_topics
// (GetDigestsCreatedAfter/GetDigestTopics) and messages, and writes ONLY
// memory_digest_shadow — never a digests/digest_topics row, never a digest
// bound or watermark (MEM-05/MEM-14; the legacy pipeline stays authoritative
// and byte-untouched until the compare wins the owner's hand-review, a later
// slice). A per-channel render/read error is isolated (logged + counted), never
// aborts the batch (the CATCHUP-03 "one bad theme never sinks the run" spirit).

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
)

// digestCompareLookback bounds the daemon-tail compare to the legacy channel
// digests written in roughly the current cycle. A code const, like the
// retention/calendar-lookback constants: the shadow rows are keyed by (channel,
// period) and self-overwrite, so a generous overlap only re-renders a window,
// never duplicates it.
const digestCompareLookback = 48 * time.Hour

// ChannelCompare is the per-channel diff between one legacy channel digest and
// the memory render of the same window — the report's row and the metric input.
type ChannelCompare struct {
	ChannelID          string
	LegacyDigestID     int64
	PeriodFrom         float64
	PeriodTo           float64
	LegacyTopics       int     // topic count in the legacy digest
	MemoryTopics       int     // topic count in the memory render (0 when the window had no episodes)
	LegacyRefs         int     // total legacy key_messages + decision refs
	LegacyRefsValid    int     // how many of them resolve against messages (the ~0.6% hallucination audit)
	MemoryRefs         int     // total memory render refs (100% valid by construction — MEM-13)
	MemoryRefsRejected int     // invented render refs dropped at write (RenderRefsRejected)
	Coverage           float64 // covered window messages / total window messages
	LegacyChars        int     // legacy summary+topic char length
	MemoryChars        int     // memory render summary+topic char length
}

// CompareStats is the outcome of one compare run: per-channel diffs plus the
// pipeline counters the RunStats tail folds in.
type CompareStats struct {
	Channels       []ChannelCompare
	ShadowsWritten int // shadow rows written (a covered window OR a coverage-0 no-episode window)
	Failed         int // channels whose render/read failed and were isolated
	RefsRejected   int // total invented render refs dropped across all channels
}

// CompareDigests renders each legacy channel digest written since `since` from
// its window's memory episodes and shadow-stores the diff. It is the shared core
// of the daemon tail (runDigestCompare) and the CLI report. Pure reader of the
// legacy tables; writes only memory_digest_shadow. A top-level digest-list read
// failure aborts (returned); a per-channel failure is isolated and counted.
func (p *Pipeline) CompareDigests(ctx context.Context, since time.Time) (CompareStats, error) {
	var cs CompareStats
	if p.generator == nil {
		return cs, nil
	}
	sinceISO := since.UTC().Format("2006-01-02T15:04:05Z")
	digests, err := p.db.GetDigestsCreatedAfter("channel", sinceISO)
	if err != nil {
		return cs, err
	}
	for _, d := range digests {
		cc, rejected, cerr := p.compareOneChannel(ctx, d)
		if cerr != nil {
			cs.Failed++
			p.logf("memory: digest compare [%s]: %v", d.ChannelID, cerr)
			continue
		}
		cs.Channels = append(cs.Channels, cc)
		cs.ShadowsWritten++
		cs.RefsRejected += rejected
	}
	return cs, nil
}

// compareOneChannel renders one legacy channel digest's window from its memory
// episodes, writes the shadow row, and returns the per-channel diff + the number
// of invented render refs dropped. A window with no overlapping episodes records
// a coverage-0 shadow row and makes NO generator call (there is nothing distilled
// to render from — rendering only-raw gaps would merely re-run legacy at cost).
func (p *Pipeline) compareOneChannel(ctx context.Context, d db.Digest) (ChannelCompare, int, error) {
	cc := ChannelCompare{
		ChannelID:      d.ChannelID,
		LegacyDigestID: int64(d.ID),
		PeriodFrom:     d.PeriodFrom,
		PeriodTo:       d.PeriodTo,
	}
	var err error
	if cc.LegacyTopics, cc.LegacyRefs, cc.LegacyRefsValid, cc.LegacyChars, err = p.legacyMetrics(d); err != nil {
		return cc, 0, err
	}
	if cc.MemoryTopics, cc.MemoryRefs, cc.MemoryRefsRejected, cc.MemoryChars, cc.Coverage, err = p.shadowRender(ctx, d); err != nil {
		return cc, 0, err
	}
	return cc, cc.MemoryRefsRejected, nil
}

// legacyMetrics reads the legacy digest's diff inputs (topic count, message-ref
// validity, char length) — all read-only against digests/digest_topics/messages.
func (p *Pipeline) legacyMetrics(d db.Digest) (topics, refs, valid, chars int, err error) {
	legacyTopics, err := p.db.GetDigestTopics(d.ID)
	if err != nil {
		return 0, 0, 0, 0, err
	}
	refs, valid, err = p.legacyRefValidity(d.ChannelID, legacyTopics)
	if err != nil {
		return 0, 0, 0, 0, err
	}
	return len(legacyTopics), refs, valid, legacyDigestChars(d, legacyTopics), nil
}

// shadowRender renders d's window from its memory episodes, writes the shadow
// row, and returns the memory-side diff inputs + coverage. A window with no
// overlapping episodes records a coverage-0 shadow row and makes NO generator
// call (nothing distilled to render from; rendering only-raw gaps would just
// re-run legacy at cost).
func (p *Pipeline) shadowRender(ctx context.Context, d db.Digest) (memTopics, memRefs, rejected, memChars int, coverage float64, err error) {
	ids, err := p.db.ListEpisodesForChannelWindow(d.ChannelID, d.PeriodFrom, d.PeriodTo)
	if err != nil {
		return 0, 0, 0, 0, 0, err
	}
	episodes, coveredTS, err := p.loadRenderEpisodes(d.ChannelID, ids)
	if err != nil {
		return 0, 0, 0, 0, 0, err
	}
	windowMsgs, err := p.db.ListChannelMessagesInWindow(d.ChannelID, d.PeriodFrom, d.PeriodTo)
	if err != nil {
		return 0, 0, 0, 0, 0, err
	}
	gapMsgs, covered := splitCoverage(windowMsgs, coveredTS)
	coverage = coverageRatio(covered, len(windowMsgs))

	if len(episodes) == 0 {
		if err := p.writeShadow(d, renderedDigest{Topics: []renderedTopic{}}, 0, coverage, ""); err != nil {
			return 0, 0, 0, 0, 0, err
		}
		return 0, 0, 0, 0, coverage, nil
	}

	rendered, rejected, usage, err := p.renderChannelDigest(ctx, d.ChannelID, episodes, gapMsgs)
	if err != nil {
		return 0, 0, 0, 0, 0, err
	}
	model := ""
	if usage != nil {
		model = usage.Model
	}
	if err := p.writeShadow(d, rendered, rejected, coverage, model); err != nil {
		return 0, 0, 0, 0, 0, err
	}
	return len(rendered.Topics), countMemoryRefs(rendered), rejected, renderedChars(rendered), coverage, nil
}

// loadRenderEpisodes reads each episode node's body from the vault and projects
// it into a renderEpisode (title + Story/Outcome + this channel's provenance ts).
// coveredTS is the union of those channel-scoped provenance ts — the coverage
// numerator and the gap-message filter. A vault read error propagates (the
// caller isolates the whole channel).
func (p *Pipeline) loadRenderEpisodes(channelID string, ids []string) ([]renderEpisode, map[string]bool, error) {
	var episodes []renderEpisode
	covered := make(map[string]bool)
	for _, id := range ids {
		n, err := p.vault.ReadNode(id)
		if err != nil {
			return nil, nil, fmt.Errorf("read episode %s: %w", id, err)
		}
		var prov []string
		for _, r := range parseProvenance(n.Body) {
			if r.ChannelID == channelID {
				prov = append(prov, r.TS)
				covered[r.TS] = true
			}
		}
		episodes = append(episodes, renderEpisode{
			Title:      n.Title,
			Story:      sectionProse(n.Body, "## Story"),
			Outcome:    sectionProse(n.Body, "## Outcome"),
			Provenance: prov,
		})
	}
	return episodes, covered, nil
}

// splitCoverage partitions the window's messages: covered counts those whose ts
// is in coveredTS (an episode's provenance), and the rest become raw gap messages
// the render may cite to fill what the episodes miss.
func splitCoverage(msgs []db.MemoryExtractMessage, coveredTS map[string]bool) (gap []gapMessage, covered int) {
	for _, m := range msgs {
		if coveredTS[m.TS] {
			covered++
			continue
		}
		gap = append(gap, gapMessage{TS: m.TS, Author: m.Author, Text: m.Text})
	}
	return gap, covered
}

// coverageRatio is covered/total, 0 when the window is empty (the honest "memory
// covered nothing here" reading, never a divide-by-zero).
func coverageRatio(covered, total int) float64 {
	if total <= 0 {
		return 0
	}
	return float64(covered) / float64(total)
}

// writeShadow marshals the render to the legacy digest_topics JSON shape and
// upserts it into memory_digest_shadow, self-overwriting on the (channel, period)
// key. This is the ONLY write the compare runner makes to the DB.
func (p *Pipeline) writeShadow(d db.Digest, rd renderedDigest, rejected int, coverage float64, model string) error {
	raw, err := json.Marshal(rd)
	if err != nil {
		return fmt.Errorf("marshal render for %s: %w", d.ChannelID, err)
	}
	return p.db.UpsertDigestShadow(db.DigestShadowRow{
		ChannelID:          d.ChannelID,
		PeriodFrom:         d.PeriodFrom,
		PeriodTo:           d.PeriodTo,
		LegacyDigestID:     int64(d.ID),
		RenderedJSON:       string(raw),
		Coverage:           coverage,
		RenderRefsRejected: rejected,
		Model:              model,
		CreatedAt:          time.Now().UTC().Format(time.RFC3339),
	})
}

// legacyRefValidity measures the legacy digest's message-ref hallucination: for
// every key_message ts and decision message_ts across the digest's topics, it
// counts how many resolve against the messages table (via the MEM-01 checker).
// The memory render's refs are 100% valid by construction (MEM-13), so this
// legacy rate is the number that motivates the switch (~0.6% valid in the audit).
// A checker error aborts the channel (isolated by the caller).
func (p *Pipeline) legacyRefValidity(channelID string, topics []db.DigestTopic) (total, valid int, err error) {
	for _, t := range topics {
		for _, ts := range legacyTopicRefTS(t) {
			total++
			ok, cerr := p.checkMsg.MessageExists(channelID, ts)
			if cerr != nil {
				return 0, 0, cerr
			}
			if ok {
				valid++
			}
		}
	}
	return total, valid, nil
}

// legacyTopicRefTS returns every non-empty message ts a legacy topic cites —
// its key_messages plus its decisions' message_ts — parsed from the topic's JSON
// columns (a malformed column is a no-op, never an error; the validity metric is
// best-effort telemetry).
func legacyTopicRefTS(t db.DigestTopic) []string {
	var out []string
	var kms []string
	if t.KeyMessages != "" {
		_ = json.Unmarshal([]byte(t.KeyMessages), &kms)
	}
	for _, ts := range kms {
		if ts != "" {
			out = append(out, ts)
		}
	}
	var decs []renderedDecision // shares the message_ts field with the legacy Decision shape
	if t.Decisions != "" {
		_ = json.Unmarshal([]byte(t.Decisions), &decs)
	}
	for _, dec := range decs {
		if dec.MessageTS != "" {
			out = append(out, dec.MessageTS)
		}
	}
	return out
}

// countMemoryRefs counts the render's surviving message refs (key_messages +
// non-empty decision message_ts) — all episode-cited or resolving gap ts (MEM-13).
func countMemoryRefs(rd renderedDigest) int {
	n := 0
	for _, t := range rd.Topics {
		n += len(t.KeyMessages)
		for _, d := range t.Decisions {
			if d.MessageTS != "" {
				n++
			}
		}
	}
	return n
}

// renderedChars is the render's summary+topic character length (compression input).
func renderedChars(rd renderedDigest) int {
	n := len(rd.Summary)
	for _, t := range rd.Topics {
		n += len(t.Title) + len(t.Summary)
		for _, d := range t.Decisions {
			n += len(d.Text)
		}
		for _, a := range t.ActionItems {
			n += len(a.Text)
		}
	}
	return n
}

// legacyDigestChars is the legacy digest's summary+topic character length.
func legacyDigestChars(d db.Digest, topics []db.DigestTopic) int {
	n := len(d.Summary)
	for _, t := range topics {
		n += len(t.Title) + len(t.Summary)
	}
	return n
}

// runDigestCompare is the memory-phase tail sub-step (behind
// memory.renders.digest_compare): it runs the bounded-lookback compare, folds
// the counters into RunStats, and records one pipeline_steps row. Source-
// isolated: a compare error is logged, never fatal to the run.
func (p *Pipeline) runDigestCompare(ctx context.Context, runID int64, stats *RunStats) {
	start := time.Now()
	cs, err := p.CompareDigests(ctx, time.Now().Add(-digestCompareLookback))
	stats.DigestsCompared += cs.ShadowsWritten
	stats.CompareFailed += cs.Failed
	stats.CompareRefsRejected += cs.RefsRejected
	step := p.nextSemanticStep(runID, 0)
	p.recordSemanticStep(runID, &step, "digest-compare", stepStatus(err), nil, start)
	if err != nil {
		p.logf("memory: digest compare: %v", err)
	}
}

// sectionProse returns all non-empty lines under the given "## X" heading joined
// with a space (up to the next "## " heading), or "" when the section is absent.
// Multi-line-safe (a calendar episode's Story spans several lines), unlike
// sectionFirstLine which the semantic tier uses for one-liner sampling.
func sectionProse(body, heading string) string {
	var lines []string
	inSection := false
	for _, line := range strings.Split(body, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "## ") {
			inSection = trimmed == heading
			continue
		}
		if inSection && trimmed != "" {
			lines = append(lines, trimmed)
		}
	}
	return strings.Join(lines, " ")
}

// ── Task 6: diff metrics + report rendering ──────────────────────────────────

// refValidityRate is valid/total as a fraction in [0,1], 0 when there are no
// refs (never NaN — a channel with no citations reads as 0% validity, not an
// undefined cell).
func refValidityRate(valid, total int) float64 {
	if total <= 0 {
		return 0
	}
	return float64(valid) / float64(total)
}

// lengthRatio is memChars/legacyChars — the compression the memory render
// achieves against the legacy digest (0 when the legacy digest is empty).
func lengthRatio(memChars, legacyChars int) float64 {
	if legacyChars <= 0 {
		return 0
	}
	return float64(memChars) / float64(legacyChars)
}

// RenderCompareReport renders the human-readable markdown compare report: a
// per-channel legacy-vs-memory table, the workspace aggregate metrics, and a
// pointer at the validation-task hand-review protocol. Deterministic (same
// CompareStats + timestamp → identical bytes); generated, never hand-edited.
func RenderCompareReport(cs CompareStats, generatedAt time.Time) string {
	var b strings.Builder
	b.WriteString("# Digest compare report (dark compare-mode)\n\n")
	fmt.Fprintf(&b, "Generated: %s\n\n", generatedAt.UTC().Format(time.RFC3339))
	b.WriteString("> Auto-generated by `watchtower memory digest-compare`. The legacy digest pipeline is authoritative and byte-untouched; these memory renders live only in `memory_digest_shadow`.\n\n")

	fmt.Fprintf(&b, "Channels compared: %d (failed: %d, invented refs dropped: %d)\n\n", cs.ShadowsWritten, cs.Failed, cs.RefsRejected)

	// Per-channel table.
	b.WriteString("## Per-channel\n\n")
	b.WriteString("| Channel | Legacy topics | Memory topics | Legacy ref-valid | Memory ref-valid | Coverage | Length ratio |\n")
	b.WriteString("|---|---|---|---|---|---|---|\n")
	var (
		totLegacyRefs, totLegacyValid int
		totMemRefs                    int
		totLegacyChars, totMemChars   int
		sumCoverage                   float64
	)
	for _, c := range cs.Channels {
		fmt.Fprintf(&b, "| %s | %d | %d | %.1f%% (%d/%d) | %.1f%% (%d/%d) | %.0f%% | %.2f |\n",
			c.ChannelID, c.LegacyTopics, c.MemoryTopics,
			100*refValidityRate(c.LegacyRefsValid, c.LegacyRefs), c.LegacyRefsValid, c.LegacyRefs,
			100*refValidityRate(c.MemoryRefs, c.MemoryRefs), c.MemoryRefs, c.MemoryRefs,
			100*c.Coverage, lengthRatio(c.MemoryChars, c.LegacyChars))
		totLegacyRefs += c.LegacyRefs
		totLegacyValid += c.LegacyRefsValid
		totMemRefs += c.MemoryRefs
		totLegacyChars += c.LegacyChars
		totMemChars += c.MemoryChars
		sumCoverage += c.Coverage
	}

	// Aggregate.
	b.WriteString("\n## Aggregate\n\n")
	avgCoverage := 0.0
	if len(cs.Channels) > 0 {
		avgCoverage = sumCoverage / float64(len(cs.Channels))
	}
	fmt.Fprintf(&b, "- Legacy key_message ref-validity: **%.1f%%** (%d/%d resolve against `messages`)\n",
		100*refValidityRate(totLegacyValid, totLegacyRefs), totLegacyValid, totLegacyRefs)
	fmt.Fprintf(&b, "- Memory render ref-validity: **%.1f%%** (%d/%d — 100%% by construction, MEM-13)\n",
		100*refValidityRate(totMemRefs, totMemRefs), totMemRefs, totMemRefs)
	fmt.Fprintf(&b, "- Mean episode coverage: **%.0f%%**\n", 100*avgCoverage)
	fmt.Fprintf(&b, "- Length ratio (memory/legacy chars): **%.2f**\n\n", lengthRatio(totMemChars, totLegacyChars))

	// Hand-review pointer.
	b.WriteString("## Hand-review protocol\n\n")
	b.WriteString("See Section 5 of `docs/specs/memory-final-validation-task.md` for the go/no-go criteria. For N random channels above, read the legacy digest and the memory render side by side and grade the render's quality ≥ legacy; confirm every memory `key_messages` ts resolves. The switch off legacy is gated on this hand-review.\n")
	return b.String()
}
