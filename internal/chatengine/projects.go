package chatengine

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"os"
	"slices"
	"strings"

	"watchtower/internal/chatstore"
)

// ProjectSource is one source pinned to a chat project (Swift
// ChatProjectSource): Kind is jira_project, slack_channel,
// confluence_space, target, track or person.
type ProjectSource struct {
	Kind  string `json:"kind"`
	Ref   string `json:"ref"`
	Label string `json:"label"`
}

// projectSourceKinds is chat_project_sources.kind's CHECK.
var projectSourceKinds = []string{"jira_project", "slack_channel", "confluence_space", "target", "track", "person"}

// The project_manage ops: every write of the Mac's ChatProjectQueries and
// project page (spec §5.2, ruling F8).
const (
	ProjectCreate       = "create"        // Name ("" = "New project") → the new id
	ProjectUpdate       = "update"        // ID; Name (rename) and/or Instructions
	ProjectArchive      = "archive"       // ID
	ProjectDelete       = "delete"        // ID: chats survive detached, files go
	ProjectSourceAdd    = "source_add"    // ID, Sources (one already pinned is skipped)
	ProjectSourceRemove = "source_remove" // SourceID
	ProjectFileAdd      = "file_add"      // ID, Path (a file the app holds) → the file's id
	ProjectFileRemove   = "file_remove"   // FileID
)

// DefaultProjectName is ChatProjectQueries.defaultName.
const DefaultProjectName = "New project"

// ProjectRequest is one chat project write.
type ProjectRequest struct {
	Op                 string
	ID                 *int64
	Name, Instructions *string
	Sources            []ProjectSource
	SourceID, FileID   int64
	Path               string
}

// projectWrite is what a committed project write leaves to do.
type projectWrite struct {
	id        int64    // the result (a new project's or file's id)
	project   int64    // the project whose prompt changed (0 = none)
	deleted   bool     // the project is gone
	convs     []int64  // its conversations, told of the change
	orphans   []string // files no row points at any more, removed after the commit
	unchanged bool     // nothing was written
}

// ManageProject applies a chat project write (Swift ChatProjectQueries).
// A write that changes what a project chat's prompt holds (instructions,
// sources, files, delete) drops the project chats' stored sessions in its
// transaction and retires their warm `ai session` processes (an idle one
// closes now, a busy one after its turn), as ChatSessionPool.retireSessions
// does. ErrProjectGone for a missing project, chatstore.ErrNotFound for a
// missing source or file, chatstore.ErrInvalid for a bad request.
func (e *Engine) ManageProject(ctx context.Context, r ProjectRequest) (int64, error) {
	var (
		w   projectWrite
		err error
	)
	if r.Op != ProjectCreate && r.Op != ProjectSourceRemove && r.Op != ProjectFileRemove && (r.ID == nil || *r.ID <= 0) {
		return 0, chatstore.ErrInvalid
	}
	switch r.Op {
	case ProjectCreate:
		w, err = e.createProject(ctx, r.Name)
	case ProjectUpdate:
		w, err = e.updateProject(ctx, *r.ID, r.Name, r.Instructions)
	case ProjectArchive:
		w, err = e.projectTx(ctx, func(tx *sql.Tx, now float64) (projectWrite, error) {
			return projectWrite{}, requireRow(tx.Exec(`UPDATE chat_projects SET archived_at = ?, updated_at = ? WHERE id = ?`, now, now, *r.ID))
		})
	case ProjectDelete:
		w, err = e.deleteProject(ctx, *r.ID)
	case ProjectSourceAdd:
		w, err = e.addSources(ctx, *r.ID, r.Sources)
	case ProjectSourceRemove:
		w, err = e.removeSource(ctx, r.SourceID)
	case ProjectFileAdd:
		w, err = e.addProjectFile(ctx, *r.ID, r.Path)
	case ProjectFileRemove:
		w, err = e.removeProjectFile(ctx, r.FileID)
	default:
		return 0, chatstore.ErrInvalid
	}
	if err != nil {
		return 0, err
	}
	for _, p := range w.orphans {
		if err := os.Remove(p); err != nil && !errors.Is(err, os.ErrNotExist) {
			log.Printf("chatengine: a removed project file stayed on disk (%s)", errClass(err))
		}
	}
	if w.deleted && e.c.FilesDir != "" {
		if err := chatstore.RemoveProjectFiles(e.c.FilesDir, w.project); err != nil {
			log.Printf("chatengine: project %d deleted, its files folder was not removed (%s)", w.project, errClass(err))
		}
	}
	if w.project != 0 {
		e.retireProject(w.project)
	}
	if !w.unchanged {
		for _, c := range w.convs {
			e.changed(c)
		}
		e.changed(0) // the list's projects
	}
	return w.id, nil
}

