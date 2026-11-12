package tuning

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strconv"

	"github.com/google/jsonschema-go/jsonschema"

	"watchtower/internal/agentkind"
	"watchtower/internal/db"
	"watchtower/internal/prompts"
	"watchtower/internal/tools"
)

// maxReportDays caps the period of an agent report read (spec §4.2).
const maxReportDays = 90

// ErrNotFound is what a Deps reader wraps when the thing it was asked for
// (an agent session) does not exist; the tool turns it into a "not found"
// tool error.
var ErrNotFound = errors.New("not found")

// ReadTools are the tuning chat's analytics, usage, prompt, skill,
// instruction and proposal reads. Every one returns the owner's content, so
// every one is CompanyData and counts against the read budget (READ-01);
// none writes anything.
func ReadTools(deps Deps) []*tools.Tool {
	return append([]*tools.Tool{
		readTool[reportArgs]("get_agent_report",
			"Read the agent analytics report of one workbench (agents report JSON): totals, time split, models, "+
				"commands, context, skills, trouble, tasks, hints and the session list. days 0 = the whole retention, "+
				"at most 90; agent claude or codex narrows it to one agent.",
			func(ctx context.Context, d *db.DB, b tools.Binding, a reportArgs) (any, error) {
				wb, err := reportScope(d, b, &a)
				if err != nil {
					return nil, err
				}
				return deps.AgentReport(ctx, wb, a.Days, a.Agent)
			}),
		readTool[reportArgs]("list_agent_sessions",
			"List one workbench's agent sessions in a period with their cost, time and trouble (the session list of "+
				"get_agent_report). Open one with get_agent_session.",
			func(ctx context.Context, d *db.DB, b tools.Binding, a reportArgs) (any, error) {
				wb, err := reportScope(d, b, &a)
				if err != nil {
					return nil, err
				}
				rep, err := deps.AgentReport(ctx, wb, a.Days, a.Agent)
				if err != nil {
					return nil, err
				}
				return sessionsOf(rep)
			}),
		readTool[sessionArgs]("get_agent_session",
			"Read one agent session's report: time split, subagents, lanes, commands, context, skills and hints.",
			func(ctx context.Context, d *db.DB, b tools.Binding, a sessionArgs) (any, error) {
				wb, err := workbenchOf(d, b, a.WorkbenchID)
				if err != nil {
					return nil, err
				}
				if a.Session == "" {
					return nil, &tools.ValidationError{Msg: "session is required"}
				}
				res, err := deps.AgentSession(ctx, wb, a.Session)
				if errors.Is(err, ErrNotFound) {
					return nil, &tools.ValidationError{Msg: "session " + a.Session + " not found"}
				}
				return res, err
			}),
		readTool[usageArgs]("get_llm_usage",
			"Read what Watchtower spent on AI in a period (usage llm JSON): sections and per-purpose rows.",
			func(ctx context.Context, _ *db.DB, _ tools.Binding, a usageArgs) (any, error) {
				if !slices.Contains([]string{"today", "7d", "30d"}, a.Period) {
					return nil, &tools.ValidationError{Msg: fmt.Sprintf("invalid period %q: must be one of today|7d|30d", a.Period)}
				}
				return deps.LLMUsage(ctx, a.Period)
			}),
		readTool[struct{}]("list_prompts",
			"List Watchtower's prompts: id, description, whether owner additions reach it, version, additions and "+
				"the spend of its purpose over the last 30 days. Open one with get_prompt.",
			func(ctx context.Context, d *db.DB, _ tools.Binding, _ struct{}) (any, error) {
				return listPrompts(ctx, d, deps)
			}),
		readTool[promptArgs]("get_prompt",
			"Read one Watchtower prompt: its template without the additions, its additions and its version history.",
			func(_ context.Context, d *db.DB, _ tools.Binding, a promptArgs) (any, error) {
				return getPrompt(d, deps, a.PromptID)
			}),
	}, skillTools(deps)...)
}

