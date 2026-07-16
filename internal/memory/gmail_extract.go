package memory

// This file is the Gmail thread → episode extractor (behind memory.sources.gmail):
// a cheap-tier consolidator that turns each Gmail thread into at most one episode
// node, mirroring the Slack extractor's batching + own-watermark + MEM-04 freeze
// discipline over THREADS instead of channel windows (resolved ambiguity #1 — a
// thread IS one story arc). It shares the Slack extractor's tie-safe helpers
// (groupWindowsIntoBatches, safeWatermark) and node builder (buildEpisodeNodes),
// differing only in grouping (thread_id), prompt (memory.extract_email_episodes),
// ref scheme (mail:<message_id>, validated through the registry's mail resolver),
// and its OWN watermark (memory_gmail_last_extracted_ts).

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// gmailExtractSource is the WithSource tag that routes the Gmail extractor to
// the cheap model tier (see internal/digest/models.go and internal/codex/models.go).
const gmailExtractSource = prompts.MemoryExtractEmailEpisodes

// gmailExtractMsg is one message line of a thread fed to the email extractor.
type gmailExtractMsg struct {
	messageID string
	fromName  string
	fromEmail string
	tsUnix    float64
	body      string
}

// gmailThread is one Gmail thread — the extraction unit (one thread → at most
// one episode). tsUnix is parallel to messages (ascending) for the MEM-04
// watermark math.
type gmailThread struct {
	threadID     string
	subject      string
	participants []string // distinct "name <email>" senders, first-seen order
	messages     []gmailExtractMsg
	tsUnix       []float64
}

// groupGmailThreads groups the (globally ts-ordered) messages into per-thread
// units keyed by thread_id, then orders the threads by their earliest message ts
// so the watermark can trail completed threads (safeWatermark's ascending
// first-ts assumption, the buildWindows precedent). The subject is the first
// non-empty subject seen; participants are the distinct senders in first-seen
// order.
func groupGmailThreads(msgs []db.GmailExtractMessage) []gmailThread {
	index := make(map[string]int)
	var threads []gmailThread
	for _, m := range msgs {
		i, ok := index[m.ThreadID]
		if !ok {
			i = len(threads)
			index[m.ThreadID] = i
			threads = append(threads, gmailThread{threadID: m.ThreadID})
		}
		th := &threads[i]
		if th.subject == "" && m.Subject != "" {
			th.subject = m.Subject
		}
		th.messages = append(th.messages, gmailExtractMsg{
			messageID: m.MessageID, fromName: m.FromName, fromEmail: m.FromEmail,
			tsUnix: m.TSUnix, body: m.BodyText,
		})
		th.tsUnix = append(th.tsUnix, m.TSUnix)
	}
	for i := range threads {
		threads[i].participants = distinctSenders(threads[i].messages)
	}
	sort.SliceStable(threads, func(a, b int) bool {
		return threads[a].tsUnix[0] < threads[b].tsUnix[0]
	})
	return threads
}

// distinctSenders returns the thread's distinct "name <email>" sender labels in
// first-seen order — the Participants line the email prompt renders.
func distinctSenders(msgs []gmailExtractMsg) []string {
	seen := make(map[string]bool)
	var out []string
	for _, m := range msgs {
		label := senderLabel(m.fromName, m.fromEmail)
		if label == "" || seen[label] {
			continue
		}
		seen[label] = true
		out = append(out, label)
	}
	return out
}

// senderLabel renders a "name <email>" participant/sender label, degrading to
// just the email (or just the name) when one is missing.
func senderLabel(name, email string) string {
	name = strings.TrimSpace(name)
	email = strings.TrimSpace(email)
	switch {
	case name != "" && email != "":
		return name + " <" + email + ">"
	case email != "":
		return email
	default:
		return name
	}
}

// buildEmailEpisodesPrompt renders the memory.extract_email_episodes call:
// several threads, each under its own "=== Thread: subject ===" block with a
// participants line and "[unix] sender (mail:<id>): body" message lines.
// maxEpisodes bounds the whole call (one episode per thread at most). The user
// message deliberately opens with a non-dash line (the claude-CLI argv gotcha,
// TestBuildExtractPromptsNeverStartWithDash).
func buildEmailEpisodesPrompt(tmpl, lang string, threads []gmailThread, maxEpisodes int) (system, user string) {
	system = fmt.Sprintf(tmpl, prompts.Directive(lang), maxEpisodes)

	var b strings.Builder
	b.WriteString("Email threads:\n\n")
	for _, t := range threads {
		fmt.Fprintf(&b, "=== Thread: %s ===\n", oneLine(t.subject))
		if len(t.participants) > 0 {
			fmt.Fprintf(&b, "Participants: %s\n", strings.Join(t.participants, ", "))
		}
		b.WriteString("Messages:\n")
		for _, m := range t.messages {
			fmt.Fprintf(&b, "[%d] %s (mail:%s): %s\n",
				int64(m.tsUnix), senderLabel(m.fromName, m.fromEmail), m.messageID, oneLine(m.body))
		}
		b.WriteString("\n")
	}
	return system, b.String()
}

