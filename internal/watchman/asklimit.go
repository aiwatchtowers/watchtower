package watchman

import "regexp"

// LimitInventory is approving a change to a behavior-inventory contract or a
// guard test (docs/inventory, Test<Module>NN_): CLAUDE.md requires the owner.
const LimitInventory HardLimit = "inventory"

// askLimits is the §5 table for ask text (spec 2026-11-16-watchman-design
// §5, WATCHMAN-01): what an agent's question, or the twin's choice on it,
// names that only the owner may decide. Patterns, not understanding: the
// light-tier label call after it may add a park, never remove one. A row
// can only be added; one test row per entry (TestAskParkedBy).
var askLimits = []struct {
	limit HardLimit
	re    *regexp.Regexp
}{
	// A merge, push or rebase whose destination is main/master — never one
	// from main into a feature branch.
	{LimitMainRef, regexp.MustCompile(`(?i)\b(merge|merging|merged|push|pushing|rebase|rebasing|land|landing)\b[^.\n]*?\b(into|onto|to|on)\s+(the\s+)?(origin/|upstream/)?(main|master)\b`)},
	{LimitMainRef, regexp.MustCompile(`(?i)\bgit\s+push\s+(-\S+\s+)*\S+\s+(\S+:)?(main|master)\b`)},
	{LimitMainRef, regexp.MustCompile(`(?i)(смерж|смердж|мерж|мердж|влить|влей|влива|запуш|пушн|пуша|ребейз)\p{L}*[^.\n]*?(^|[^\p{L}])(в|на|into|onto)\s+(origin/)?(main|master)\b`)},
	{LimitRelease, regexp.MustCompile(`(?i)\b(cut|publish|ship|create|make|draft|do|prepare)\s+(a\s+|the\s+|new\s+|a\s+new\s+)?release\b|\bgh\s+release\b|\brelease\s+v?\d+\.\d+`)},
	{LimitRelease, regexp.MustCompile(`(?i)(выпуст|сделать|сделай|опубликов)\p{L}*\s+(\p{L}+\s+)?релиз`)},
	{LimitTag, regexp.MustCompile(`(?i)\bgit\s+tag\b|\bpush\s+(the\s+)?tags?\b|\b(create|cut)\s+(a\s+|the\s+|new\s+)?(git\s+|release\s+|version\s+)?tag\b|\btag\s+v\d+(\.\d+)*`)},
	{LimitTestFlight, regexp.MustCompile(`(?i)\btest\s?flight\b|\bapp\s?store\s+connect\b`)},
	// A message other people see: Slack, mail, a PR or issue comment.
	{LimitOutward, regexp.MustCompile(`(?i)\b(send|post|reply|message|ping|dm|notify|announce)\b[^.\n]*?\b(slack|e-?mail|mail|channel)\b`)},
	{LimitOutward, regexp.MustCompile(`(?i)\bsend_slack_message\b|\bgh\s+(pr|issue)\s+(comment|review)\b`)},
	{LimitOutward, regexp.MustCompile(`(?i)\b(comment|reply|post|respond)\b[^.\n]*?\b(on|to|in|under)\s+(the\s+|this\s+|that\s+)?(pr|pull\s+request|issue|github|jira|linear)\b`)},
	{LimitInventory, regexp.MustCompile(`(?i)docs/inventory\b|\b(behaviou?r[- ]inventory|inventory\s+contract|guard\s+tests?)\b`)},
	{LimitInventory, regexp.MustCompile(`\bTest[A-Z][A-Za-z]*[0-9]{2}_`)},
}

// AskParkedBy reports the hard limit an ask's text (or its text with the
// twin's choice) names, if any. Run on the question before the model and on
// question + choice after (spec §4).
func AskParkedBy(text string) (HardLimit, bool) {
	for _, l := range askLimits {
		if l.re.MatchString(text) {
			return l.limit, true
		}
	}
	return "", false
}
