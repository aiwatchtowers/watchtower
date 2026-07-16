package memory

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/digest"
)

// gmailPipelineConfig is pipelineTestConfig with the Gmail memory source ON.
func gmailPipelineConfig() config.MemoryConfig {
	cfg := pipelineTestConfig()
	cfg.Sources.Gmail = true
	return cfg
}

// gmailMsgTime renders an RFC3339 internal_date offsetSeconds after an hour ago
// and returns it alongside its whole-second unix value (what strftime yields).
func gmailMsgTime(offsetSeconds int) (iso string, unix int64) {
	t := time.Now().Add(-time.Hour).Add(time.Duration(offsetSeconds) * time.Second).UTC().Truncate(time.Second)
	return t.Format(time.RFC3339), t.Unix()
}

// emailEpisodeJSON renders a one-episode extractor reply with the given
// mail:<id> refs (each pair is {channel_id, ts}).
func emailEpisodeJSON(title string, refs ...[2]string) string {
	var rb strings.Builder
	for i, r := range refs {
		if i > 0 {
			rb.WriteString(", ")
		}
		fmt.Fprintf(&rb, `{"channel_id": %q, "ts": %q}`, r[0], r[1])
	}
	return fmt.Sprintf(`[{"title": %q, "story": "An email thread.", "outcome": "resolved",
		"participants": ["a@example.com", "b@example.com"],
		"refs": [%s], "entity_hints": []}]`, title, rb.String())
}

// TestGmailExtract_ThreadBecomesOneEpisode: a two-message thread becomes one
// episode with two mail: refs; the refs validate through the registry; the
// Gmail watermark advances to the newest thread message.
func TestGmailExtract_ThreadBecomesOneEpisode(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	iso1, u1 := gmailMsgTime(0)
	iso2, u2 := gmailMsgTime(60)
	seedGmailMessage(t, d, "m1", "thr-1", "a@example.com", "Ann", "Budget review", "Can we cut costs?", iso1)
	seedGmailMessage(t, d, "m2", "thr-1", "b@example.com", "Bob", "Re: Budget review", "Yes, done.", iso2)

	gen := &fakeGen{
		usage: digest.Usage{InputTokens: 100, OutputTokens: 20, TotalAPITokens: 150, Model: "haiku"},
		reply: func(string) (string, error) {
			return emailEpisodeJSON("Budget cut agreed",
				[2]string{"mail:m1", fmt.Sprintf("%d", u1)},
				[2]string{"mail:m2", fmt.Sprintf("%d", u2)}), nil
		},
	}
	p := NewPipeline(d, v, gen, gmailPipelineConfig(), t.Logf)

	stats, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, stats.GmailEpisodes)
	assert.Zero(t, stats.GmailThreadsFailed)

	// Episode in the vault with both mail refs.
	var epBody string
	nodes, err := d.ListMemoryNodes()
	require.NoError(t, err)
	for _, n := range nodes {
		if n.Type == "episode" {
			node, rerr := v.ReadNode(n.ID)
			require.NoError(t, rerr)
			epBody = node.Body
		}
	}
	assert.Contains(t, epBody, "mail:m1")
	assert.Contains(t, epBody, "mail:m2")

	wm, err := d.MemoryGmailWatermark()
	require.NoError(t, err)
	assert.Equal(t, float64(u2), wm, "watermark at the newest thread message")

	// The Slack extraction watermark is untouched.
	slackWM, err := d.MemoryWatermark()
	require.NoError(t, err)
	assert.Zero(t, slackWM)
}

