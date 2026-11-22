package watchman

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/instructions"
	"watchtower/internal/prompts"
)

// decidePrecedents is how many precedents the twin reads per item (spec §4).
const decidePrecedents = 8

// ErrChoiceNotOffered reports a model choice that is not one of the item's
// options.
var ErrChoiceNotOffered = errors.New("watchman: the choice is not one of the offered options")

// ErrBadReply wraps every Decide error that comes from the model's reply
// (not JSON, a missing choice, an unknown enum, a choice not offered) rather
// than from the call: the backtest counts such an item as a disagreement.
var ErrBadReply = errors.New("watchman decide: unusable reply")

// decideCategories are the fixed decision categories (the CHECK of
// watchman_precedents.category).
var decideCategories = map[string]bool{
	"design": true, "scope": true, "ux_text": true, "tests": true,
	"review_code": true, "review_doc": true, "permission": true, "finish": true,
}

// Item is one decision the twin makes. The caller supplies Profile and
// Instructions (LiveContext for a live item, a leak-free profile in the
// backtest); Decide never reads watchman_profile itself. Retrieval sees only
// precedents decided strictly before DecidedBefore and not in Exclude.
type Item struct {
	WorkbenchID   int64
	Category      string
	Situation     string
	Options       []string
	DecidedBefore time.Time
	Exclude       []int64
	Profile       string
	Instructions  string
	// SessionInstructions is the owner's instruction for the session the
	// item waits in ("Target: …" then "Session: …", LiveDecide); "" in the
	// backtest, which has no session. It never lifts a hard limit: those
	// run in Go before and after the model (WATCHMAN-01).
	SessionInstructions string
	// ItemID and SessionID place a live item (its watchman_items row and
	// session; 0 = none) for LiveDecide's read and log. Never sent to the
	// model.
	ItemID, SessionID int64
	// Findings are the spec review's findings of a review_doc item, by key:
	// what the reply's marks may name.
	Findings []Finding
}

// Finding is one keyed finding of a spec review the twin may mark.
type Finding struct {
	Key  string `json:"key"`
	Text string `json:"text"`
}

// TwinMarkReply is the twin's mark on one finding of a review_doc item:
// State ok, comment or not_useful; Body its words on a comment.
type TwinMarkReply struct {
	Key   string `json:"key"`
	State string `json:"state"`
	Body  string `json:"body"`
}

// markStates are the states a twin mark may carry.
var markStates = map[string]bool{"ok": true, "comment": true, "not_useful": true}

// The twin's handoff values (spec §4 "Hand to the owner", D35): owner_only
// when the step needs the owner's own hands (a token, a sign-in, a command
// on his side, his device, a payment); none for everything else.
const (
	HandoffNone      = "none"
	HandoffOwnerOnly = "owner_only"
)

// Decision is the twin's validated answer. Confidence is low, medium or high;
// Importance is low or high; Handoff is HandoffNone or HandoffOwnerOnly (a
// reply without it is none). PrecedentIDs holds only ids that were retrieved
// for the item. Marks, only for a review_doc item, holds only marks on the
// item's findings with a known state.
type Decision struct {
	Choice, Rationale, Category, Confidence, Importance, Handoff string
	PrecedentIDs                                                 []int64
	Marks                                                        []TwinMarkReply
	Usage                                                        *digest.Usage
}

// LiveContext returns the stored profile text of category and the owner's
// current instructions (global and the workbench's) for a live item.
func LiveContext(d *db.DB, workbenchID int64, category string) (profile, instr string, err error) {
	ps, err := d.WatchmanProfiles(workbenchID)
	if err != nil {
		return "", "", fmt.Errorf("watchman live context: %w", err)
	}
	for _, p := range ps {
		if p.Key == category {
			profile = p.Text
		}
	}
	t, err := instructions.Load(d, workbenchID)
	if err != nil {
		return "", "", fmt.Errorf("watchman live context: %w", err)
	}
	return profile, renderInstructions(t), nil
}

