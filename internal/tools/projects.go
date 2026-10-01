package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"watchtower/internal/db"
	"watchtower/internal/projectfiles"
)

// projectSurface is the registry surface of `watchtower mcp --project N`.
// Every project tool is visible there and nowhere else.
const projectSurface = "project"

var projectSurfaces = []string{projectSurface}

// maxBatchTargets caps one create_targets call — a whole plan, not a backlog.
const maxBatchTargets = 100

// ProjectTools returns every project tool (surface "project"), in the order
// buildToolRegistry registers them. files stores the images attached to
// targets.
func ProjectTools(files projectfiles.Store) []*Tool {
	return []*Tool{
		NewProjectInfo(), NewProjectBoard(), NewUpdateProject(),
		NewAddProjectSource(), NewRemoveProjectSource(),
		NewCreateTargets(files), NewUpdateTarget(files),
		NewAttachDocument(), NewListComments(), NewAddComment(), NewResolveComment(),
	}
}

// targetInProject loads a target and fails unless it belongs to projectID —
// a target of another project, of no project, or a missing one all read as
// "not in this project" (wrapping db.ErrNotInProject), never as a different
// error that would confirm it exists.
func targetInProject(d *db.DB, projectID, targetID int64) (*db.Target, error) {
	notHere := notInProject("target", targetID)
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
	if t.ProjectID.Int64 != projectID {
		return nil, notHere
	}
	return t, nil
}

// notInProject is the model-facing refusal for a row outside the bound
// project; it wraps db.ErrNotInProject.
func notInProject(noun string, id int64) error {
	return &ValidationError{Msg: fmt.Sprintf("%s %d is not in this project", noun, id), Err: db.ErrNotInProject}
}

// projectScope is the Scope of a project tool that touches no existing row:
// the binding must name a live project.
func projectScope(ctx context.Context, d *db.DB, _ json.RawMessage, b Binding) error {
	_, err := projectOf(ctx, d, b)
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

// ---- project_info ------------------------------------------------------

type sourceView struct {
	ID    int64  `json:"id"`
	Kind  string `json:"kind"`
	Ref   string `json:"ref"`
	Label string `json:"label,omitempty"`
}

type projectInfoView struct {
	ID          int64  `json:"id"`
	Name        string `json:"name"`
	Folder      string `json:"folder"`
	Description string `json:"description"`
	// BoardLanguage is the stored value (empty = follow the session);
	// BoardLanguageRule is the sentence the agent follows.
	BoardLanguage     string         `json:"board_language"`
	BoardLanguageRule string         `json:"board_language_rule"`
	Sources           []sourceView   `json:"sources"`
	Targets           map[string]int `json:"targets_by_status"`
	Documents         int            `json:"documents"`
	NewComments       int            `json:"comments_new_for_agent"`
}

// NewProjectInfo describes the bound project: what it is, its sources and
// how much is on its board.
func NewProjectInfo() *Tool {
	return &Tool{
		Name: "project_info",
		Description: "Describe this Watchtower project: name, folder, description, board language, sources, target counts by " +
			"status, attached documents and owner comments waiting for you. An empty description means the " +
			"project is not set up yet (run the watchtower-project skill's setup).",
		InputSchema: mustSchema[emptyArgs]("project_info"),
		Access:      AccessRead,
		Surfaces:    projectSurfaces,
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			p, err := projectOf(ctx, d, call.Binding)
			if err != nil {
				return nil, err
			}
			return buildProjectInfo(d, p)
		},
	}
}

