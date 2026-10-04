package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"watchtower/internal/db"
	"watchtower/internal/workbenchfiles"
)

// WorkbenchSurface is the registry surface of `watchtower mcp --workbench N`.
// Every workbench tool is visible there and nowhere else. The value is the
// pre-rename "project": it is persisted as agent_actions.surface (spec
// 2026-10-02 A1).
const WorkbenchSurface = "project"

var workbenchSurfaces = []string{WorkbenchSurface}

// maxBatchTargets caps one create_targets call — a whole plan, not a backlog.
const maxBatchTargets = 100

// WorkbenchTools returns every workbench tool (surface "project"), in the order
// buildToolRegistry registers them. files stores the images attached to
// targets.
func WorkbenchTools(files workbenchfiles.Store) []*Tool {
	return workbenchTools(files, processTerminalSession)
}

// workbenchTools is WorkbenchTools with the terminal session env read through
// sessionEnv — tests inject their own.
func workbenchTools(files workbenchfiles.Store, sessionEnv func() string) []*Tool {
	return []*Tool{
		NewWorkbenchInfo(), NewWorkbenchBoard(), NewUpdateWorkbench(),
		NewAddWorkbenchSource(), NewRemoveWorkbenchSource(),
		NewCreateTargets(files, sessionEnv), NewUpdateTarget(files, sessionEnv),
		NewListComments(), NewAddComment(sessionEnv), NewResolveComment(),
		NewAskOwner(sessionEnv), NewGetAsk(),
		NewListAsks(sessionEnv), NewWithdrawAsk(),
		NewFinishSession(sessionEnv),
	}
}

// targetInWorkbench loads a target and fails unless it belongs to projectID —
// a target of another workbench, of no workbench, or a missing one all read as
// "not in this workbench" (wrapping db.ErrNotInWorkbench), never as a different
// error that would confirm it exists.
func targetInWorkbench(d *db.DB, projectID, targetID int64) (*db.Target, error) {
	notHere := notInWorkbench("target", targetID)
	if projectID <= 0 || targetID <= 0 {
		return nil, notHere
	}
	t, err := d.GetTargetByID(int(targetID))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, notHere
	}
	if err != nil {
		return nil, fmt.Errorf("loading target %d: %w", targetID, err)
	}
	if t.WorkbenchID.Int64 != projectID {
		return nil, notHere
	}
	return t, nil
}

// notInWorkbench is the model-facing refusal for a row outside the bound
// workbench; it wraps db.ErrNotInWorkbench.
func notInWorkbench(noun string, id int64) error {
	return &ValidationError{Msg: fmt.Sprintf("%s %d is not in this workbench", noun, id), Err: db.ErrNotInWorkbench}
}

// workbenchScope is the Scope of a workbench tool that touches no existing row:
// the binding must name a live workbench.
func workbenchScope(ctx context.Context, d *db.DB, _ json.RawMessage, b Binding) error {
	_, err := workbenchOf(ctx, d, b)
	return err
}

// requireText trims s and checks it is non-empty and at most limit runes.
func requireText(field, s string, limit int) (string, error) {
	s = strings.TrimSpace(s)
	switch {
	case s == "":
		return "", &ValidationError{Msg: field + " is required"}
	case len([]rune(s)) > limit:
		return "", &ValidationError{Msg: fmt.Sprintf("%s must be at most %d characters", field, limit)}
	}
	return s, nil
}

type emptyArgs struct{}

// ---- workbench_info ----------------------------------------------------

type sourceView struct {
	ID    int64  `json:"id"`
	Kind  string `json:"kind"`
	Ref   string `json:"ref"`
	Label string `json:"label,omitempty"`
}

type workbenchInfoView struct {
	ID          int64  `json:"id"`
	Name        string `json:"name"`
	Folder      string `json:"folder"`
	Description string `json:"description"`
	// BoardLanguageRule is the sentence the agent follows (BoardLanguageLine).
	BoardLanguageRule string         `json:"board_language_rule"`
	Sources           []sourceView   `json:"sources"`
	Targets           map[string]int `json:"targets_by_status"` // the whole board, archived targets included
	Archived          int            `json:"archived"`          // archived targets (PROJ-15)
	NewComments       int            `json:"comments_new_for_agent"`
}