// renderInstructions joins the session and procedure texts under short
// headers; "" when every text is empty.
func renderInstructions(t instructions.Texts) string {
	var parts []string
	for _, s := range []struct{ head, body string }{
		{"Session instructions:", t.Global.Session},
		{"Session instructions for this workbench:", t.Workbench.Session},
		{"Target procedure:", t.Global.Procedure},
		{"Target procedure for this workbench:", t.Workbench.Procedure},
	} {
		if b := strings.TrimSpace(s.body); b != "" {
			parts = append(parts, s.head+"\n"+b)
		}
	}
	return strings.Join(parts, "\n\n")
}

type decidePrecedent struct {
	ID         int64  `json:"id"`
	Situation  string `json:"situation"`
	Choice     string `json:"choice"`
	OwnerWords string `json:"owner_words"`
	DecidedAt  string `json:"decided_at"`
}

type decideInput struct {
	Category   string            `json:"category"`
	Situation  string            `json:"situation"`
	Options    []string          `json:"options"`
	Precedents []decidePrecedent `json:"precedents"`
	Profile    string            `json:"profile"`
	// SessionInstructions sits between the profile and the standing
	// instructions, as in the prompt (watchman.decide v5).
	SessionInstructions string    `json:"session_instructions"`
	Instructions        string    `json:"instructions"`
	Findings            []Finding `json:"findings,omitempty"`
}

type decideReply struct {
	Choice       string          `json:"choice"`
	Rationale    string          `json:"rationale"`
	PrecedentIDs []int64         `json:"precedent_ids"`
	Confidence   string          `json:"confidence"`
	Category     string          `json:"category"`
	Importance   string          `json:"importance"`
	Handoff      string          `json:"handoff"`
	Marks        []TwinMarkReply `json:"marks"`
}

// Decide retrieves the item's precedents, asks the model on the strong tier
// and validates its answer. It never writes. On a reply that fails validation
// the returned Decision still carries the call's Usage, so callers can count
// the cost.
func Decide(ctx context.Context, d *db.DB, gen digest.Generator, store *prompts.Store, it Item) (Decision, error) {
	ps, err := d.SearchWatchmanPrecedents(it.WorkbenchID, it.Category, it.Situation, it.DecidedBefore, it.Exclude, decidePrecedents)
	if err != nil {
		return Decision{}, fmt.Errorf("watchman decide: retrieving precedents: %w", err)
	}
	user, err := buildDecideUser(it, ps)
	if err != nil {
		return Decision{}, err
	}
	// Known-safe ignore: on a failed or empty store read Resolve still hands
	// back the built-in template, and Decide has no logger to report it to.
	tmpl, _, _ := prompts.Resolve(store, prompts.WatchmanDecide, "")
	raw, usage, _, err := gen.Generate(digest.WithSource(ctx, prompts.WatchmanDecide), tmpl, user, "")
	if err != nil {
		return Decision{Usage: usage}, fmt.Errorf("watchman decide: generating: %w", err)
	}
	dec, err := parseDecision(raw, it, ps)
	dec.Usage = usage
	if err != nil {
		return dec, fmt.Errorf("%w: %w", ErrBadReply, err)
	}
	return dec, nil
}

// buildDecideUser fences the item and its context as data: one JSON object
// between <data> and </data>. json.Marshal escapes '<' and '>', so no text in
// it can close the fence.
func buildDecideUser(it Item, ps []db.WatchmanPrecedent) (string, error) {
	in := decideInput{
		Category: it.Category, Situation: it.Situation, Options: it.Options,
		Precedents: make([]decidePrecedent, 0, len(ps)), Profile: it.Profile,
		SessionInstructions: it.SessionInstructions, Instructions: it.Instructions,
	}
	if it.Category == CategoryReviewDoc {
		in.Findings = it.Findings
	}
	if in.Options == nil {
		in.Options = []string{}
	}
	for _, p := range ps {
		in.Precedents = append(in.Precedents, decidePrecedent{
			ID: p.ID, Situation: p.Situation, Choice: p.Choice, OwnerWords: p.OwnerWords,
			DecidedAt: p.DecidedAt.UTC().Format(time.RFC3339),
		})
	}
	body, err := json.Marshal(in)
	if err != nil {
		return "", fmt.Errorf("watchman decide: encoding the item: %w", err)
	}
	return "=== DATA ===\n<data>\n" + string(body) + "\n</data>\n", nil
}

