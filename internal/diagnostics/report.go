package diagnostics

import (
	"encoding/json"
	"slices"
	"strings"
)

// Report is the finished summary: the text lines plus the values the
// Desktop puts into the GitHub form. Reasons name the budgets that ran out
// (the Reason* constants); any reason makes the report partial.
type Report struct {
	Lines    []string
	Version  string
	MacOS    string
	Chip     string
	Provider string
	Flavor   string
	Sources  []string
	Reasons  []string
}

// reasonOrder is the fixed order of the `Partial report:` line.
var reasonOrder = []string{ReasonDatabaseBusy, ReasonLogScan, ReasonTimedOut}

// orderedReasons returns each reason once, in reasonOrder; a reason
// outside it (none is produced today) follows in the order first seen.
func orderedReasons(in []string) []string {
	out := make([]string, 0, len(in))
	for _, r := range reasonOrder {
		if slices.Contains(in, r) {
			out = append(out, r)
		}
	}
	for _, r := range in {
		if !slices.Contains(out, r) {
			out = append(out, r)
		}
	}
	return out
}

// Text is the report as printed: one fact per line, then
// `Partial report: <reasons>` when any budget ran out.
func (r Report) Text() string {
	lines := r.Lines
	if len(r.Reasons) > 0 {
		lines = append(slices.Clip(lines), PartialPrefix+strings.Join(orderedReasons(r.Reasons), ", "))
	}
	return strings.Join(lines, "\n")
}

// reportJSON pins the `--json` keys; the Desktop's DiagnosticsAnswer
// decodes exactly these.
type reportJSON struct {
	Text     string   `json:"text"`
	Version  string   `json:"version"`
	MacOS    string   `json:"macos"`
	Chip     string   `json:"chip"`
	Provider string   `json:"provider"`
	Sources  []string `json:"sources"`
	Flavor   string   `json:"flavor"`
	Partial  bool     `json:"partial"`
}

// JSON is the `--json` output; `sources` is never null.
func (r Report) JSON() ([]byte, error) {
	sources := r.Sources
	if sources == nil {
		sources = []string{}
	}
	return json.Marshal(reportJSON{
		Text:     r.Text(),
		Version:  r.Version,
		MacOS:    r.MacOS,
		Chip:     r.Chip,
		Provider: r.Provider,
		Sources:  sources,
		Flavor:   r.Flavor,
		Partial:  len(r.Reasons) > 0,
	})
}