// oneLine collapses newlines/tabs to spaces so one message renders on one prompt
// line (bodies are already length-truncated at sync time).
func oneLine(s string) string {
	return strings.Join(strings.Fields(s), " ")
}

// runGmailExtract is the Gmail episode-extraction step (Run step 4b, behind
// memory.sources.gmail). It loads gmail_messages above the Gmail watermark
// (capped at MaxChunkMessages, boundary-drained for same-second tie safety),
// groups them into threads, and extracts one episode per thread, batching small
// threads into one AI call. The watermark advances only behind committed thread
// batches (MEM-04); a per-batch AI/lookup failure freezes every thread in that
// batch and re-extracts next run, never failing the run (batch isolation, the
// Slack extractor's contract). stepOffset is the number of Slack extraction
// batch rows already recorded, so Gmail batch rows number after them. Returns
// the number of Gmail batch pipeline_steps rows recorded.
func (p *Pipeline) runGmailExtract(ctx context.Context, runID int64, stepOffset int, acc *usageAccumulator, stats *RunStats) (int, error) {
	if p.generator == nil {
		return 0, nil
	}
	wm, err := p.db.MemoryGmailWatermark()
	if err != nil {
		return 0, err
	}
	msgs, err := p.db.ListGmailThreadsForExtract(wm, orDefault(p.cfg.MaxChunkMessages, 2000))
	if err != nil {
		return 0, err
	}
	if len(msgs) == 0 {
		return 0, nil
	}
	threads := groupGmailThreads(msgs)

	// Reuse the Slack extractor's tie-safe batching + watermark helpers by
	// projecting each thread onto a runWindow (thread_id as the channel bucket,
	// the thread's tsUnix as the window's). The projected Messages length feeds
	// the batch message-count bound only; the AI call reads the threads directly.
	windows := make([]runWindow, len(threads))
	for i, t := range threads {
		windows[i] = runWindow{
			channelWindow: channelWindow{
				ChannelID:   t.threadID,
				ChannelName: oneLine(t.subject),
				Messages:    make([]extractMsg, len(t.messages)),
			},
			tsUnix: t.tsUnix,
		}
	}
	done := make([]bool, len(threads))
	current := wm

	batches := groupWindowsIntoBatches(windows,
		orDefault(p.cfg.BatchMaxChannels, 20), orDefault(p.cfg.BatchMaxMessages, 1500))

	recorded := 0
	for bi, idxs := range batches {
		if ctx.Err() != nil {
			p.logf("memory: gmail extraction interrupted, %d threads left for the next run", remainingWindows(batches[bi:]))
			break
		}
		start := time.Now()
		episodes, usage, werr := p.extractGmailBatch(ctx, runID, threads, idxs)
		acc.add(usage)
		status := "done"
		if werr != nil {
			status = "error"
			stats.GmailThreadsFailed += len(idxs)
			p.logf("memory: gmail extract batch [%s]: %v", batchChannelNames(windows, idxs), werr)
		} else {
			for _, i := range idxs {
				done[i] = true
			}
			stats.GmailEpisodes += episodes
			current = p.advanceGmailWatermark(windows, done, current)
		}
		p.recordBatchStep(runID, stepOffset+bi+1, stepOffset+len(batches), status, windows, idxs, usage, start)
		recorded++
	}
	return recorded, nil
}

// advanceGmailWatermark moves the Gmail extraction watermark to the highest safe
// point behind the committed thread batches (MEM-04, the Slack advanceWatermark
// analog over memory_gmail_last_extracted_ts).
func (p *Pipeline) advanceGmailWatermark(windows []runWindow, done []bool, current float64) float64 {
	safe, ok := safeWatermark(windows, done)
	if !ok || safe <= current {
		return current
	}
	if err := p.db.SetMemoryGmailWatermark(safe); err != nil {
		p.logf("memory: set gmail watermark: %v", err)
		return current
	}
	return safe
}

