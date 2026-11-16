package inboxfeed

import (
	"context"
	"database/sql"
	"fmt"
	"strconv"
	"strings"

	"watchtower/internal/db"
	"watchtower/internal/slack"
	"watchtower/internal/tools"
	"watchtower/internal/tower/api"
)

// approvalsFeatureID is the approval-cards switch (ActionStripViewModel.approvalsFeatureID):
// off, every open approval draws its native card.
const approvalsFeatureID = "approval-cards"

// approval is one open approval with its card picked (NeedsApprovalItem).
type approval struct {
	open db.OpenApproval
	// recipe is the needs-approval built-in's artifact drawing it; nil
	// draws the native card.
	recipe *output
}

// pickApproval is NeedsApprovalSelection.pick: the recipe's card only when
// all four hold — the recipe is on (the switch on, the built-in not
// stopped), its latest run did not fail, its artifact for the approval
// exists, and that artifact was written at or after the approval's last
// change. Otherwise the native card (APPROVAL-01).
func pickApproval(a db.OpenApproval, card *db.ApprovalCard, b db.ApprovalBuiltinState) bool {
	if !b.FeatureOn || b.Stopped || !b.LastRunOK || card == nil || b.AutomationID == 0 ||
		card.AutomationID != b.AutomationID {
		return false
	}
	return !parseStamp(card.WrittenAt).Before(parseStamp(a.ChangedAt))
}

// approvals are the open approvals in list order with their cards picked:
// the native ones above the recipe's, each half oldest created first
// (InboxFolderEntries.approvals). A built-in artifact whose approval is not
// open here is never drawn.
func (s *snapshot) approvals() []approval {
	var native, recipe []approval
	for _, a := range s.needs.Open {
		var card *db.ApprovalCard
		if c, ok := s.needs.Cards[a.Ref()]; ok {
			card = &c
		}
		if pickApproval(a, card, s.needs.Builtin) {
			if o, ok := s.outputs[card.OutputID]; ok {
				recipe = append(recipe, approval{open: a, recipe: &o})
				continue
			}
		}
		native = append(native, approval{open: a})
	}
	return append(native, recipe...)
}

// approvalCards are Needs approval's entries, shown in folder: the
// built-in upgrade notices, then every open approval (native cards above
// the recipe's), then the settled actions (approved or executing, drawn
// natively and never counted).
func (s *snapshot) approvalCards(folder int64) []api.Card {
	out := make([]api.Card, 0, len(s.notices)+len(s.needs.Open)+len(s.needs.Settled))
	for _, n := range s.notices {
		out = append(out, noticeCard(n, folder))
	}
	for _, a := range s.approvals() {
		out = append(out, s.approvalCard(a, folder))
	}
	for _, a := range s.needs.Settled {
		out = append(out, s.actionCard(actionRowOf(a), folder))
	}
	return out
}

// approvalCard is an open approval's card: the recipe's artifact, the
// native proposal or the native reminder. Every one is unread (the folder
// row's rule) and titled as the folder row names it.
func (s *snapshot) approvalCard(a approval, folder int64) api.Card {
	o := a.open
	if a.recipe != nil {
		c := s.artifactCard(*a.recipe, folder)
		c.Title, c.Unread = approvalTitle(o), true
		if o.Kind == db.ApprovalKindAction {
			c.Approval = s.approvalOf(actionRowOfOpen(o))
		}
		return c
	}
	if o.Kind == db.ApprovalKindReminder {
		return s.reminderCard(o, folder)
	}
	return s.actionCard(actionRowOfOpen(o), folder)
}

// approvalTitle is the folder row's title (InboxFolderEntries.approvalTitle):
// an action's reason, else its tool; a reminder's note, else "Reminder".
func approvalTitle(o db.OpenApproval) string {
	if o.Kind == db.ApprovalKindReminder {
		return reminderTitle(o.Note)
	}
	if o.Reason == "" {
		return o.Tool
	}
	return o.Reason
}

func reminderTitle(note string) string {
	if note == "" {
		return "Reminder"
	}
	return note
}

// actionRow is the agent_actions columns an approval card reads.
type actionRow struct {
	ID                                                int64
	Tool, ArgsJSON, ResultJSON, Reason, Status, Error string
	ContextType, ContextID, CreatedAt                 string
}

func actionRowOfOpen(o db.OpenApproval) actionRow {
	return actionRow{ID: o.ID, Tool: o.Tool, ArgsJSON: o.ArgsJSON, ResultJSON: o.ResultJSON, Reason: o.Reason,
		Status: o.Status, Error: o.Error, ContextType: o.ContextType, ContextID: o.ContextID, CreatedAt: o.CreatedAt}
}

func actionRowOf(a db.AgentAction) actionRow {
	return actionRow{ID: a.ID, Tool: a.Tool, ArgsJSON: a.ArgsJSON, ResultJSON: a.ResultJSON, Reason: a.Reason,
		Status: a.Status, Error: a.Error, ContextType: a.ContextType, ContextID: a.ContextID, CreatedAt: a.CreatedAt}
}

