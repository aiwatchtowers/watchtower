package tools

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/specreview"
)

// TestDocPathRelativeResolvesInTheCallersFolder (spec §6.11): a relative
// doc_path is read in the filing session's folder; the ask stores that
// folder's id and the path relative to it — never <folder>/<rel> — and the
// document is indexed under that folder, so the same relative path in two
// folders makes two index entries.
func TestDocPathRelativeResolvesInTheCallersFolder(t *testing.T) {
	ctx := context.Background()
	fx := newWorkbenchFixture(t)
	hubPath, hub := putFolderOnBench(t, fx.d, fx.a, "hub", 1)
	require.NoError(t, os.MkdirAll(filepath.Join(hubPath, "docs"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(hubPath, "docs", "spec.md"), []byte("# Hub spec\n"), 0o644))
	writeWorkbenchFile(t, fx.d, fx.a, "docs/spec.md", "# Home spec\n")
	home, err := fx.d.HomeFolder(ctx, fx.a)
	require.NoError(t, err)

	hubSession := folderSession(t, fx.d, fx.a, hub, hubPath, 0)
	out := mustApply(t, askRegistry(t, fx.d, strconv.FormatInt(hubSession, 10)), fx.a, "ask_owner",
		`{"kind":"review","title":"Hub spec","doc_path":"docs/spec.md","reason":"r"}`)
	a := storedAsk(t, fx.d, fx.a, askID(t, out))
	assert.Equal(t, "docs/spec.md", a.DocPath, "relative to its folder, no folder name")
	assert.Equal(t, sql.NullInt64{Int64: hub, Valid: true}, a.DocFolderID)
	assert.Equal(t, "# Hub spec\n", a.DocSnapshot)

	mustApply(t, askRegistry(t, fx.d, ""), fx.a, "ask_owner",
		`{"kind":"review","title":"Home spec","doc_path":"docs/spec.md","reason":"r"}`)

	var ids []string
	rows, err := fx.d.Query(`SELECT id FROM kb_documents WHERE source = 'project_doc' ORDER BY id`)
	require.NoError(t, err)
	defer rows.Close()
	for rows.Next() {
		var id string
		require.NoError(t, rows.Scan(&id))
		ids = append(ids, id)
	}
	require.NoError(t, rows.Err())
	assert.ElementsMatch(t, []string{
		fmt.Sprintf("wbdoc:%d:%d:docs/spec.md", fx.a, home.ID),
		fmt.Sprintf("wbdoc:%d:%d:docs/spec.md", fx.a, hub),
	}, ids, "one entry per folder")
}

// TestDocPathOfAnOldAskResolvesInTheHomeFolder (spec §4 item 9): an ask
// filed before folders (doc_folder_id NULL) reads its doc_path in the home
// folder, whatever other folders the bench has since.
func TestDocPathOfAnOldAskResolvesInTheHomeFolder(t *testing.T) {
	ctx := context.Background()
	fx := newWorkbenchFixture(t)
	putFolderOnBench(t, fx.d, fx.a, "hub", 1)
	home, err := fx.d.HomeFolder(ctx, fx.a)
	require.NoError(t, err)
	got, err := specreview.ReadFolder(ctx, fx.d, &db.OwnerAsk{WorkbenchID: fx.a, Kind: "review", DocPath: "docs/spec.md"})
	require.NoError(t, err)
	assert.Equal(t, home.FolderPath, got)
}

// TestDocPathAbsoluteOutsideTheBenchIsRefused (spec §6.11): an absolute
// doc_path must lie in a live folder of the bench — another bench's folder,
// a folder that left the bench, or any other path is refused.
func TestDocPathAbsoluteOutsideTheBenchIsRefused(t *testing.T) {
	ctx := context.Background()
	fx := newWorkbenchFixture(t)
	reg := askRegistry(t, fx.d, "")
	writeWorkbenchFile(t, fx.d, fx.b, "spec.md", "# Beta\n")
	beta, err := fx.d.GetWorkbench(fx.b)
	require.NoError(t, err)
	gonePath, gone := putFolderOnBench(t, fx.d, fx.a, "gone", 1)
	require.NoError(t, os.WriteFile(filepath.Join(gonePath, "spec.md"), []byte("# Gone\n"), 0o644))
	_, err = fx.d.ExecContext(ctx, `UPDATE workbench_folders SET removed_at = '2026-11-18T00:00:00Z' WHERE id = ?`, gone)
	require.NoError(t, err)
	outside := filepath.Join(t.TempDir(), "spec.md")
	require.NoError(t, os.WriteFile(outside, []byte("# Out\n"), 0o644))

	for name, path := range map[string]string{
		"another bench's folder": filepath.Join(beta.FolderPath, "spec.md"),
		"a removed folder":       filepath.Join(gonePath, "spec.md"),
		"outside every folder":   outside,
	} {
		_, err := proposeIn(t, reg, fx.a, "ask_owner",
			fmt.Sprintf(`{"kind":"review","title":"Review","doc_path":%q,"reason":"r"}`, path))
		assert.Contains(t, refusal(t, err), "is not in a folder of this workbench", name)
	}
	var n int
	require.NoError(t, fx.d.QueryRow(`SELECT COUNT(*) FROM owner_asks`).Scan(&n))
	assert.Zero(t, n)
}
