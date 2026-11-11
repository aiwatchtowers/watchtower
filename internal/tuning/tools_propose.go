package tuning

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/google/jsonschema-go/jsonschema"

	"watchtower/internal/coach"
	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// proposeToolName is the tuning surface's only write tool.
const proposeToolName = "propose_tuning_edit"

// ProposalTools is propose_tuning_edit (spec §4.2): it files one coach
// proposal for the owner to Accept on its card and never writes a
// destination. It is a local write (not External, not AlwaysAsk), so the
// tuning binding's DirectApply applies it inline: the call lands as an
// applied agent_actions row whose result is the proposal id and status only.
// Every refusal of the coach is a *tools.ValidationError raised before the
// row is written, so a refused call leaves no agent_actions row.
func ProposalTools(deps Deps) []*tools.Tool {
	schema, err := jsonschema.For[proposeArgs](nil)
	if err != nil {
		panic(proposeToolName + " schema: " + err.Error())
	}
	return []*tools.Tool{{
		Name: proposeToolName,
		Description: "Propose one edit of the owner's LLM setup — a prompt addition, a skill, an instruction file, " +
			"an allow rule, a pack overlay or a workbench repository file. It files a proposal card the owner " +
			"accepts or declines; nothing changes until then. find must match whole lines exactly once; " +
			"replace swaps them, after inserts lines after them (or appends when find is empty). Read the " +
			"destination's text and list_coach_proposals first; a refusal says what to fix.",
		InputSchema: schema,
		Access:      tools.AccessWrite,
		Surfaces:    []string{tools.SurfaceTuning},
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			_, err := decodePropose(raw)
			return err
		},
		Normalize: withReason,
		// Scope runs at Propose (a refusal writes no agent_actions row) and
		// again at Apply; Execute validates once more for the proposal it
		// files. Each run re-reads the destination: cheap next to a turn.
		Scope: func(ctx context.Context, d *db.DB, raw json.RawMessage, b tools.Binding) error {
			_, err := validateProposal(ctx, d, deps, raw, b)
			return err
		},
		Execute: func(ctx context.Context, d *db.DB, call tools.Call) (any, error) {
			p, err := validateProposal(ctx, d, deps, call.Args, call.Binding)
			if err != nil {
				return nil, err
			}
			id, err := fileProposal(d, p, call.Binding.ConversationID, deps.Now())
			if err != nil {
				return nil, err
			}
			return map[string]any{"proposal_id": id, "status": "open"}, nil
		},
	}}
}

type proposeArgs struct {
	Destination string   `json:"destination" jsonschema:"where the edit goes: prompt_addition, chat, session, procedure, claude_md_user, claude_settings_allow, claude_skill_user, codex_skill_user, codex_agents_md_user, codex_rules_allow, pack_overlay, repo_claude_md, repo_agents_md, repo_claude_skill, repo_codex_skill or repo_workflow"`
	WorkbenchID int64    `json:"workbench_id,omitempty" jsonschema:"the workbench of a per-workbench destination; a repo_* destination defaults to the panel's workbench"`
	PromptID    string   `json:"prompt_id,omitempty" jsonschema:"the prompt of a prompt_addition, from list_prompts"`
	Skill       string   `json:"skill,omitempty" jsonschema:"the skill of a skill or pack_overlay destination, from list_skills"`
	Kind        string   `json:"kind" jsonschema:"add, cut or replace"`
	Find        string   `json:"find,omitempty" jsonschema:"whole lines of the current text, matching exactly once; empty = append"`
	Replace     string   `json:"replace,omitempty" jsonschema:"the text that takes find's place (or is appended when find is empty)"`
	After       string   `json:"after,omitempty" jsonschema:"lines to insert after find (or append when find is empty); use replace or after, not both"`
	Title       string   `json:"title" jsonschema:"one line naming the change, shown on the card"`
	Why         string   `json:"why" jsonschema:"why the owner's setup needs it, shown on the card"`
	Metric      string   `json:"metric" jsonschema:"what the coach measures after Accept: corrections, task_cost, owner_loop or review_findings"`
	Refs        []string `json:"refs,omitempty" jsonschema:"evidence you cite: session refs s<id>, chat refs c<id>, ask:<id>, round:<id>, hint:<id>@wb<id>; this chat is cited already"`
}

// decodePropose reads the arguments and refuses the pair the coach cannot
// see (replace with after).
func decodePropose(raw json.RawMessage) (proposeArgs, error) {
	var a proposeArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return a, &tools.ValidationError{Msg: "invalid arguments: " + err.Error()}
	}
	if a.After != "" && a.Replace != "" {
		return a, &tools.ValidationError{Msg: "use replace or after, not both"}
	}
	return a, nil
}

