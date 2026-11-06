package builtin

import (
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"watchtower/internal/automations"
	"watchtower/internal/automations/blocks"
	"watchtower/internal/db"
	"watchtower/internal/slack"
	"watchtower/internal/tools"
)

// approvals.list's text limits, below the blocks' own (heading 200, row
// title 300, row subtitle 500 characters).
const (
	approvalTitleRunes  = 200
	approvalLineRunes   = 300
	approvalDetailRunes = 500
	approvalTextRunes   = 4000
	// approvalsBudgetBytes bounds the JSON size of every approval's
	// strings together, well under the SDK result cap
	// (automations.MaxSDKResultBytes): each approval gets an even share,
	// its short strings a fixed part of it and its text what they leave.
	// Every approval is kept, only its words are cut.
	approvalsBudgetBytes = 100 << 10
	// approvalRowOverhead is an approval's JSON besides its strings: the
	// keys, key, kind, id, tone, status and the stamps.
	approvalRowOverhead = 400
)

// approvalSummaryArgs are the argument keys an action's one-line summary is
// read from, in order: the first non-empty string wins.
var approvalSummaryArgs = []string{"text", "summary", "title", "body", "message", "essence", "note", "query", "project_key"}

// ApprovalsPrimitives returns approvals.list over d — Needs approval's one
// read (no model): the open approvals at now() (db.ReadApprovalsView, the
// same set, order and cap of automations.MaxOutputsPerRun that the approval
// sweep compares with) as {status: "done", approvals: [{key, kind, id,
// title, line, detail, text, tone, link, tool, status, error, reason,
// run_label, created_at, changed_at, remind_at}], remove: [keys], count,
// truncated}. remove is every action:/reminder: key of the built-in's living
// artifacts whose approval is closed or gone; count is every open approval,
// truncated whether approvals left some out (the oldest are kept).
func ApprovalsPrimitives(d *db.DB, now func() time.Time) map[string]automations.PrimitiveFunc {
	return map[string]automations.PrimitiveFunc{
		automations.PrimitiveApprovalsList: func(ctx context.Context, call automations.PrimitiveCall) (automations.PrimitiveResult, error) {
			if d == nil {
				return automations.PrimitiveResult{}, errNotWired
			}
			// The built-in's artifacts are the ones remove names: in a dry
			// run of an unsaved draft there is no row yet, and none to remove.
			var automationID int64
			a, err := d.GetBuiltinAutomation(NeedsApprovalID)
			switch {
			case err == nil:
				automationID = a.ID
			case !errors.Is(err, db.ErrAutomationNotFound):
				return automations.PrimitiveResult{}, err
			}
			view, err := d.ReadApprovalsView(ctx, automationID, now(), automations.MaxOutputsPerRun)
			if err != nil {
				return automations.PrimitiveResult{}, err
			}
			labels, err := runLabels(ctx, d, view.Open)
			if err != nil {
				return automations.PrimitiveResult{}, err
			}
			items := make([]any, 0, len(view.Open))
			share := approvalsBudgetBytes / max(len(view.Open), 1)
			for _, o := range view.Open {
				items = append(items, approvalItem(o, labels[o.ID], share))
			}
			remove := make([]any, 0, len(view.Closed))
			for _, k := range view.Closed {
				remove = append(remove, k)
			}
			return automations.PrimitiveResult{Status: "done", Fields: map[string]any{
				"approvals": items, "remove": remove,
				"count": view.Total, "truncated": view.Total > len(view.Open),
			}}, nil
		},
	}
}

