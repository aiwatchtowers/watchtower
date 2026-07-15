package memory

import (
	"encoding/json"
	"fmt"
	"strings"

	"watchtower/internal/db"
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
// memory.extract_episodes call (cheap tier). The system prompt pins the
// strict-JSON schema, the per-window episode cap, and the copy-don't-invent
// ts rule that the write-time validator (MEM-01) enforces; the user message
// carries the channel context line plus the window's messages as
// "[ts] author: text" lines.
func buildExtractPrompt(w channelWindow, maxEpisodes int) (system, user string) {
	system = fmt.Sprintf(`You are the memory consolidator of a workplace secretary. You read a window of raw Slack messages from one channel and extract the noteworthy episodes — self-contained stories worth remembering (an incident, a decision, a launch, a conflict resolved), not routine chatter.

Respond with STRICT JSON only: an array of at most %d episodes, no prose, no markdown outside an optional single JSON code fence. Each episode is:
{"title": "short headline", "story": "2-4 sentence summary", "outcome": "resolution or null when still open", "participants": ["user id"], "refs": [{"channel_id": "channel id", "ts": "message ts"}], "entity_hints": ["alias of a person/channel/project involved"]}

Rules:
- copy ts values EXACTLY from the input, never invent or adjust them; every ref must point at one of the messages shown to you.
- most windows are routine chatter and contain no episodes: return [] for those.`, maxEpisodes)

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

// validateRefs enforces MEM-01 at write time: every ref is checked against
// the messages table and dropped when it does not resolve (never repaired).
// An episode whose refs ALL fail is discarded entirely.
//
// Counting semantics: dropped counts individual refs that failed validation
// — including the refs of fully-discarded episodes; the number of discarded
// episodes itself is len(eps) - len(kept).
func validateRefs(database *db.DB, eps []extractedEpisode) (kept []extractedEpisode, dropped int) {
	for _, ep := range eps {
		var surviving []episodeRef
		for _, ref := range ep.Refs {
			ok, err := database.MessageExists(ref.ChannelID, ref.TS)
			if err != nil || !ok {
				// A lookup error fails closed: MEM-01 forbids writing a ref
				// that was not positively validated.
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
	return kept, dropped
}
