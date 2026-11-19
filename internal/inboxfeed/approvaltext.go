package inboxfeed

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"unicode/utf8"

	"watchtower/internal/tower/api"
)

// The tools whose approval card the text rules below name.
const (
	toolSaveAutomation  = "save_automation"
	toolSlackSend       = "send_slack_message"
	toolConnectorCall   = "claude_ai_connector_call"
	toolConfluenceEdit  = "edit_confluence_page"
	toolBriefContext    = "brief_context"
	automationRunCtx    = "automation_run"
	defaultProposalLine = "Assistant proposal"
)

// toolTitles are the shared human names of the proposable tools
// (ReactionToolCatalog.entries' titles); any other tool is named as is.
var toolTitles = map[string]string{
	"create_target":            "Create a target",
	"create_jira_issue":        "Create a Jira issue",
	"create_linear_issue":      "Create a Linear issue",
	"create_track":             "Track this",
	"create_idea":              "Save as idea",
	"remind_me":                "Remind me",
	"brief_context":            "Brief me",
	"connect_jira_board":       "Connect a Jira board",
	"dismiss_tracks":           "Dismiss tracks",
	"add_jira_comment":         "Comment on a Jira issue",
	"transition_jira_issue":    "Move a Jira issue",
	"assign_jira_issue":        "Assign a Jira issue",
	"update_jira_issue":        "Update a Jira issue",
	"add_linear_comment":       "Comment on a Linear issue",
	"transition_linear_issue":  "Move a Linear issue",
	"assign_linear_issue":      "Assign a Linear issue",
	"update_linear_issue":      "Update a Linear issue",
	"edit_confluence_page":     "Edit a Confluence page",
	"send_slack_message":       "Send to Slack",
	"claude_ai_connector_call": "Use a claude.ai connector",
}

// ToolTitle is a tool's human name (AgentActionCardView.title(for:)).
func ToolTitle(tool string) string {
	if t, ok := toolTitles[tool]; ok {
		return t
	}
	return tool
}

// ApprovalText is what the Mac's native approval card says about a
// proposal: its header title, its body lines and whether the Mac edits its
// args (Edit…, Edit Input, Open Draft).
type ApprovalText struct {
	Title     string
	Summary   []string
	EditOnMac bool
	// Disclosure, RecipeText and Diff are a save_automation past pending's
	// recipe disclosure (SaveAutomationCardDetails): its title, a new
	// recipe's text, an edit's diff (none when unchanged).
	Disclosure string
	RecipeText string
	Diff       []api.DiffLine
}

// ApprovalTextOf is a proposal in status's card text, as the Mac draws it
// (InboxReadingPane's proposal branch, AgentActionCardView.body): a pending
// save_automation as SaveAutomationProposalPane (the For / When / It may
// lines under "Save automation <name>", Open Draft), any other
// save_automation as SaveAutomationCardDetails (its scope line, the
// model's lines and its dry-run summary), a claude.ai connector call as its
// connector, tool and indented input, a Slack send as its recipient and
// text, any other tool as AgentActionCardView.summaryLines. workbenchName
// names a workbench ("" when not known): the Mac's workbench list is the
// projects table (WorkbenchQueries.summaries).
func ApprovalTextOf(tool, argsJSON, resultJSON, status string, workbenchName func(int64) string) ApprovalText {
	args := jsonObject(argsJSON)
	switch tool {
	case toolSaveAutomation:
		if status != "pending" {
			return saveAutomationCard(argsJSON, workbenchName)
		}
		s := SummarizeSaveAutomation(argsJSON, workbenchName)
		return ApprovalText{Title: s.Name, Summary: []string{"For: " + s.Scope, "When: " + s.When, "It may: " + s.May},
			EditOnMac: true}
	case toolConnectorCall:
		if c, ok := connectorCall(args, argsJSON); ok {
			return ApprovalText{Title: ToolTitle(tool), Summary: []string{"Connector: " + c.server, "Tool: " + c.tool, c.input},
				EditOnMac: true}
		}
	case toolSlackSend:
		if s, ok := slackSend(args); ok {
			return ApprovalText{Title: ToolTitle(tool), Summary: []string{s.recipientLine(), s.text}, EditOnMac: true}
		}
	}
	return ApprovalText{Title: ToolTitle(tool), Summary: summaryLines(tool, args, argsJSON, jsonObject(resultJSON))}
}