func buildProjectInfo(d *db.DB, p *db.Project) (*projectInfoView, error) {
	sources, err := d.ListProjectSources(p.ID)
	if err != nil {
		return nil, fmt.Errorf("listing sources: %w", err)
	}
	board, err := d.GetProjectBoard(p.ID)
	if err != nil {
		return nil, fmt.Errorf("loading board: %w", err)
	}
	docs, err := d.ListProjectDocuments(p.ID)
	if err != nil {
		return nil, fmt.Errorf("listing documents: %w", err)
	}
	fresh, err := d.ListProjectComments(db.ProjectCommentFilter{ProjectID: p.ID, NewForAgent: true})
	if err != nil {
		return nil, fmt.Errorf("listing comments: %w", err)
	}
	v := &projectInfoView{
		ID: p.ID, Name: p.Name, Folder: p.FolderPath, Description: p.Description,
		BoardLanguage: p.BoardLanguage, BoardLanguageRule: BoardLanguageLine(p.BoardLanguage),
		Sources: make([]sourceView, 0, len(sources)), Targets: map[string]int{},
		Documents: len(docs), NewComments: len(fresh),
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

// ---- project_board -----------------------------------------------------

type documentView struct {
	ID       int64  `json:"id"`
	RelPath  string `json:"rel_path"`
	Kind     string `json:"kind"`
	Title    string `json:"title,omitempty"`
	TargetID int64  `json:"target_id,omitempty"`
	Updated  string `json:"updated_at"`
	Origin   string `json:"origin"` // agent | import (found by the setup scan) | owner
}

type boardNodeView struct {
	ID             int             `json:"id"`
	Text           string          `json:"text"`
	Intent         string          `json:"intent,omitempty"`
	Status         string          `json:"status"`
	Priority       string          `json:"priority"`
	Progress       float64         `json:"progress"`
	StatusSince    string          `json:"status_since,omitempty"` // when it entered its current status (UTC)
	NewForAgent    int             `json:"comments_new_for_agent,omitempty"`
	UnreadForOwner int             `json:"comments_unread_for_owner,omitempty"`
	Documents      []documentView  `json:"documents,omitempty"`
	Children       []boardNodeView `json:"children,omitempty"`
}

type projectBoardView struct {
	ProjectID int64           `json:"project_id"`
	Targets   []boardNodeView `json:"targets"`
	Documents []documentView  `json:"documents"`
}

// NewProjectBoard returns the bound project's target tree with comment
// counters, plus every attached document.
func NewProjectBoard() *Tool {
	return &Tool{
		Name: "project_board",
		Description: "The project board: the target tree (ids, status and since when, priority, progress, comment counters, " +
			"linked documents; siblings sorted by priority, then status) and every attached document. " +
			"Read it before changing the board.",
		InputSchema: mustSchema[emptyArgs]("project_board"),
		Access:      AccessRead,
		Surfaces:    projectSurfaces,
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			p, err := projectOf(ctx, d, call.Binding)
			if err != nil {
				return nil, err
			}
			board, err := d.GetProjectBoard(p.ID)
			if err != nil {
				return nil, fmt.Errorf("loading board: %w", err)
			}
			docs, err := d.ListProjectDocuments(p.ID)
			if err != nil {
				return nil, fmt.Errorf("listing documents: %w", err)
			}
			return projectBoardView{ProjectID: p.ID, Targets: boardViews(board), Documents: documentViews(docs)}, nil
		},
	}
}

func boardViews(nodes []db.BoardNode) []boardNodeView {
	out := make([]boardNodeView, 0, len(nodes))
	for _, n := range nodes {
		out = append(out, boardNodeView{
			ID: n.Target.ID, Text: n.Target.Text, Intent: n.Target.Intent,
			Status: n.Target.Status, Priority: n.Target.Priority, Progress: n.Target.Progress,
			StatusSince: n.StatusSince, NewForAgent: n.NewForAgent, UnreadForOwner: n.UnreadForOwner,
			Documents: documentViews(n.Documents), Children: boardViews(n.Children),
		})
	}
	return out
}

func documentViews(docs []db.ProjectDocument) []documentView {
	out := make([]documentView, 0, len(docs))
	for _, doc := range docs {
		out = append(out, documentView{
			ID: doc.ID, RelPath: doc.RelPath, Kind: doc.Kind, Title: doc.Title,
			TargetID: doc.TargetID.Int64, Updated: doc.UpdatedAt, Origin: doc.Origin,
		})
	}
	return out
}

// ---- update_project ----------------------------------------------------

type updateProjectArgs struct {
	Description   *string `json:"description,omitempty" jsonschema:"what the project is, a few sentences; replaces the current description"`
	BoardLanguage *string `json:"board_language,omitempty" jsonschema:"the language the board is written in, a name or tag such as Russian or pt-BR; empty follows the session language. Set it only when the owner asks"`
	Reason        string  `json:"reason" jsonschema:"one sentence: why you make this change"`
}

// NewUpdateProject sets the bound project's description and/or board language.
func NewUpdateProject() *Tool {
	return &Tool{
		Name: "update_project",
		Description: "Set this project's description (what it is, a few sentences) and/or its board language " +
			"(the language targets, intents and comments are written in; empty = follow the session language). " +
			"Applied immediately.",
		InputSchema: mustSchema[updateProjectArgs]("update_project"),
		Access:      AccessWrite,
		Surfaces:    projectSurfaces,
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a updateProjectArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			if a.Description == nil && a.BoardLanguage == nil {
				return &ValidationError{Msg: "give description, board_language or both"}
			}
			if a.Description != nil {
				if _, err := requireText("description", *a.Description, 4000); err != nil {
					return err
				}
			}
			if a.BoardLanguage != nil {
				if _, err := db.NormalizeBoardLanguage(*a.BoardLanguage); err != nil {
					return &ValidationError{Msg: err.Error(), Err: err}
				}
			}
			return nil
		},
		Scope: projectScope,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a updateProjectArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding update_project args: %w", err)
			}
			if err := d.UpdateProject(call.Binding.ProjectID, db.ProjectUpdate{
				Description: a.Description, BoardLanguage: a.BoardLanguage,
			}); err != nil {
				return nil, fmt.Errorf("updating project: %w", err)
			}
			out := map[string]any{"project_id": call.Binding.ProjectID}
			if a.BoardLanguage != nil {
				p, err := d.GetProject(call.Binding.ProjectID)
				if err != nil {
					return nil, fmt.Errorf("reading the project back: %w", err)
				}
				out["board_language"] = p.BoardLanguage
				out["board_language_rule"] = BoardLanguageLine(p.BoardLanguage)
			}
			return out, nil
		},
	}
}