// NewWorkbenchInfo describes the bound workbench: what it is, its sources and
// how much is on its board.
func NewWorkbenchInfo() *Tool {
	return &Tool{
		Name: WorkbenchInfoTool,
		Description: "Describe this Watchtower workbench: name, folder, description, board language, sources, target counts by " +
			"status (the whole board), how many targets are archived and owner comments waiting for you. An empty description means the " +
			"workbench is not set up yet (run the setup of the Watchtower skill in this folder).",
		InputSchema: mustSchema[emptyArgs](WorkbenchInfoTool),
		Access:      AccessRead,
		Surfaces:    workbenchSurfaces,
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			p, err := workbenchOf(ctx, d, call.Binding)
			if err != nil {
				return nil, err
			}
			return buildWorkbenchInfo(d, p)
		},
	}
}

func buildWorkbenchInfo(d *db.DB, p *db.Workbench) (*workbenchInfoView, error) {
	sources, err := d.ListWorkbenchSources(p.ID)
	if err != nil {
		return nil, fmt.Errorf("listing sources: %w", err)
	}
	board, err := d.GetWorkbenchBoard(p.ID)
	if err != nil {
		return nil, fmt.Errorf("loading board: %w", err)
	}
	fresh, err := d.ListWorkbenchComments(db.WorkbenchCommentFilter{WorkbenchID: p.ID, NewForAgent: true})
	if err != nil {
		return nil, fmt.Errorf("listing comments: %w", err)
	}
	v := &workbenchInfoView{
		ID: p.ID, Name: p.Name, Folder: p.FolderPath, Description: p.Description,
		BoardLanguageRule: BoardLanguageLine, Sources: make([]sourceView, 0, len(sources)),
		Targets: map[string]int{}, Archived: db.CountArchived(board), NewComments: len(fresh),
	}
	for _, s := range sources {
		v.Sources = append(v.Sources, sourceView{ID: s.ID, Kind: s.Kind, Ref: s.Ref, Label: s.Label})
	}
	countStatuses(board, v.Targets)
	return v, nil
}

func countStatuses(nodes []db.BoardNode, into map[string]int) {
	for _, n := range nodes {
		into[n.Target.Status]++
		countStatuses(n.Children, into)
	}
}

// ---- update_workbench --------------------------------------------------

type updateWorkbenchArgs struct {
	Description string `json:"description" jsonschema:"what the workbench is, a few sentences; replaces the current description"`
	Reason      string `json:"reason" jsonschema:"one sentence: why you make this change"`
}

// NewUpdateWorkbench sets the bound workbench's description.
func NewUpdateWorkbench() *Tool {
	return &Tool{
		Name:        UpdateWorkbenchTool,
		Description: "Set this workbench's description (what it is, a few sentences). Applied immediately.",
		InputSchema: mustSchema[updateWorkbenchArgs](UpdateWorkbenchTool),
		Access:      AccessWrite,
		Surfaces:    workbenchSurfaces,
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a updateWorkbenchArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			_, err := requireText("description", a.Description, 4000)
			return err
		},
		Scope: workbenchScope,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a updateWorkbenchArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding update_workbench args: %w", err)
			}
			if err := d.UpdateWorkbenchDescription(call.Binding.WorkbenchID, a.Description); err != nil {
				return nil, fmt.Errorf("updating workbench: %w", err)
			}
			// "project_id" stays: this result is persisted in
			// agent_actions.result_json (spec 2026-10-02 A1).
			return map[string]any{"project_id": call.Binding.WorkbenchID}, nil
		},
	}
}

// BoardLanguageLine is the one line every session reads (workbench brief,
// workbench_info) to know which language the board is written in: always the
// session's (board item #153 retired the per-workbench override; the
// projects.board_language column is no longer read).
const BoardLanguageLine = "Board language: follow the session language (write targets, intents and comments in the language the owner uses with you)."