type reportArgs struct {
	WorkbenchID int64  `json:"workbench_id,omitempty" jsonschema:"the workbench; omit for the panel's workbench"`
	Days        int    `json:"days" jsonschema:"the period in days back from now; 0 = the whole retention, at most 90"`
	Agent       string `json:"agent,omitempty" jsonschema:"claude or codex; omit for both agents"`
}

type sessionArgs struct {
	WorkbenchID int64  `json:"workbench_id,omitempty" jsonschema:"the workbench; omit for the panel's workbench"`
	Session     string `json:"session" jsonschema:"the session's uuid, from list_agent_sessions"`
}

type usageArgs struct {
	Period string `json:"period" jsonschema:"today, 7d or 30d"`
}

type promptArgs struct {
	PromptID string `json:"prompt_id" jsonschema:"the prompt's id, from list_prompts"`
}

// readTool builds one tuning read tool over typed arguments.
func readTool[A any](name, desc string, run func(context.Context, *db.DB, tools.Binding, A) (any, error)) *tools.Tool {
	schema, err := jsonschema.For[A](nil)
	if err != nil {
		panic(name + " schema: " + err.Error())
	}
	return &tools.Tool{
		Name:        name,
		Description: desc,
		InputSchema: schema,
		Access:      tools.AccessRead,
		CompanyData: true,
		Surfaces:    []string{tools.SurfaceTuning},
		Execute: func(ctx context.Context, d *db.DB, call tools.Call) (any, error) {
			var a A
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &tools.ValidationError{Msg: "invalid arguments: " + err.Error()}
			}
			return run(ctx, d, call.Binding, a)
		},
	}
}

// reportScope checks a report read's arguments and returns its workbench;
// days past 90 are clamped in a.
func reportScope(d *db.DB, b tools.Binding, a *reportArgs) (int64, error) {
	switch {
	case a.Days < 0:
		return 0, &tools.ValidationError{Msg: "days must not be negative"}
	case a.Agent != "" && !agentkind.IsAgent(a.Agent):
		return 0, &tools.ValidationError{Msg: fmt.Sprintf("invalid agent %q: must be claude or codex", a.Agent)}
	}
	a.Days = min(a.Days, maxReportDays)
	return workbenchOf(d, b, a.WorkbenchID)
}

// workbenchOf is the named workbench, else the tuning panel's (the binding's
// context id), checked to exist.
func workbenchOf(d *db.DB, b tools.Binding, id int64) (int64, error) {
	if id == 0 && b.ContextType == ContextType {
		ctxID, err := strconv.ParseInt(b.ContextID, 10, 64)
		if err != nil {
			return 0, &tools.ValidationError{Msg: fmt.Sprintf("the chat's workbench %q is not a workbench id; pass workbench_id", b.ContextID), Err: err}
		}
		id = ctxID
	}
	if id <= 0 {
		return 0, &tools.ValidationError{Msg: "workbench_id is required"}
	}
	if _, err := d.GetWorkbench(id); err != nil {
		if errors.Is(err, db.ErrWorkbenchNotFound) {
			return 0, &tools.ValidationError{Msg: fmt.Sprintf("workbench %d not found", id)}
		}
		return 0, err
	}
	return id, nil
}

// sessionsOf keeps the period, the agent filter, the session list and the
// analytics state of an agents report (enabled, import: an empty list while
// analytics is off or the first import runs is not an all-clear).
func sessionsOf(rep any) (any, error) {
	raw, err := json.Marshal(rep)
	if err != nil {
		return nil, fmt.Errorf("encoding the agent report: %w", err)
	}
	var all map[string]json.RawMessage
	if err := json.Unmarshal(raw, &all); err != nil {
		return nil, fmt.Errorf("reading the agent report: %w", err)
	}
	out := map[string]json.RawMessage{}
	for _, k := range []string{"workbench_id", "since", "until", "agent", "agents", "sessions", "old_format_sessions", "enabled", "import"} {
		if v, ok := all[k]; ok {
			out[k] = v
		}
	}
	return out, nil
}

