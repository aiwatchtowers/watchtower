package inboxfeed

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"net/url"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/automations/blocks"
	"watchtower/internal/db"
	"watchtower/internal/tower/api"
)

// buttonContextType is the context of an Inbox target button's proposal
// (AgentActionQueries.buttonContextType): "<output>:<index>:<hash>".
const buttonContextType = "automation_output"

// targetStuckAfter is how long an approved or executing target proposal
// shows "creating" before it reads as stuck (TargetButtonStateResolver).
const targetStuckAfter = 120 * time.Second

// The Reply buttons' state (InboxReplyState), sent as a CardAction's Detail.
const (
	replyReady             = "ready"
	replySent              = "sent"
	replyNeedsConfirmation = "needs_confirmation"
	replyOff               = "off"
	replyUnreadable        = "unreadable"
	replyRemoved           = "removed"
)

// A target button's state (TargetButtonStateResolver without the Mac's own
// press and apply processes), sent as a CardAction's Detail.
const (
	targetIdle     = "idle"
	targetWaiting  = "waiting"
	targetCreating = "creating"
	targetStuck    = "stuck"
	targetFailed   = "failed"
	targetCreated  = "created"
)

// targetFacts is what the read knows about one target button
// (InboxTargetButtonFacts without the Mac's own process state): the newest
// proposal of its context and whether that proposal's task exists.
type targetFacts struct {
	proposal   *db.AgentAction
	taskExists bool
}

// recipeState is an artifact's automation as its Reply buttons read it.
type recipeState struct {
	parseError, needsConfirmation, runnable, removed bool
}

// replyState is InboxCardAction.replyState: a press already made wins, then
// a removed recipe, then the recipe's state.
func replyState(o output) string {
	switch {
	case o.PressedAction.Valid:
		return replySent
	case o.Recipe.removed:
		return replyRemoved
	case o.Recipe.parseError:
		return replyUnreadable
	case o.Recipe.needsConfirmation:
		return replyNeedsConfirmation
	case o.Recipe.runnable:
		return replyReady
	}
	return replyOff
}

// replyCaption is why the Reply buttons will not send now
// (InboxCardButtons.caption); "" when they will or were sent.
func replyCaption(state string) string {
	switch state {
	case replyNeedsConfirmation:
		return "Needs confirmation"
	case replyOff:
		return "Off"
	case replyUnreadable:
		return "Recipe can't be read"
	case replyRemoved:
		return "Recipe removed"
	}
	return ""
}

// cardActions are an artifact's buttons in press order (blocks.FlattenActions:
// its own actions, then each block action in document order), each with
// the state the Mac draws (InboxCardButtons, InboxCardPress.isDisabled,
// TargetButtonStateResolver):
//   - link: enabled for a web link with a host, mac_only for a screen link
//     (watchtower-nav://, which only the Mac opens), else disabled;
//   - chat and agent: mac_only (the handoff stays on the Mac);
//   - reply: pressed once a press was made (labelled "Sent — run #N" on the
//     pressed one), disabled when the recipe was removed, else enabled; the
//     detail is the Reply state and the note its caption;
//   - target: pressed while its proposal waits, is being created or its
//     task exists; enabled otherwise (idle, stuck and failed offer a press);
//     the detail is the button's state and the note a failure's message.
//
// An action the Mac cannot draw (no label, an unknown kind, a missing
// field) is left out; the others keep their press index.
func (s *snapshot) cardActions(o output, now time.Time) []api.CardAction {
	out := []api.CardAction{}
	var own []json.RawMessage
	if json.Unmarshal([]byte(o.ActionsJSON), &own) != nil {
		own = nil
	}
	var doc *blocks.Document
	if o.BlocksJSON != "" {
		if d, err := blocks.Decode(o.BlocksJSON); err == nil {
			doc = d
		}
	}
	decoded := make([]db.InboxAction, len(own))
	valid := make([]bool, len(own))
	for i, raw := range own {
		var fields map[string]json.RawMessage
		valid[i] = json.Unmarshal(raw, &decoded[i]) == nil && json.Unmarshal(raw, &fields) == nil
		// InboxCardAction.decode drops a reply with no "reply" key.
		if _, ok := fields["reply"]; valid[i] && decoded[i].Kind == "reply" && !ok {
			valid[i] = false
		}
	}
	flat := blocks.FlattenActions(decoded, doc)
	reply := replyState(o)
	for i, a := range flat {
		if i < len(valid) && !valid[i] {
			continue
		}
		c, ok := s.cardAction(o, i, a, reply, now)
		if ok {
			out = append(out, c)
		}
	}
	return out
}

