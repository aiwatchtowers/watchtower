package automations

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"slices"
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
//	 "trigger":<trigger_spec>,"budget":{"tokens":N,"minutes":M},"concurrency":N}
//
// with the keys in that order, no whitespace and no HTML escaping; the
// trigger is the indexer's trigger_spec shape (a where map's keys sorted).
// Owner confirmations and auto grants bind to it, so a schedule, budget or
// concurrency edit needs the owner's confirmation again; name, description,
// missed and pause_timeout_hours are deliberately left out.
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
	buf.WriteString(`,"budget":`)
	writeCanonical(&buf, canonicalBudget{Tokens: r.Budget.Tokens, Minutes: r.Budget.Minutes})
	buf.WriteString(`,"concurrency":`)
	writeCanonical(&buf, r.Concurrency)
	buf.WriteByte('}')
	return buf.Bytes()
}

// canonicalBudget is the budget's place in the approval canonical form.
type canonicalBudget struct {
	Tokens  int `json:"tokens"`
	Minutes int `json:"minutes"`
}

// canonicalTrigger is t in the trigger_spec shape; a trigger of no known kind
// (only a hand-built Recipe, never a parsed one) is the empty object.
func canonicalTrigger(t Trigger) triggerSpec {
	var spec triggerSpec
	switch t.Kind {
	case TriggerSchedule:
		spec.Schedule = t.Schedule
	case TriggerButton:
		if t.Button != nil {
			spec.Button = &triggerSpecButton{Label: t.Button.Label, Confirm: t.Button.Confirm}
		}
	case TriggerEvent:
		if t.Event != nil {
			spec.Event = &triggerSpecEvent{Type: t.Event.Type, Where: t.Event.Where}
		}
	case TriggerManual:
		spec.Manual = true
	}
	return spec
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