// retireProject retires the live sessions of projectID's chats: an idle one
// closes now, a busy one after its turn; the next turn spawns with the
// current prompt. A session not launched yet reads the prompt at launch.
func (e *Engine) retireProject(projectID int64) {
	e.mu.Lock()
	defer e.mu.Unlock()
	for _, s := range e.sessions {
		if s.cfg.project == projectID && s.phase != phasePending && !s.retire {
			s.retire = true
			s.poke()
		}
	}
	e.admit()
}

// projectTx runs fn in one write transaction with the clock's seconds.
func (e *Engine) projectTx(ctx context.Context, fn func(tx *sql.Tx, now float64) (projectWrite, error)) (projectWrite, error) {
	tx, err := e.c.DB.BeginTx(ctx, nil)
	if err != nil {
		return projectWrite{}, fmt.Errorf("chatengine: chat project write: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	w, err := fn(tx, seconds(e.c.Clock()))
	if err != nil {
		return projectWrite{}, err
	}
	if err := tx.Commit(); err != nil {
		return projectWrite{}, fmt.Errorf("chatengine: chat project write: %w", err)
	}
	return w, nil
}

func (e *Engine) createProject(ctx context.Context, name *string) (projectWrite, error) {
	n := ""
	if name != nil {
		n = strings.TrimSpace(*name)
	}
	if n == "" {
		n = DefaultProjectName
	}
	return e.projectTx(ctx, func(tx *sql.Tx, now float64) (projectWrite, error) {
		res, err := tx.Exec(`INSERT INTO chat_projects (name, instructions, created_at, updated_at) VALUES (?, '', ?, ?)`, n, now, now)
		if err != nil {
			return projectWrite{}, fmt.Errorf("chatengine: creating a chat project: %w", err)
		}
		id, err := res.LastInsertId()
		return projectWrite{id: id}, err
	})
}

// updateProject is ChatProjectQueries.rename (a blank name is ignored) and
// updateInstructions (drops the stored sessions) in one transaction.
func (e *Engine) updateProject(ctx context.Context, id int64, name, instructions *string) (projectWrite, error) {
	if name == nil && instructions == nil {
		return projectWrite{}, chatstore.ErrInvalid
	}
	return e.projectTx(ctx, func(tx *sql.Tx, now float64) (projectWrite, error) {
		var w projectWrite
		if err := requireProject(tx, id); err != nil {
			return w, err
		}
		w.unchanged = true
		if name != nil {
			if n := strings.TrimSpace(*name); n != "" {
				if _, err := tx.Exec(`UPDATE chat_projects SET name = ?, updated_at = ? WHERE id = ?`, n, now, id); err != nil {
					return w, fmt.Errorf("chatengine: renaming a chat project: %w", err)
				}
				w.unchanged = false
			}
		}
		if instructions != nil {
			if _, err := tx.Exec(`UPDATE chat_projects SET instructions = ?, updated_at = ? WHERE id = ?`, *instructions, now, id); err != nil {
				return w, fmt.Errorf("chatengine: chat project instructions: %w", err)
			}
			if err := dropSessionsTx(tx, id); err != nil {
				return w, err
			}
			w.project, w.unchanged = id, false
		}
		return w, nil
	})
}

// deleteProject is ChatProjectQueries.delete: its chats survive detached
// (ON DELETE SET NULL), its sources and file rows go by cascade, its files
// leave the disk after the commit.
func (e *Engine) deleteProject(ctx context.Context, id int64) (projectWrite, error) {
	return e.projectTx(ctx, func(tx *sql.Tx, _ float64) (projectWrite, error) {
		w := projectWrite{project: id, deleted: true}
		if err := requireProject(tx, id); err != nil {
			return w, err
		}
		var err error
		if w.orphans, err = strs(tx, `SELECT DISTINCT path FROM chat_attachments WHERE project_id = ? ORDER BY path`, id); err != nil {
			return w, err
		}
		if w.convs, err = ids(tx, `SELECT id FROM chat_conversations WHERE project_id = ? ORDER BY id`, id); err != nil {
			return w, err
		}
		if err := dropSessionsTx(tx, id); err != nil {
			return w, err
		}
		if _, err := tx.Exec(`DELETE FROM chat_projects WHERE id = ?`, id); err != nil {
			return w, fmt.Errorf("chatengine: deleting a chat project: %w", err)
		}
		return w, nil
	})
}

// addSources is ChatProjectQueries.addSource for each source; one already
// pinned (UNIQUE(project_id, kind, ref)) is skipped.
func (e *Engine) addSources(ctx context.Context, id int64, sources []ProjectSource) (projectWrite, error) {
	if len(sources) == 0 {
		return projectWrite{}, chatstore.ErrInvalid
	}
	for _, s := range sources {
		if !slices.Contains(projectSourceKinds, s.Kind) || s.Ref == "" {
			return projectWrite{}, chatstore.ErrInvalid
		}
	}
	return e.projectTx(ctx, func(tx *sql.Tx, now float64) (projectWrite, error) {
		w := projectWrite{unchanged: true}
		if err := requireProject(tx, id); err != nil {
			return w, err
		}
		for _, s := range sources {
			res, err := tx.Exec(`INSERT OR IGNORE INTO chat_project_sources (project_id, kind, ref, label) VALUES (?, ?, ?, ?)`,
				id, s.Kind, s.Ref, s.Label)
			if err != nil {
				return w, fmt.Errorf("chatengine: pinning a project source: %w", err)
			}
			if n, _ := res.RowsAffected(); n > 0 {
				w.unchanged = false
			}
		}
		if w.unchanged {
			return w, nil
		}
		if _, err := tx.Exec(`UPDATE chat_projects SET updated_at = ? WHERE id = ?`, now, id); err != nil {
			return w, fmt.Errorf("chatengine: pinning a project source: %w", err)
		}
		w.project = id
		return w, dropSessionsTx(tx, id)
	})
}

// removeSource is ChatProjectQueries.removeSource.
func (e *Engine) removeSource(ctx context.Context, sourceID int64) (projectWrite, error) {
	return e.projectTx(ctx, func(tx *sql.Tx, _ float64) (projectWrite, error) {
		var project int64
		err := tx.QueryRow(`SELECT project_id FROM chat_project_sources WHERE id = ?`, sourceID).Scan(&project)
		if errors.Is(err, sql.ErrNoRows) {
			return projectWrite{}, chatstore.ErrNotFound
		}
		if err != nil {
			return projectWrite{}, fmt.Errorf("chatengine: removing a project source: %w", err)
		}
		if _, err := tx.Exec(`DELETE FROM chat_project_sources WHERE id = ?`, sourceID); err != nil {
			return projectWrite{}, fmt.Errorf("chatengine: removing a project source: %w", err)
		}
		return projectWrite{project: project}, dropSessionsTx(tx, project)
	})
}

// addProjectFile is ChatAttachmentStore.importFile(url:projectID:): the file
// the app holds at path, validated and stored under the project's folder.
func (e *Engine) addProjectFile(ctx context.Context, project int64, path string) (projectWrite, error) {
	name, data, err := readAttachable(path)
	if err != nil {
		return projectWrite{}, err
	}
	kind, rej := chatstore.ValidateAttachment(data, name)
	if rej != nil {
		return projectWrite{}, &AttachError{Rejection: rej}
	}
	id, err := chatstore.SaveProjectAttachment(ctx, e.c.DB, e.c.FilesDir, project, name, kind, data, seconds(e.c.Clock()))
	if err != nil {
		return projectWrite{}, err
	}
	return projectWrite{id: id, project: project}, nil
}

// removeProjectFile is ChatProjectQueries.removeFile: the row, and its file
// once no other row points at it.
func (e *Engine) removeProjectFile(ctx context.Context, fileID int64) (projectWrite, error) {
	return e.projectTx(ctx, func(tx *sql.Tx, _ float64) (projectWrite, error) {
		var (
			path    string
			project int64
		)
		err := tx.QueryRow(`SELECT path, project_id FROM chat_attachments WHERE id = ? AND project_id IS NOT NULL`, fileID).
			Scan(&path, &project)
		if errors.Is(err, sql.ErrNoRows) {
			return projectWrite{}, chatstore.ErrNotFound
		}
		if err != nil {
			return projectWrite{}, fmt.Errorf("chatengine: removing a project file: %w", err)
		}
		if _, err := tx.Exec(`DELETE FROM chat_attachments WHERE id = ?`, fileID); err != nil {
			return projectWrite{}, fmt.Errorf("chatengine: removing a project file: %w", err)
		}
		w := projectWrite{project: project}
		var n int
		if err := tx.QueryRow(`SELECT COUNT(*) FROM chat_attachments WHERE path = ?`, path).Scan(&n); err != nil {
			return w, fmt.Errorf("chatengine: removing a project file: %w", err)
		}
		if n == 0 {
			w.orphans = []string{path}
		}
		return w, dropSessionsTx(tx, project)
	})
}

// dropSessionsTx is ChatProjectQueries.dropSessions.
func dropSessionsTx(tx *sql.Tx, project int64) error {
	if _, err := tx.Exec(`UPDATE chat_conversations SET session_id = NULL WHERE project_id = ?`, project); err != nil {
		return fmt.Errorf("chatengine: dropping project sessions: %w", err)
	}
	return nil
}

func requireProject(tx *sql.Tx, id int64) error {
	var one int
	err := tx.QueryRow(`SELECT 1 FROM chat_projects WHERE id = ?`, id).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return chatstore.ErrProjectGone
	}
	if err != nil {
		return fmt.Errorf("chatengine: reading a chat project: %w", err)
	}
	return nil
}

// requireRow is an UPDATE's error, ErrProjectGone when it touched nothing.
func requireRow(res sql.Result, err error) error {
	if err != nil {
		return fmt.Errorf("chatengine: chat project write: %w", err)
	}
	if n, err := res.RowsAffected(); err != nil || n == 0 {
		return chatstore.ErrProjectGone
	}
	return nil
}

func strs(tx *sql.Tx, q string, args ...any) ([]string, error) {
	rs, err := tx.Query(q, args...)
	if err != nil {
		return nil, fmt.Errorf("chatengine: %w", err)
	}
	defer rs.Close()
	var out []string
	for rs.Next() {
		var s string
		if err := rs.Scan(&s); err != nil {
			return nil, fmt.Errorf("chatengine: %w", err)
		}
		out = append(out, s)
	}
	return out, rs.Err()
}

func ids(tx *sql.Tx, q string, args ...any) ([]int64, error) {
	rs, err := tx.Query(q, args...)
	if err != nil {
		return nil, fmt.Errorf("chatengine: %w", err)
	}
	defer rs.Close()
	var out []int64
	for rs.Next() {
		var id int64
		if err := rs.Scan(&id); err != nil {
			return nil, fmt.Errorf("chatengine: %w", err)
		}
		out = append(out, id)
	}
	return out, rs.Err()
}
