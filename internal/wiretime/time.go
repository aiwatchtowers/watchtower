// Package wiretime is the date of the phone <-> Mac payloads: a JSON number
// of seconds since 1970, as Swift's `.secondsSince1970` writes it. It is a
// leaf so both the hub (internal/hub/wire) and the chat engine
// (internal/chatengine), which never imports the hub, encode the same bytes.
package wiretime

import (
	"bytes"
	"fmt"
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
			return fmt.Errorf("wiretime: bad time %q", s)
		}
		if len(frac) > 9 {
			frac = frac[:9]
		}
		nsec, err := strconv.ParseInt(frac+strings.Repeat("0", 9-len(frac)), 10, 64)
		if err != nil {
			return fmt.Errorf("wiretime: bad time %q", s)
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
		return fmt.Errorf("wiretime: bad time %q", s)
	}
	whole := int64(f)
	t.Time = time.Unix(whole, int64((f-float64(whole))*1e9)).UTC()
	return nil
}
