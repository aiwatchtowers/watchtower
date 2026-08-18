package memory

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// This file is the Phase-5 slice-3 channel-digest RENDER: the first
// render-inversion of 5B — a Slack channel's digest rendered from the memory
// episodes overlapping a time window, dark-launched in compare mode against the
// legacy digest pipeline (the compare runner + shadow storage land in Task 5).
//
// The render carries the MEM-13 kernel: the model may cite key_messages /
// decision message_ts ONLY by a timestamp it was shown (an input episode's
// provenance ts, or a raw coverage-gap message ts), and code re-validates every
// ref at write — an episode-cited ref is trusted with no round-trip (episodes
// only ever carry MEM-01-validated refs), a gap-message ts resolves through the
// message checker, and anything else is dropped-and-counted (RenderRefsRejected),
// never written. The hallucinated key_messages class dies by construction.

// renderChannelDigestSource is the WithSource tag that routes the render to the
// cheap model tier (see the TierForSource table in internal/digest/models.go),
// matching the legacy channel digest.
const renderChannelDigestSource = prompts.MemoryRenderChannelDigest

// renderEpisode is one input episode for the channel-digest render: its
// title + Story/Outcome prose and the channel-scoped provenance ts values that
// define its episode-cited ref set (MEM-13). The compare runner (Task 5) builds
// these from each overlapping episode node's body; because the extractor
// validated those refs at write (MEM-01), every ts here already points at a
// real message.
type renderEpisode struct {
	Title      string
	Story      string
	Outcome    string
	Provenance []string // ts values for THIS channel (bare-channel refs)
}

// gapMessage is one raw window message that no episode covers ("coverage gap").
// The render may cite its ts to fill what the episodes miss; the ts resolves
// through the message checker at validation time.
type gapMessage struct {
	TS     string
	Author string
	Text   string
}

// renderedDigest is the render's output, mirroring the legacy digest_topics
// JSON shape (digest.DigestResult) EXACTLY so the compare diff is field-by-field
// and a future switch is a drop-in. Defined locally to avoid importing
// internal/digest's structs (the JSON contract is the coupling — a shape
// assertion in digest_render_test.go proves it round-trips through the legacy
// struct).
type renderedDigest struct {
	Summary string          `json:"summary"`
	Topics  []renderedTopic `json:"topics"`
}

type renderedTopic struct {
	Title       string               `json:"title"`
	Summary     string               `json:"summary"`
	Decisions   []renderedDecision   `json:"decisions"`
	ActionItems []renderedActionItem `json:"action_items"`
	Situations  []json.RawMessage    `json:"situations"`
	KeyMessages []string             `json:"key_messages"`
}

type renderedDecision struct {
	Text       string `json:"text"`
	By         string `json:"by"`
	MessageTS  string `json:"message_ts"`
	ChannelID  string `json:"channel_id,omitempty"`
	Importance string `json:"importance"`
}

type renderedActionItem struct {
	Text     string `json:"text"`
	Assignee string `json:"assignee"`
	Status   string `json:"status"`
}

// renderChannelDigest renders channelID's digest from the overlapping episodes
// (plus any raw coverage-gap messages), validates every emitted ref (MEM-13),
// and returns the validated digest, the number of invented refs dropped
// (RenderRefsRejected — the shadow row's telemetry), and the call usage. The
// caller (Task 5) marshals the returned digest into the shadow row. A generate
// or parse failure returns an error and is isolated per-channel by the caller.
func (p *Pipeline) renderChannelDigest(ctx context.Context, channelID string, episodes []renderEpisode, gapMsgs []gapMessage) (renderedDigest, int, *digest.Usage, error) {
	system, user := buildRenderPrompt(p.getPrompt(prompts.MemoryRenderChannelDigest), p.Language, channelID, episodes, gapMsgs)
	raw, usage, _, err := p.generator.Generate(digest.WithSource(ctx, renderChannelDigestSource), system, user, "")
	if err != nil {
		return renderedDigest{}, 0, usage, fmt.Errorf("memory: render channel %s: generate: %w", channelID, err)
	}
	rd, err := parseRenderedDigest(raw)
	if err != nil {
		return renderedDigest{}, 0, usage, err
	}
	rejected, err := validateRenderRefs(p.checkMsg, channelID, episodes, &rd)
	if err != nil {
		return renderedDigest{}, 0, usage, err
	}
	return rd, rejected, usage, nil
}

// buildRenderPrompt renders the system and user messages for the
// memory.render_channel_digest call (cheap tier). The user message lists each
// overlapping episode's title + Story + Outcome + its provenance ts (the only
// timestamps the model may cite for that episode), then the raw coverage-gap
// messages as a fallback block. It deliberately opens with a "Channel:" line,
// never a dash: the claude/codex CLI wrappers pass the whole user message as a
// raw "-p" argv token, and a leading dash is parsed as an unknown flag (the
// extract-builder gotcha, guarded by TestBuildRenderPromptContent).
func buildRenderPrompt(tmpl, lang, channelID string, episodes []renderEpisode, gapMsgs []gapMessage) (system, user string) {
	system = fmt.Sprintf(tmpl, prompts.Directive(lang))

	var b strings.Builder
	fmt.Fprintf(&b, "Channel: %s\n\n", channelID)
	b.WriteString("Episodes:\n")
	for _, ep := range episodes {
		fmt.Fprintf(&b, "\n### %s\n", ep.Title)
		if ep.Story != "" {
			fmt.Fprintf(&b, "Story: %s\n", ep.Story)
		}
		if ep.Outcome != "" {
			fmt.Fprintf(&b, "Outcome: %s\n", ep.Outcome)
		}
		if len(ep.Provenance) > 0 {
			fmt.Fprintf(&b, "Message timestamps: %s\n", strings.Join(ep.Provenance, ", "))
		}
	}
	if len(gapMsgs) > 0 {
		b.WriteString("\nUncovered messages (use only to fill gaps the episodes miss):\n")
		for _, m := range gapMsgs {
			fmt.Fprintf(&b, "[%s] %s: %s\n", m.TS, m.Author, m.Text)
		}
	}
	return system, b.String()
}

