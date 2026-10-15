package briefing

import (
	"fmt"
	"slices"
	"strings"
	"time"
	"unicode/utf8"
)

// noAutomationOutputs is the FROM YOUR AUTOMATIONS placeholder when no
// automation left a briefing output since the previous briefing; the template
// tells the model not to mention automations then, and it keeps the Sprintf
// argument count fixed.
const noAutomationOutputs = "No automation output since the last briefing."

// maxAutomationSectionBytes bounds the whole FROM YOUR AUTOMATIONS block
// (spec §12.6: 4 KiB, oldest dropped first with a "+N more" line).
const maxAutomationSectionBytes = 4096

const (
	// automationEntrySep separates two outputs in the block.
	automationEntrySep = "\n\n"
	// automationBodyIndent prefixes every body line, so a body can never
	// start a line the block's structure owns ("⚙ …", "+N more", "=== … ===").
	automationBodyIndent = "    "
	// maxAutomationEntriesLoaded caps the rows read: the shortest possible
	// entry is well over 64 bytes of a 4 KiB block once rendered usefully, and
	// every row past the cap is still counted into "+N more".
	maxAutomationEntriesLoaded = 64
	// automationGatherMargin reaches back before the previous briefing's
	// created_at, which is stamped after its generation: an output committed
	// while that briefing was being generated was never in its prompt. The
	// price is that an output written in the margin before the previous
	// briefing finished can appear in both.
	automationGatherMargin = 10 * time.Minute
	// maxAutomationLookbackDays bounds how far back (calendar days) a briefing
	// after a long gap reaches for automation outputs.
	maxAutomationLookbackDays = 7
)

// automationLineBreaks is every line break a body may carry: each starts a
// new indented line, and the header flattens each to a space, so no text can
// begin a line the block's structure owns.
var automationLineBreaks = []string{"\r\n", "\n", "\r", "\u2028", "\u2029", "\u0085"}

func lineBreakReplacer(with string) *strings.Replacer {
	pairs := make([]string, 0, 2*len(automationLineBreaks))
	for _, br := range automationLineBreaks {
		pairs = append(pairs, br, with)
	}
	return strings.NewReplacer(pairs...)
}

var (
	automationHeaderFlattener = lineBreakReplacer(" ")
	automationBodyIndenter    = lineBreakReplacer("\n" + automationBodyIndent)
)

// automationOutputsSince is where the FROM YOUR AUTOMATIONS window starts for
// the briefing of date: the created_at of the user's latest earlier briefing
// (however many days back — a skipped weekend loses nothing) minus
// automationGatherMargin, never earlier than seven calendar days before date; with no
// earlier briefing, the previous day's midnight. A read error is logged and
// takes the no-earlier-briefing window.
func (p *Pipeline) automationOutputsSince(userID, date string) time.Time {
	day, err := time.ParseInLocation("2006-01-02", date, time.Local)
	if err != nil {
		day = time.Now()
	}
	fallback := day.AddDate(0, 0, -1)
	prev, ok, err := p.db.LastBriefingCreatedAtBefore(userID, date)
	if err != nil {
		p.logger.Printf("briefing: %v — automation outputs since %s", err, fallback.Format(time.RFC3339))
		return fallback
	}
	if !ok {
		return fallback
	}
	since := prev.Add(-automationGatherMargin)
	if floor := day.AddDate(0, 0, -maxAutomationLookbackDays); since.Before(floor) {
		since = floor
	}
	return since
}

// gatherAutomationOutputs renders the FROM YOUR AUTOMATIONS block: the
// output.briefing rows written since `since`, oldest first, each a header line
// "⚙ <automation name>: <title>" and its body indented as data. Mechanical,
// no AI. A load error is logged and renders the placeholder, like every other
// gather.
func (p *Pipeline) gatherAutomationOutputs(since time.Time) (string, bool) {
	outputs, total, err := p.db.ListAutomationOutputsSince("briefing", since, maxAutomationEntriesLoaded, maxAutomationSectionBytes)
	if err != nil {
		p.logger.Printf("briefing: error loading automation outputs: %v", err)
		return noAutomationOutputs, false
	}
	if len(outputs) == 0 {
		return noAutomationOutputs, false
	}
	newestFirst := make([]string, len(outputs))
	for i, o := range outputs {
		newestFirst[i] = renderAutomationEntry(o.AutomationName, o.Title, o.Body)
	}
	return boundAutomationEntries(newestFirst, total, maxAutomationSectionBytes), true
}

// renderAutomationEntry is one output: the header on one line (name and title
// flattened), every body line indented.
func renderAutomationEntry(name, title, body string) string {
	return fmt.Sprintf("⚙ %s: %s\n%s%s", automationHeaderFlattener.Replace(name), automationHeaderFlattener.Replace(title),
		automationBodyIndent, automationBodyIndenter.Replace(body))
}

// boundAutomationEntries keeps the newest entries that fit in limit bytes
// together with the "+N more" line for the rest (N = total − kept, where total
// also counts rows never loaded), and renders them oldest first. When the
// newest entry alone does not fit, it is clipped on a character boundary and
// marked "…" rather than dropped. One pass, newest first.
func boundAutomationEntries(newestFirst []string, total, limit int) string {
	kept, size := 0, 0
	for _, e := range newestFirst {
		next := size + len(e)
		if kept > 0 {
			next += len(automationEntrySep)
		}
		if next+len(automationMoreLine(total-kept-1)) > limit {
			break
		}
		size, kept = next, kept+1
	}
	if kept == 0 {
		more := automationMoreLine(total - 1)
		return clipUTF8(newestFirst[0], limit-len(more)-len("…")) + "…" + more
	}
	shown := slices.Clone(newestFirst[:kept])
	slices.Reverse(shown)
	return strings.Join(shown, automationEntrySep) + automationMoreLine(total-kept)
}

// automationMoreLine is the "+N more" tail for n left-out outputs ("" for 0).
func automationMoreLine(n int) string {
	if n <= 0 {
		return ""
	}
	return fmt.Sprintf("%s+%d more", automationEntrySep, n)
}

// clipUTF8 cuts s to at most n bytes without splitting a character.
func clipUTF8(s string, n int) string {
	if len(s) <= n {
		return s
	}
	if n <= 0 {
		return ""
	}
	for n > 0 && !utf8.RuneStart(s[n]) {
		n--
	}
	return s[:n]
}