// withReason stores the proposal's why as the agent_actions reason the
// registry requires of every write: the tool has no separate reason argument.
// An empty why is stored as the tool's name, so the coach's own refusal
// ("title and why are required") answers rather than the registry's.
func withReason(_ context.Context, _ *db.DB, raw json.RawMessage) (json.RawMessage, error) {
	a, err := decodePropose(raw)
	if err != nil {
		return nil, err
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, &tools.ValidationError{Msg: "invalid arguments: " + err.Error()}
	}
	reason := strings.TrimSpace(a.Why)
	if reason == "" {
		reason = proposeToolName
	}
	why, err := json.Marshal(reason)
	if err != nil {
		return nil, err
	}
	m["reason"] = why
	return json.Marshal(m)
}

// validateProposal builds the coach edit of one call and checks it with
// coach.ValidateChatProposal against the destination's current text. A
// coach refusal, a removed conversation and a missing workbench, prompt or
// skill are *tools.ValidationError with the plain reason (it may quote the
// model's own arguments: it goes back to the chat only, never to a log).
func validateProposal(ctx context.Context, d *db.DB, deps Deps, raw json.RawMessage, b tools.Binding) (db.CoachProposal, error) {
	a, err := decodePropose(raw)
	if err != nil {
		return db.CoachProposal{}, err
	}
	if b.ConversationID <= 0 {
		return db.CoachProposal{}, &tools.ValidationError{Msg: "the tuning chat has no conversation"}
	}
	c, err := d.GetChatConversation(b.ConversationID)
	if err != nil {
		return db.CoachProposal{}, err
	}
	if c == nil {
		return db.CoachProposal{}, &tools.ValidationError{Msg: "conversation removed"}
	}
	if c.ContextType != ContextType || c.ContextID != b.ContextID {
		return db.CoachProposal{}, &tools.ValidationError{Msg: "this conversation is not the tuning chat's"}
	}
	env, err := deps.coachEnv()
	if err != nil {
		return db.CoachProposal{}, err
	}
	e := chatEditOf(a, b.ConversationID)
	if e.WorkbenchID == 0 && coach.IsRepoDestination(e.Destination) {
		// A repository file defaults to the panel's workbench.
		if e.WorkbenchID, err = workbenchOf(d, b, 0); err != nil {
			return db.CoachProposal{}, err
		}
	}
	p, err := coach.ValidateChatProposal(ctx, d, e, env)
	if errors.Is(err, coach.ErrRefused) {
		return db.CoachProposal{}, &tools.ValidationError{Msg: err.Error(), Err: err}
	}
	return p, err
}

// chatEditOf maps the tool's arguments onto coach.ChatEdit: after becomes a
// Replace that keeps find and adds the lines after it; the evidence starts
// with this conversation, then the refs the chat cites.
func chatEditOf(a proposeArgs, conv int64) coach.ChatEdit {
	e := coach.ChatEdit{Destination: a.Destination, WorkbenchID: a.WorkbenchID, PromptID: a.PromptID,
		Skill: a.Skill, Kind: a.Kind, Find: a.Find, Replace: a.Replace, Title: a.Title, Why: a.Why,
		Metric: a.Metric}
	if a.After != "" {
		e.Replace = insertAfter(a.Find, a.After)
	}
	e.Evidence = append([]string{"c" + strconv.FormatInt(conv, 10)}, a.Refs...)
	return e
}

// insertAfter is the replacement that keeps find's lines and puts after's
// lines right below them; with find empty it is after (an append).
func insertAfter(find, after string) string {
	after = strings.TrimRight(after, "\n")
	switch {
	case find == "":
		return after
	case strings.HasSuffix(find, "\n"):
		return find + after + "\n"
	default:
		return find + "\n" + after
	}
}

// fileProposal inserts p as the open chat proposal of conversation conv. A
// fingerprint another call filed between validation and this insert is
// "already proposed as #N", never a success.
func fileProposal(d *db.DB, p db.CoachProposal, conv int64, now time.Time) (int64, error) {
	id, err := d.InsertChatCoachProposal(p, &conv, now)
	switch {
	case err != nil:
		return 0, err
	case id != 0:
		return id, nil
	}
	prev, err := d.CoachProposalByFingerprint(p.Fingerprint)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return 0, errors.New("already proposed")
	case err != nil:
		return 0, err
	}
	return 0, fmt.Errorf("already proposed as #%d", prev.ID)
}
