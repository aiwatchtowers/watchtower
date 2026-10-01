package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"watchtower/internal/db"
)

// projectAgentLabel is the agent_label every agent comment carries.
const projectAgentLabel = "claude-code"

// resolveInsideFolder resolves rel against the project folder — symlinks
// included — and returns the absolute path only when it stays inside the
// folder and names an existing .md/.txt file. `../` and a symlink (file or
// directory) pointing out of the folder are both refused.
func resolveInsideFolder(folder, rel string) (string, error) {
	if strings.TrimSpace(rel) == "" || filepath.IsAbs(rel) {
		return "", &ValidationError{Msg: "rel_path must be a path relative to the project folder"}
	}
	return resolveDocumentFile(folder, filepath.Join(folder, rel), rel)
}

// ResolveProjectDocumentPath is attach_document's path check for the owner's
// `project attach-doc`: path may be absolute or relative to the folder, and
// the result is the folder-relative, slash-separated path of the resolved
// file. The same refusals apply — outside the folder (symlinks followed),
// missing, not a regular .md/.txt file.
func ResolveProjectDocumentPath(folder, path string) (string, error) {
	if strings.TrimSpace(path) == "" {
		return "", &ValidationError{Msg: "a document path is required"}
	}
	candidate := path
	if !filepath.IsAbs(path) {
		candidate = filepath.Join(folder, path)
	}
	abs, err := resolveDocumentFile(folder, candidate, path)
	if err != nil {
		return "", err
	}
	rel, err := filepath.Rel(folder, abs)
	if err != nil {
		return "", fmt.Errorf("relativizing %s: %w", abs, err)
	}
	return filepath.ToSlash(rel), nil
}

// resolveDocumentFile resolves candidate's symlinks and checks it names a
// document file inside folder; rel is how errors name the path.
func resolveDocumentFile(folder, candidate, rel string) (string, error) {
	abs, err := filepath.EvalSymlinks(candidate)
	if errors.Is(err, fs.ErrNotExist) {
		return "", &ValidationError{Msg: fmt.Sprintf("%s does not exist in the project folder", rel)}
	}
	if err != nil {
		return "", &ValidationError{Msg: fmt.Sprintf("cannot read %s: %v", rel, err)}
	}
	inside, err := filepath.Rel(folder, abs)
	if err != nil || inside == ".." || strings.HasPrefix(inside, ".."+string(filepath.Separator)) {
		return "", &ValidationError{Msg: fmt.Sprintf("%s resolves outside the project folder", rel)}
	}
	return abs, checkDocumentFile(rel, abs)
}

func checkDocumentFile(rel, abs string) error {
	ext := strings.ToLower(filepath.Ext(abs))
	if ext != ".md" && ext != ".txt" {
		return &ValidationError{Msg: fmt.Sprintf("%s is not a .md or .txt file", rel)}
	}
	st, err := os.Stat(abs)
	if err != nil {
		return &ValidationError{Msg: fmt.Sprintf("cannot read %s: %v", rel, err)}
	}
	if !st.Mode().IsRegular() {
		return &ValidationError{Msg: fmt.Sprintf("%s is not a regular file", rel)}
	}
	return nil
}

// documentInProject loads a document and fails unless it belongs to projectID.
func documentInProject(d *db.DB, projectID, documentID int64) (*db.ProjectDocument, error) {
	notHere := notInProject("document", documentID)
	if projectID <= 0 || documentID <= 0 {
		return nil, notHere
	}
	doc, err := d.GetProjectDocument(documentID)
	if err != nil {
		return nil, fmt.Errorf("loading document %d: %w", documentID, err)
	}
	if doc == nil || doc.ProjectID != projectID {
		return nil, notHere
	}
	return doc, nil
}

// commentInProject loads a comment and fails unless it belongs to projectID.
func commentInProject(d *db.DB, projectID, commentID int64) (*db.ProjectComment, error) {
	notHere := notInProject("comment", commentID)
	if projectID <= 0 || commentID <= 0 {
		return nil, notHere
	}
	c, err := d.GetProjectComment(commentID)
	if err != nil {
		return nil, fmt.Errorf("loading comment %d: %w", commentID, err)
	}
	if c == nil || c.ProjectID != projectID {
		return nil, notHere
	}
	return c, nil
}