// parseRenderedDigest parses the render reply: a JSON object, tolerated bare or
// inside a ```json fence (the legacy parseDigestResult shape). Anything that
// does not contain a parseable object is an error the caller isolates.
func parseRenderedDigest(raw string) (renderedDigest, error) {
	s := strings.TrimSpace(raw)
	if i := strings.Index(s, "```json"); i >= 0 {
		s = s[i+len("```json"):]
		if e := strings.Index(s, "```"); e >= 0 {
			s = s[:e]
		}
	} else if i := strings.Index(s, "```"); i >= 0 {
		s = s[i+len("```"):]
		if e := strings.Index(s, "```"); e >= 0 {
			s = s[:e]
		}
	}
	s = strings.TrimSpace(s)
	start := strings.Index(s, "{")
	end := strings.LastIndex(s, "}")
	if start < 0 || end < start {
		return renderedDigest{}, fmt.Errorf("memory: render response has no JSON object")
	}
	var rd renderedDigest
	if err := json.Unmarshal([]byte(s[start:end+1]), &rd); err != nil {
		return renderedDigest{}, fmt.Errorf("memory: parse render response: %w", err)
	}
	return rd, nil
}

// validateRenderRefs enforces MEM-13 on the parsed render: every key_messages
// entry and every non-empty decision message_ts is kept iff it is episode-cited
// (a member of the input episodes' provenance set — trusted with no DB
// round-trip, since episodes only carry MEM-01-validated refs) OR it resolves
// through the message checker (a raw coverage-gap message). An invented ref is
// dropped-and-counted; a topic whose refs were ALL invented is dropped whole
// (the hallucinated-topic class). A checker ERROR is not an invalid ref — it
// means the lookup could not run, so it propagates and the caller isolates the
// whole channel (never a silent drop of an unchecked ref). Returns the number
// of dropped refs (RenderRefsRejected).
func validateRenderRefs(checker messageChecker, channelID string, episodes []renderEpisode, rd *renderedDigest) (rejected int, err error) {
	cited := make(map[string]bool)
	for _, ep := range episodes {
		for _, ts := range ep.Provenance {
			cited[ts] = true
		}
	}
	// keep reports whether a non-empty ts resolves; an episode-cited ts needs no
	// round-trip, a gap-message ts hits the checker.
	keep := func(ts string) (bool, error) {
		if cited[ts] {
			return true, nil
		}
		return checker.MessageExists(channelID, ts)
	}

	var keptTopics []renderedTopic
	for ti := range rd.Topics {
		t, drop, tRejected, terr := filterTopicRefs(keep, channelID, rd.Topics[ti])
		if terr != nil {
			return 0, terr
		}
		rejected += tRejected
		if drop {
			continue // every ref this topic cited was invented — drop the topic
		}
		keptTopics = append(keptTopics, t)
	}
	rd.Topics = keptTopics
	return rejected, nil
}

// filterTopicRefs validates one topic's key_messages and decision message_ts
// refs against keep (episode-cited or checker-resolved), dropping invented
// refs. It returns the filtered topic, whether every ref the topic originally
// cited was invented (so the caller should drop the topic whole — the
// hallucinated-topic class), the count of refs dropped, and any checker error
// (which propagates rather than silently treating an unchecked ref as
// invalid — the caller returns 0 rejected on error, matching validateRenderRefs'
// existing all-or-nothing error contract).
func filterTopicRefs(keep func(string) (bool, error), channelID string, t renderedTopic) (filtered renderedTopic, drop bool, rejected int, err error) {
	origRefs := 0

	keptKM := make([]string, 0, len(t.KeyMessages))
	for _, ts := range t.KeyMessages {
		if ts == "" {
			continue // an empty entry is not a ref — dropped silently, not counted
		}
		origRefs++
		ok, verr := keep(ts)
		if verr != nil {
			return renderedTopic{}, false, 0, fmt.Errorf("memory: render key_message ref %s/%s: %w", channelID, ts, verr)
		}
		if !ok {
			rejected++
			continue
		}
		keptKM = append(keptKM, ts)
	}
	t.KeyMessages = keptKM

	keptDec := make([]renderedDecision, 0, len(t.Decisions))
	for _, d := range t.Decisions {
		if d.MessageTS == "" {
			keptDec = append(keptDec, d) // a decision with no citation — nothing to validate
			continue
		}
		origRefs++
		ok, verr := keep(d.MessageTS)
		if verr != nil {
			return renderedTopic{}, false, 0, fmt.Errorf("memory: render decision ref %s/%s: %w", channelID, d.MessageTS, verr)
		}
		if !ok {
			rejected++
			continue // an invented decision citation — drop the decision whole
		}
		keptDec = append(keptDec, d)
	}
	t.Decisions = keptDec

	survivingRefs := len(keptKM)
	for _, d := range keptDec {
		if d.MessageTS != "" {
			survivingRefs++
		}
	}
	return t, origRefs > 0 && survivingRefs == 0, rejected, nil
}