// summaryLines is AgentActionCardView.summaryLines: the per-tool lines,
// the raw args for a tool it has no rendering for.
func summaryLines(tool string, args map[string]any, argsJSON string, result map[string]any) []string {
	arg := func(k string) (string, bool) { return stringValue(args[k]) }
	argOr := func(k, def string) string {
		if v, ok := arg(k); ok {
			return v
		}
		return def
	}
	nonEmpty := func(k string) (string, bool) {
		v, ok := arg(k)
		return v, ok && v != ""
	}
	switch tool {
	case "create_target":
		lines := []string{argOr("text", "")}
		var meta []string
		if v, ok := nonEmpty("due"); ok {
			meta = append(meta, "Due: "+v)
		}
		if v, ok := nonEmpty("priority"); ok {
			meta = append(meta, "Priority: "+v)
		}
		if v, ok := nonEmpty("parent_id"); ok {
			meta = append(meta, "Under task #"+v)
		}
		if len(meta) > 0 {
			lines = append(lines, strings.Join(meta, " · "))
		}
		if v, ok := nonEmpty("intent"); ok {
			lines = append(lines, "Why: "+v)
		}
		return lines
	case "create_jira_issue":
		lines := []string{"Project: " + argOr("project_key", "?") + " · " + argOr("issue_type", "?"),
			"Summary: " + argOr("summary", "")}
		for _, f := range [][2]string{{"description", "Description"}, {"labels", "Labels"}, {"priority", "Priority"}} {
			if v, ok := nonEmpty(f[0]); ok {
				lines = append(lines, f[1]+": "+v)
			}
		}
		return lines
	}
	if tool == toolConfluenceEdit {
		changes, ok := args["changes"].([]any)
		if !ok || len(changes) == 0 || !allObjects(changes) {
			return []string{"Unreadable Confluence edit proposal"}
		}
		title := argOr("title", "")
		if title == "" {
			title = "Confluence page"
		}
		return []string{"Page: " + title + " · edits version " + argOr("base_version", "?")}
	}
	if lines, ok := waveTwoLines(tool, args, argsJSON, result, arg, argOr, nonEmpty); ok {
		return lines
	}
	if lines, ok := issueWriteLines(tool, argOr, nonEmpty); ok {
		return lines
	}
	if s, ok := slackSend(args); ok && tool == toolSlackSend {
		return []string{s.recipientLine(), s.text}
	}
	return []string{argsJSON}
}

// waveTwoLines are connect_jira_board's and the Reaction Commands Wave 2
// tools' lines (AgentActionCardView.waveTwoSummaryLines).
func waveTwoLines(tool string, args map[string]any, argsJSON string, result map[string]any,
	arg func(string) (string, bool), argOr func(string, string) string, nonEmpty func(string) (string, bool),
) ([]string, bool) {
	switch tool {
	case "connect_jira_board":
		lines := []string{"Project: " + argOr("project_key", "?")}
		if v, ok := nonEmpty("board_name"); ok {
			lines = append(lines, "Board: "+v)
		}
		return lines, true
	case "create_track":
		return []string{argOr("text", argsJSON)}, true
	case "dismiss_tracks":
		return dismissTracksLines(args), true
	case "create_idea":
		lines := []string{argOr("essence", "")}
		if v, ok := nonEmpty("title"); ok {
			lines = append([]string{v}, lines...)
		}
		return lines, true
	case "remind_me":
		lines := []string{"Remind at: " + argOr("remind_at", "?")}
		if v, ok := nonEmpty("note"); ok {
			lines = append(lines, v)
		}
		return lines, true
	case toolBriefContext:
		if v, ok := stringValue(result["summary"]); ok {
			return []string{v}, true
		}
		if v, ok := arg("summary"); ok {
			return []string{v}, true
		}
		return []string{argsJSON}, true
	}
	return nil, false
}

