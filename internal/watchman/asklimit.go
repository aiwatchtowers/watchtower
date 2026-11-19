package watchman

import (
	"regexp"
	"strings"
)

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
	and   *regexp.Regexp // also required when set
}{
	// A merge, push or rebase whose destination is main/master — never one
	// from main into a feature branch.
	{limit: LimitMainRef, re: regexp.MustCompile(`(?i)\b(merge|merging|merged|push|pushing|rebase|rebasing|land|landing)\b[^.\n]*?\b(into|onto|to|on)\s+(the\s+)?(origin/|upstream/)?(main|master)\b`)},
	{limit: LimitMainRef, re: regexp.MustCompile(`(?i)\bgit\s+push\s+(-\S+\s+)*\S+\s+(\S+:)?(main|master)\b`)},
	{limit: LimitMainRef, re: regexp.MustCompile(`(?i)(смерж|смердж|мерж|мердж|влить|влей|влива|запуш|пушн|пуша|ребейз)\p{L}*[^.\n]*?(^|[^\p{L}])(в|на|into|onto)\s+(origin/)?(main|master)\b`)},
	// Every PR merge is the owner's in phase 2, whatever its base (the
	// permission side's main_ref): a merge word with a PR, and the
	// permission backstop's words — a merge word with gh, hub, api,
	// graphql, pulls or curl.
	{limit: LimitMainRef, re: regexp.MustCompile(`(?i)\b(merg\w*|squash|land)\b[^.\n]*?(\b(pr|prs|mr|pull[\s-]+requests?)\b|#\d+)|\b(pr|pull[\s-]+requests?)\b[^.\n]*?\bmerg\w*`)},
	{limit: LimitMainRef, re: mergeWords, and: mergeTools},
	{limit: LimitMainRef, re: regexp.MustCompile(`(?i)(смерж|смердж|мерж|мердж|влить|влей|влива)\p{L}*[^.\n]*?((^|[^\p{L}])(pr|пр|мр)([^\p{L}]|$)|пул+-?реквест|pull[\s-]+request)`)},
	// A forced push, to any branch.
	{limit: LimitForcePush, re: regexp.MustCompile(`(?i)\bforce[\s-]?push\w*|\bpush\b[^.\n]*?(\s--force(-with-lease|-if-includes)?\b|\s-[a-z]*f[a-z]*\b|\s\+\S)`)},
	{limit: LimitForcePush, re: regexp.MustCompile(`(?i)форс[\s-]?пуш|пуш\p{L}*\s+(с\s+)?форс`)},
	{limit: LimitRelease, re: regexp.MustCompile(`(?i)\b(cut|publish|ship|create|make|draft|do|prepare)\s+(a\s+|the\s+|new\s+|a\s+new\s+)?release\b|\bgh\s+release\b|\brelease\s+v?\d+\.\d+`)},
	{limit: LimitRelease, re: regexp.MustCompile(`(?i)(выпуст|сделать|сделай|опубликов)\p{L}*\s+(\p{L}+\s+)?релиз`)},
	{limit: LimitTag, re: regexp.MustCompile(`(?i)\bgit\s+tag\b|\bpush\s+(the\s+)?tags?\b|\b(create|cut)\s+(a\s+|the\s+|new\s+)?(git\s+|release\s+|version\s+)?tag\b|\btag\s+v\d+(\.\d+)*`)},
	{limit: LimitTestFlight, re: regexp.MustCompile(`(?i)\btest\s?flight\b|\bapp\s?store\s+connect\b`)},
	// A message other people see: Slack, mail, a PR or issue comment.
	{limit: LimitOutward, re: regexp.MustCompile(`(?i)\b(send|post|reply|message|ping|dm|notify|announce)\b[^.\n]*?\b(slack|e-?mail|mail|channel)\b`)},
	{limit: LimitOutward, re: regexp.MustCompile(`(?i)\bsend_slack_message\b|\bgh\s+(pr|issue)\s+(comment|review)\b`)},
	{limit: LimitOutward, re: regexp.MustCompile(`(?i)\b(comment|reply|post|respond)\b[^.\n]*?\b(on|to|in|under)\s+(the\s+|this\s+|that\s+)?(pr|pull\s+request|issue|github|jira|linear)\b`)},
	{limit: LimitInventory, re: regexp.MustCompile(`(?i)docs/inventory\b|\b(behaviou?r[- ]inventory|inventory\s+contract|guard\s+tests?)\b`)},
	{limit: LimitInventory, re: regexp.MustCompile(`\bTest[A-Z][A-Za-z]*[0-9]{2}_`)},
}

// AskParkedBy reports the hard limit an ask's text (or its text with the
// twin's choice) names, if any. Run on the question before the model and on
// question + choice after (spec §4).
func AskParkedBy(text string) (HardLimit, bool) {
	plain := markdownMarks.Replace(text)
	for _, l := range askLimits {
		// Both forms: the plain one so "into `main`" or "**master**" match,
		// the raw one so identifiers with "_" (send_slack_message, a guard
		// test's name) still do.
		match := func(t string) bool { return l.re.MatchString(t) && (l.and == nil || l.and.MatchString(t)) }
		if match(plain) || match(text) {
			return l.limit, true
		}
	}
	return "", false
}

// markdownMarks strips Markdown code, emphasis and quote marks.
var markdownMarks = strings.NewReplacer("`", "", "*", "", "_", "", `"`, "", "'", "", "“", "", "”", "", "‘", "", "’", "", "«", "", "»", "")
