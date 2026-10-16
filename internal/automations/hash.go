package automations

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"slices"
	"strconv"
)

// ContentHash is the hex sha256 of a recipe file's raw bytes (spec §2.4). It
// only detects that the file changed; it binds nothing.
func ContentHash(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

// ApprovalHash is "what this code may do, when and how much" (spec §2.4, §20
// D5 as amended by D26, ask #294): the hex sha256 of the canonical JSON
//
//	{"permissions":[sorted normalised],"outputs":[sorted],"scope":"<scope>","script":"<js>",
//	 "trigger":<trigger>,"missed":"<policy>","budget":{"tokens":N,"minutes":M},"concurrency":N}
//
// with the keys in that order, no whitespace and no HTML escaping; the
// trigger is the trigger_spec shape (a where map's keys sorted) without the
// button's cosmetic label (its confirm flag stays). Owner confirmations and
// auto grants bind to it, so a schedule, missed-policy, budget or concurrency
// edit needs the owner's confirmation again; name, description, the button
// label and pause_timeout_hours are deliberately left out.
func ApprovalHash(r *Recipe) string {
	return ContentHash(approvalCanonical(r))
}

// approvalCanonical is the exact byte string ApprovalHash hashes.
func approvalCanonical(r *Recipe) []byte {
	var buf bytes.Buffer
	buf.WriteString(`{"permissions":`)
	writeCanonical(&buf, normalizedPermissions(r.Permissions))
	buf.WriteString(`,"outputs":`)
	writeCanonical(&buf, sortedCopy(r.Outputs))
	buf.WriteString(`,"scope":`)
	writeCanonical(&buf, r.Scope.String())
	buf.WriteString(`,"script":`)
	writeCanonical(&buf, r.Script)
	buf.WriteString(`,"trigger":`)
	writeCanonical(&buf, canonicalTrigger(r.Trigger))
	buf.WriteString(`,"missed":`)
	writeCanonical(&buf, string(r.Missed))
	buf.WriteString(`,"budget":`)
	writeCanonical(&buf, canonicalBudget{Tokens: r.Budget.Tokens, Minutes: r.Budget.Minutes})
	buf.WriteString(`,"concurrency":`)
	writeCanonical(&buf, r.Concurrency)
	buf.WriteByte('}')
	return buf.Bytes()
}

// ApprovalField is one field ApprovalHash binds, as comparable text: the
// trigger, outputs and permissions in their canonical JSON (the trigger
// without a button's label), the missed policy, scope and script as they
// are, the numbers in decimal.
type ApprovalField struct {
	Name  string
	Value string
}

// ApprovalFields lists the fields ApprovalHash binds, in the order the
// confirmation sheet's Changed block shows them (spec §12.2, D26): trigger,
// missed, budget_tokens, budget_minutes, concurrency, outputs, permissions,
// scope, script. Two recipes with equal fields have equal approval hashes.
func ApprovalFields(r *Recipe) []ApprovalField {
	return []ApprovalField{
		{"trigger", canonicalText(canonicalTrigger(r.Trigger))},
		{"missed", string(r.Missed)},
		{"budget_tokens", strconv.Itoa(r.Budget.Tokens)},
		{"budget_minutes", strconv.Itoa(r.Budget.Minutes)},
		{"concurrency", strconv.Itoa(r.Concurrency)},
		{"outputs", canonicalText(sortedCopy(r.Outputs))},
		{"permissions", canonicalText(normalizedPermissions(r.Permissions))},
		{"scope", r.Scope.String()},
		{"script", r.Script},
	}
}

// canonicalText is v's canonical JSON as a string.
func canonicalText(v any) string {
	var buf bytes.Buffer
	writeCanonical(&buf, v)
	return buf.String()
}

// canonicalBudget is the budget's place in the approval canonical form.
type canonicalBudget struct {
	Tokens  int `json:"tokens"`
	Minutes int `json:"minutes"`
}

// canonicalTriggerForm is the trigger's place in the approval canonical form:
// the trigger_spec shape without the button's label.
type canonicalTriggerForm struct {
	Schedule string            `json:"schedule,omitempty"`
	Button   *canonicalButton  `json:"button,omitempty"`
	Event    *triggerSpecEvent `json:"event,omitempty"`
	Manual   bool              `json:"manual,omitempty"`
}

// canonicalButton keeps only what a button changes about a run: whether it
// asks before starting. The label is cosmetic.
type canonicalButton struct {
	Confirm bool `json:"confirm"`
}

// canonicalTrigger is t's hashed form; a trigger of no known kind (only a
// hand-built Recipe, never a parsed one) is the empty object.
func canonicalTrigger(t Trigger) canonicalTriggerForm {
	spec := triggerSpecOf(t)
	form := canonicalTriggerForm{Schedule: spec.Schedule, Event: spec.Event, Manual: spec.Manual}
	if spec.Button != nil {
		form.Button = &canonicalButton{Confirm: spec.Button.Confirm}
	}
	return form
}

// sortedCopy returns a sorted, deduplicated copy that is never nil: a recipe
// without a list hashes the same as one with an empty list ("[]", never
// "null"), and listing an entry twice grants nothing more, so it keeps the
// hash.
func sortedCopy(in []string) []string {
	out := make([]string, len(in))
	copy(out, in)
	slices.Sort(out)
	return slices.Compact(out)
}

// writeCanonical appends v as JSON without HTML escaping and without the
// encoder's trailing newline. v is only ever a string, a []string, an int or
// a plain struct of those (map keys sorted), which json cannot fail to encode.
func writeCanonical(buf *bytes.Buffer, v any) {
	var tmp bytes.Buffer
	enc := json.NewEncoder(&tmp)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		panic(fmt.Sprintf("automations: canonical JSON of %T: %v", v, err))
	}
	buf.Write(bytes.TrimSuffix(tmp.Bytes(), []byte("\n")))
}
