package inboxfeed

import (
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"
)

// SaveAutomationSummary is a save_automation proposal as the Inbox's
// reading pane sums it up (SaveAutomationProposalSummary): its title, where
// the recipe goes, when it runs and the first of what it may do. Built from
// the args authoring.Normalize pinned at propose, never re-derived.
type SaveAutomationSummary struct {
	Name string `json:"name"`
	// Scope is "Personal", or the workbench's name ("Workbench #3" when not
	// known).
	Scope string `json:"scope"`
	When  string `json:"when"`
	// May is the first two permissions in words, then "and N more";
	// "Nothing" with none.
	May string `json:"may"`
}

// saveArgs are the save_automation args the summary reads.
type saveArgs struct {
	Name        string          `json:"name"`
	Slug        string          `json:"slug"`
	TriggerKind string          `json:"trigger_kind"`
	TriggerSpec json.RawMessage `json:"trigger_spec"`
	Permissions []string        `json:"permissions"`
	WorkbenchID *int64          `json:"workbench_id"`
}

// SummarizeSaveAutomation sums up a save_automation proposal from its
// args_json; workbenchName names a workbench ("" when not known). Args that
// do not decode sum up as empty ones, as on the Mac.
func SummarizeSaveAutomation(argsJSON string, workbenchName func(id int64) string) SaveAutomationSummary {
	var a saveArgs
	if json.Unmarshal([]byte(argsJSON), &a) != nil {
		a = saveArgs{}
	}
	name := a.Name
	if name == "" {
		name = a.Slug
	}
	s := SaveAutomationSummary{Name: "Save automation " + name, Scope: "Personal"}
	if a.WorkbenchID != nil {
		s.Scope = workbenchName(*a.WorkbenchID)
		if s.Scope == "" {
			s.Scope = "Workbench #" + strconv.FormatInt(*a.WorkbenchID, 10)
		}
	}
	s.When = triggerSentence(a.TriggerKind, a.TriggerSpec)
	lines := make([]string, 0, len(a.Permissions))
	for _, p := range a.Permissions {
		lines = append(lines, PermissionLine(p))
	}
	shown := strings.Join(lines[:min(2, len(lines))], ", ")
	switch len(lines) {
	case 0:
		s.May = "Nothing"
	case 1, 2:
		s.May = shown
	default:
		s.May = fmt.Sprintf("%s and %d more", shown, len(lines)-2)
	}
	return s
}

// triggerSpec is a recipe's trigger_spec as its words read it.
type triggerSpec struct {
	Schedule string `json:"schedule"`
	Button   *struct {
		Label string `json:"label"`
	} `json:"button"`
	Event *struct {
		Type  string            `json:"type"`
		Where map[string]string `json:"where"`
	} `json:"event"`
	Sync string `json:"sync"`
}

// syncWords are a built-in's sync slot in words.
var syncWords = map[string]string{
	"morning_brief":  "Every morning, at the first sync after its time",
	"tracks":         "After every sync",
	"ideas":          "Every few hours",
	"reactions":      "When you react in Slack",
	"custom_tracks":  "After every sync",
	"waiting_for_me": "After every sync",
}

// eventWords are an event trigger's type in words.
var eventWords = map[string]string{
	"gmail.new_messages":      "On new Gmail",
	"slack.new_messages":      "On new Slack messages",
	"jira.issue_changed":      "On Jira change",
	"calendar.event_changed":  "On calendar change",
	"confluence.page_changed": "On Confluence change",
	"slack.reaction_added":    "On a Slack reaction",
	"approval":                "When an action or a reminder needs you",
}

// triggerSentence is the card's "When:" line (AutomationTriggerText.sentence):
// a schedule as a sentence, a manual recipe as "Only when you run it", the
// rest as triggerDescribe.
func triggerSentence(kind string, raw json.RawMessage) string {
	switch kind {
	case "schedule":
		spec := decodeTriggerSpec(raw)
		if spec.Schedule == "" {
			return "Schedule"
		}
		return cronSentence(spec.Schedule)
	case "manual":
		return "Only when you run it"
	}
	return triggerDescribe(kind, raw)
}

// decodeTriggerSpec reads a trigger_spec; one that does not decode reads
// as empty, as on the Mac.
func decodeTriggerSpec(raw json.RawMessage) triggerSpec {
	var spec triggerSpec
	if json.Unmarshal(raw, &spec) != nil {
		return triggerSpec{}
	}
	return spec
}

