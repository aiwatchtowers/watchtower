package catchup

import (
	"errors"
	"fmt"
	"time"
)

// maxWindowDays bounds a recap window; a longer one is rejected, not clamped.
const maxWindowDays = 31

// ErrWindow is returned (wrapped) for every invalid WindowSpec.
var ErrWindow = errors.New("invalid catch-up window")

// WindowSpec is the operator's window request. Empty = auto.
type WindowSpec struct {
	Preset string
	From   time.Time
	To     time.Time
}

// Window is a resolved [From, To] plus how it was chosen.
type Window struct {
	From, To time.Time
	Source   string
}

// ResolveWindow turns a spec into a concrete window. Auto: from the last
// acknowledged recap's period_to (lastAckTo, unix seconds; 0 = none → now-24h)
// to now. Presets use now's location for day boundaries.
func ResolveWindow(spec WindowSpec, now time.Time, lastAckTo float64) (Window, error) {
	custom := !spec.From.IsZero() || !spec.To.IsZero()
	if spec.Preset != "" && custom {
		return Window{}, fmt.Errorf("%w: --preset and --from/--to are exclusive", ErrWindow)
	}
	var w Window
	switch {
	case spec.Preset != "":
		w.Source = "preset:" + spec.Preset
		w.To = now
		midnight := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
		switch spec.Preset {
		case "today":
			w.From = midnight
		case "yesterday":
			w.From, w.To = midnight.AddDate(0, 0, -1), midnight
		case "3d":
			w.From = now.Add(-72 * time.Hour)
		case "week":
			w.From = now.Add(-7 * 24 * time.Hour)
		default:
			return Window{}, fmt.Errorf("%w: unknown preset %q", ErrWindow, spec.Preset)
		}
	case custom:
		w.Source = "custom"
		w.From, w.To = spec.From, spec.To
		if w.To.IsZero() {
			w.To = now
		}
		if w.From.IsZero() {
			return Window{}, fmt.Errorf("%w: --from is required with --to", ErrWindow)
		}
	default:
		w.Source = "auto"
		w.To = now
		if lastAckTo > 0 {
			w.From = time.Unix(int64(lastAckTo), 0).In(now.Location())
		} else {
			w.From = now.Add(-24 * time.Hour)
		}
	}
	if !w.From.Before(w.To) {
		return Window{}, fmt.Errorf("%w: from must precede to", ErrWindow)
	}
	if w.To.Sub(w.From) > maxWindowDays*24*time.Hour {
		return Window{}, fmt.Errorf("%w: longer than %d days", ErrWindow, maxWindowDays)
	}
	return w, nil
}

// ParseWindowTime accepts "2006-01-02" (local midnight in loc) or RFC 3339.
func ParseWindowTime(s string, loc *time.Location) (time.Time, error) {
	if d, err := time.ParseInLocation("2006-01-02", s, loc); err == nil {
		return d, nil
	}
	if ts, err := time.Parse(time.RFC3339, s); err == nil {
		return ts, nil
	}
	return time.Time{}, fmt.Errorf("%w: %q is neither YYYY-MM-DD nor RFC 3339", ErrWindow, s)
}
