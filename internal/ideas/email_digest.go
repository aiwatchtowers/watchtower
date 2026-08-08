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
		tag := fmt.Sprintf("gmail:%d:%s", accountID, th.threadID)
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

// runEmailDigests is the ideas registry's Gmail pre-digest pass: one Generate
// call per connected, Gmail-enabled Google account, over the thread window
// newer than that account's google_accounts.ideas_email_floor. A nil
// generator is a clean no-op (the inbox pipeline.go:253 pattern). Per-account
// errors are logged and the loop continues to the next account; the first
// error encountered is returned once every account has had a turn.
func (p *Pipeline) runEmailDigests(ctx context.Context) error {
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
		if err := p.runEmailDigestAccount(ctx, acct); err != nil {
			p.logf("ideas: email digest account %d: %v", acct.ID, err)
			if firstErr == nil {
				firstErr = err
			}
		}
	}
	return firstErr
}

// runEmailDigestAccount runs the email pre-digest pass for one account. A
// floor of 0 (never initialized) initializes to the account's current Gmail
// sync watermark and skips extraction — no backfill, the memory
// jira_ingest.go:80 precedent. Zero new messages is a clean no-op: no AI
// call, no row, floor untouched.
func (p *Pipeline) runEmailDigestAccount(ctx context.Context, acct db.GoogleAccount) error {
	floor, err := p.db.IdeasEmailFloor(acct.ID)
	if err != nil {
		return fmt.Errorf("getting ideas email floor: %w", err)
	}
	if floor == 0 {
		// gmail_last_internal_date IS the newest synced message's internal_date
		// for this account — exactly "current max internal_date" — so no extra
		// query is needed to initialize the floor.
		maxTS, werr := p.db.GetGmailAccountWatermark(acct.ID)
		if werr != nil {
			return fmt.Errorf("getting gmail sync watermark: %w", werr)
		}
		if maxTS == 0 {
			return nil // no synced mail yet — retry initialization next run
		}
		if serr := p.db.SetIdeasEmailFloor(acct.ID, maxTS); serr != nil {
			return fmt.Errorf("initializing ideas email floor: %w", serr)
		}
		p.logf("ideas: email account %d floor initialized at %v, no backfill", acct.ID, maxTS)
		return nil
	}

	msgs, err := p.db.ListGmailThreadsForExtract(acct.ID, floor, 500)
	if err != nil {
		return fmt.Errorf("listing gmail threads: %w", err)
	}
	if len(msgs) == 0 {
		return nil
	}

	threads := groupThreads(msgs)
	block, tags := renderEmailBlock(acct.ID, threads, p.maxPromptChars())

	tmpl, _ := p.getPrompt("ideas.digest_email")
	system := fmt.Sprintf(tmpl, prompts.Directive(p.language()))

	reply, usage, _, err := p.generator.Generate(digest.WithSource(ctx, "ideas.digest_email"), system, block, "")
	p.accumulateUsage(usage)
	if err != nil {
		return fmt.Errorf("generating email digest: %w", err)
	}

	raw, err := prompts.ExtractJSONObject(reply)
	if err != nil {
		return fmt.Errorf("extracting email digest JSON: %w", err)
	}
	var parsed streamTopics
	if err := json.Unmarshal([]byte(raw), &parsed); err != nil {
		return fmt.Errorf("parsing email digest JSON: %w", err)
	}
	if parsed.Topics == nil {
		return fmt.Errorf("email digest reply has no \"topics\" key")
	}
	topics := validateRefs(*parsed.Topics, tags)
	topicsJSON, err := json.Marshal(topics)
	if err != nil {
		return fmt.Errorf("marshaling email digest topics: %w", err)
	}

	minTS, maxTS := msgs[0].TSUnix, msgs[0].TSUnix
	for _, m := range msgs {
		if m.TSUnix < minTS {
			minTS = m.TSUnix
		}
		if m.TSUnix > maxTS {
			maxTS = m.TSUnix
		}
	}

	_, err = p.db.InsertStreamDigest(db.StreamDigest{
		Source:     "gmail",
		AccountID:  acct.ID,
		Scope:      "",
		PeriodFrom: time.Unix(int64(minTS), 0).UTC().Format(time.RFC3339),
		PeriodTo:   time.Unix(int64(maxTS), 0).UTC().Format(time.RFC3339),
		TopicsJSON: string(topicsJSON),
	})
	if err != nil {
		return fmt.Errorf("inserting stream digest: %w", err)
	}

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