// approvalItem is the script's view of one open approval, its strings
// within share bytes of JSON (approvalsBudgetBytes): the title, line, detail,
// error, reason and run label an eighth of it each at most, the link only
// when it fits its eighth, the text what is left.
func approvalItem(o db.OpenApproval, runLabel string, share int) map[string]any {
	part := share / 8
	clip := func(s string, runes int) string { return clipJSON(clipApproval(s, runes), part) }
	item := map[string]any{
		"key": o.Ref(), "kind": o.Kind, "id": o.ID,
		"created_at": o.CreatedAt, "changed_at": o.ChangedAt,
		"tool": "", "status": o.Status, "error": "", "reason": "", "run_label": "",
		"remind_at": "", "link": "", "tone": "",
	}
	var text string
	if o.Kind == db.ApprovalKindReminder {
		text = strings.TrimSpace(o.Note)
		item["title"] = "Reminder"
		item["line"] = clip(oneLine(o.Note), approvalLineRunes)
		if item["line"] == "" {
			item["line"] = "Reminder"
		}
		item["detail"] = "Due " + o.RemindAt
		item["remind_at"] = o.RemindAt
		if link := reminderLink(o.MessageRef); jsonLen(link) <= part {
			item["link"] = link
		}
	} else {
		title := clip(toolTitle(o.Tool), approvalTitleRunes)
		text = actionSummary(o.ArgsJSON)
		item["title"] = title
		item["tool"] = clip(o.Tool, approvalTitleRunes)
		item["error"] = clip(o.Error, approvalDetailRunes)
		item["reason"] = clip(o.Reason, approvalDetailRunes)
		item["run_label"] = clip(runLabel, approvalDetailRunes)
		item["line"] = clip(oneLine(text), approvalLineRunes)
		if item["line"] == "" {
			item["line"] = title
		}
		if o.Status == "failed" {
			item["detail"] = clip(oneLine("Failed: "+o.Error), approvalDetailRunes)
			item["tone"] = "danger"
		} else {
			item["detail"] = clip(oneLine(o.Reason), approvalDetailRunes)
		}
	}
	left := share - approvalRowOverhead
	for _, k := range []string{"title", "line", "detail", "tool", "error", "reason", "run_label", "link", "remind_at", "created_at", "changed_at"} {
		left -= jsonLen(item[k].(string))
	}
	item["text"] = clipJSON(clipApproval(text, approvalTextRunes), left)
	return item
}

// runLabels maps each automation proposal among open (context
// automation_run) to its run's label, "⚙ <name> · run #<id>", or "⚙
// automation · run #<id>" when the run is gone — as the Desktop labels the
// card (ActionStripViewModel.labels). Other actions get none.
func runLabels(ctx context.Context, d *db.DB, open []db.OpenApproval) (map[int64]string, error) {
	runOf := map[int64]int64{}
	var ids []int64
	for _, o := range open {
		if o.Kind != db.ApprovalKindAction || o.ContextType != tools.AutomationContextType {
			continue
		}
		run, err := strconv.ParseInt(o.ContextID, 10, 64)
		if err != nil || run <= 0 {
			continue
		}
		runOf[o.ID] = run
		ids = append(ids, run)
	}
	named, err := d.AutomationRunLabels(ctx, ids)
	if err != nil {
		return nil, err
	}
	out := map[int64]string{}
	for action, run := range runOf {
		out[action] = cmp.Or(named[run], fmt.Sprintf("⚙ automation · run #%d", run))
	}
	return out, nil
}

// toolTitle is a tool's name in words: "create_jira_issue" → "Create jira
// issue". The Desktop's card shows the catalog's own title next to Approve;
// this is the artifact's heading.
func toolTitle(tool string) string {
	words := strings.Fields(strings.ReplaceAll(tool, "_", " "))
	if len(words) == 0 {
		return "Action"
	}
	s := strings.Join(words, " ")
	r, n := utf8.DecodeRuneInString(s)
	return string(unicode.ToUpper(r)) + s[n:]
}

// actionSummary is the first non-empty approvalSummaryArgs string of args,
// with the issue key in front when the args name one ("ACME-1: …"); "" when
// args are not a JSON object or hold none of them — the action is still
// drawn, with its tool's title.
func actionSummary(argsJSON string) string {
	var args map[string]any
	if json.Unmarshal([]byte(argsJSON), &args) != nil {
		return ""
	}
	text := ""
	for _, k := range approvalSummaryArgs {
		if s, ok := args[k].(string); ok && strings.TrimSpace(s) != "" {
			text = strings.TrimSpace(s)
			break
		}
	}
	if key, ok := args["key"].(string); ok && strings.TrimSpace(key) != "" {
		if text == "" {
			return strings.TrimSpace(key)
		}
		return strings.TrimSpace(key) + ": " + text
	}
	return text
}

// reminderLink is the Slack web link of a reminder's message
// (<channel>@<ts>, split on the last @), "" when it names none or the link
// is longer than a card link may be (blocks.MaxLinkBytes).
func reminderLink(ref string) string {
	at := strings.LastIndex(ref, "@")
	if at <= 0 || at == len(ref)-1 {
		return ""
	}
	channel, ts := slack.RawID(ref[:at]), ref[at+1:]
	if channel == "" || strings.ContainsAny(channel+ts, "/?#% ") {
		return ""
	}
	link := "https://slack.com/archives/" + channel + "/p" + strings.ReplaceAll(ts, ".", "")
	if len(link) > blocks.MaxLinkBytes {
		return "" // the blocks would refuse it, and with it the whole run
	}
	return link
}

// oneLine is s with every run of whitespace (newlines included) as one
// space, trimmed.
func oneLine(s string) string { return strings.Join(strings.Fields(s), " ") }

// clipApproval is s cut to at most n runes, an ellipsis marking the cut.
func clipApproval(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	r := []rune(s)
	return string(r[:n-1]) + "…"
}
