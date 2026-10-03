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

// workbenchAgentLabel is the agent_label every agent comment carries.
const workbenchAgentLabel = "claude-code"

// ResolveWorkbenchDocumentPath checks a document path of the workbench folder:
// path may be absolute or relative to the folder, and the result is the
// folder-relative, slash-separated path of the resolved file. It refuses a
// path outside the folder (symlinks followed), a missing one, and anything
// but a regular .md/.markdown/.txt file.
func ResolveWorkbenchDocumentPath(folder, path string) (string, error) {
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
		return "", &ValidationError{Msg: fmt.Sprintf("%s does not exist in the workbench folder", rel)}
	}
	if err != nil {
		return "", &ValidationError{Msg: fmt.Sprintf("cannot read %s: %v", rel, err)}
	}
	inside, err := filepath.Rel(folder, abs)
	if err != nil || inside == ".." || strings.HasPrefix(inside, ".."+string(filepath.Separator)) {
		return "", &ValidationError{Msg: fmt.Sprintf("%s resolves outside the workbench folder", rel)}
	}
	return abs, checkDocumentFile(rel, abs)
}

func checkDocumentFile(rel, abs string) error {
	ext := strings.ToLower(filepath.Ext(abs))
	if ext != ".md" && ext != ".markdown" && ext != ".txt" {
		return &ValidationError{Msg: fmt.Sprintf("%s is not a .md, .markdown or .txt file", rel)}
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

// commentInWorkbench loads a comment and fails unless it belongs to projectID.
func commentInWorkbench(d *db.DB, projectID, commentID int64) (*db.WorkbenchComment, error) {
	notHere := notInWorkbench("comment", commentID)
	if projectID <= 0 || commentID <= 0 {
		return nil, notHere
	}
	c, err := d.GetWorkbenchComment(commentID)
	if err != nil {
		return nil, fmt.Errorf("loading comment %d: %w", commentID, err)
	}
	if c == nil || c.WorkbenchID != projectID {
		return nil, notHere
	}
	return c, nil
}

// ---- list_comments -----------------------------------------------------

type listCommentsArgs struct {
	TargetID int64 `json:"target_id,omitempty" jsonschema:"comments on this workbench target"`
	// DocumentID stays in the schema only so a call that still sends it gets
	// documentsReplaced rather than an unknown-property error.
	DocumentID  *int64 `json:"document_id,omitempty" jsonschema:"removed: documents were replaced by asks; any value is refused"`
	NewForAgent *bool  `json:"new_for_agent,omitempty" jsonschema:"only what is new for you (open owner comments, unanswered owner replies); default true when no id is given"`
}

type workbenchCommentView struct {
	ID        int64  `json:"id"`
	TargetID  int64  `json:"target_id,omitempty"`
	ParentID  int64  `json:"parent_id,omitempty"`
	Author    string `json:"author"`
	Body      string `json:"body"`
	Status    string `json:"status"`
	CreatedAt string `json:"created_at"`
}

// documentsReplaced is list_comments' refusal of the document_id argument the
// attached documents had (spec 2026-10-03 §4).
const documentsReplaced = "documents were replaced by asks — use ask_owner (kind review)"

// NewListComments lists workbench comments by target or — the default —
// everything new for the agent.
func NewListComments() *Tool {
	return &Tool{
		Name: "list_comments",
		Description: "List comments on this workbench: on a target (target_id) or — by default — every owner " +
			"comment new for you.",
		InputSchema: mustSchema[listCommentsArgs]("list_comments"),
		Access:      AccessRead,
		Surfaces:    workbenchSurfaces,
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a listCommentsArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			if a.DocumentID != nil {
				return nil, &ValidationError{Msg: documentsReplaced}
			}
			f, err := commentFilter(ctx, d, call.Binding, a)
			if err != nil {
				return nil, err
			}
			comments, err := d.ListWorkbenchComments(f)
			if err != nil {
				return nil, fmt.Errorf("listing comments: %w", err)
			}
			return commentViews(comments), nil
		},
	}
}

func commentFilter(ctx context.Context, d *db.DB, b Binding, a listCommentsArgs) (db.WorkbenchCommentFilter, error) {
	p, err := workbenchOf(ctx, d, b)
	if err != nil {
		return db.WorkbenchCommentFilter{}, err
	}
	f := db.WorkbenchCommentFilter{WorkbenchID: p.ID, TargetID: a.TargetID}
	f.NewForAgent = a.TargetID == 0
	if a.NewForAgent != nil {
		f.NewForAgent = *a.NewForAgent
	}
	if a.TargetID != 0 {
		if _, err := targetInWorkbench(d, p.ID, a.TargetID); err != nil {
			return f, err
		}
	}
	return f, nil
}

func commentViews(comments []db.WorkbenchComment) []workbenchCommentView {
	out := make([]workbenchCommentView, 0, len(comments))
	for _, c := range comments {
		out = append(out, workbenchCommentView{
			ID: c.ID, TargetID: c.TargetID.Int64, ParentID: c.ParentID.Int64,
			Author: c.Author, Body: c.Body, Status: c.Status, CreatedAt: c.CreatedAt,
		})
	}
	return out
}

// ---- add_comment -------------------------------------------------------

type addCommentArgs struct {
	TargetID int64  `json:"target_id,omitempty" jsonschema:"start a thread on this workbench target"`
	ParentID int64  `json:"parent_id,omitempty" jsonschema:"reply to this comment instead"`
	Body     string `json:"body" jsonschema:"the comment: a question, a blocker or a done-summary"`
	Reason   string `json:"reason" jsonschema:"one sentence: why you comment"`
}

// NewAddComment posts an agent comment on a workbench target, or a reply, and
// links the comment's target — for a reply its root's — to the terminal
// session sessionEnv names (linkSession).
func NewAddComment(sessionEnv func() string) *Tool {
	return &Tool{
		Name: "add_comment",
		Description: "Comment on a workbench target (target_id) or reply to a comment (parent_id) — questions for " +
			"the owner, blockers, done-summaries only. The owner is notified; keep working meanwhile. " +
			"Applied immediately.",
		InputSchema: mustSchema[addCommentArgs]("add_comment"),
		Access:      AccessWrite,
		Surfaces:    workbenchSurfaces,
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
			id, err := addAgentComment(d, call.Binding.WorkbenchID, a.TargetID, a.ParentID, a.Body)
			if err != nil {
				return nil, err
			}
			out := map[string]any{"comment_id": id}
			linkCommentTarget(d, call.Binding, sessionEnv, out, id)
			return out, nil
		},
	}
}

