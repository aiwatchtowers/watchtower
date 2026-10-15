package briefing

import (
	"fmt"
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

// automationEntrySep separates two outputs in the block.
const automationEntrySep = "\n\n"

// gatherAutomationOutputs renders the FROM YOUR AUTOMATIONS block: every
// output.briefing written since `since` (the previous briefing), oldest first,
// as "⚙ <automation name>: <title>\n<body>". Mechanical, no AI. A load error
// is logged and renders the placeholder, like every other gather.
func (p *Pipeline) gatherAutomationOutputs(since time.Time) (string, bool) {
	outputs, err := p.db.ListAutomationOutputsSince("briefing", since)
	if err != nil {
		p.logger.Printf("briefing: error loading automation outputs: %v", err)
		return noAutomationOutputs, false
	}
	if len(outputs) == 0 {
		return noAutomationOutputs, false
	}
	entries := make([]string, len(outputs))
	for i, o := range outputs {
		entries[i] = fmt.Sprintf("⚙ %s: %s\n%s", o.AutomationName, o.Title, o.Body)
	}
	return boundAutomationEntries(entries, maxAutomationSectionBytes), true
}

// boundAutomationEntries joins entries (oldest first) into at most limit
// bytes: while over, the oldest entry is dropped and the block ends with
// "+N more" (N = dropped count). When the newest entry alone does not fit, it
// is clipped on a character boundary and marked "…" rather than dropped.
func boundAutomationEntries(entries []string, limit int) string {
	for dropped := 0; ; dropped++ {
		kept := entries[dropped:]
		suffix := ""
		if dropped > 0 {
			suffix = fmt.Sprintf("%s+%d more", automationEntrySep, dropped)
		}
		body := strings.Join(kept, automationEntrySep)
		if len(body)+len(suffix) <= limit {
			return body + suffix
		}
		if len(kept) == 1 {
			return clipUTF8(body, limit-len(suffix)-len("…")) + "…" + suffix
		}
	}
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
