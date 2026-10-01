-- +goose Up
-- Images attached to project board targets (board target #117): a screenshot
-- the owner pasted into the message a target was born from keeps its
-- context. The file itself is a 0600 copy under
-- <workspace>/project_files/<project_id>/<sha256>.<ext> (outside the project
-- folder, never committed); `path` is that copy's absolute path. One file per
-- project and content, shared by every row naming it; a row is per target and
-- content, so attaching the same image to one target twice is a no-op. The
-- rows go with their project or target (PROJ-02); `project delete` removes the
-- project's file directory, and a target delete or a detach discards the
-- copies no remaining row names. Board-only: no non-board reader touches this
-- table (PROJ-01).
CREATE TABLE project_target_images (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    target_id  INTEGER NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
    file_name  TEXT NOT NULL,
    mime       TEXT NOT NULL CHECK(mime IN ('image/png','image/jpeg','image/gif','image/webp')),
    size       INTEGER NOT NULL,
    sha256     TEXT NOT NULL,
    path       TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    UNIQUE(target_id, sha256)
);
CREATE INDEX IF NOT EXISTS idx_project_target_images_project ON project_target_images(project_id);

-- +goose Down
DROP INDEX IF EXISTS idx_project_target_images_project;
DROP TABLE IF EXISTS project_target_images;