// issueWriteLines are the existing-issue Jira and the Linear writes' lines
// (jiraIssueWriteSummaryLines, linearSummaryLines).
func issueWriteLines(tool string, argOr func(string, string) string, nonEmpty func(string) (string, bool)) ([]string, bool) {
	key := argOr("key", "?")
	present := func(pairs [][2]string) []string {
		var out []string
		for _, p := range pairs {
			if v, ok := nonEmpty(p[0]); ok {
				out = append(out, p[1]+": "+v)
			}
		}
		return out
	}
	first := func(keys ...string) string {
		for _, k := range keys {
			if v, ok := nonEmpty(k); ok {
				return v
			}
		}
		return "?"
	}
	switch tool {
	case "add_jira_comment", "add_linear_comment":
		return []string{"Issue: " + key, argOr("body", "")}, true
	case "transition_jira_issue":
		return []string{"Issue: " + key + " → " + argOr("status", "?")}, true
	case "assign_jira_issue":
		asked := argOr("assignee", "?")
		name, ok := nonEmpty("resolved_assignee_name")
		if !ok {
			return []string{"Issue: " + key + " · Assignee: " + asked}, true
		}
		var detail []string
		if name != asked {
			detail = append(detail, `asked for "`+asked+`"`)
		}
		if acc, ok := nonEmpty("resolved_assignee_account_id"); ok {
			detail = append(detail, "Jira account "+acc)
		}
		head := "Issue: " + key + " · Assignee: " + name
		if len(detail) == 0 {
			return []string{head}, true
		}
		return []string{head, strings.Join(detail, " · ")}, true
	case "update_jira_issue":
		return append([]string{"Issue: " + key}, present([][2]string{{"summary", "Summary"}, {"priority", "Priority"},
			{"labels_add", "Add labels"}, {"labels_remove", "Remove labels"}, {"due_date", "Due"}})...), true
	case "create_linear_issue":
		return present([][2]string{{"team", "Team"}, {"title", "Title"}, {"description", "Description"},
			{"state", "State"}, {"assignee", "Assignee"}, {"labels", "Labels"}, {"priority", "Priority"}}), true
	case "transition_linear_issue":
		return []string{"Issue: " + key + " → " + first("state_name", "state", "state_type")}, true
	case "assign_linear_issue":
		return []string{"Issue: " + key + " · Assignee: " + first("assignee_name", "assignee")}, true
	case "update_linear_issue":
		return append([]string{"Issue: " + key}, present([][2]string{{"title", "Title"}, {"priority", "Priority"},
			{"labels_add", "Add labels"}, {"labels_remove", "Remove labels"}, {"due_date", "Due"},
			{"estimate", "Estimate"}})...), true
	}
	return nil, false
}

// dismissTracksLines: the summary line Go pinned, the sample titles and how
// many the preview leaves out.
func dismissTracksLines(args map[string]any) []string {
	var titles []string
	if list, ok := args["sample_titles"].([]any); ok {
		for _, v := range list {
			if s, ok := stringValue(v); ok {
				titles = append(titles, s)
			}
		}
	}
	total := len(titles)
	if ids, ok := args["resolved_ids"].([]any); ok {
		total = len(ids)
	}
	head, ok := stringValue(args["summary"])
	if !ok {
		head = "Dismiss tracks"
	}
	lines := []string{head}
	for _, t := range titles {
		lines = append(lines, "• "+t)
	}
	if total > len(titles) {
		lines = append(lines, fmt.Sprintf("…and %d more", total-len(titles)))
	}
	return lines
}

// slackProposal is a send_slack_message proposal (SlackSendProposal).
type slackProposal struct {
	text       string
	target     *slackRecipient
	candidates []slackRecipient
}

type slackRecipient struct {
	workspace, label, threadTS, userID, handle, realName string
	isDM                                                 bool
}

// slackSend reads a Slack send's args; false when it names no recipient.
func slackSend(args map[string]any) (slackProposal, bool) {
	var p slackProposal
	if t, ok := args["target"].(map[string]any); ok {
		r := recipientOf(t)
		p.target = &r
	}
	if list, ok := args["candidates"].([]any); ok {
		for _, v := range list {
			m, ok := v.(map[string]any)
			if !ok {
				// Swift's `as? [[String: Any]]` fails the whole array.
				p.candidates = nil
				break
			}
			p.candidates = append(p.candidates, recipientOf(m))
		}
	}
	if p.target == nil && len(p.candidates) == 0 {
		return p, false
	}
	p.text, _ = stringValue(args["text"])
	return p, true
}

