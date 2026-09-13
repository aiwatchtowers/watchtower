package ideas

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// streamCandidate is one mined idea or decision candidate, in the JSON shape
// both the ideas.digest_email and ideas.digest_jira prompts emit (see
// internal/prompts/defaults.go's defaultIdeasDigestEmail/Jira) — shared by
// both this file and jira_digest.go.
type streamCandidate struct {
	Text   string `json:"text"`
	Author string `json:"author"`
	Ref    string `json:"ref"`
}

// streamTopic groups mined candidates under a short headline.
type streamTopic struct {
	Title     string            `json:"title"`
	Summary   string            `json:"summary"`
	Ideas     []streamCandidate `json:"ideas"`
	Decisions []streamCandidate `json:"decisions"`
}

// streamTopics is the top-level JSON shape both stage-1 prompts return, and
// what stream_digests.topics_json holds (the array of streamTopic). Topics is
// a POINTER for the same reason consolidateResult.Ops is: a reply that omits
// the key entirely answered nothing and must be treated as a model error (no
// row, floor unchanged), not as an empty-but-valid verdict.
type streamTopics struct {
	Topics *[]streamTopic `json:"topics"`
}

// validateRefs drops every candidate whose Ref is not in validTags — the
// model is never trusted to copy a ref correctly (the model only proposes,
// Go disposes). A topic left with no surviving candidates is dropped too.
// Always returns a non-nil slice (possibly empty) so its json.Marshal is a
// well-formed "[]", never "null" — stream_digests.topics_json must stay a
// valid array for the stage-2 consolidator.
func validateRefs(topics []streamTopic, validTags map[string]bool) []streamTopic {
	out := []streamTopic{}
	for _, t := range topics {
		t.Ideas = filterCandidates(t.Ideas, validTags)
		t.Decisions = filterCandidates(t.Decisions, validTags)
		if len(t.Ideas) == 0 && len(t.Decisions) == 0 {
			continue
		}
		out = append(out, t)
	}
	return out
}

func filterCandidates(cands []streamCandidate, validTags map[string]bool) []streamCandidate {
	out := []streamCandidate{}
	for _, c := range cands {
		if validTags[c.Ref] {
			out = append(out, c)
		}
	}
	return out
}

// maxMessagesPerThread caps a poison thread at its newest N messages so a
// single oversized thread cannot blow the prompt budget (the
// internal/memory/gmail_extract.go groupGmailThreads precedent).
const maxMessagesPerThread = 50

// emailThread is one Gmail thread grouped for the ideas email pre-digest — a
// local, deliberately independent copy of the shape
// internal/memory/gmail_extract.go's groupGmailThreads builds: the ideas
// registry mines topics, memory mines episodes, and the two packages must
// not import each other.
type emailThread struct {
	threadID     string
	subject      string
	participants []string
	messages     []db.GmailExtractMessage
}

// groupThreads groups accountID's ts-ordered gmail messages into per-thread
// units keyed by thread_id: the first non-empty subject wins, participants
// are distinct "name <email>" senders in first-seen order, and a thread is
// capped at its newest maxMessagesPerThread messages.
func groupThreads(msgs []db.GmailExtractMessage) []emailThread {
	index := make(map[string]int)
	var threads []emailThread
	for _, m := range msgs {
		i, ok := index[m.ThreadID]
		if !ok {
			i = len(threads)
			index[m.ThreadID] = i
			threads = append(threads, emailThread{threadID: m.ThreadID})
		}
		th := &threads[i]
		if th.subject == "" && m.Subject != "" {
			th.subject = m.Subject
		}
		th.messages = append(th.messages, m)
	}
	for i := range threads {
		if n := len(threads[i].messages); n > maxMessagesPerThread {
			threads[i].messages = threads[i].messages[n-maxMessagesPerThread:]
		}
		threads[i].participants = distinctSenders(threads[i].messages)
	}
	return threads
}

