package chatengine

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestChatengine_PortedProjectWriteCases: the rules the #1170 branch's
// chat.project.* tower commands pinned (chatstore/testdata/chat_writes.json,
// retired when the engine took the main chat's writes) and no engine test
// named: a created project's name is trimmed and a blank one is the default
// name; removing a project file removes that project's row only, never a
// chat's attachment, and drops the project's stored sessions.
func TestChatengine_PortedProjectWriteCases(t *testing.T) {
	g := newRig(t, fakeOpts{})
	ctx := context.Background()

	trimmed := newProject(t, g, "  Alpha  ")
	blank := newProject(t, g, " ")
	var name string
	require.NoError(t, g.d.QueryRow(`SELECT name FROM chat_projects WHERE id = ?`, trimmed).Scan(&name))
	assert.Equal(t, "Alpha", name)
	require.NoError(t, g.d.QueryRow(`SELECT name FROM chat_projects WHERE id = ?`, blank).Scan(&name))
	assert.Equal(t, DefaultProjectName, name)

	_, err := g.d.Exec(`INSERT INTO chat_conversations (id, title, project_id, session_id, created_at, updated_at)
		VALUES (41, 'A', ?, 's1', 1, 1)`, trimmed)
	require.NoError(t, err)
	_, err = g.d.Exec(`INSERT INTO chat_attachments (id, project_id, name, mime, size, path, sha256, created_at)
		VALUES (51, ?, 'a', 'text/plain', 1, '/nonexistent/a.txt', 'h1', 1)`, trimmed)
	require.NoError(t, err)
	_, err = g.d.Exec(`INSERT INTO chat_attachments (id, conversation_id, name, mime, size, path, sha256, created_at)
		VALUES (52, 41, 'b', 'text/plain', 1, '/nonexistent/b.txt', 'h2', 1)`)
	require.NoError(t, err)

	_, err = g.r.ManageProject(ctx, ProjectRequest{Op: ProjectFileRemove, FileID: 52})
	assert.Equal(t, "not_found", ErrorCode(err), "a chat's attachment is no project file")
	_, err = g.r.ManageProject(ctx, ProjectRequest{Op: ProjectFileRemove, FileID: 51})
	require.NoError(t, err)

	var left []int64
	rows, err := g.d.Query(`SELECT id FROM chat_attachments ORDER BY id`)
	require.NoError(t, err)
	for rows.Next() {
		var id int64
		require.NoError(t, rows.Scan(&id))
		left = append(left, id)
	}
	require.NoError(t, rows.Close())
	assert.Equal(t, []int64{52}, left)
	var session *string
	require.NoError(t, g.d.QueryRow(`SELECT session_id FROM chat_conversations WHERE id = 41`).Scan(&session))
	assert.Nil(t, session, "the project's stored sessions are dropped")
}
