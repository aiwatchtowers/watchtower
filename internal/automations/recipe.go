package automations

import (
	"bytes"
	"errors"
	"fmt"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/robfig/cron/v3"
	"gopkg.in/yaml.v3"
)

// ScopeKind says where a recipe lives: the personal folder or a workbench
// folder (spec §2.1).
type ScopeKind string

// Recipe scopes.
const (
	ScopePersonal  ScopeKind = "personal"
	ScopeWorkbench ScopeKind = "workbench"
)

// Scope binds a recipe to the folder it lives in (spec §20 D15); WorkbenchID
// is set only for ScopeWorkbench.
type Scope struct {
	Kind        ScopeKind
	WorkbenchID int64
}

// String is the scope's canonical form, part of the approval hash:
// "personal" or "workbench:<id>".
func (s Scope) String() string {
	if s.Kind == ScopeWorkbench {
		return "workbench:" + strconv.FormatInt(s.WorkbenchID, 10)
	}
	return string(ScopePersonal)
}

// TriggerKind is the one trigger a recipe declares (spec §7.1).
type TriggerKind string

// Trigger kinds.
const (
	TriggerSchedule TriggerKind = "schedule"
	TriggerButton   TriggerKind = "button"
	TriggerEvent    TriggerKind = "event"
	TriggerManual   TriggerKind = "manual"
)

// ButtonTrigger is trigger.button.
type ButtonTrigger struct {
	Label   string
	Confirm bool
}

// EventTrigger is trigger.event; Where maps an event field to a string or glob.
type EventTrigger struct {
	Type  string
	Where map[string]string
}

// Trigger is the parsed trigger map; exactly one of Schedule, Button and Event
// is set for its kind, and none for TriggerManual.
type Trigger struct {
	Kind     TriggerKind
	Schedule string
	Button   *ButtonTrigger
	Event    *EventTrigger
}

// EventTypes are the event types a trigger.event may name (spec §8).
var EventTypes = []string{
	"slack.new_messages",
	"gmail.new_messages",
	"jira.issue_changed",
	"calendar.event_changed",
	"confluence.page_changed",
}

// MissedPolicy is what the scheduler does with a missed schedule.
type MissedPolicy string

// Missed policies.
const (
	MissedRunOnce MissedPolicy = "run_once"
	MissedSkip    MissedPolicy = "skip"
)

// Budget is a run's token and wall-clock budget (spec §7.5, §20 D4).
type Budget struct {
	Tokens, Minutes int
}

// Recipe is a parsed recipe file (spec §2). Permissions are kept as written;
// ParseRecipe validates them with ParseManifest, and ApprovalHash and
// ParseManifest normalise them.
type Recipe struct {
	Slug              string
	Name              string
	Trigger           Trigger
	Missed            MissedPolicy
	Concurrency       int
	Permissions       []string
	Outputs           []string
	Budget            Budget
	PauseTimeoutHours int
	Description       string
	Script            string
	ScriptLine        int // 1-based file line of the script's first line
	Scope             Scope
}

// ParseError is a recipe the parser refuses. Line is the 1-based file line,
// 0 when the error is about the whole file.
type ParseError struct {
	Line int
	Msg  string
}

func (e *ParseError) Error() string {
	if e.Line <= 0 {
		return e.Msg
	}
	return fmt.Sprintf("line %d: %s", e.Line, e.Msg)
}

const (
	maxNameRunes        = 80
	maxButtonLabelRunes = 24
	// frontmatterLineOffset turns a yaml line (1 = the line after the opening
	// "---") into a file line.
	frontmatterLineOffset = 1
)

var slugPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,63}$`)

// ValidSlug reports whether s is a valid recipe slug (the file stem).
func ValidSlug(s string) bool {
	return slugPattern.MatchString(s)
}

var utf8BOM = []byte("\xef\xbb\xbf")

// normaliseRecipeBytes strips a UTF-8 BOM and turns CRLF (and a lone CR) into
// LF, so a recipe saved on another platform parses (and hashes) like its LF
// twin. Line numbers in errors count lines of the normalised text.
func normaliseRecipeBytes(data []byte) []byte {
	data = bytes.TrimPrefix(data, utf8BOM)
	data = bytes.ReplaceAll(data, []byte("\r\n"), []byte("\n"))
	return bytes.ReplaceAll(data, []byte("\r"), []byte("\n"))
}

// validateScope refuses a scope that is neither personal nor a workbench with
// an id: a zero Scope is a caller bug, never a silent "personal".
func validateScope(s Scope) error {
	switch {
	case s.Kind == ScopePersonal && s.WorkbenchID == 0:
		return nil
	case s.Kind == ScopeWorkbench && s.WorkbenchID > 0:
		return nil
	}
	return &ParseError{Msg: fmt.Sprintf("invalid recipe scope %+v: want personal, or workbench with an id > 0", s)}
}

// ParseRecipe parses a recipe file. slug is the file stem; scope is the folder
// the file lives in. Every refusal is a *ParseError.
func ParseRecipe(slug string, data []byte, scope Scope) (*Recipe, error) {
	if !ValidSlug(slug) {
		return nil, &ParseError{Msg: fmt.Sprintf("invalid slug %q: want %s", slug, slugPattern.String())}
	}
	if err := validateScope(scope); err != nil {
		return nil, err
	}
	if len(data) > MaxRecipeBytes {
		return nil, &ParseError{Msg: fmt.Sprintf("%s.md is %d bytes; the limit is %d", slug, len(data), MaxRecipeBytes)}
	}
	text := normaliseRecipeBytes(data)
	if err := checkUTF8(slug, text); err != nil {
		return nil, err
	}
	lines := strings.Split(string(text), "\n")
	fmLines, bodyStart, err := splitFrontmatter(lines)
	if err != nil {
		return nil, err
	}
	r := &Recipe{Slug: slug, Scope: scope}
	if err := parseFrontmatter(strings.Join(fmLines, "\n"), r); err != nil {
		return nil, err
	}
	if err := parseBody(lines, bodyStart, r); err != nil {
		return nil, err
	}
	var pre *PreParseError
	if err := PreParse(r.Script); errors.As(err, &pre) {
		return nil, &ParseError{Line: r.ScriptLine + pre.Line - 1, Msg: pre.Error()}
	}
	if err := scriptShapeError(r.Script); err != nil {
		return nil, &ParseError{Line: r.ScriptLine, Msg: err.Error()}
	}
	return r, nil
}

func checkUTF8(slug string, text []byte) error {
	if utf8.Valid(text) {
		return nil
	}
	off := 0
	for off < len(text) {
		r, size := utf8.DecodeRune(text[off:])
		if r == utf8.RuneError && size <= 1 {
			break
		}
		off += size
	}
	line := bytes.Count(text[:off], []byte("\n")) + 1
	return &ParseError{Line: line, Msg: slug + ".md: invalid UTF-8"}
}

// splitFrontmatter returns the frontmatter lines and the index of the first
// body line. The file must open with a "---" line and close it with another.
func splitFrontmatter(lines []string) ([]string, int, error) {
	if len(lines) == 0 || strings.TrimRight(lines[0], " \t") != "---" {
		return nil, 0, &ParseError{Line: 1, Msg: `the recipe must start with a "---" frontmatter line`}
	}
	for i := 1; i < len(lines); i++ {
		if strings.TrimRight(lines[i], " \t") == "---" {
			return lines[1:i], i + 1, nil
		}
	}
	return nil, 0, &ParseError{Line: 1, Msg: `the frontmatter is not closed by a "---" line`}
}

// ---- frontmatter ----

var yamlLineRe = regexp.MustCompile(`^yaml: line (\d+): (.*)$`)

func parseFrontmatter(src string, r *Recipe) error {
	var doc yaml.Node
	if err := yaml.Unmarshal([]byte(src), &doc); err != nil {
		if m := yamlLineRe.FindStringSubmatch(err.Error()); m != nil {
			n, _ := strconv.Atoi(m[1]) // the regexp guarantees digits
			return &ParseError{Line: n + frontmatterLineOffset, Msg: "invalid frontmatter: " + m[2]}
		}
		return &ParseError{Line: 1, Msg: "invalid frontmatter: " + err.Error()}
	}
	if len(doc.Content) == 0 || doc.Content[0].Kind != yaml.MappingNode {
		return &ParseError{Line: 2, Msg: "the frontmatter must be a mapping of keys"}
	}
	fields, err := mappingFields(doc.Content[0], "", topLevelKeys)
	if err != nil {
		return err
	}
	return applyFields(fields, r)
}

var topLevelKeys = []string{"name", "trigger", "missed", "concurrency", "permissions", "outputs", "budget", "pause_timeout_hours"}

// mappingFields indexes a mapping's values by key, refusing duplicate and
// unknown keys (strict, spec §2.2) with the key's line.
func mappingFields(m *yaml.Node, prefix string, allowed []string) (map[string]*yaml.Node, error) {
	out := make(map[string]*yaml.Node, len(m.Content)/2)
	for i := 0; i+1 < len(m.Content); i += 2 {
		k := m.Content[i]
		name := prefix + k.Value
		if _, dup := out[k.Value]; dup {
			return nil, &ParseError{Line: fileLine(k), Msg: fmt.Sprintf("duplicate key %q", name)}
		}
		if !slices.Contains(allowed, k.Value) {
			return nil, &ParseError{Line: fileLine(k), Msg: unknownKeyMsg(name)}
		}
		out[k.Value] = m.Content[i+1]
	}
	return out, nil
}

func unknownKeyMsg(name string) string {
	switch name {
	case "workbench":
		return `"workbench" is not allowed in a recipe: the workbench is the folder the file lives in`
	case "budget.usd":
		return `"budget.usd" is not supported: budgets are in tokens (budget.tokens)`
	}
	return fmt.Sprintf("unknown key %q", name)
}

func fileLine(n *yaml.Node) int { return n.Line + frontmatterLineOffset }

// decodeField decodes one value node, naming the key and the wanted type on
// failure.
func decodeField(n *yaml.Node, key, want string, out any) error {
	if err := n.Decode(out); err != nil {
		return &ParseError{Line: fileLine(n), Msg: fmt.Sprintf("%s must be %s", key, want)}
	}
	return nil
}

func applyFields(f map[string]*yaml.Node, r *Recipe) error {
	if err := applyName(f["name"], r); err != nil {
		return err
	}
	if err := applyTrigger(f["trigger"], r); err != nil {
		return err
	}
	if err := applyMissed(f["missed"], r); err != nil {
		return err
	}
	if err := applyLists(f, r); err != nil {
		return err
	}
	if err := applyBudget(f["budget"], r); err != nil {
		return err
	}
	var err error
	if r.Concurrency, err = boundedInt(f["concurrency"], "concurrency", DefaultConcurrency, 1, MaxConcurrency); err != nil {
		return err
	}
	r.PauseTimeoutHours, err = boundedInt(f["pause_timeout_hours"], "pause_timeout_hours", DefaultPauseTimeoutHours, 1, MaxPauseTimeoutHours)
	return err
}

func applyName(n *yaml.Node, r *Recipe) error {
	if n == nil {
		return &ParseError{Line: 2, Msg: `"name" is required`}
	}
	var s string
	if err := decodeField(n, "name", "a string", &s); err != nil {
		return err
	}
	s = strings.TrimSpace(s)
	if c := utf8.RuneCountInString(s); c < 1 || c > maxNameRunes {
		return &ParseError{Line: fileLine(n), Msg: fmt.Sprintf("name must be 1-%d characters", maxNameRunes)}
	}
	r.Name = s
	return nil
}

func applyMissed(n *yaml.Node, r *Recipe) error {
	r.Missed = MissedRunOnce
	if n == nil {
		return nil
	}
	var s string
	if err := decodeField(n, "missed", "run_once or skip", &s); err != nil {
		return err
	}
	switch MissedPolicy(s) {
	case MissedRunOnce, MissedSkip:
		r.Missed = MissedPolicy(s)
		return nil
	}
	return &ParseError{Line: fileLine(n), Msg: fmt.Sprintf("missed must be run_once or skip, not %q", s)}
}

func applyLists(f map[string]*yaml.Node, r *Recipe) error {
	if n := f["permissions"]; n != nil {
		if err := decodeField(n, "permissions", "a list of strings", &r.Permissions); err != nil {
			return err
		}
	}
	if n := f["outputs"]; n != nil {
		if err := decodeField(n, "outputs", "a list of strings", &r.Outputs); err != nil {
			return err
		}
	}
	return validateManifest(f, r)
}

// validateManifest runs ParseManifest over the decoded lists and turns its
// refusal into a *ParseError on the offending entry's line.
func validateManifest(f map[string]*yaml.Node, r *Recipe) error {
	_, err := ParseManifest(r.Permissions, r.Outputs, r.Scope)
	var me *ManifestError
	if !errors.As(err, &me) {
		return err
	}
	n := f[me.Field]
	line := fileLine(n)
	if n.Kind == yaml.SequenceNode && me.Index < len(n.Content) {
		line = fileLine(n.Content[me.Index])
	}
	return &ParseError{Line: line, Msg: me.Field + ": " + me.Msg}
}

func applyBudget(n *yaml.Node, r *Recipe) error {
	r.Budget = Budget{Tokens: DefaultBudgetTokens, Minutes: DefaultBudgetMinutes}
	if n == nil {
		return nil
	}
	if n.Kind != yaml.MappingNode {
		return &ParseError{Line: fileLine(n), Msg: "budget must be a map {tokens, minutes}"}
	}
	f, err := mappingFields(n, "budget.", []string{"tokens", "minutes"})
	if err != nil {
		return err
	}
	if r.Budget.Tokens, err = boundedInt(f["tokens"], "budget.tokens", DefaultBudgetTokens, MinBudgetTokens, MaxBudgetTokens); err != nil {
		return err
	}
	r.Budget.Minutes, err = boundedInt(f["minutes"], "budget.minutes", DefaultBudgetMinutes, MinBudgetMinutes, MaxBudgetMinutes)
	return err
}

// boundedInt decodes an optional integer within [lo, hi]; absent → def.
func boundedInt(n *yaml.Node, key string, def, lo, hi int) (int, error) {
	if n == nil {
		return def, nil
	}
	// yaml.v3 truncates a float into an int field (1.9 → 1), so only a plain
	// integer scalar is accepted.
	var v int
	if n.Kind != yaml.ScalarNode || n.ShortTag() != "!!int" {
		return 0, &ParseError{Line: fileLine(n), Msg: key + " must be an integer"}
	}
	if err := decodeField(n, key, "an integer", &v); err != nil {
		return 0, err
	}
	if v < lo || v > hi {
		return 0, &ParseError{Line: fileLine(n), Msg: fmt.Sprintf("%s must be between %d and %d, not %d", key, lo, hi, v)}
	}
	return v, nil
}

// ---- trigger ----

func applyTrigger(n *yaml.Node, r *Recipe) error {
	if n == nil {
		return &ParseError{Line: 2, Msg: `"trigger" is required (one of schedule, button, event, manual)`}
	}
	if n.Kind != yaml.MappingNode {
		return &ParseError{Line: fileLine(n), Msg: "trigger must be a map with one of schedule, button, event, manual"}
	}
	f, err := mappingFields(n, "trigger.", []string{"schedule", "button", "event", "manual"})
	if err != nil {
		return err
	}
	if len(f) != 1 {
		return &ParseError{Line: fileLine(n), Msg: fmt.Sprintf("trigger must have exactly one of schedule, button, event, manual; it has %d", len(f))}
	}
	for key, v := range f { // exactly one entry
		r.Trigger.Kind = TriggerKind(key)
		switch r.Trigger.Kind {
		case TriggerSchedule:
			r.Trigger.Schedule, err = parseSchedule(v)
		case TriggerButton:
			r.Trigger.Button, err = parseButton(v)
		case TriggerEvent:
			r.Trigger.Event, err = parseEvent(v)
		case TriggerManual:
			err = parseManual(v)
		}
	}
	return err
}

// parseSchedule accepts a 5-field cron expression in the local time zone
// (robfig/cron's standard parser); descriptors ("@daily") are refused, and a
// TZ= prefix leaves too few fields for the parser.
func parseSchedule(n *yaml.Node) (string, error) {
	var s string
	if err := decodeField(n, "trigger.schedule", "a cron string", &s); err != nil {
		return "", err
	}
	s = strings.TrimSpace(s)
	if len(strings.Fields(s)) != 5 {
		return "", &ParseError{Line: fileLine(n), Msg: fmt.Sprintf("trigger.schedule %q must be a 5-field cron expression (minute hour day month weekday)", s)}
	}
	if _, err := cron.ParseStandard(s); err != nil {
		return "", &ParseError{Line: fileLine(n), Msg: fmt.Sprintf("trigger.schedule %q: %v", s, err)}
	}
	return s, nil
}

func parseButton(n *yaml.Node) (*ButtonTrigger, error) {
	if n.Kind != yaml.MappingNode {
		return nil, &ParseError{Line: fileLine(n), Msg: "trigger.button must be a map {label, confirm}"}
	}
	f, err := mappingFields(n, "trigger.button.", []string{"label", "confirm"})
	if err != nil {
		return nil, err
	}
	b := &ButtonTrigger{}
	if v := f["label"]; v != nil {
		if err := decodeField(v, "trigger.button.label", "a string", &b.Label); err != nil {
			return nil, err
		}
	}
	b.Label = strings.TrimSpace(b.Label)
	if c := utf8.RuneCountInString(b.Label); c < 1 || c > maxButtonLabelRunes {
		return nil, &ParseError{Line: fileLine(n), Msg: fmt.Sprintf("trigger.button.label must be 1-%d characters", maxButtonLabelRunes)}
	}
	if v := f["confirm"]; v != nil {
		if err := decodeField(v, "trigger.button.confirm", "true or false", &b.Confirm); err != nil {
			return nil, err
		}
	}
	return b, nil
}

func parseEvent(n *yaml.Node) (*EventTrigger, error) {
	if n.Kind != yaml.MappingNode {
		return nil, &ParseError{Line: fileLine(n), Msg: "trigger.event must be a map {type, where}"}
	}
	f, err := mappingFields(n, "trigger.event.", []string{"type", "where"})
	if err != nil {
		return nil, err
	}
	e := &EventTrigger{}
	if v := f["type"]; v != nil {
		if err := decodeField(v, "trigger.event.type", "a string", &e.Type); err != nil {
			return nil, err
		}
	}
	if !slices.Contains(EventTypes, e.Type) {
		return nil, &ParseError{Line: fileLine(n), Msg: fmt.Sprintf("trigger.event.type %q must be one of %s", e.Type, strings.Join(EventTypes, ", "))}
	}
	if v := f["where"]; v != nil {
		if err := decodeField(v, "trigger.event.where", "a map of field: string", &e.Where); err != nil {
			return nil, err
		}
		if err := validateWhere(v, e); err != nil {
			return nil, err
		}
	}
	return e, nil
}

// validateWhere refuses a where key the event type cannot match and a
// malformed glob, walking the map in file order so the first bad key is named.
func validateWhere(n *yaml.Node, e *EventTrigger) error {
	if n.Kind == yaml.AliasNode && n.Alias != nil {
		n = n.Alias // where: *anchor — check the mapping it names
	}
	for i := 0; i+1 < len(n.Content); i += 2 {
		key := n.Content[i].Value
		if !slices.Contains(EventFields[e.Type], key) {
			return &ParseError{Line: fileLine(n.Content[i]), Msg: fmt.Sprintf("trigger.event.where key %q is not a matchable %s field (%s)", key, e.Type, strings.Join(EventFields[e.Type], ", "))}
		}
		if !validGlob(e.Where[key]) {
			return &ParseError{Line: fileLine(n.Content[i]), Msg: fmt.Sprintf("trigger.event.where key %q has a malformed glob %q", key, e.Where[key])}
		}
	}
	return nil
}

func parseManual(n *yaml.Node) error {
	var on bool
	if err := decodeField(n, "trigger.manual", "true", &on); err != nil {
		return err
	}
	if !on {
		return &ParseError{Line: fileLine(n), Msg: "trigger.manual must be true"}
	}
	return nil
}

// ---- body ----

// fence is an open Markdown code fence.
type fence struct {
	char  byte
	count int
	info  string
}

// openFence reports whether line opens a fenced code block (up to three
// spaces of indent, then three or more backticks or tildes).
func openFence(line string) (fence, bool) {
	trimmed := strings.TrimLeft(line, " ")
	if len(line)-len(trimmed) > 3 || len(trimmed) < 3 || (trimmed[0] != '`' && trimmed[0] != '~') {
		return fence{}, false
	}
	c := trimmed[0]
	n := 0
	for n < len(trimmed) && trimmed[n] == c {
		n++
	}
	if n < 3 {
		return fence{}, false
	}
	info := strings.TrimSpace(trimmed[n:])
	if c == '`' && strings.Contains(info, "`") {
		return fence{}, false
	}
	if i := strings.IndexAny(info, " \t"); i >= 0 {
		info = info[:i]
	}
	return fence{char: c, count: n, info: info}, true
}