// actionCard is a proposal's native card (a<id>): the folder row's title,
// the proposer's line (the "⚙ <automation> · run #<n>" label, else
// "Assistant proposal"), its args' SHA-256 as the content hash every
// approval write pins.
func (s *snapshot) actionCard(a actionRow, folder int64) api.Card {
	title := a.Reason
	if title == "" {
		title = a.Tool
	}
	ap := s.approvalOf(a)
	source := ap.Proposer
	if source == "" {
		source = defaultProposalLine
	}
	return api.Card{
		ID: ActionCardID(a.ID), FolderID: folder, CardKind: api.CardApprovalNative,
		Title: title, SourceLine: source, Stamp: formatStamp(parseStamp(a.CreatedAt)), Unread: true,
		Priority: "medium", ContentHash: ap.ArgsSHA256, Actions: []api.CardAction{}, RefFacts: []api.RefFacts{},
		Approval: ap,
	}
}

// approvalOf is a proposal's approval block: the native card's text
// (ApprovalTextOf), its state and where it came from.
func (s *snapshot) approvalOf(a actionRow) *api.Approval {
	t := ApprovalTextOf(a.Tool, a.ArgsJSON, a.ResultJSON, a.Status, func(id int64) string { return s.workbenches[id] })
	return &api.Approval{
		Tool: a.Tool, Title: t.Title, Summary: strings.Join(t.Summary, "\n"),
		ArgsSHA256: tools.ArgsSHA256(a.ArgsJSON), Status: a.Status, Error: a.Error,
		Proposer: s.proposer(a), Reason: a.Reason, EditOnMac: t.EditOnMac && a.Status == "pending",
	}
}

// proposer is the label above a proposal an automation run made
// (ActionStripViewModel.labels): "⚙ <automation> · run #<n>", or
// "⚙ automation · run #<n>" once the run is gone; "" for any other row.
func (s *snapshot) proposer(a actionRow) string {
	if a.ContextType != automationRunCtx {
		return ""
	}
	run, ok := parseRunID(a.ContextID)
	if !ok {
		return ""
	}
	if label, ok := s.runLabels[run]; ok {
		return label
	}
	return fmt.Sprintf("⚙ automation · run #%d", run)
}

// reminderCard is a due reminder's native card (r<id>): its note, the
// "Reminder" source (the time is the due time, the card's stamp) and its
// Slack message as the reminder ref's link.
func (s *snapshot) reminderCard(o db.OpenApproval, folder int64) api.Card {
	return api.Card{
		ID: ReminderCardID(o.ID), FolderID: folder, CardKind: api.CardReminder,
		Title: reminderTitle(o.Note), SourceLine: "Reminder", Stamp: formatStamp(parseStamp(o.RemindAt)),
		Unread: true, Priority: "medium", Actions: []api.CardAction{},
		RefFacts: []api.RefFacts{{Kind: api.RefReminder, ID: o.ID, Open: true, Waits: true,
			Link: slackMessageURL(o.MessageRef)}},
	}
}

// slackMessageURL is SlackMessageRef.url: "<channel>@<ts>" as the message's
// archive link; "" for anything else.
func slackMessageURL(ref string) string {
	at := strings.LastIndex(ref, "@")
	if at < 0 {
		return ""
	}
	channel, ts := slack.RawID(ref[:at]), ref[at+1:]
	if ref[:at] == "" || ts == "" || channel == "" {
		return ""
	}
	return "https://slack.com/archives/" + channel + "/p" + strings.ReplaceAll(ts, ".", "")
}

// readApprovalExtras reads what the approval cards name: the run labels of
// the proposals automation runs made and the workbench names.
func readApprovalExtras(ctx context.Context, tx *sql.Tx, s *snapshot) error {
	s.runLabels = map[int64]string{}
	err := eachRow(ctx, tx, `SELECT r.id, COALESCE(NULLIF(a.name, ''), a.slug)
		FROM automation_runs r JOIN automations a ON a.id = r.automation_id
		WHERE r.id IN (SELECT CAST(context_id AS INTEGER) FROM agent_actions
			WHERE context_type = 'automation_run' AND status IN ('pending','failed','approved','executing'))`,
		nil, func(rows *sql.Rows) error {
			var id int64
			var name string
			if err := rows.Scan(&id, &name); err != nil {
				return err
			}
			s.runLabels[id] = fmt.Sprintf("⚙ %s · run #%d", name, id)
			return nil
		})
	if err != nil {
		return fmt.Errorf("inboxfeed: reading the run labels: %w", err)
	}
	s.workbenches = map[int64]string{}
	err = eachRow(ctx, tx, `SELECT id, name FROM projects`, nil, func(rows *sql.Rows) error {
		var id int64
		var name string
		if err := rows.Scan(&id, &name); err != nil {
			return err
		}
		s.workbenches[id] = name
		return nil
	})
	if err != nil {
		return fmt.Errorf("inboxfeed: reading the workbench names: %w", err)
	}
	return nil
}

// eachRow runs query and calls scan on each row.
func eachRow(ctx context.Context, tx *sql.Tx, query string, args []any, scan func(*sql.Rows) error) error {
	rows, err := tx.QueryContext(ctx, query, args...)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		if err := scan(rows); err != nil {
			return err
		}
	}
	return rows.Err()
}

// parseRunID reads an automation_run context id (ActionStripViewModel.automationRunID).
func parseRunID(s string) (int64, bool) {
	id, err := strconv.ParseInt(s, 10, 64)
	return id, err == nil
}