func recipientOf(m map[string]any) slackRecipient {
	s := func(k, def string) string {
		if v, ok := stringValue(m[k]); ok {
			return v
		}
		return def
	}
	r := slackRecipient{workspace: s("workspace", ""), label: s("label", "?"), threadTS: s("thread_ts", ""),
		userID: s("user_id", ""), handle: s("handle", ""), realName: s("real_name", "")}
	r.isDM = r.userID != ""
	return r
}

// recipientLine is SlackSendProposal.recipientLine.
func (p slackProposal) recipientLine() string {
	if p.target != nil {
		return "To: " + p.target.line()
	}
	return fmt.Sprintf("To: %s — exists in %d workspaces, choose one", p.candidates[0].label, len(p.candidates))
}

func (r slackRecipient) line() string {
	shownRealName := r.realName
	if r.realName == "" || r.label == "@"+r.realName {
		shownRealName = ""
	}
	var parts []string
	for _, p := range []string{shownRealName, r.identity()} {
		if p != "" {
			parts = append(parts, p)
		}
	}
	threadLabel := r.label
	if r.threadTS != "" {
		threadLabel = "a thread in " + r.label
	}
	var who string
	switch {
	case r.isDM && len(parts) > 0:
		who = r.label + " (" + strings.Join(parts, ", ") + ")"
	case r.isDM:
		who = r.label
	default:
		who = threadLabel
	}
	if r.workspace == "" {
		return who
	}
	return who + " in " + r.workspace
}

func (r slackRecipient) identity() string {
	var parts []string
	if r.handle != "" {
		parts = append(parts, "@"+r.handle)
	}
	if r.userID != "" {
		parts = append(parts, r.userID)
	}
	return strings.Join(parts, " · ")
}

// connector is a claude_ai_connector_call proposal (ConnectorCallProposal).
type connector struct{ server, tool, input string }

func connectorCall(args map[string]any, argsJSON string) (connector, bool) {
	server, _ := args["server"].(string)
	tool, _ := args["tool"].(string)
	if _, ok := args["input"].(map[string]any); !ok || server == "" || tool == "" {
		return connector{}, false
	}
	raw, ok := rawMember("input", argsJSON)
	if !ok {
		return connector{}, false
	}
	return connector{server: server, tool: tool, input: rawIndented(raw)}, true
}

// stringValue is AgentAction.stringValue: a string as is, a number as
// NSNumber prints it (a bool as 1 or 0), an array as its strings joined
// with ", "; anything else is none.
func stringValue(v any) (string, bool) {
	switch x := v.(type) {
	case string:
		return x, true
	case bool:
		if x {
			return "1", true
		}
		return "0", true
	case json.Number:
		return numberString(x), true
	case float64:
		return strconv.FormatFloat(x, 'g', -1, 64), true
	case []any:
		var parts []string
		for _, e := range x {
			if s, ok := stringValue(e); ok {
				parts = append(parts, s)
			}
		}
		return strings.Join(parts, ", "), true
	}
	return "", false
}

// numberString prints a JSON number as NSNumber.stringValue does for the
// values a proposal carries: an integer as itself, a fraction shortest.
func numberString(n json.Number) string {
	if i, err := strconv.ParseInt(string(n), 10, 64); err == nil {
		return strconv.FormatInt(i, 10)
	}
	f, err := n.Float64()
	if err != nil {
		return string(n)
	}
	if f == float64(int64(f)) {
		return strconv.FormatInt(int64(f), 10)
	}
	return strconv.FormatFloat(f, 'g', -1, 64)
}

// jsonObject decodes a JSON object (numbers kept as json.Number); anything
// else is empty, as AgentAction.args reads it.
func jsonObject(s string) map[string]any {
	dec := json.NewDecoder(strings.NewReader(s))
	dec.UseNumber()
	var m map[string]any
	if dec.Decode(&m) != nil || m == nil {
		return map[string]any{}
	}
	return m
}

func allObjects(list []any) bool {
	for _, v := range list {
		if _, ok := v.(map[string]any); !ok {
			return false
		}
	}
	return true
}

