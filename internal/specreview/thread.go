package specreview

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/db"
)

// QuestionTimeout is how long the author has to answer a thread's question
// before the daemon's sweep closes it as expired (spec 2026-11-08 §3).
const QuestionTimeout = AuthorTimeout

// ThreadContextID is the conversation key of a spec review thread:
// "<workbench>:<root>:<key>", where root is the first ask of the review chain,
// so a re-round's card with the same item key continues the same thread. The
// Desktop computes the same key (testdata/thread_keys.json is the shared
// fixture).
func ThreadContextID(workbenchID, rootAskID int64, itemKey string) string {
	return strconv.FormatInt(workbenchID, 10) + ":" + strconv.FormatInt(rootAskID, 10) + ":" + itemKey
}

// ParseThreadContextID splits a key ThreadContextID made. Both ids are
// positive decimals in canonical form and the item key (which may hold
// colons) is not empty; anything else is not ok.
func ParseThreadContextID(s string) (workbenchID, rootAskID int64, itemKey string, ok bool) {
	wb, rest, ok1 := strings.Cut(s, ":")
	root, key, ok2 := strings.Cut(rest, ":")
	if !ok1 || !ok2 || key == "" {
		return 0, 0, "", false
	}
	w, okW := canonicalID(wb)
	r, okR := canonicalID(root)
	if !okW || !okR {
		return 0, 0, "", false
	}
	return w, r, key, true
}

// canonicalID parses a positive decimal id written as FormatInt writes it.
func canonicalID(s string) (int64, bool) {
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil || v <= 0 || strconv.FormatInt(v, 10) != s {
		return 0, false
	}
	return v, true
}

// Fenced blocks a thread agent may end a reply with (the Desktop parses them;
// testdata/thread_blocks is the shared fixture): one question to the author,
// {"question": "…"}, and one proposed finding, a ThreadFindingInput.
const (
	AskAuthorFence = "watchtower-ask-author"
	FindingFence   = "watchtower-finding"
)

// Sources of a thread finding's quote.
const (
	QuoteDocument = "document" // the document snapshot the reviewer saw
	QuoteThread   = "thread"   // the owner's own words in the thread
)

// ErrQuoteNotFound refuses a thread finding whose quote or where-quote is
// not found where it says it is.
var ErrQuoteNotFound = errors.New("not added: quote not found")

// ErrNoSuchItem is a thread-context key that names no item of the review.
var ErrNoSuchItem = errors.New("no such item")

// ThreadQuote is the quote a proposed finding rests on: Source is
// QuoteDocument or QuoteThread.
type ThreadQuote struct {
	Source string `json:"source"`
	Text   string `json:"text"`
}

// ThreadFindingInput is the finding block a thread agent proposes, as the
// Desktop hands it to `spec-review add-finding` on the owner's press.
type ThreadFindingInput struct {
	Kind     string      `json:"kind"`
	Severity string      `json:"severity"`
	Title    string      `json:"title"`
	Text     string      `json:"text"`
	Quote    ThreadQuote `json:"quote"`
	Where    *Anchor     `json:"where"`
}

// ThreadFinding is a validated thread finding: the finding JSON of a
// spec_review_thread_findings row. Speaker is set by validation (owner for a
// thread quote, agent for a document quote), Chapter from the where-anchor
// ("" = Other), Thread by the caller.
type ThreadFinding struct {
	Key      string      `json:"key"`
	Kind     string      `json:"kind"`
	Severity string      `json:"severity"`
	Title    string      `json:"title"`
	Text     string      `json:"text"`
	Chapter  string      `json:"chapter"`
	Quote    ThreadQuote `json:"quote"`
	Speaker  string      `json:"speaker"`
	Where    *Anchor     `json:"where"`
	Thread   string      `json:"thread"`
}

func validThreadFindingKind(k string) bool {
	switch k {
	case "differs", "missing", KindDecidedAlone, KindBlindSpot:
		return true
	}
	return false
}

// ValidateThreadFinding checks a proposed finding with Parse's own rules: a
// known kind, a non-empty title and text (clipped as every field), the quote
// a real substring of the document (speaker agent) or of one of ownerLines,
// the owner's rows of the thread (speaker owner), and the where-quote, when
// given, anchored in a chapter of the document. A quote or where-quote not
// found is ErrQuoteNotFound; every refusal starts "not added: ".
func ValidateThreadFinding(in ThreadFindingInput, doc string, t DocType, ownerLines []string) (ThreadFinding, error) {
	out := ThreadFinding{
		Kind: in.Kind, Severity: normSeverity(in.Severity), Title: field(in.Title), Text: field(in.Text),
		Quote: ThreadQuote{Source: in.Quote.Source, Text: in.Quote.Text},
	}
	switch {
	case !validThreadFindingKind(in.Kind):
		return ThreadFinding{}, fmt.Errorf("not added: kind %q is not differs, missing, decided_alone or blind_spot", in.Kind)
	case out.Title == "" || out.Text == "":
		return ThreadFinding{}, errors.New("not added: the finding needs a title and a text")
	}
	switch in.Quote.Source {
	case QuoteDocument:
		if !ContainsQuote(doc, in.Quote.Text) {
			return ThreadFinding{}, ErrQuoteNotFound
		}
		out.Speaker = SpeakerAgent
	case QuoteThread:
		for _, l := range ownerLines {
			if ContainsQuote(l, in.Quote.Text) {
				out.Speaker = SpeakerOwner
				break
			}
		}
		if out.Speaker == "" {
			return ThreadFinding{}, ErrQuoteNotFound
		}
	default:
		return ThreadFinding{}, ErrQuoteNotFound
	}
	whereQuote := ""
	if in.Where != nil {
		ch, h, ok := docValidator(doc, t).anchor(*in.Where)
		if !ok {
			return ThreadFinding{}, ErrQuoteNotFound
		}
		out.Chapter, out.Where, whereQuote = ch, &Anchor{Heading: h, Quote: in.Where.Quote}, in.Where.Quote
	}
	out.Key = itemKey("tf:", out.Text, whereQuote)
	return out, nil
}

