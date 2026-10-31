// Package wire holds the phone <-> hub payload types that both sides pin in
// one shared fixture (spec §12a): the JSON the hub writes into sealed records
// and the QR link code. Encoding is the Kit's RelayCoder twin: snake_case
// keys, sorted object keys, dates as JSON numbers of seconds since 1970.
package wire

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// Time is a Swift `.secondsSince1970` date: a JSON number of seconds, with
// the fraction kept (nanosecond resolution, no float rounding on output).
type Time struct{ time.Time }

// MarshalJSON prints whole seconds without a fraction and others with the
// shortest exact decimal fraction.
func (t Time) MarshalJSON() ([]byte, error) {
	sec, nsec := t.Unix(), int64(t.Nanosecond())
	s := strconv.FormatInt(sec, 10)
	if nsec != 0 {
		frac := strings.TrimRight(fmt.Sprintf("%09d", nsec), "0")
		if sec < 0 {
			// Unix() floors, so a negative instant is (sec + nsec/1e9).
			return json.Marshal(float64(sec) + float64(nsec)/1e9)
		}
		s += "." + frac
	}
	return []byte(s), nil
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

// Marshal is the RelayCoder twin: object keys sorted at every level, no HTML
// escaping, no trailing newline.
func Marshal(v any) ([]byte, error) {
	var first bytes.Buffer
	enc := json.NewEncoder(&first)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	// Round trip through generic maps (sorted on encode); numbers stay verbatim.
	dec := json.NewDecoder(&first)
	dec.UseNumber()
	var generic any
	if err := dec.Decode(&generic); err != nil {
		return nil, err
	}
	var out bytes.Buffer
	enc = json.NewEncoder(&out)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(generic); err != nil {
		return nil, err
	}
	return bytes.TrimRight(out.Bytes(), "\n"), nil
}
