package chatengine

import (
	"context"
	"encoding/json"
)

// registerMacOps adds the operations only the Mac had before the engine
// (spec §5.2): the pickers, projects, the artifact panel and attachments.
func (e *Engine) registerMacOps() {
	e.Register("entity_search", e.opEntitySearch)
	e.Register("skills_list", e.opSkillsList)
	e.Register("project_manage", e.opProjectManage)
	e.Register("artifact_manage", e.opArtifactManage)
	e.Register("attach", e.opAttach)
	e.Register("attach_discard", e.opAttachDiscard)
}

func (e *Engine) opEntitySearch(ctx context.Context, params json.RawMessage, _ Client) (any, error) {
	var p struct {
		Query string   `json:"query"`
		Kinds []string `json:"kinds"`
	}
	if err := decode(params, &p); err != nil {
		return nil, err
	}
	hits, err := e.EntitySearch(ctx, p.Query, p.Kinds)
	if err != nil {
		return nil, err
	}
	if hits == nil {
		hits = []EntityHit{}
	}
	return map[string]any{"hits": hits}, nil
}

func (e *Engine) opSkillsList(ctx context.Context, _ json.RawMessage, _ Client) (any, error) {
	list, err := e.SkillsList(ctx)
	if err != nil {
		return nil, err
	}
	return map[string]any{"skills": list}, nil
}

func (e *Engine) opProjectManage(ctx context.Context, params json.RawMessage, c Client) (any, error) {
	var p struct {
		Op           string          `json:"op"`
		ProjectID    *int64          `json:"project_id"`
		Name         *string         `json:"name"`
		Instructions *string         `json:"instructions"`
		Sources      []ProjectSource `json:"sources"`
		SourceID     int64           `json:"source_id"`
		FileID       int64           `json:"file_id"`
		Path         string          `json:"path"`
	}
	if err := decode(params, &p); err != nil {
		return nil, err
	}
	if p.Op == ProjectFileAdd && !readsPaths(c) {
		return nil, ErrForbidden
	}
	id, err := e.ManageProject(ctx, ProjectRequest{Op: p.Op, ID: p.ProjectID, Name: p.Name, Instructions: p.Instructions,
		Sources: p.Sources, SourceID: p.SourceID, FileID: p.FileID, Path: p.Path})
	if err != nil {
		return nil, err
	}
	return map[string]int64{"id": id}, nil
}

func (e *Engine) opArtifactManage(ctx context.Context, params json.RawMessage, _ Client) (any, error) {
	var p struct {
		Op             string           `json:"op"`
		ConversationID int64            `json:"conversation_id"`
		Key            string           `json:"key"`
		Version        int              `json:"version"`
		CommentID      int64            `json:"comment_id"`
		Comment        *ArtifactComment `json:"comment"`
		Moved          []int64          `json:"moved"`
		Lost           []int64          `json:"lost"`
		Content        string           `json:"content"`
	}
	if err := decode(params, &p); err != nil {
		return nil, err
	}
	id, err := e.ManageArtifact(ctx, ArtifactRequest{Op: p.Op, Conversation: p.ConversationID, Key: p.Key, Version: p.Version,
		CommentID: p.CommentID, Comment: p.Comment, Moved: p.Moved, Lost: p.Lost, Content: p.Content})
	if err != nil {
		return nil, err
	}
	return map[string]int64{"id": id}, nil
}

// readsPaths: c may name a file on this Mac for the engine to read — only
// the Mac app, which holds the file the owner picked. Every other client
// (the phone's sealed upload goes through the hub to AttachBytes) is
// refused, so no op reads an arbitrary path for it.
func readsPaths(c Client) bool { return c.Kind == "mac" }

// opAttach is the Mac's form: a path the app holds (readsPaths).
func (e *Engine) opAttach(ctx context.Context, params json.RawMessage, c Client) (any, error) {
	if !readsPaths(c) {
		return nil, ErrForbidden
	}
	var p struct {
		ConversationID int64  `json:"conversation_id"`
		Path           string `json:"path"`
	}
	if err := decode(params, &p); err != nil {
		return nil, err
	}
	if p.ConversationID <= 0 {
		return nil, errBadParams
	}
	id, err := e.AttachPath(ctx, p.ConversationID, p.Path)
	if err != nil {
		return nil, err
	}
	return map[string]int64{"attachment_id": id}, nil
}

func (e *Engine) opAttachDiscard(ctx context.Context, params json.RawMessage, _ Client) (any, error) {
	var p struct {
		ConversationID int64 `json:"conversation_id"`
		AttachmentID   int64 `json:"attachment_id"`
	}
	if err := decode(params, &p); err != nil {
		return nil, err
	}
	return ack(e.DiscardAttachment(ctx, p.ConversationID, p.AttachmentID))
}