// rawMember is RawJSON.member: the raw text of key's value in a JSON
// object, as written.
func rawMember(key, js string) (string, bool) {
	chars := []rune(js)
	i := skipSpace(chars, 0)
	if i >= len(chars) || chars[i] != '{' {
		return "", false
	}
	i++
	for {
		i = skipSpace(chars, i)
		if i >= len(chars) || chars[i] != '"' {
			return "", false
		}
		keyEnd := valueEnd(chars, i)
		var name string
		nameOK := json.Unmarshal([]byte(string(chars[i:keyEnd])), &name) == nil
		i = skipSpace(chars, keyEnd)
		if i >= len(chars) || chars[i] != ':' {
			return "", false
		}
		start := skipSpace(chars, i+1)
		end := valueEnd(chars, start)
		if nameOK && name == key {
			return string(chars[start:end]), true
		}
		i = skipSpace(chars, end)
		if i >= len(chars) || chars[i] != ',' {
			return "", false
		}
		i++
	}
}

// rawIndented is RawJSON.indented: the text re-indented two spaces a level,
// key order and number spelling kept, a \u escape of a printable character
// written as the character.
func rawIndented(js string) string {
	chars := []rune(js)
	var out bytes.Buffer
	depth := 0
	newline := func() {
		out.WriteByte('\n')
		out.WriteString(strings.Repeat("  ", depth))
	}
	for i := 0; i < len(chars); {
		c := chars[i]
		switch c {
		case '"':
			end := valueEnd(chars, i)
			appendString(chars[i:end], &out)
			i = end
			continue
		case '{', '[':
			out.WriteRune(c)
			next := skipSpace(chars, i+1)
			if next < len(chars) && (chars[next] == '}' || chars[next] == ']') {
				out.WriteRune(chars[next])
				i = next + 1
				continue
			}
			depth++
			newline()
		case '}', ']':
			depth--
			newline()
			out.WriteRune(c)
		case ',':
			out.WriteRune(c)
			newline()
		case ':':
			out.WriteString(": ")
		case ' ', '\t', '\n', '\r':
		default:
			out.WriteRune(c)
		}
		i++
	}
	return out.String()
}

func appendString(token []rune, out *bytes.Buffer) {
	for i := 0; i < len(token); {
		c := token[i]
		if c != '\\' || i+1 >= len(token) {
			out.WriteRune(c)
			i++
			continue
		}
		if token[i+1] == 'u' && i+6 <= len(token) {
			if code, err := strconv.ParseUint(string(token[i+2:i+6]), 16, 32); err == nil &&
				code >= 0x20 && code != 0x22 && code != 0x5C && (code < 0x7F || code > 0x9F) &&
				utf8.ValidRune(rune(code)) {
				out.WriteRune(rune(code))
				i += 6
				continue
			}
		}
		out.WriteRune(token[i])
		out.WriteRune(token[i+1])
		i += 2
	}
}

func skipSpace(chars []rune, from int) int {
	i := from
	for i < len(chars) && (chars[i] == ' ' || chars[i] == '\t' || chars[i] == '\n' || chars[i] == '\r') {
		i++
	}
	return i
}

func valueEnd(chars []rune, from int) int {
	if from >= len(chars) {
		return from
	}
	i := from
	switch chars[i] {
	case '"':
		i++
		for i < len(chars) && chars[i] != '"' {
			if chars[i] == '\\' {
				i += 2
			} else {
				i++
			}
		}
		return min(i+1, len(chars))
	case '{', '[':
		depth := 0
		for i < len(chars) {
			switch chars[i] {
			case '"':
				i = valueEnd(chars, i)
				continue
			case '{', '[':
				depth++
			case '}', ']':
				depth--
				if depth == 0 {
					return i + 1
				}
			}
			i++
		}
		return i
	}
	for i < len(chars) && !strings.ContainsRune(",}] \t\n\r", chars[i]) {
		i++
	}
	return i
}

// saveCardArgs are the save_automation args SaveAutomationCardModel reads.
type saveCardArgs struct {
	Name          string          `json:"name"`
	Slug          string          `json:"slug"`
	TriggerKind   string          `json:"trigger_kind"`
	TriggerSpec   json.RawMessage `json:"trigger_spec"`
	Permissions   []string        `json:"permissions"`
	Outputs       []string        `json:"outputs"`
	Widening      []string        `json:"widening"`
	BudgetTokens  int64           `json:"budget_tokens"`
	BudgetMinutes int64           `json:"budget_minutes"`
	Missed        string          `json:"missed"`
	Concurrency   int64           `json:"concurrency"`
	Path          string          `json:"path"`
	IsNew         bool            `json:"is_new"`
	DryRunSummary string          `json:"dry_run_summary"`
	WorkbenchID   *int64          `json:"workbench_id"`
	RecipeText    string          `json:"recipe_text"`
	Previous      string          `json:"previous_recipe_text"`
}