// optionalTarget checks an optional target id against the project.
func optionalTarget(d *db.DB, projectID, targetID int64) (sql.NullInt64, error) {
	if targetID == 0 {
		return sql.NullInt64{}, nil
	}
	if _, err := targetInProject(d, projectID, targetID); err != nil {
		return sql.NullInt64{}, err
	}
	return sql.NullInt64{Int64: targetID, Valid: true}, nil
}

// ---- attach_document ---------------------------------------------------

type attachDocumentArgs struct {
	RelPath  string `json:"rel_path" jsonschema:"path of the .md/.txt file relative to the project folder, e.g. docs/specs/x.md"`
	Kind     string `json:"kind" jsonschema:"spec | plan | doc"`
	Title    string `json:"title,omitempty" jsonschema:"display title; defaults to the file name"`
	TargetID int64  `json:"target_id,omitempty" jsonschema:"the project target this document belongs to"`
	Reason   string `json:"reason" jsonschema:"one sentence: what the document is, e.g. 'plan for feature X'"`
}

// NewAttachDocument attaches (or re-attaches, marking it revised) a file in
// the project folder so the owner can review and comment on it.
func NewAttachDocument() *Tool {
	return &Tool{
		Name: "attach_document",
		Description: "Attach a spec, plan or doc (a .md/.txt file inside the project folder) so the owner can " +
			"review and comment on it in Watchtower. Attach again after revising it — that marks it revised. " +
			"Applied immediately.",
		InputSchema: mustSchema[attachDocumentArgs]("attach_document"),
		Access:      AccessWrite,
		Surfaces:    projectSurfaces,
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a attachDocumentArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			if a.Kind == "" {
				return &ValidationError{Msg: "kind is required"}
			}
			return validateEnum("kind", a.Kind, "spec", "plan", "doc")
		},
		Scope: func(ctx context.Context, d *db.DB, raw json.RawMessage, b Binding) error {
			var a attachDocumentArgs
			if err := json.Unmarshal(raw, &a); err != nil {
				return &ValidationError{Msg: "invalid arguments"}
			}
			_, _, err := resolveAttachment(ctx, d, b, a)
			return err
		},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a attachDocumentArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding attach_document args: %w", err)
			}
			return attachDocument(ctx, d, call.Binding, a)
		},
	}
}

// resolveAttachment returns the folder-relative clean path of the file and
// the checked target link.
func resolveAttachment(ctx context.Context, d *db.DB, b Binding, a attachDocumentArgs) (string, sql.NullInt64, error) {
	p, err := projectOf(ctx, d, b)
	if err != nil {
		return "", sql.NullInt64{}, err
	}
	abs, err := resolveInsideFolder(p.FolderPath, a.RelPath)
	if err != nil {
		return "", sql.NullInt64{}, err
	}
	target, err := optionalTarget(d, p.ID, a.TargetID)
	if err != nil {
		return "", sql.NullInt64{}, err
	}
	rel, err := filepath.Rel(p.FolderPath, abs)
	if err != nil {
		return "", sql.NullInt64{}, fmt.Errorf("relativizing %s: %w", abs, err)
	}
	return filepath.ToSlash(rel), target, nil
}

func attachDocument(ctx context.Context, d *db.DB, b Binding, a attachDocumentArgs) (any, error) {
	rel, target, err := resolveAttachment(ctx, d, b, a)
	if err != nil {
		return nil, err
	}
	title := strings.TrimSpace(a.Title)
	if title == "" {
		title = strings.TrimSuffix(filepath.Base(rel), filepath.Ext(rel))
	}
	id, created, err := d.UpsertProjectDocument(db.ProjectDocument{
		ProjectID: b.ProjectID, TargetID: target, RelPath: rel, Kind: a.Kind, Title: title,
	})
	if err != nil {
		return nil, fmt.Errorf("attaching %s: %w", rel, err)
	}
	return map[string]any{"document_id": id, "rel_path": rel, "created": created}, nil
}

// ---- list_comments -----------------------------------------------------

type listCommentsArgs struct {
	TargetID    int64 `json:"target_id,omitempty" jsonschema:"comments on this project target"`
	DocumentID  int64 `json:"document_id,omitempty" jsonschema:"comments on this attached document"`
	NewForAgent *bool `json:"new_for_agent,omitempty" jsonschema:"only what is new for you (open owner comments, unanswered owner replies); default true when no id is given"`
}