// BoardLanguageLine is the one line every session reads (project brief,
// project_info) to know which language the board is written in.
func BoardLanguageLine(lang string) string {
	if lang == "" {
		return "Board language: follow the session language (write targets, intents and comments in the language the owner uses with you)."
	}
	return "Board language: " + lang + " (write targets, intents and comments in " + lang + ", whatever language the session uses)."
}

// ---- add_project_source / remove_project_source -------------------------

type addProjectSourceArgs struct {
	Kind   string `json:"kind" jsonschema:"slack_channel | jira_project | confluence_space | person | link"`
	Ref    string `json:"ref" jsonschema:"the source reference: channel id or name, Jira project key, space key, person email, URL"`
	Label  string `json:"label,omitempty" jsonschema:"short human label"`
	Reason string `json:"reason" jsonschema:"one sentence: why this source belongs to the project"`
}

// NewAddProjectSource records a source (channel, Jira project, space, person,
// link) as belonging to the bound project. Idempotent on (kind, ref).
func NewAddProjectSource() *Tool {
	return &Tool{
		Name: "add_project_source",
		Description: "Record a source that belongs to this project (a Slack channel, Jira project, Confluence " +
			"space, person or link). Add only sources the project's docs clearly name. Applied immediately.",
		InputSchema: mustSchema[addProjectSourceArgs]("add_project_source"),
		Access:      AccessWrite,
		Surfaces:    projectSurfaces,
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a addProjectSourceArgs
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
		Scope: projectScope,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a addProjectSourceArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding add_project_source args: %w", err)
			}
			id, err := d.AddProjectSource(db.ProjectSource{
				ProjectID: call.Binding.ProjectID, Kind: a.Kind,
				Ref: strings.TrimSpace(a.Ref), Label: strings.TrimSpace(a.Label),
			})
			if err != nil {
				return nil, fmt.Errorf("adding source: %w", err)
			}
			return map[string]any{"source_id": id}, nil
		},
	}
}

type removeProjectSourceArgs struct {
	SourceID int64  `json:"source_id" jsonschema:"the source id from project_info"`
	Reason   string `json:"reason" jsonschema:"one sentence: why the source no longer belongs"`
}

// NewRemoveProjectSource drops one of the bound project's sources.
func NewRemoveProjectSource() *Tool {
	return &Tool{
		Name:        "remove_project_source",
		Description: "Remove a source from this project (id from project_info). Applied immediately.",
		InputSchema: mustSchema[removeProjectSourceArgs]("remove_project_source"),
		Access:      AccessWrite,
		Surfaces:    projectSurfaces,
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a removeProjectSourceArgs
			return decodeStrict(raw, &a)
		},
		Scope: func(_ context.Context, d *db.DB, raw json.RawMessage, b Binding) error {
			var a removeProjectSourceArgs
			if err := json.Unmarshal(raw, &a); err != nil {
				return &ValidationError{Msg: "invalid arguments"}
			}
			return sourceInProject(d, b.ProjectID, a.SourceID)
		},
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a removeProjectSourceArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding remove_project_source args: %w", err)
			}
			if err := d.RemoveProjectSource(call.Binding.ProjectID, a.SourceID); err != nil {
				return nil, fmt.Errorf("removing source: %w", err)
			}
			return map[string]any{"source_id": a.SourceID, "removed": true}, nil
		},
	}
}

func sourceInProject(d *db.DB, projectID, sourceID int64) error {
	sources, err := d.ListProjectSources(projectID)
	if err != nil {
		return fmt.Errorf("listing sources: %w", err)
	}
	for _, s := range sources {
		if s.ID == sourceID {
			return nil
		}
	}
	return notInProject("source", sourceID)
}
