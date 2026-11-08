// Package specreview holds the pure part of the spec reviewer: the result
// types (a cross-language contract the Desktop decodes), the document
// chapters, and the validation that keeps an invented quote out of storage.
package specreview

import "strings"

// DocType is the kind of document under review.
type DocType string

const (
	Spec  DocType = "spec"
	Plan  DocType = "plan"
	Other DocType = "other"
)

func validDocType(s string) bool {
	switch DocType(s) {
	case Spec, Plan, Other:
		return true
	}
	return false
}

// ClassifyDoc returns explicit when it is a valid type, else decides from the
// relative path: /specs/ or a -design.md suffix is a spec, /plans/ a plan.
func ClassifyDoc(explicit, relPath string) DocType {
	if e := strings.ToLower(strings.TrimSpace(explicit)); validDocType(e) {
		return DocType(e)
	}
	p := "/" + strings.TrimPrefix(strings.ReplaceAll(relPath, "\\", "/"), "/")
	switch {
	case strings.Contains(p, "/specs/") || strings.HasSuffix(p, "-design.md"):
		return Spec
	case strings.Contains(p, "/plans/"):
		return Plan
	}
	return Other
}

// Chapter is a slice of the document snapshot, by byte offsets.
type Chapter struct {
	Key     string `json:"key"` // ch:<n>, 1-based; ch:0 is the intro
	Heading string `json:"heading"`
	Start   int    `json:"start"`
	End     int    `json:"end"`
}

// Anchor points at a quote under a heading of the document.
type Anchor struct {
	Heading string `json:"heading"`
	Quote   string `json:"quote"`
}

// Source says where an agreement was made. Kind is one of conversation, ask,
// target, comment, decisions, spec. Speaker is set by Parse, never taken from
// the model: "owner" when the quote is the owner's own words (an owner line of
// the conversation, the owner's part of an ask answer, an owner comment), else
// "agent" (agent text, an ask's question or summary, an agent comment, the
// target, the document's Decisions section, the spec).
type Source struct {
	Kind    string `json:"kind"`
	Ref     string `json:"ref"`
	Quote   string `json:"quote"`
	Speaker string `json:"speaker"`
}

// Speakers of a Source.
const (
	SpeakerOwner = "owner"
	SpeakerAgent = "agent"
)

// Evidence is a place in the folder.
type Evidence struct {
	Path string `json:"path"`
	Line int    `json:"line"`
}

// Agreement compares one agreed point with the document. Status is as_agreed,
// differs or missing.
type Agreement struct {
	Key     string  `json:"key"`
	Text    string  `json:"text"`
	Status  string  `json:"status"`
	Note    string  `json:"note"`
	Chapter string  `json:"chapter"`
	Source  Source  `json:"source"`
	Where   *Anchor `json:"where"`
	// Severity is blocker, major or minor; empty on an as_agreed agreement.
	Severity string `json:"severity,omitempty"`
}

// DecidedAlone is something the document decides that nobody agreed.
type DecidedAlone struct {
	Key     string `json:"key"`
	Text    string `json:"text"`
	Note    string `json:"note"`
	Chapter string `json:"chapter"`
	Where   Anchor `json:"where"`
	// Severity is blocker, major or minor, or empty.
	Severity string `json:"severity,omitempty"`
}

// BlindSpot is something neither the owner nor the document considered.
type BlindSpot struct {
	Key      string    `json:"key"`
	Text     string    `json:"text"`
	Why      string    `json:"why"`
	Chapter  string    `json:"chapter"`
	Where    *Anchor   `json:"where"`
	Evidence *Evidence `json:"evidence"`
	// Severity is blocker, major or minor, or empty.
	Severity string `json:"severity,omitempty"`
}

// Check is the answer to one lens question for one chapter. Answer is ok,
// concern or n/a.
type Check struct {
	Key      string `json:"key"`
	Chapter  string `json:"chapter"`
	Lens     string `json:"lens"`
	Question string `json:"question"`
	Answer   string `json:"answer"`
	Note     string `json:"note"`
	// Severity is blocker, major or minor; empty unless Answer is concern.
	Severity string `json:"severity,omitempty"`
}

// Resolved reports a comment of the previous round. Status is resolved or open.
type Resolved struct {
	CommentQuote string `json:"comment_quote"`
	Status       string `json:"status"`
	Note         string `json:"note"`
}