// distinctSenders returns a thread's distinct "name <email>" sender labels in
// first-seen order.
func distinctSenders(msgs []db.GmailExtractMessage) []string {
	seen := make(map[string]bool)
	var out []string
	for _, m := range msgs {
		label := senderLabel(m.FromName, m.FromEmail)
		if label == "" || seen[label] {
			continue
		}
		seen[label] = true
		out = append(out, label)
	}
	return out
}

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

// emailExcerptBytes caps each message's rendered excerpt.
const emailExcerptBytes = 240

// emailThreadTag is the one place the Gmail stage-1 ref format is spelled
// out: renderEmailBlock stamps it into the block and the tag set, and
// renderedEmailWindow reads it back to decide which messages this run may
// claim. Both must agree, or the floor would advance over material the model
// was never shown.
func emailThreadTag(accountID int64, threadID string) string {
	return fmt.Sprintf("gmail:%d:%s", accountID, threadID)
}

// renderEmailBlock renders one numbered line per thread — "[n] <subject>
// (gmail:<accountID>:<threadID>): <participants> — <excerpts>" — and returns
// the set of "gmail:<accountID>:<threadID>" tags a candidate's ref must copy
// exactly to survive validateRefs. Threads are appended whole until maxChars
// is spent; a thread that doesn't fit is left out of BOTH the block and the
// tag set, so a candidate can never validate against material the model was
// never shown.
func renderEmailBlock(accountID int64, threads []emailThread, maxChars int) (string, map[string]bool) {
	var b strings.Builder
	tags := make(map[string]bool, len(threads))
	budget := maxChars
	for i, th := range threads {
		tag := emailThreadTag(accountID, th.threadID)
		subject := th.subject
		if subject == "" {
			subject = "(no subject)"
		}
		var excerpts []string
		for _, m := range th.messages {
			if ex := capBytes(oneLine(m.BodyText), emailExcerptBytes); ex != "" {
				excerpts = append(excerpts, ex)
			}
		}
		line := fmt.Sprintf("[%d] %s (%s): %s — %s\n", i+1, subject, tag,
			strings.Join(th.participants, ", "), strings.Join(excerpts, " / "))
		if len(line) > budget {
			break
		}
		budget -= len(line)
		tags[tag] = true
		b.WriteString(line)
	}
	return b.String(), tags
}

// renderedEmailWindow returns the message-timestamp window one email pass may
// claim — the period its stream_digests row covers and the furthest its floor
// may advance. renderedTags is renderEmailBlock's tag set, i.e. exactly the
// threads put in front of the model (and so exactly what a candidate may cite,
// IDEA-02).
//
// msgs arrives ordered by timestamp ascending, so the scan stops at the first
// message whose thread the prompt budget dropped: everything below that point
// was rendered, everything from it on must stay unclaimed. A plain max over
// rendered threads would not do — thread render order follows each thread's
// FIRST message, so a dropped thread can hold messages older than a rendered
// one's, and the floor would bury them (IDEA-01).
//
// ok is false when not even the oldest message's thread was rendered: nothing
// was mined, so the floor must not move at all.
func renderedEmailWindow(accountID int64, msgs []db.GmailExtractMessage, renderedTags map[string]bool) (minTS, maxTS float64, ok bool) {
	for _, m := range msgs {
		if !renderedTags[emailThreadTag(accountID, m.ThreadID)] {
			break
		}
		if !ok {
			minTS, maxTS, ok = m.TSUnix, m.TSUnix, true
			continue
		}
		if m.TSUnix < minTS {
			minTS = m.TSUnix
		}
		if m.TSUnix > maxTS {
			maxTS = m.TSUnix
		}
	}
	return minTS, maxTS, ok
}