// TestGmailExtract_ShapeDegenerateFreezesWatermark: a zero-ref (schema-drifted)
// thread freezes the Gmail watermark for its batch while a good sibling thread
// commits (BatchMaxChannels=1 → one thread per batch). MEM-04 over threads.
func TestGmailExtract_ShapeDegenerateFreezesWatermark(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	iso1, u1 := gmailMsgTime(0)
	iso2, _ := gmailMsgTime(120)
	seedGmailMessage(t, d, "m1", "thr-1", "a@example.com", "Ann", "Alpha thread", "hi", iso1)
	seedGmailMessage(t, d, "m2", "thr-2", "b@example.com", "Bob", "Beta thread", "yo", iso2)

	gen := &fakeGen{
		usage: digest.Usage{InputTokens: 100, OutputTokens: 20, TotalAPITokens: 150, Model: "haiku"},
		reply: func(user string) (string, error) {
			if strings.Contains(user, "Beta thread") {
				return `[{"title": "degenerate", "story": "s", "outcome": null, "participants": [], "refs": [], "entity_hints": []}]`, nil
			}
			return emailEpisodeJSON("Alpha done", [2]string{"mail:m1", fmt.Sprintf("%d", u1)}), nil
		},
	}
	p := NewPipeline(d, v, gen, gmailPipelineConfig(), t.Logf)

	stats, err := p.Run(context.Background())
	require.NoError(t, err, "batch isolation: a degenerate thread never fails the run")
	assert.Equal(t, 1, stats.GmailEpisodes, "the good thread committed")
	assert.Equal(t, 1, stats.GmailThreadsFailed)

	// Watermark == thr-1's newest message, never past the failed thr-2.
	wm, err := d.MemoryGmailWatermark()
	require.NoError(t, err)
	assert.Equal(t, float64(u1), wm)
}

// TestGmailExtract_AbsentGmailTablesNoOp: with gmail_messages absent, the gated
// Gmail extractor is a clean no-op — no error, watermark unmoved.
func TestGmailExtract_AbsentGmailTablesNoOp(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	_, err := d.Exec(`DROP TABLE gmail_messages`)
	require.NoError(t, err)

	p := NewPipeline(d, v, &fakeGen{reply: func(string) (string, error) { return "[]", nil }}, gmailPipelineConfig(), t.Logf)
	stats, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Zero(t, stats.GmailEpisodes)

	wm, err := d.MemoryGmailWatermark()
	require.NoError(t, err)
	assert.Zero(t, wm)
}

// TestGmailExtract_GateOffNoOp: with memory.sources.gmail false, no Gmail work
// happens even when gmail_messages has rows — watermark unmoved, no episodes.
func TestGmailExtract_GateOffNoOp(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	iso1, _ := gmailMsgTime(0)
	seedGmailMessage(t, d, "m1", "thr-1", "a@example.com", "Ann", "Budget", "hi", iso1)

	gen := &fakeGen{reply: func(string) (string, error) {
		return "", fmt.Errorf("generator must not be called for gmail when the gate is off")
	}}
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf) // gate OFF (default)

	stats, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Zero(t, stats.GmailEpisodes)

	wm, err := d.MemoryGmailWatermark()
	require.NoError(t, err)
	assert.Zero(t, wm, "gmail watermark unmoved when the source is dark")
}

// TestListGmailThreadsForExtract_BoundaryDrain: the same-second boundary is
// fully loaded even when the message limit cuts inside it, so the whole-second
// watermark never skips an unloaded same-second row.
func TestListGmailThreadsForExtract_BoundaryDrain(t *testing.T) {
	d := newTestDB(t)
	iso, _ := gmailMsgTime(0)
	// Three messages sharing one internal_date second.
	seedGmailMessage(t, d, "m1", "t1", "a@example.com", "A", "s", "b", iso)
	seedGmailMessage(t, d, "m2", "t2", "b@example.com", "B", "s", "b", iso)
	seedGmailMessage(t, d, "m3", "t3", "c@example.com", "C", "s", "b", iso)

	msgs, err := d.ListGmailThreadsForExtract(0, 2) // limit cuts inside the second
	require.NoError(t, err)
	assert.Len(t, msgs, 3, "boundary second drained past the limit")
}

// TestBuildEmailEpisodesPromptNeverStartsWithDash: the email extractor's user
// message must never open with a dash (the claude-CLI argv gotcha, same as the
// Slack extract builders).
func TestBuildEmailEpisodesPromptNeverStartsWithDash(t *testing.T) {
	thr := gmailThread{
		threadID: "t1", subject: "Budget",
		participants: []string{"Ann <a@example.com>"},
		messages:     []gmailExtractMsg{{messageID: "m1", fromName: "Ann", fromEmail: "a@example.com", tsUnix: 100, body: "hi"}},
		tsUnix:       []float64{100},
	}
	_, user := buildEmailEpisodesPrompt("%s %d", "en", []gmailThread{thr}, 1)
	assert.False(t, strings.HasPrefix(user, "-"), "email prompt must not start with '-'")
	assert.Contains(t, user, "mail:m1")
	assert.Contains(t, user, "Budget")
}
