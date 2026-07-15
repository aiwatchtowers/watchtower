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
	if w.RunningSummary != "" {
		fmt.Fprintf(&b, "Running summary: %s\n", w.RunningSummary)
	}
	b.WriteString("\nMessages:\n")
	for _, m := range w.Messages {
		fmt.Fprintf(&b, "[%s] %s: %s\n", m.TS, m.Author, m.Text)
	}
	return system, b.String()
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

// splitMalformed separates shape-valid episodes (at least one ref) from
// shape-degenerate ones. The extractor schema requires refs on every episode,
// so a parsed episode with zero refs means the reply drifted from the schema
// (misnamed key, wrong nesting) — it must never be read as routine chatter.
func splitMalformed(eps []extractedEpisode) (valid []extractedEpisode, malformed int) {
	for _, ep := range eps {
		if len(ep.Refs) == 0 {
			malformed++
			continue
		}
		valid = append(valid, ep)
	}
	return valid, malformed
}

// validateRefs enforces MEM-01 at write time: every ref is checked against
// the messages table and dropped when it positively does not resolve (never
// repaired). An episode whose refs ALL fail is discarded entirely.
//
// A lookup ERROR is not an invalid ref: it means the check itself could not
// run, so validateRefs returns the error and the caller must fail the whole
// window/situation (watermark frozen, nothing written) instead of silently
// dropping refs it never actually checked.
//
// Counting semantics: dropped counts individual refs that failed validation
// — including the refs of fully-discarded episodes; the number of discarded
// episodes itself is len(eps) - len(kept).
func validateRefs(checker messageChecker, eps []extractedEpisode) (kept []extractedEpisode, dropped int, err error) {
	for _, ep := range eps {
		var surviving []episodeRef
		for _, ref := range ep.Refs {
			ok, err := checker.MessageExists(ref.ChannelID, ref.TS)
			if err != nil {
				return nil, 0, fmt.Errorf("memory: validating ref %s/%s: %w", ref.ChannelID, ref.TS, err)
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