// Idea compares the owner's idea with the document's goal. Verdict is
// matches, narrowed or differs.
type Idea struct {
	OwnerQuote  string `json:"owner_quote"`
	GoalQuote   string `json:"goal_quote"`
	Verdict     string `json:"verdict"`
	Note        string `json:"note"`
	OwnerSource Source `json:"owner_source"`
}

// Thesis kinds of the summary.
const (
	ThesisGoal        = "goal"
	ThesisDecision    = "decision"
	ThesisOwnerChange = "owner_change" // what changes for the owner
	ThesisNonGoal     = "non_goal"
	ThesisRisk        = "risk"
)

// Thesis is one line of the review's summary, tied to its place in the
// document. Its key comes from the kind and the normalised text only, so a
// Discuss thread on it survives a re-run that quotes another passage.
type Thesis struct {
	Key     string `json:"key"`
	Kind    string `json:"kind"`
	Text    string `json:"text"`
	Chapter string `json:"chapter"`
	Where   Anchor `json:"where"`
}

// Result is the validated reviewer reply: what Plan 2 reads and the Desktop
// decodes. JSON keys are pinned by testdata/result_keys.golden. Idea is nil
// (and the key left out) when the reviewer gave none or it was dropped.
// Verdicts (author-loop rounds 2+ only) rule on the previous round's open
// items; the key is left out when there are none. Brief and Theses are the
// summary screen: empty in a reply from before it existed.
type Result struct {
	Summary      string         `json:"summary"`
	Brief        string         `json:"brief"`
	Theses       []Thesis       `json:"theses"`
	Idea         *Idea          `json:"idea,omitempty"`
	Agreements   []Agreement    `json:"agreements"`
	DecidedAlone []DecidedAlone `json:"decided_alone"`
	BlindSpots   []BlindSpot    `json:"blind_spots"`
	Checks       []Check        `json:"checks"`
	Resolved     []Resolved     `json:"resolved"`
	Verdicts     []Verdict      `json:"verdicts,omitempty"`
	Chapters     []Chapter      `json:"chapters"`
	Notes        []string       `json:"notes"`
	CodeRead     bool           `json:"code_read"`
	Dropped      int            `json:"dropped"`
	// DroppedBy counts, by drift-guard reason (DropUnchangedText,
	// DropMinorLate, DropDecided), the entries Dropped holds for that
	// reason; left out when no guard dropped anything.
	DroppedBy map[string]int `json:"dropped_by,omitempty"`
}

// Sources is everything a quote may come from. Every map is keyed by the Ref
// the prompt shows (entry:<id>, ask:<n>, comment:<n>). OwnerWords holds, per
// ref, the pieces of that source the owner said (an owner line, the owner's
// answer texts, notes and comment bodies of an ask, an owner comment); a ref
// absent from it is the agent's.
type Sources struct {
	OwnerWords   map[string][]string
	Doc          string
	Conversation map[string]string
	Asks         map[string]string
	Target       string
	Comments     map[string]string
	Spec         string
	Folder       string
	PrevComments []string
	// PrevOpenKeys is the previous round's open items of an author loop:
	// the only keys a verdict may name.
	PrevOpenKeys map[string]bool
	// Closed is the review chain's closed list (ClosedList): findings that
	// never come back.
	Closed []ClosedItem
	// KnownKeys is every key in a ledger or an open list along the chain.
	KnownKeys map[string]bool
	// LoopRound is the round of the author loop under review, 0 when the
	// review is not a loop round: the drift guards run only in a loop.
	LoopRound int
	// PrevDoc is the previous ask's document along the chain, "" for none:
	// the baseline of the changed-text guard.
	PrevDoc string
	// NewRefs is the conversation entries, asks and comments newer than the
	// previous ask: a finding with no where-quote may cite only these.
	NewRefs map[string]bool
}

// Severity levels of a finding.
const (
	SeverityBlocker = "blocker"
	SeverityMajor   = "major"
	SeverityMinor   = "minor"
)

// normSeverity lower-cases and trims s and keeps it only when it is one of
// the three levels; anything else is "".
func normSeverity(s string) string {
	switch s = strings.ToLower(strings.TrimSpace(s)); s {
	case SeverityBlocker, SeverityMajor, SeverityMinor:
		return s
	}
	return ""
}