// mineStreamTopics performs one stage-1 AI call over block and returns the
// topics that survived ref validation against renderedTags. promptID doubles
// as the digest source tag (the two are the same string for both stage-1
// passes). A generator, extraction, parse, or missing-"topics"-key failure
// returns an error, so the caller writes no row and leaves its floor untouched
// (IDEA-01). Shared by the Gmail and Jira passes, which differ only in their
// prompt and their tag vocabulary.
func (p *Pipeline) mineStreamTopics(ctx context.Context, promptID, block string, renderedTags map[string]bool) ([]streamTopic, error) {
	tmpl, _ := p.getPrompt(promptID)
	system := fmt.Sprintf(tmpl, prompts.Directive(p.language()))

	reply, usage, _, err := p.generator.Generate(digest.WithSource(ctx, promptID), system, block, "")
	p.accumulateUsage(usage)
	if err != nil {
		return nil, fmt.Errorf("generating %s: %w", promptID, err)
	}

	raw, err := prompts.ExtractJSONObject(reply)
	if err != nil {
		return nil, fmt.Errorf("extracting %s JSON: %w", promptID, err)
	}
	var parsed streamTopics
	if err := json.Unmarshal([]byte(raw), &parsed); err != nil {
		return nil, fmt.Errorf("parsing %s JSON: %w", promptID, err)
	}
	if parsed.Topics == nil {
		return nil, fmt.Errorf("%s reply has no \"topics\" key", promptID)
	}
	return validateRefs(*parsed.Topics, renderedTags), nil
}

// insertStreamTopics writes one stream_digests row carrying topics, or writes
// nothing at all when validation left nothing behind. An empty row is a digest
// with no content: it badges the Desktop Digests feed as unread for nothing,
// and it marks a window as covered on the strength of material it does not
// carry. The caller still advances its floor — the window was genuinely mined,
// it simply had nothing worth recording (IDEA-01's converse clause). what
// labels the account in the skip log.
func (p *Pipeline) insertStreamTopics(row db.StreamDigest, topics []streamTopic, what string) error {
	if len(topics) == 0 {
		p.logf("ideas: %s: no topics survived validation, no stream_digests row written", what)
		return nil
	}
	topicsJSON, err := json.Marshal(topics)
	if err != nil {
		return fmt.Errorf("marshaling stream digest topics: %w", err)
	}
	row.TopicsJSON = string(topicsJSON)
	if _, err := p.db.InsertStreamDigest(row); err != nil {
		return fmt.Errorf("inserting stream digest: %w", err)
	}
	return nil
}

// runEmailDigests is the ideas registry's Gmail pre-digest pass: one Generate
// call per connected, Gmail-enabled Google account, over the thread window
// newer than that account's google_accounts.ideas_email_floor. A nil
// generator is a clean no-op (the inbox pipeline.go:253 pattern). Per-account
// errors are logged and the loop continues to the next account; the first
// error encountered is returned once every account has had a turn. bound is
// an optional upper bound on the thread window (the zero value is unbounded
// — Run's ordinary daemon/incremental path passes time.Time{}); a non-zero
// bound is how a backfill run scopes one pass to a slice of history.
func (p *Pipeline) runEmailDigests(ctx context.Context, bound time.Time) error {
	if p.generator == nil {
		return nil
	}
	accounts, err := p.db.ListGoogleAccounts()
	if err != nil {
		return fmt.Errorf("ideas: listing google accounts: %w", err)
	}
	var firstErr error
	for _, acct := range accounts {
		if !acct.GmailEnabled {
			continue
		}
		if err := p.runEmailDigestAccount(ctx, acct, bound); err != nil {
			p.logf("ideas: email digest account %d: %v", acct.ID, err)
			if firstErr == nil {
				firstErr = err
			}
		}
	}
	return firstErr
}