func scopeComment(ctx context.Context, d *db.DB, b Binding, targetID, parentID int64) error {
	if _, err := workbenchOf(ctx, d, b); err != nil {
		return err
	}
	if targetID != 0 {
		_, err := targetInWorkbench(d, b.WorkbenchID, targetID)
		return err
	}
	_, err := commentInWorkbench(d, b.WorkbenchID, parentID)
	return err
}

// linkCommentTarget links comment id's target: a reply is stored with its
// root's target (placeReply), so the new row names the right one either way.
func linkCommentTarget(d *db.DB, b Binding, sessionEnv func() string, out map[string]any, id int64) {
	c, err := d.GetWorkbenchComment(id)
	switch {
	case err != nil:
		reportLinkFailure(out, err)
	case c != nil && c.TargetID.Valid:
		linkSession(d, b, sessionEnv, out, c.TargetID.Int64)
	}
}

func addAgentComment(d *db.DB, projectID, targetID, parentID int64, body string) (int64, error) {
	id, err := d.AddWorkbenchComment(agentComment(projectID, targetID, parentID, body))
	if err != nil {
		return 0, fmt.Errorf("adding comment: %w", err)
	}
	return id, nil
}

func agentComment(projectID, targetID, parentID int64, body string) db.WorkbenchComment {
	c := db.WorkbenchComment{WorkbenchID: projectID, Author: "agent", AgentLabel: workbenchAgentLabel, Body: strings.TrimSpace(body)}
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
		Surfaces:    workbenchSurfaces,
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
			return resolveComment(d, call.Binding.WorkbenchID, a)
		},
	}
}

func scopeResolve(ctx context.Context, d *db.DB, b Binding, commentID int64) error {
	if _, err := workbenchOf(ctx, d, b); err != nil {
		return err
	}
	c, err := commentInWorkbench(d, b.WorkbenchID, commentID)
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
			id, err := d.AddWorkbenchCommentTx(tx, agentComment(projectID, 0, a.CommentID, a.Reply))
			if err != nil {
				return fmt.Errorf("adding comment: %w", err)
			}
			out["reply_id"] = id
		}
		if err := d.SetWorkbenchCommentStatusTx(tx, a.CommentID, "resolved"); err != nil {
			return fmt.Errorf("resolving comment %d: %w", a.CommentID, err)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}