// extractGmailBatch runs one email-extraction call over a batch of threads and
// commits the resulting episode nodes (plus entity back-links) as one vault
// commit. Any error means NONE of the batch's threads were committed (batch
// isolation). A schema-degenerate episode (zero refs, or refs spanning more than
// one shown thread) fails the whole batch (MEM-04, the splitMalformed precedent).
func (p *Pipeline) extractGmailBatch(ctx context.Context, runID int64, threads []gmailThread, idxs []int) (episodes int, usage *digest.Usage, err error) {
	batch := make([]gmailThread, len(idxs))
	msgToThread := make(map[string]string)
	for i, idx := range idxs {
		batch[i] = threads[idx]
		for _, m := range threads[idx].messages {
			msgToThread[m.messageID] = threads[idx].threadID
		}
	}
	label := gmailBatchLabel(batch)

	system, user := buildEmailEpisodesPrompt(p.getPrompt(prompts.MemoryExtractEmailEpisodes), p.Language, batch, len(batch))
	raw, usage, _, err := p.generator.Generate(digest.WithSource(ctx, gmailExtractSource), system, user, "")
	if err != nil {
		return 0, usage, fmt.Errorf("generate: %w", err)
	}
	eps, err := parseExtract(raw)
	if err != nil {
		return 0, usage, err
	}
	if len(eps) > len(batch) {
		eps = eps[:len(batch)] // at most one episode per thread
	}

	valid, malformed := splitMalformedEmail(eps, msgToThread)
	if malformed > 0 {
		return 0, usage, fmt.Errorf("memory: gmail extract returned %d episode(s) with zero or cross-thread refs — schema-degenerate reply", malformed)
	}
	// MEM-01/MEM-12: every mail: ref validates against gmail_messages through the
	// registry's mail resolver; a lookup error freezes the batch (re-extracted
	// next run), a positive miss drops the ref, an episode left with no ref is
	// discarded.
	kept, rejected, err := validateRefsVia(newProvenanceRegistry(mailResolver{p.db}), valid)
	if err != nil {
		return 0, usage, err
	}
	if rejected > 0 {
		p.logf("memory: gmail extract [%s]: refs_rejected=%d (MEM-01)", label, rejected)
	}
	if len(kept) == 0 {
		return 0, usage, nil // routine mail — a fully processed batch with nothing to keep
	}

	nodes, ids := p.buildEpisodeNodes(label, kept)
	msg := CommitMsg{
		Op:      "extract",
		Summary: fmt.Sprintf("%d gmail episodes from [%s]", len(kept), label),
		Cause:   fmt.Sprintf("run:%d", runID),
		NodeIDs: ids,
	}
	if _, err := p.vault.WriteNodes(nodes, msg); err != nil {
		return 0, usage, err
	}
	now := time.Now().UTC().Format(time.RFC3339)
	for _, n := range nodes {
		if err := upsertIndexNode(p.db, n, now); err != nil {
			// The vault commit stands; the index is derived and the next Reconcile
			// repairs it, so this does not fail the batch (the Slack extractor's rule).
			p.logf("memory: index %s after gmail extract: %v", n.ID, err)
		}
	}
	return len(kept), usage, nil
}

// splitMalformedEmail separates shape-valid email episodes (at least one ref,
// all refs pointing at messages of ONE shown thread) from shape-degenerate ones.
// A zero-ref episode, a ref to a message not shown in this batch, or refs
// spanning two threads are all schema violations the extractor was told never to
// produce — never written half-trusted (the Slack splitMalformed analog, but the
// "same channel_id" bucket is replaced by "same thread_id", since each email ref
// is a distinct mail:<message_id>).
func splitMalformedEmail(eps []extractedEpisode, msgToThread map[string]string) (valid []extractedEpisode, malformed int) {
	for _, ep := range eps {
		if len(ep.Refs) == 0 || !refsSameThread(ep.Refs, msgToThread) {
			malformed++
			continue
		}
		valid = append(valid, ep)
	}
	return valid, malformed
}

// refsSameThread reports whether every ref points at a message of a single shown
// thread. A ref whose message id was not shown in this batch (unknown scheme, or
// a message from another thread/outside the batch) makes the episode degenerate.
func refsSameThread(refs []episodeRef, msgToThread map[string]string) bool {
	var thread string
	for i, r := range refs {
		id := strings.TrimPrefix(r.ChannelID, mailRefPrefix)
		t, ok := msgToThread[id]
		if !ok {
			return false
		}
		if i == 0 {
			thread = t
		} else if t != thread {
			return false
		}
	}
	return true
}

// gmailBatchLabel renders a batch's thread subjects for the commit summary and
// logs, capped so a large batch cannot blow up a log line or vault message.
func gmailBatchLabel(threads []gmailThread) string {
	names := make([]string, len(threads))
	for i, t := range threads {
		s := oneLine(t.subject)
		if s == "" {
			s = "(no subject)"
		}
		names[i] = s
	}
	joined := strings.Join(names, ", ")
	const maxLen = 200
	if r := []rune(joined); len(r) > maxLen {
		joined = string(r[:maxLen]) + "…"
	}
	return joined
}