func (s *snapshot) cardAction(o output, index int, a db.InboxAction, reply string, now time.Time) (api.CardAction, bool) {
	if a.Label == "" {
		return api.CardAction{}, false
	}
	c := api.CardAction{Index: index, Kind: a.Kind, Label: a.Label}
	switch a.Kind {
	case "link":
		u, err := url.Parse(a.Open)
		if err != nil || u.Scheme == "" {
			return c, false
		}
		c.State = linkState(u)
	case "chat":
		if a.Chat == "" {
			return c, false
		}
		c.State = api.ActionMacOnly
	case "agent":
		if a.Agent == nil || a.Agent.Task == "" {
			return c, false
		}
		c.State = api.ActionMacOnly
	case "reply":
		c.Detail, c.Note = reply, replyCaption(reply)
		switch reply {
		case replySent:
			c.State = api.ActionPressed
			if o.PressedAction.Valid && o.PressedAction.Int64 == int64(index) {
				c.Label = "Sent"
				if o.PressedRunID.Valid {
					c.Label = "Sent — run #" + strconv.FormatInt(o.PressedRunID.Int64, 10)
				}
			}
		case replyRemoved:
			c.State = api.ActionDisabled
		default:
			c.State = api.ActionEnabled
		}
	case "target":
		if a.Target == nil || a.Target.Title == "" {
			return c, false
		}
		ctxID := fmt.Sprintf("%d:%d:%s", o.ID, index, blocks.ActionHash(a))
		c.Detail, c.Note = targetState(s.targets[ctxID], now)
		if c.Detail == targetCreating {
			c.Until = creatingUntil(s.targets[ctxID].proposal)
		}
		c.State = api.ActionEnabled
		switch c.Detail {
		case targetWaiting, targetCreating, targetCreated:
			c.State = api.ActionPressed
		}
	default:
		return c, false
	}
	return c, true
}

// webLinkSchemes are the URL schemes of a web link (InboxCardLinkPolicy):
// the browser opens them, on the Mac or the phone.
var webLinkSchemes = map[string]bool{"http": true, "https": true}

// navLinkScheme is a Watchtower screen link's scheme (NavLink.scheme):
// only the Mac opens it.
const navLinkScheme = "watchtower-nav"

// linkState is a link button's state (InboxCardLinkPolicy.permits): a web
// link with a host enabled, a screen link the Mac's alone, anything else
// disabled.
func linkState(u *url.URL) api.ActionState {
	scheme := strings.ToLower(u.Scheme)
	switch {
	case webLinkSchemes[scheme] && u.Host != "":
		return api.ActionEnabled
	case scheme == navLinkScheme:
		return api.ActionMacOnly
	}
	return api.ActionDisabled
}

// targetState is TargetButtonStateResolver.state over what the database
// holds: a pending proposal waits; an approved or executing one is being
// created for two minutes after its decision, then stuck; an applied one
// is created while its task exists; a failed one not dismissed failed
// (its error, else "The task was not created."); anything else is idle.
func targetState(f targetFacts, now time.Time) (state, note string) {
	p := f.proposal
	if p == nil {
		return targetIdle, ""
	}
	switch p.Status {
	case "pending":
		return targetWaiting, ""
	case "approved", "executing":
		if decided, err := time.Parse(time.RFC3339Nano, p.DecidedAt); err == nil && now.Sub(decided) < targetStuckAfter {
			return targetCreating, ""
		}
		return targetStuck, ""
	case "applied":
		if f.taskExists {
			return targetCreated, ""
		}
		return targetIdle, ""
	case "failed":
		if p.DismissedAt != "" {
			return targetIdle, ""
		}
		if p.Error == "" {
			return targetFailed, "The task was not created."
		}
		return targetFailed, p.Error
	}
	return targetIdle, ""
}

// creatingUntil is when a creating proposal turns stuck: its decision plus
// targetStuckAfter.
func creatingUntil(p *db.AgentAction) string {
	decided, err := time.Parse(time.RFC3339Nano, p.DecidedAt)
	if err != nil {
		return ""
	}
	return formatStamp(decided.Add(targetStuckAfter))
}

// readTargetFacts reads the newest proposal of every target button of the
// open artifacts and of every button a Needs approval row proposed for
// (AgentActionQueries.newestButtonProposals over the outputs and the
// strip's contexts), and which of those proposals made a task that still
// exists (actionsWithTask).
func readTargetFacts(ctx context.Context, tx *sql.Tx) (map[string]targetFacts, error) {
	out := map[string]targetFacts{}
	var ids []any
	err := eachRow(ctx, tx, `SELECT `+db.AgentActionColumns+` FROM agent_actions
		WHERE context_type = ? AND (CAST(substr(context_id, 1, instr(context_id, ':') - 1) AS INTEGER) IN
			(SELECT id FROM automation_outputs WHERE kind = 'inbox' AND done_at IS NULL AND dismissed_at IS NULL)
			OR context_id IN (SELECT context_id FROM agent_actions WHERE context_type = ?
				AND status IN ('pending','failed','approved','executing')))
		ORDER BY id DESC`, []any{buttonContextType, buttonContextType}, func(rows *sql.Rows) error {
		a, err := db.ScanAgentAction(rows)
		if err != nil {
			return err
		}
		if _, ok := out[a.ContextID]; !ok {
			out[a.ContextID] = targetFacts{proposal: a}
			ids = append(ids, "action:"+strconv.FormatInt(a.ID, 10))
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("inboxfeed: reading the target buttons: %w", err)
	}
	if len(ids) == 0 {
		return out, nil
	}
	tasks := map[int64]bool{}
	err = eachRow(ctx, tx, `SELECT source_id FROM targets WHERE source_type = 'chat' AND source_id IN (`+
		strings.TrimSuffix(strings.Repeat("?,", len(ids)), ",")+`)`, ids, func(rows *sql.Rows) error {
		var source string
		if err := rows.Scan(&source); err != nil {
			return err
		}
		if id, err := strconv.ParseInt(strings.TrimPrefix(source, "action:"), 10, 64); err == nil {
			tasks[id] = true
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("inboxfeed: reading the target buttons' tasks: %w", err)
	}
	for k, f := range out {
		f.taskExists = tasks[f.proposal.ID]
		out[k] = f
	}
	return out, nil
}