// closes reports whether line closes f.
func (f fence) closes(line string) bool {
	trimmed := strings.TrimLeft(line, " ")
	if len(line)-len(trimmed) > 3 {
		return false
	}
	rest := strings.TrimRight(trimmed, " \t")
	return len(rest) >= f.count && strings.Trim(rest, string(f.char)) == ""
}

// isScriptFence reports whether f opens the script: a backtick or tilde fence
// whose info string is js or javascript, case-insensitively (CommonMark).
func isScriptFence(f fence) bool {
	return strings.EqualFold(f.info, "js") || strings.EqualFold(f.info, "javascript")
}

// parseBody finds exactly one js fenced block in lines[start:]; everything
// else is the description.
func parseBody(lines []string, start int, r *Recipe) error {
	var desc, script []string
	found := false
	for i := start; i < len(lines); i++ {
		f, ok := openFence(lines[i])
		if !ok {
			desc = append(desc, lines[i])
			continue
		}
		end := closingLine(lines, i+1, f)
		if !isScriptFence(f) {
			if end < 0 {
				end = len(lines) - 1
			}
			desc = append(desc, lines[i:end+1]...)
			i = end
			continue
		}
		if found {
			return &ParseError{Line: i + 1, Msg: "a recipe must have exactly one ```js block; found a second one"}
		}
		if end < 0 {
			return &ParseError{Line: i + 1, Msg: "the ```js block is not closed"}
		}
		script = lines[i+1 : end]
		if strings.TrimSpace(strings.Join(script, "\n")) == "" {
			return &ParseError{Line: i + 1, Msg: "the ```js block is empty: the script is empty"}
		}
		found = true
		r.ScriptLine = i + 2
		i = end
	}
	if !found {
		return &ParseError{Line: start + 1, Msg: "a recipe must have exactly one ```js (or ```javascript) block; found none"}
	}
	r.Script = joinScript(script)
	r.Description = strings.TrimSpace(strings.Join(desc, "\n"))
	return nil
}

// closingLine returns the index of the line closing f, or -1.
func closingLine(lines []string, from int, f fence) int {
	for j := from; j < len(lines); j++ {
		if f.closes(lines[j]) {
			return j
		}
	}
	return -1
}

// joinScript returns the block's text with every line newline-terminated.
func joinScript(lines []string) string {
	if len(lines) == 0 {
		return ""
	}
	return strings.Join(lines, "\n") + "\n"
}