type promptRow struct {
	ID             string   `json:"id"`
	Description    string   `json:"description"`
	TakesAdditions bool     `json:"takes_additions"`
	Version        int      `json:"version"`
	Additions      []string `json:"additions"`
	Spend30dUSD    float64  `json:"spend_30d_usd"`
}

// listPrompts is list_prompts. The spend reads llm_calls only: calls still
// in the spool file (imported once per daemon cycle) are not counted yet.
func listPrompts(ctx context.Context, d *db.DB, deps Deps) ([]promptRow, error) {
	usage, err := d.ReadLLMUsage(ctx, deps.Now().AddDate(0, 0, -30), nil)
	if err != nil {
		return nil, err
	}
	spend := map[string]float64{}
	for _, g := range usage.Groups {
		spend[g.Purpose] += g.CostUSD
	}
	store := deps.Store(d)
	out := make([]promptRow, 0, len(prompts.AllIDs))
	for _, id := range prompts.AllIDs {
		_, version, err := templateOf(store, id)
		if err != nil {
			return nil, err
		}
		adds, err := additionsOf(d, id)
		if err != nil {
			return nil, err
		}
		out = append(out, promptRow{
			ID: id, Description: prompts.Descriptions[id], TakesAdditions: prompts.TakesAdditions(id),
			Version: version, Additions: adds, Spend30dUSD: spend[id],
		})
	}
	return out, nil
}

type promptVersion struct {
	Version   int    `json:"version"`
	Reason    string `json:"reason"`
	CreatedAt string `json:"created_at"`
	Template  string `json:"template"`
}

type promptDetail struct {
	ID          string          `json:"id"`
	Description string          `json:"description"`
	Version     int             `json:"version"`
	Template    string          `json:"template"`
	Additions   []string        `json:"additions"`
	History     []promptVersion `json:"history"`
}

func getPrompt(d *db.DB, deps Deps, id string) (*promptDetail, error) {
	if _, ok := prompts.Defaults[id]; !ok {
		return nil, &tools.ValidationError{Msg: "prompt " + id + " not found"}
	}
	store := deps.Store(d)
	tmpl, version, err := templateOf(store, id)
	if err != nil {
		return nil, err
	}
	adds, err := additionsOf(d, id)
	if err != nil {
		return nil, err
	}
	hist, err := store.History(id)
	if err != nil {
		return nil, err
	}
	out := &promptDetail{
		ID: id, Description: prompts.Descriptions[id], Version: version, Template: tmpl,
		Additions: adds, History: make([]promptVersion, 0, len(hist)),
	}
	for _, h := range hist {
		out.History = append(out.History, promptVersion{Version: h.Version, Reason: h.Reason, CreatedAt: h.CreatedAt, Template: h.Template})
	}
	return out, nil
}

// templateOf is the base template of a prompt as prompts.Resolve loads it
// without a role and without the additions: the stored row, or the built-in
// default at version 0 when the row is missing or empty. Role variants are
// not shown.
func templateOf(store *prompts.Store, id string) (string, int, error) {
	tmpl, version, err := store.Get(id)
	if err != nil {
		return "", 0, err
	}
	if tmpl == "" {
		return prompts.Defaults[id], 0, nil
	}
	return tmpl, version, nil
}

// additionsOf is the texts of a prompt's stored additions, oldest first; a
// prompt that takes none has none.
func additionsOf(d *db.DB, id string) ([]string, error) {
	out := []string{}
	if !prompts.TakesAdditions(id) {
		return out, nil
	}
	rows, err := d.ListPromptAdditions(id)
	if err != nil {
		return nil, err
	}
	for _, r := range rows {
		out = append(out, r.Text)
	}
	return out, nil
}
