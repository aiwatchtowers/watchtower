package memory

import (
	"encoding/json"
	"fmt"
	"strings"

	"watchtower/internal/prompts"
)

// extractedEpisode is one episode returned by the memory.extract_episodes
// prompt (strict-JSON array elements).
type extractedEpisode struct {
	Title        string       `json:"title"`
	Story        string       `json:"story"`
	Outcome      *string      `json:"outcome"`
	Participants []string     `json:"participants"`
	Refs         []episodeRef `json:"refs"`
	EntityHints  []string     `json:"entity_hints"`
}

// episodeRef is one provenance pointer into the messages table.
type episodeRef struct {
	ChannelID string `json:"channel_id"`
	TS        string `json:"ts"`
}

// extractMsg is one raw message line fed to the extractor prompt.
type extractMsg struct {
	TS     string
	Author string
	Text   string
}

// channelWindow is one per-channel batch of raw messages for extraction,
// with optional running-summary context from the digest pipeline.
type channelWindow struct {
	ChannelID      string
	ChannelName    string
	RunningSummary string
	Messages       []extractMsg
}

// buildExtractPrompt renders the system and user messages for the
// memory.extract_episodes call (cheap tier). tmpl is the prompt template
// (prompts.MemoryExtractEpisodes — user-customizable via the prompt store,
// falling back to the built-in default); its verbs are the language
// directive and the per-window episode cap. The template pins the
// strict-JSON schema and the copy-don't-invent ts rule that the write-time
// validator (MEM-01) enforces; the user message carries the channel context
// line plus the window's messages as "[ts] author: text" lines.
func buildExtractPrompt(tmpl, lang string, w channelWindow, maxEpisodes int) (system, user string) {
	system = fmt.Sprintf(tmpl, prompts.Directive(lang), maxEpisodes)

	var b strings.Builder
	fmt.Fprintf(&b, "Channel: #%s (%s)\n", w.ChannelName, w.ChannelID)
	writeChannelWindow(&b, w)
	return system, b.String()
}

// buildBatchExtractPrompt renders the system and user messages for the
// memory.extract_episodes_batch call: several channel windows shown in one
// prompt, each under its own "=== #channel (id) ===" block. maxEpisodes
// bounds the whole call, not each channel individually.
//
// The user message deliberately opens with a non-dash line and uses "==="
// rather than digest's "--- ... ---" delimiter (internal/digest's
// generateBatchDigest): unlike digest's channel blocks, which sit embedded
// inside a larger templated prompt, this is the ENTIRE user message, and the
// claude/codex CLI wrappers pass it as a raw argv token ("-p", userMessage —
// see internal/ai/client.go), not via stdin. A message beginning with "--"
// is parsed by the claude CLI as an unrecognized flag instead of the -p
// value ("unknown option '--- #channel...'"), discovered when the E2E
// validation run against live data made this the very first batch — no unit
// test with a fake generator could have caught it.
func buildBatchExtractPrompt(tmpl, lang string, windows []channelWindow, maxEpisodes int) (system, user string) {
	system = fmt.Sprintf(tmpl, prompts.Directive(lang), maxEpisodes)

	var b strings.Builder
	b.WriteString("Channels:\n\n")
	for _, w := range windows {
		fmt.Fprintf(&b, "=== #%s (%s) ===\n", w.ChannelName, w.ChannelID)
		writeChannelWindow(&b, w)
		b.WriteString("\n")
	}
	return system, b.String()
}

// writeChannelWindow renders one channel's running summary (if any) and
// "[ts] author: text" message lines — the part buildExtractPrompt and
// buildBatchExtractPrompt share, so the two prompt paths cannot silently
// drift on how a message line is formatted.
func writeChannelWindow(b *strings.Builder, w channelWindow) {
	if w.RunningSummary != "" {
		fmt.Fprintf(b, "Running summary: %s\n", w.RunningSummary)
	}
	b.WriteString("\nMessages:\n")
	for _, m := range w.Messages {
		fmt.Fprintf(b, "[%s] %s: %s\n", m.TS, m.Author, m.Text)
	}
}