type projectCommentView struct {
	ID         int64  `json:"id"`
	TargetID   int64  `json:"target_id,omitempty"`
	DocumentID int64  `json:"document_id,omitempty"`
	ParentID   int64  `json:"parent_id,omitempty"`
	Author     string `json:"author"`
	Body       string `json:"body"`
	Status     string `json:"status"`
	Quote      string `json:"anchor_quote,omitempty"`
	Heading    string `json:"anchor_heading,omitempty"`
	CreatedAt  string `json:"created_at"`
}

// NewListComments lists project comments by target, by document, or — the
// default — everything new for the agent.
func NewListComments() *Tool {
	return &Tool{
		Name: "list_comments",
		Description: "List comments on this project: on a target (target_id), on a document (document_id, " +
			"with the quoted passage and its heading), or — by default — every owner comment new for you. " +
			"Read a document's comments before revising it.",
		InputSchema: mustSchema[listCommentsArgs]("list_comments"),
		Access:      AccessRead,
		Surfaces:    projectSurfaces,
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a listCommentsArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			f, err := commentFilter(ctx, d, call.Binding, a)
			if err != nil {
				return nil, err
			}
			comments, err := d.ListProjectComments(f)
			if err != nil {
				return nil, fmt.Errorf("listing comments: %w", err)
			}
			return commentViews(comments), nil
		},
	}
}

func commentFilter(ctx context.Context, d *db.DB, b Binding, a listCommentsArgs) (db.ProjectCommentFilter, error) {
	p, err := projectOf(ctx, d, b)
	if err != nil {
		return db.ProjectCommentFilter{}, err
	}
	f := db.ProjectCommentFilter{ProjectID: p.ID, TargetID: a.TargetID, DocumentID: a.DocumentID}
	f.NewForAgent = a.TargetID == 0 && a.DocumentID == 0
	if a.NewForAgent != nil {
		f.NewForAgent = *a.NewForAgent
	}
	if a.TargetID != 0 {
		if _, err := targetInProject(d, p.ID, a.TargetID); err != nil {
			return f, err
		}
	}
	if a.DocumentID != 0 {
		if _, err := documentInProject(d, p.ID, a.DocumentID); err != nil {
			return f, err
		}
	}
	return f, nil
}

func commentViews(comments []db.ProjectComment) []projectCommentView {
	out := make([]projectCommentView, 0, len(comments))
	for _, c := range comments {
		out = append(out, projectCommentView{
			ID: c.ID, TargetID: c.TargetID.Int64, DocumentID: c.DocumentID.Int64, ParentID: c.ParentID.Int64,
			Author: c.Author, Body: c.Body, Status: c.Status,
			Quote: c.AnchorQuote, Heading: c.AnchorHeading, CreatedAt: c.CreatedAt,
		})
	}
	return out
}

// ---- add_comment -------------------------------------------------------

type addCommentArgs struct {
	TargetID int64  `json:"target_id,omitempty" jsonschema:"start a thread on this project target"`
	ParentID int64  `json:"parent_id,omitempty" jsonschema:"reply to this comment instead"`
	Body     string `json:"body" jsonschema:"the comment: a question, a blocker or a done-summary"`
	Reason   string `json:"reason" jsonschema:"one sentence: why you comment"`
}

// NewAddComment posts an agent comment on a project target, or a reply.
func NewAddComment() *Tool {
	return &Tool{
		Name: "add_comment",
		Description: "Comment on a project target (target_id) or reply to a comment (parent_id) — questions for " +
			"the owner, blockers, done-summaries only. The owner is notified; keep working meanwhile. " +
			"Applied immediately.",
		InputSchema: mustSchema[addCommentArgs]("add_comment"),
		Access:      AccessWrite,
		Surfaces:    projectSurfaces,
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a addCommentArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			if (a.TargetID == 0) == (a.ParentID == 0) {
				return &ValidationError{Msg: "give exactly one of target_id or parent_id"}
			}
			_, err := requireText("body", a.Body, 8000)
			return err
		},
		Scope: func(ctx context.Context, d *db.DB, raw json.RawMessage, b Binding) error {
			var a addCommentArgs
			if err := json.Unmarshal(raw, &a); err != nil {
				return &ValidationError{Msg: "invalid arguments"}
			}
			return scopeComment(ctx, d, b, a.TargetID, a.ParentID)
		},
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a addCommentArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding add_comment args: %w", err)
			}
			id, err := addAgentComment(d, call.Binding.ProjectID, a.TargetID, a.ParentID, a.Body)
			if err != nil {
				return nil, err
			}
			return map[string]any{"comment_id": id}, nil
		},
	}
}