// ---- add_workbench_source / remove_workbench_source ---------------------

type addWorkbenchSourceArgs struct {
	Kind   string `json:"kind" jsonschema:"slack_channel | jira_project | confluence_space | person | link"`
	Ref    string `json:"ref" jsonschema:"the source reference: channel id or name, Jira project key, space key, person email, URL"`
	Label  string `json:"label,omitempty" jsonschema:"short human label"`
	Reason string `json:"reason" jsonschema:"one sentence: why this source belongs to the workbench"`
}

// NewAddWorkbenchSource records a source (channel, Jira project, space, person,
// link) as belonging to the bound workbench. Idempotent on (kind, ref).
func NewAddWorkbenchSource() *Tool {
	return &Tool{
		Name: AddWorkbenchSourceTool,
		Description: "Record a source that belongs to this workbench (a Slack channel, Jira project, Confluence " +
			"space, person or link). Add only sources the workbench's docs clearly name. Applied immediately.",
		InputSchema: mustSchema[addWorkbenchSourceArgs](AddWorkbenchSourceTool),
		Access:      AccessWrite,
		Surfaces:    workbenchSurfaces,
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a addWorkbenchSourceArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			if a.Kind == "" {
				return &ValidationError{Msg: "kind is required"}
			}
			if err := validateEnum("kind", a.Kind, "slack_channel", "jira_project", "confluence_space", "person", "link"); err != nil {
				return err
			}
			_, err := requireText("ref", a.Ref, 500)
			return err
		},
		Scope: workbenchScope,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a addWorkbenchSourceArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding add_workbench_source args: %w", err)
			}
			id, err := d.AddWorkbenchSource(db.WorkbenchSource{
				WorkbenchID: call.Binding.WorkbenchID, Kind: a.Kind,
				Ref: strings.TrimSpace(a.Ref), Label: strings.TrimSpace(a.Label),
			})
			if err != nil {
				return nil, fmt.Errorf("adding source: %w", err)
			}
			return map[string]any{"source_id": id}, nil
		},
	}
}

type removeWorkbenchSourceArgs struct {
	SourceID int64  `json:"source_id" jsonschema:"the source id from workbench_info"`
	Reason   string `json:"reason" jsonschema:"one sentence: why the source no longer belongs"`
}

// NewRemoveWorkbenchSource drops one of the bound workbench's sources.
func NewRemoveWorkbenchSource() *Tool {
	return &Tool{
		Name:        RemoveWorkbenchSourceTool,
		Description: "Remove a source from this workbench (id from workbench_info). Applied immediately.",
		InputSchema: mustSchema[removeWorkbenchSourceArgs](RemoveWorkbenchSourceTool),
		Access:      AccessWrite,
		Surfaces:    workbenchSurfaces,
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a removeWorkbenchSourceArgs
			return decodeStrict(raw, &a)
		},
		Scope: func(_ context.Context, d *db.DB, raw json.RawMessage, b Binding) error {
			var a removeWorkbenchSourceArgs
			if err := json.Unmarshal(raw, &a); err != nil {
				return &ValidationError{Msg: "invalid arguments"}
			}
			return sourceInWorkbench(d, b.WorkbenchID, a.SourceID)
		},
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a removeWorkbenchSourceArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding remove_workbench_source args: %w", err)
			}
			if err := d.RemoveWorkbenchSource(call.Binding.WorkbenchID, a.SourceID); err != nil {
				return nil, fmt.Errorf("removing source: %w", err)
			}
			return map[string]any{"source_id": a.SourceID, "removed": true}, nil
		},
	}
}

func sourceInWorkbench(d *db.DB, projectID, sourceID int64) error {
	sources, err := d.ListWorkbenchSources(projectID)
	if err != nil {
		return fmt.Errorf("listing sources: %w", err)
	}
	for _, s := range sources {
		if s.ID == sourceID {
			return nil
		}
	}
	return notInWorkbench("source", sourceID)
}
