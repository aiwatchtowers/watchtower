// Package wire holds the phone <-> hub payload types that both sides pin in
// one shared fixture (spec §12a): the JSON the hub writes into sealed records
// and the QR link code. Encoding is the Kit's RelayCoder twin: snake_case
// keys, sorted object keys, dates as JSON numbers of seconds since 1970.
package wire

import (
	"bytes"
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Time is a Swift `.secondsSince1970` date: a JSON number of seconds, with
// the fraction kept (nanosecond resolution, no float rounding on output).
type Time struct{ time.Time }

// MarshalJSON prints the shortest decimal of the Double Swift would write:
// whole seconds without a fraction ("1730000000"), others like 1730000000.5.
// Sub-microsecond digits are lost, as in a Swift Date.
func (t Time) MarshalJSON() ([]byte, error) {
	f := float64(t.Unix()) + float64(t.Nanosecond())/1e9
	return []byte(strconv.FormatFloat(f, 'f', -1, 64)), nil
}

// UnmarshalJSON accepts any JSON number.
func (t *Time) UnmarshalJSON(b []byte) error {
	s := string(bytes.TrimSpace(b))
	if sec, frac, ok := strings.Cut(s, "."); ok && !strings.ContainsAny(s, "eE-") {
		whole, err := strconv.ParseInt(sec, 10, 64)
		if err != nil {
			return fmt.Errorf("wire: bad time %q", s)
		}
		if len(frac) > 9 {
			frac = frac[:9]
		}
		nsec, err := strconv.ParseInt(frac+strings.Repeat("0", 9-len(frac)), 10, 64)
		if err != nil {
			return fmt.Errorf("wire: bad time %q", s)
		}
		t.Time = time.Unix(whole, nsec).UTC()
		return nil
	}
	if whole, err := strconv.ParseInt(s, 10, 64); err == nil {
		t.Time = time.Unix(whole, 0).UTC()
		return nil
	}
	f, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return fmt.Errorf("wire: bad time %q", s)
	}
	whole := int64(f)
	t.Time = time.Unix(whole, int64((f-float64(whole))*1e9)).UTC()
	return nil
}

// Marshal is the twin of the Kit's `RelayCoder.makeEncoder()` (JSONEncoder
// with `.sortedKeys`): object keys sorted at every level, "/" written as
// "\/", control characters as lowercase \u00xx, everything else (HTML
// characters, non-ASCII, U+2028) raw. No trailing newline. Use it for every
// sealed or relay payload.
func Marshal(v any) ([]byte, error) { return marshal(v, true) }

// MarshalUnescapedSlashes is the twin of the Kit's `LinkPayload.makeEncoder()`
// (`.sortedKeys, .withoutEscapingSlashes`): as Marshal but "/" stays "/".
// Only the QR link code uses it (share URLs stay short).
func MarshalUnescapedSlashes(v any) ([]byte, error) { return marshal(v, false) }

func marshal(v any, escapeSlash bool) ([]byte, error) {
	var first bytes.Buffer
	enc := json.NewEncoder(&first)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	dec := json.NewDecoder(&first)
	dec.UseNumber() // numbers stay verbatim
	var generic any
	if err := dec.Decode(&generic); err != nil {
		return nil, err
	}
	var out bytes.Buffer
	writeValue(&out, generic, escapeSlash)
	return out.Bytes(), nil
}

func writeValue(out *bytes.Buffer, v any, escapeSlash bool) {
	switch x := v.(type) {
	case map[string]any:
		keys := make([]string, 0, len(x))
		for k := range x {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		out.WriteByte('{')
		for i, k := range keys {
			if i > 0 {
				out.WriteByte(',')
			}
			writeString(out, k, escapeSlash)
			out.WriteByte(':')
			writeValue(out, x[k], escapeSlash)
		}
		out.WriteByte('}')
	case []any:
		out.WriteByte('[')
		for i, e := range x {
			if i > 0 {
				out.WriteByte(',')
			}
			writeValue(out, e, escapeSlash)
		}
		out.WriteByte(']')
	case string:
		writeString(out, x, escapeSlash)
	case json.Number:
		out.WriteString(x.String())
	case bool:
		out.WriteString(strconv.FormatBool(x))
	case nil:
		out.WriteString("null")
	}
}

func writeString(out *bytes.Buffer, s string, escapeSlash bool) {
	out.WriteByte('"')
	for _, r := range s {
		switch {
		case r == '"':
			out.WriteString(`\"`)
		case r == '\\':
			out.WriteString(`\\`)
		case r == '/' && escapeSlash:
			out.WriteString(`\/`)
		case r == '\n':
			out.WriteString(`\n`)
		case r == '\r':
			out.WriteString(`\r`)
		case r == '\t':
			out.WriteString(`\t`)
		case r == '\b':
			out.WriteString(`\b`)
		case r == '\f':
			out.WriteString(`\f`)
		case r < 0x20:
			fmt.Fprintf(out, `\u%04x`, r)
		default:
			out.WriteRune(r)
		}
	}
	out.WriteByte('"')
}