func scopeComment(ctx context.Context, d *db.DB, b Binding, targetID, parentID int64) error {
	if _, err := projectOf(ctx, d, b); err != nil {
		return err
	}
	if targetID != 0 {
		_, err := targetInProject(d, b.ProjectID, targetID)
		return err
	}
	_, err := commentInProject(d, b.ProjectID, parentID)
	return err
}

func addAgentComment(d *db.DB, projectID, targetID, parentID int64, body string) (int64, error) {
	id, err := d.AddProjectComment(agentComment(projectID, targetID, parentID, body))
	if err != nil {
		return 0, fmt.Errorf("adding comment: %w", err)
	}
	return id, nil
}

func agentComment(projectID, targetID, parentID int64, body string) db.ProjectComment {
	c := db.ProjectComment{ProjectID: projectID, Author: "agent", AgentLabel: projectAgentLabel, Body: strings.TrimSpace(body)}
	if targetID != 0 {
		c.TargetID = sql.NullInt64{Int64: targetID, Valid: true}
	}
	if parentID != 0 {
		c.ParentID = sql.NullInt64{Int64: parentID, Valid: true}
	}
	return c
}

// ---- resolve_comment ---------------------------------------------------

type resolveCommentArgs struct {
	CommentID int64  `json:"comment_id" jsonschema:"the thread's root comment"`
	Reply     string `json:"reply,omitempty" jsonschema:"one line: what you changed"`
	Reason    string `json:"reason" jsonschema:"one sentence: why it is resolved"`
}

// NewResolveComment resolves a comment thread, optionally with a reply.
func NewResolveComment() *Tool {
	return &Tool{
		Name: "resolve_comment",
		Description: "Resolve a comment thread (its root comment id) after addressing it, optionally with a " +
			"one-line reply saying what changed. Applied immediately.",
		InputSchema: mustSchema[resolveCommentArgs]("resolve_comment"),
		Access:      AccessWrite,
		Surfaces:    projectSurfaces,
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a resolveCommentArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			if len([]rune(a.Reply)) > 8000 {
				return &ValidationError{Msg: "reply must be at most 8000 characters"}
			}
			return nil
		},
		Scope: func(ctx context.Context, d *db.DB, raw json.RawMessage, b Binding) error {
			var a resolveCommentArgs
			if err := json.Unmarshal(raw, &a); err != nil {
				return &ValidationError{Msg: "invalid arguments"}
			}
			return scopeResolve(ctx, d, b, a.CommentID)
		},
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a resolveCommentArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding resolve_comment args: %w", err)
			}
			return resolveComment(d, call.Binding.ProjectID, a)
		},
	}
}

func scopeResolve(ctx context.Context, d *db.DB, b Binding, commentID int64) error {
	if _, err := projectOf(ctx, d, b); err != nil {
		return err
	}
	c, err := commentInProject(d, b.ProjectID, commentID)
	if err != nil {
		return err
	}
	if c.ParentID.Valid {
		return &ValidationError{Msg: fmt.Sprintf("comment %d is a reply; resolve its thread's root comment %d", commentID, c.ParentID.Int64)}
	}
	return nil
}

// resolveComment posts the optional reply and resolves the root in one
// transaction: a failure leaves neither, so a Retry cannot duplicate the reply.
func resolveComment(d *db.DB, projectID int64, a resolveCommentArgs) (any, error) {
	out := map[string]any{"comment_id": a.CommentID}
	err := d.WithTx(func(tx *sql.Tx) error {
		if strings.TrimSpace(a.Reply) != "" {
			id, err := d.AddProjectCommentTx(tx, agentComment(projectID, 0, a.CommentID, a.Reply))
			if err != nil {
				return fmt.Errorf("adding comment: %w", err)
			}
			out["reply_id"] = id
		}
		if err := d.SetProjectCommentStatusTx(tx, a.CommentID, "resolved"); err != nil {
			return fmt.Errorf("resolving comment %d: %w", a.CommentID, err)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}