// triggerDescribe is a trigger in words (AutomationTriggerText.describe).
func triggerDescribe(kind string, raw json.RawMessage) string {
	spec := decodeTriggerSpec(raw)
	switch kind {
	case "schedule":
		if spec.Schedule == "" {
			return "Schedule"
		}
		return cronDescribe(spec.Schedule)
	case "button":
		if spec.Button == nil || spec.Button.Label == "" {
			return "Button"
		}
		return "Button: " + spec.Button.Label
	case "event":
		return eventDescribe(spec)
	case "manual":
		return "Manual"
	case "sync":
		if w, ok := syncWords[spec.Sync]; ok {
			return w
		}
		return "In every sync cycle"
	}
	return "—"
}

// eventDescribe is an event trigger in words: its type, a reaction's emoji,
// then its other filters' values by key.
func eventDescribe(spec triggerSpec) string {
	typ := ""
	filters := map[string]string{}
	if spec.Event != nil {
		typ = spec.Event.Type
		for k, v := range spec.Event.Where {
			filters[k] = v
		}
	}
	base, ok := eventWords[typ]
	if !ok {
		base = "On " + typ
		if typ == "" {
			base = "On event"
		}
	}
	if raw, has := filters["emoji"]; typ == "slack.reaction_added" && has {
		delete(filters, "emoji")
		if emoji := strings.Trim(raw, ":"); emoji != "" {
			base = "On :" + emoji + ": reactions"
		}
	}
	keys := make([]string, 0, len(filters))
	for k := range filters {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	values := make([]string, 0, len(keys))
	for _, k := range keys {
		values = append(values, filters[k])
	}
	if len(values) == 0 {
		return base
	}
	return base + " (" + strings.Join(values, ", ") + ")"
}

// dayNames index a cron day of week (0 and 7 are Sunday).
var dayNames = []string{"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"}

// The day shapes parseCron reads besides one weekday (0…7).
const (
	cronDaily    = -1
	cronWeekdays = -2
)

// cronDescribe is the list's short form (CronText.describe): "Weekdays
// 09:00", "Mondays 08:30", "Daily 09:00", else "Cron: <expr>".
func cronDescribe(expr string) string {
	days, times, ok := parseCron(expr)
	switch {
	case !ok:
		return "Cron: " + expr
	case days == cronDaily:
		return "Daily " + times
	case days == cronWeekdays:
		return "Weekdays " + times
	}
	return dayNames[days] + "s " + times
}

// cronSentence is the card's sentence (CronText.sentence): "Every weekday
// at 09:00", "Every Monday at 08:30", "Every day at 09:00".
func cronSentence(expr string) string {
	days, times, ok := parseCron(expr)
	switch {
	case !ok:
		return "Cron: " + expr
	case days == cronDaily:
		return "Every day at " + times
	case days == cronWeekdays:
		return "Every weekday at " + times
	}
	return "Every " + dayNames[days] + " at " + times
}

// parseCron reads the common five-field shapes: a fixed minute, one or more
// hours, any day of month and month, and every day, weekdays or one
// weekday.
func parseCron(expr string) (days int, times string, ok bool) {
	var fields []string
	for _, f := range strings.Split(expr, " ") {
		if f != "" {
			fields = append(fields, f)
		}
	}
	if len(fields) != 5 || fields[2] != "*" || fields[3] != "*" {
		return 0, "", false
	}
	minute, err := strconv.Atoi(fields[0])
	if err != nil || minute < 0 || minute > 59 {
		return 0, "", false
	}
	var parts []string
	for _, h := range strings.Split(fields[1], ",") {
		hour, err := strconv.Atoi(h)
		if err != nil || hour < 0 || hour > 23 {
			return 0, "", false
		}
		parts = append(parts, fmt.Sprintf("%02d:%02d", hour, minute))
	}
	switch fields[4] {
	case "*":
		days = cronDaily
	case "1-5":
		days = cronWeekdays
	default:
		dow, err := strconv.Atoi(fields[4])
		if err != nil || dow < 0 || dow >= len(dayNames) {
			return 0, "", false
		}
		days = dow
	}
	return days, strings.Join(parts, ", "), true
}

// permissionSource is a synced source's words.
type permissionSource struct{ name, noun, all, write string }

var permissionSources = map[string]permissionSource{
	"gmail":      {"Gmail", "mail", "all accounts", "Send mail from"},
	"slack":      {"Slack", "messages", "all workspaces", "Post messages in"},
	"calendar":   {"Calendar", "events", "all accounts", "Change events in"},
	"jira":       {"Jira", "issues", "all projects", "Change issues in"},
	"linear":     {"Linear", "issues", "all teams", "Change issues in"},
	"confluence": {"Confluence", "pages", "all spaces", "Edit pages in"},
}

var localNouns = map[string]string{
	"targets": "your targets", "tracks": "your tracks", "ideas": "your ideas", "digests": "digests",
	"people": "people cards", "transcripts": "meeting transcripts", "meetings": "meeting recaps and notes",
	"dayplan": "your day plan",
}

// builtinPrimitives are a built-in's engine primitives (builtin:<name>),
// twin of automations.BuiltinPrimitiveNames.
var builtinPrimitives = map[string]string{
	"brief.compose":     "Write your daily brief",
	"plan.compose":      "Plan your day",
	"tracks.extract":    "Update your tracks from Slack digests",
	"ideas.consolidate": "Find ideas and decisions in your messages",
	"reaction.compose":  "Turn your reactions into proposals",
	"attention.waiting": "Read the messages waiting on you",
	"approvals.list":    "Read the actions and reminders that wait for you",
}

// runtimeLines are the model, agent, ask, session, Inbox-button and watch
// capabilities by "cap:verb", or "cap:verb@scope" for a scoped one.
var runtimeLines = map[string]string{
	"llm:light":            "Use the light model",
	"llm:strong":           "Use the strong model",
	"agent:run":            "Run the assistant as an agent",
	"ask:owner":            "Ask you questions",
	"session:start":        "Start agent sessions",
	"session:start@claude": "Start Claude Code sessions",
	"session:start@codex":  "Start Codex sessions",
	"inbox:reply":          "Reacts to its own Inbox buttons",
	"track:scan":           "Add events to this watch's track",
}

// nonEmptySplit2 splits s at the first sep as Swift's split(separator:,
// maxSplits: 1) does: empty pieces are dropped.
func nonEmptySplit2(s, sep string) []string {
	a, b, found := strings.Cut(s, sep)
	var out []string
	for _, p := range []string{a, b} {
		if p != "" {
			out = append(out, p)
		}
	}
	if !found && len(out) == 0 {
		return nil
	}
	return out
}

// PermissionLine is one manifest entry in words
// (AutomationCardPresentation.permissionLine); an unknown shape stays as
// written.
func PermissionLine(permission string) string {
	if line, ok := prefixedLine(permission); ok {
		return line
	}
	parts := nonEmptySplit2(permission, "@")
	scope, scoped := "", len(parts) == 2
	if scoped {
		scope = parts[1]
	}
	head := ""
	if len(parts) > 0 {
		head = parts[0]
	}
	capVerb := nonEmptySplit2(head, ":")
	if len(capVerb) != 2 {
		return permission
	}
	capName, verb := capVerb[0], capVerb[1]
	if src, ok := permissionSources[capName]; ok && scoped {
		place := scope
		if scope == "*" {
			place = src.all
		}
		switch verb {
		case "read":
			return "Read " + src.noun + " in " + place + " (" + src.name + ")"
		case "write":
			return src.write + " " + place + " (" + src.name + ")"
		}
	}
	if noun, ok := localNouns[capName]; ok && !scoped {
		switch verb {
		case "read":
			return "Read " + noun
		case "write":
			return "Change " + noun
		}
	}
	key := capName + ":" + verb
	if scoped {
		key += "@" + scope
	}
	if line, ok := runtimeLines[key]; ok {
		return line
	}
	return permission
}

// prefixedLine words the tool:, mcp:, shell: and builtin: entries.
func prefixedLine(p string) (string, bool) {
	if name, ok := strings.CutPrefix(p, "builtin:"); ok {
		line, known := builtinPrimitives[name]
		return line, known
	}
	if tool, ok := strings.CutPrefix(p, "tool:"); ok {
		return "Use the tool " + tool, true
	}
	if rest, ok := strings.CutPrefix(p, "mcp:"); ok {
		server, tool, found := strings.Cut(rest, "/")
		if !found {
			return "", false
		}
		return "Use " + tool + " from " + server + " (Quick Connection)", true
	}
	if command, ok := strings.CutPrefix(p, "shell:"); ok {
		if len([]rune(command)) >= 2 && strings.HasPrefix(command, `"`) && strings.HasSuffix(command, `"`) {
			command = command[1 : len(command)-1]
		}
		return "Run the command " + command, true
	}
	return "", false
}