// parseExtract parses the extractor's reply: a JSON array of episodes,
// tolerated bare or inside a ```json fence. An empty array is a valid,
// common result; anything that does not contain a parseable array is an
// error.
func parseExtract(raw string) ([]extractedEpisode, error) {
	s := strings.TrimSpace(raw)
	s = strings.TrimPrefix(s, "```json")
	s = strings.TrimPrefix(s, "```")
	s = strings.TrimSuffix(s, "```")
	start := strings.Index(s, "[")
	end := strings.LastIndex(s, "]")
	if start < 0 || end < start {
		return nil, fmt.Errorf("memory: extract response has no JSON array")
	}
	var eps []extractedEpisode
	if err := json.Unmarshal([]byte(s[start:end+1]), &eps); err != nil {
		return nil, fmt.Errorf("memory: parse extract response: %w", err)
	}
	return eps, nil
}

// messageChecker is the write-time provenance lookup behind MEM-01. *db.DB
// satisfies it; tests inject erroring fakes to exercise the lookup-error
// path without corrupting a real database.
type messageChecker interface {
	MessageExists(channelID, ts string) (bool, error)
}

// splitMalformed separates shape-valid episodes (at least one ref, all refs
// from the same channel) from shape-degenerate ones. The extractor schema
// requires refs on every episode, so a parsed episode with zero refs means
// the reply drifted from the schema (misnamed key, wrong nesting) — it must
// never be read as routine chatter. An episode whose refs span more than one
// channel is equally degenerate: either a batched multi-channel prompt let
// the model conflate two conversations into one story, or a ref's channel_id
// was hallucinated — both are schema violations the extractor was told never
// to produce ("never combine messages from two different channels into one
// episode"), so they are never written half-trusted.
func splitMalformed(eps []extractedEpisode) (valid []extractedEpisode, malformed int) {
	for _, ep := range eps {
		if len(ep.Refs) == 0 || !refsSameChannel(ep.Refs) {
			malformed++
			continue
		}
		valid = append(valid, ep)
	}
	return valid, malformed
}

// refsSameChannel reports whether every ref shares one channel_id (vacuously
// true for zero/one refs — the zero-ref case is caught separately).
func refsSameChannel(refs []episodeRef) bool {
	for i := 1; i < len(refs); i++ {
		if refs[i].ChannelID != refs[0].ChannelID {
			return false
		}
	}
	return true
}

// validateRefs enforces MEM-01/MEM-12 at write time for the Slack episode
// extractor: every ref is dispatched through the provenance registry (built
// from checker so the checkMsg lookup-failure seam is preserved) and dropped
// when it positively does not resolve (never repaired). A ref whose scheme has
// no registered resolver is rejected and counted the same way (MEM-12) — the
// extractor only emits bare-channel (scheme "") refs, so an unregistered scheme
// is a schema violation. An episode whose refs ALL fail is discarded entirely.
//
// A lookup ERROR is not an invalid ref: it means the check itself could not
// run, so validateRefs returns the error and the caller must fail the whole
// window/situation (watermark frozen, nothing written) instead of silently
// dropping refs it never actually checked. An unregistered scheme is NOT a
// lookup error — it is a clean drop, never a freeze.
//
// Counting semantics: dropped counts individual refs that failed validation
// — including the refs of fully-discarded episodes; the number of discarded
// episodes itself is len(eps) - len(kept).
func validateRefs(checker messageChecker, eps []extractedEpisode) (kept []extractedEpisode, dropped int, err error) {
	reg := extractorRegistry(checker)
	for _, ep := range eps {
		var surviving []episodeRef
		for _, ref := range ep.Refs {
			ok, registered, verr := reg.Validate(ref)
			if verr != nil {
				return nil, 0, fmt.Errorf("memory: validating ref %s/%s: %w", ref.ChannelID, ref.TS, verr)
			}
			if !registered {
				dropped++ // MEM-12: no resolver for this scheme — rejected at write
				continue
			}
			if !ok {
				dropped++
				continue
			}
			surviving = append(surviving, ref)
		}
		if len(surviving) == 0 {
			continue // no provenance left — the episode is unverifiable
		}
		ep.Refs = surviving
		kept = append(kept, ep)
	}
	return kept, dropped, nil
}