// initEmailFloor stamps a never-initialized account's ideas floor at its
// current Gmail sync watermark and mines nothing — no backfill, the memory
// jira_ingest.go:80 precedent. gmail_last_internal_date IS the newest synced
// message's internal_date for this account, so no extra query is needed. No
// synced mail yet leaves the floor at 0 for the next run to initialize.
func (p *Pipeline) initEmailFloor(acct db.GoogleAccount) error {
	maxTS, err := p.db.GetGmailAccountWatermark(acct.ID)
	if err != nil {
		return fmt.Errorf("getting gmail sync watermark: %w", err)
	}
	if maxTS == 0 {
		return nil
	}
	if err := p.db.SetIdeasEmailFloor(acct.ID, maxTS); err != nil {
		return fmt.Errorf("initializing ideas email floor: %w", err)
	}
	p.logf("ideas: email account %d floor initialized at %v, no backfill", acct.ID, maxTS)
	return nil
}

// runEmailDigestAccount runs the email pre-digest pass for one account. A
// floor of 0 (never initialized) initializes and skips extraction. Zero new
// messages is a clean no-op: no AI call, no row, floor untouched — and so is
// a prompt budget that fits no thread at all, since a floor may only advance
// over threads the model actually saw (IDEA-01).
func (p *Pipeline) runEmailDigestAccount(ctx context.Context, acct db.GoogleAccount, bound time.Time) error {
	floor, err := p.db.IdeasEmailFloor(acct.ID)
	if err != nil {
		return fmt.Errorf("getting ideas email floor: %w", err)
	}
	if floor == 0 {
		return p.initEmailFloor(acct)
	}

	var beforeTS float64
	if !bound.IsZero() {
		beforeTS = float64(bound.Unix())
	}
	msgs, err := p.db.ListGmailThreadsForExtract(acct.ID, floor, beforeTS, 500)
	if err != nil {
		return fmt.Errorf("listing gmail threads: %w", err)
	}
	if len(msgs) == 0 {
		return nil
	}

	block, tags := renderEmailBlock(acct.ID, groupThreads(msgs), p.maxPromptChars())
	minTS, maxTS, rendered := renderedEmailWindow(acct.ID, msgs, tags)
	if !rendered {
		// The oldest thread alone outgrows the whole prompt budget, so this
		// pass has nothing to show the model and nothing it may claim. Leave
		// the floor where it is and say why: the window is retried next run,
		// and the operator can see that ideas.max_prompt_chars is too small
		// for it rather than watching the material disappear.
		p.logf("ideas: email account %d: prompt budget fits no thread, nothing mined (floor unchanged)", acct.ID)
		return nil
	}

	topics, err := p.mineStreamTopics(ctx, "ideas.digest_email", block, tags)
	if err != nil {
		return err
	}

	if err := p.insertStreamTopics(db.StreamDigest{
		Source:     "gmail",
		AccountID:  acct.ID,
		Scope:      "",
		PeriodFrom: time.Unix(int64(minTS), 0).UTC().Format(time.RFC3339),
		PeriodTo:   time.Unix(int64(maxTS), 0).UTC().Format(time.RFC3339),
	}, topics, fmt.Sprintf("email account %d", acct.ID)); err != nil {
		return err
	}

	// maxTS is the newest RENDERED message, never the newest loaded one: a
	// thread the budget dropped stays above the floor and is mined next run.
	if err := p.db.SetIdeasEmailFloor(acct.ID, maxTS); err != nil {
		return fmt.Errorf("advancing ideas email floor: %w", err)
	}
	return nil
}

// oneLine collapses a body of text to a single line for a compact excerpt.
func oneLine(s string) string {
	return strings.Join(strings.Fields(s), " ")
}

// capBytes truncates s to at most maxBytes bytes on a rune boundary,
// appending "…" when truncated.
func capBytes(s string, maxBytes int) string {
	if len(s) <= maxBytes {
		return s
	}
	cut := maxBytes
	for cut > 0 && !isRuneStart(s[cut]) {
		cut--
	}
	return s[:cut] + "…"
}

func isRuneStart(b byte) bool { return b&0xC0 != 0x80 }