// ThreadContext is the thread agent's first-turn context for item itemKey of
// ask askID's review: the data line, then fenced blocks — the document
// snapshot the reviewer saw, the item with its quotes, the whole stored
// result, the loop ledger and the author's replies, and the conversation and
// asks blocks BuildInputs builds for the reviewer (the same code). The item
// is looked up in the result (findings and theses), the ledger, the open
// items and the ask's thread findings; none is ErrNoSuchItem. It only reads.
func ThreadContext(ctx context.Context, d Deps, askID int64, itemKey string) (string, error) {
	ask, err := d.DB.GetOwnerAskByID(askID)
	if err != nil {
		return "", fmt.Errorf("loading ask %d: %w", askID, err)
	}
	row, err := d.DB.GetSpecReview(askID)
	if err != nil {
		return "", fmt.Errorf("reading spec review of ask %d: %w", askID, err)
	}
	kind, item, err := findThreadItem(d.DB, row, itemKey)
	if err != nil {
		return "", err
	}
	in := &inputs{src: Sources{
		Conversation: map[string]string{}, Asks: map[string]string{}, OwnerWords: map[string][]string{},
	}, refAt: map[string]time.Time{}}
	in.add("document", ask.DocSnapshot)
	in.add("item", "kind: "+kind+"\n"+item)
	in.add("result", orEmpty(row.Result, "null"))
	in.add("ledger", orEmpty(row.Ledger, "[]"))
	in.add("replies", orEmpty(row.Replies, "[]"))
	in.conversation(ctx, d, ask)
	if err := in.asks(d.DB, ask); err != nil {
		return "", err
	}
	if len(in.notes) > 0 {
		in.add("notes", "- "+strings.Join(in.notes, "\n- "))
	}
	return dataLine + "\n\n" + strings.Join(in.blocks, "\n"), nil
}

func orEmpty(s, empty string) string {
	if s == "" {
		return empty
	}
	return s
}

// findThreadItem finds key in row's result, ledger and open items, then in
// the ask's thread findings, and returns its kind and its JSON.
func findThreadItem(d *db.DB, row *db.SpecReview, key string) (kind, item string, err error) {
	var hit any
	if row.Result != "" {
		var r Result
		if err := json.Unmarshal([]byte(row.Result), &r); err != nil {
			return "", "", fmt.Errorf("spec review %d result: %w", row.AskID, err)
		}
		kind, hit = findInResult(r, key)
	}
	if hit == nil {
		ledger, open, err := decodeLoop(row)
		if err != nil {
			return "", "", err
		}
		for i := range ledger {
			if ledger[i].Key == key {
				kind, hit = "ledger", ledger[i]
				break
			}
		}
		for i := range open {
			if hit == nil && open[i].Key == key {
				kind, hit = "open_item", open[i]
				break
			}
		}
	}
	if hit == nil {
		tfs, err := d.ListSpecReviewThreadFindings(row.AskID)
		if err != nil {
			return "", "", err
		}
		for _, f := range tfs {
			if f.ItemKey == key {
				return "thread_finding", f.Finding, nil
			}
		}
		return "", "", ErrNoSuchItem
	}
	js, err := json.MarshalIndent(hit, "", "  ")
	if err != nil {
		return "", "", fmt.Errorf("encoding item %s: %w", key, err)
	}
	return kind, string(js), nil
}

// findInResult is the result's finding or thesis with key, and its kind.
func findInResult(r Result, key string) (string, any) {
	for _, a := range r.Agreements {
		if a.Key == key {
			return KindAgreement, a
		}
	}
	for _, x := range r.DecidedAlone {
		if x.Key == key {
			return KindDecidedAlone, x
		}
	}
	for _, b := range r.BlindSpots {
		if b.Key == key {
			return KindBlindSpot, b
		}
	}
	for _, c := range r.Checks {
		if c.Key == key {
			return KindCheck, c
		}
	}
	for _, t := range r.Theses {
		if t.Key == key {
			return "thesis", t
		}
	}
	return "", nil
}