// saveAutomationCard is a save_automation past pending as the Mac's card
// draws it (SaveAutomationCardModel, SaveAutomationCardDetails): "Save
// automation <name>", then its scope line, the file, when, each permission
// (a widening one marked "+ "), each output, the budget, the missed-run and
// concurrency lines, and the dry-run summary. Args that do not decode read
// as empty ones, as on the Mac. Then its disclosure: a new recipe's whole
// text ("Show the whole recipe (N lines)"), an edit's diff against the
// saved text ("Show changes", or "No change to the recipe text" with no
// lines).
func saveAutomationCard(argsJSON string, workbenchName func(int64) string) ApprovalText {
	var a saveCardArgs
	if json.Unmarshal([]byte(argsJSON), &a) != nil {
		a = saveCardArgs{}
	}
	name := a.Name
	if name == "" {
		name = a.Slug
	}
	scope := "For: Personal"
	if a.WorkbenchID != nil {
		wb := workbenchName(*a.WorkbenchID)
		if wb == "" {
			wb = "#" + strconv.FormatInt(*a.WorkbenchID, 10)
		}
		scope = "For: workbench " + wb
	}
	file := a.Slug + ".md"
	if a.Path != "" {
		file = a.Path[strings.LastIndex(a.Path, "/")+1:]
	}
	if a.IsNew {
		file += " (new)"
	} else {
		file += " (replaces the saved one)"
	}
	lines := []string{scope, "File: " + file, "When: " + triggerSentence(a.TriggerKind, a.TriggerSpec)}
	widening := map[string]bool{}
	for _, w := range a.Widening {
		widening[w] = true
	}
	for _, p := range a.Permissions {
		line := p + " — " + PermissionLine(p)
		if widening[p] {
			line = "+ " + line
		}
		lines = append(lines, line)
	}
	for _, o := range a.Outputs {
		lines = append(lines, "output: "+o+" — "+outputLine(o))
	}
	lines = append(lines, "Budget: "+groupThousands(a.BudgetTokens)+" tokens · "+strconv.FormatInt(a.BudgetMinutes, 10)+" min")
	if a.Missed != "" {
		if a.Missed == "skip" {
			lines = append(lines, "Missed: skip a time the Mac was asleep")
		} else {
			lines = append(lines, "Missed: run once when the Mac wakes")
		}
	}
	switch {
	case a.Concurrency == 1:
		lines = append(lines, "Concurrency: one run at a time")
	case a.Concurrency > 1:
		lines = append(lines, fmt.Sprintf("Concurrency: up to %d runs at a time", a.Concurrency))
	}
	if summary := strings.TrimSpace(a.DryRunSummary); summary != "" {
		lines = append(lines, "Assistant's dry-run summary: "+summary)
	}
	t := ApprovalText{Title: "Save automation " + name, Summary: lines}
	if a.IsNew {
		t.Disclosure, t.RecipeText = recipeDisclosureTitle(a.RecipeText), a.RecipeText
		return t
	}
	diff := recipeDiff(a.Previous, a.RecipeText)
	t.Disclosure = "No change to the recipe text"
	for _, l := range diff {
		if l.Kind != api.DiffSame {
			t.Disclosure, t.Diff = "Show changes", diff
			break
		}
	}
	return t
}

// outputLine is AutomationCardPresentation.outputLine.
func outputLine(output string) string {
	switch output {
	case "inbox":
		return "Put cards in your Inbox"
	case "report":
		return "Add reports to this automation"
	case "briefing":
		return "Add items to your briefing"
	case "target":
		return "Create targets"
	case "slack":
		return "Send Slack messages"
	}
	return "Write " + output
}

// groupThousands is AutomationCardPresentation.number: en_US grouping.
func groupThousands(n int64) string {
	s := strconv.FormatInt(n, 10)
	neg := strings.HasPrefix(s, "-")
	s = strings.TrimPrefix(s, "-")
	var b strings.Builder
	for i, r := range s {
		if i > 0 && (len(s)-i)%3 == 0 {
			b.WriteByte(',')
		}
		b.WriteRune(r)
	}
	if neg {
		return "-" + b.String()
	}
	return b.String()
}