// parseDecision decodes the reply (one surrounding code fence dropped),
// checks the enums and the choice, and keeps only retrieved precedent ids
// and, for a review_doc item, marks on its findings.
func parseDecision(raw string, it Item, ps []db.WatchmanPrecedent) (Decision, error) {
	options := it.Options
	var r decideReply
	if err := json.Unmarshal([]byte(trimJSONFence(strings.TrimSpace(raw))), &r); err != nil {
		return Decision{}, fmt.Errorf("watchman decide: the reply is not a JSON object: %w", err)
	}
	dec := Decision{
		Choice: strings.TrimSpace(r.Choice), Rationale: strings.TrimSpace(r.Rationale),
		Category: r.Category, Confidence: r.Confidence, Importance: r.Importance, Handoff: r.Handoff,
	}
	if dec.Handoff == "" {
		dec.Handoff = HandoffNone
	}
	switch {
	case dec.Choice == "":
		return Decision{}, errors.New("watchman decide: the reply has no choice")
	case !decideCategories[dec.Category]:
		return Decision{}, fmt.Errorf("watchman decide: unknown category %q", dec.Category)
	case dec.Confidence != "low" && dec.Confidence != "medium" && dec.Confidence != "high":
		return Decision{}, fmt.Errorf("watchman decide: unknown confidence %q", dec.Confidence)
	case dec.Importance != "low" && dec.Importance != "high":
		return Decision{}, fmt.Errorf("watchman decide: unknown importance %q", dec.Importance)
	case dec.Handoff != HandoffNone && dec.Handoff != HandoffOwnerOnly:
		return Decision{}, fmt.Errorf("watchman decide: unknown handoff %q", dec.Handoff)
	}
	if len(options) > 0 {
		offered := ""
		for _, o := range options {
			if strings.TrimSpace(o) == dec.Choice {
				offered = o
				break
			}
		}
		if offered == "" {
			return Decision{}, fmt.Errorf("%w: %q", ErrChoiceNotOffered, dec.Choice)
		}
		dec.Choice = offered
	}
	known := make(map[int64]bool, len(ps))
	for _, p := range ps {
		known[p.ID] = true
	}
	for _, id := range r.PrecedentIDs {
		if known[id] {
			dec.PrecedentIDs = append(dec.PrecedentIDs, id)
			known[id] = false // once
		}
	}
	if it.Category == CategoryReviewDoc {
		dec.Marks = keptMarks(r.Marks, it.Findings)
	}
	return dec, nil
}

// keptMarks keeps the marks on known finding keys with a known state, the
// last one on a key winning; unknown ones are dropped.
func keptMarks(marks []TwinMarkReply, findings []Finding) []TwinMarkReply {
	known := make(map[string]bool, len(findings))
	for _, f := range findings {
		known[f.Key] = true
	}
	var out []TwinMarkReply
	at := map[string]int{}
	for _, m := range marks {
		m.Key, m.State, m.Body = strings.TrimSpace(m.Key), strings.TrimSpace(m.State), strings.TrimSpace(m.Body)
		if !known[m.Key] || !markStates[m.State] {
			continue
		}
		if i, ok := at[m.Key]; ok {
			out[i] = m
			continue
		}
		at[m.Key] = len(out)
		out = append(out, m)
	}
	return out
}

// trimJSONFence drops one surrounding ``` fence (and its info string).
func trimJSONFence(s string) string {
	if !strings.HasPrefix(s, "```") || !strings.HasSuffix(s, "```") || len(s) < 6 {
		return s
	}
	body := strings.TrimSuffix(s[3:], "```")
	if nl := strings.IndexByte(body, '\n'); nl >= 0 {
		body = body[nl+1:]
	}
	return strings.TrimSpace(body)
}
