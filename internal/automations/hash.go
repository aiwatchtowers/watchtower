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

// ApprovalHash is "what this code may do" (spec §2.4, §20 D5): the hex sha256
// of the canonical JSON
//
//	{"permissions":[sorted],"outputs":[sorted],"scope":"<scope>","script":"<js>"}
//
// with the keys in that order and no HTML escaping. Owner confirmations and
// auto grants bind to it, so name, description, trigger, missed, budget,
// concurrency and pause_timeout_hours are deliberately left out.
func ApprovalHash(r *Recipe) string {
	var buf bytes.Buffer
	buf.WriteString(`{"permissions":`)
	writeCanonical(&buf, sortedCopy(r.Permissions))
	buf.WriteString(`,"outputs":`)
	writeCanonical(&buf, sortedCopy(r.Outputs))
	buf.WriteString(`,"scope":`)
	writeCanonical(&buf, r.Scope.String())
	buf.WriteString(`,"script":`)
	writeCanonical(&buf, r.Script)
	buf.WriteByte('}')
	return ContentHash(buf.Bytes())
}

// sortedCopy returns a sorted copy that is never nil, so a recipe without a
// list hashes the same as one with an empty list ("[]", never "null").
func sortedCopy(in []string) []string {
	out := make([]string, len(in))
	copy(out, in)
	slices.Sort(out)
	return out
}

// writeCanonical appends v as JSON without HTML escaping and without the
// encoder's trailing newline. v is only ever a string or a []string, which
// json cannot fail to encode.
func writeCanonical(buf *bytes.Buffer, v any) {
	var tmp bytes.Buffer
	enc := json.NewEncoder(&tmp)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		panic(fmt.Sprintf("automations: canonical JSON of %T: %v", v, err))
	}
	buf.Write(bytes.TrimSuffix(tmp.Bytes(), []byte("\n")))
}
