package kb

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"os"
	oexec "os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/gitbin"
	"watchtower/internal/workbenchdocs"
)

// fixtureWorkbenchID is the workbench seedWorkbenchDocs creates (the first row).
const fixtureWorkbenchID = 1

const (
	fixturePlanRef   = "wbdoc:1:docs/plans/rollout.md"
	fixtureReadmeRef = "wbdoc:1:README.md"
)

// seedWorkbenchDocs creates a workbench whose folder holds two text files —
// a plan with headings and a README — and a file that is no text document.
// Nothing is attached: the folder's files are the workbench's documents.
func seedWorkbenchDocs(t *testing.T, d *db.DB) string {
	t.Helper()
	folder := t.TempDir()
	writeWorkbenchFile(t, folder, "docs/plans/rollout.md", "# Rollout plan\nIntro text.\n## Phase 1\nРоадмап первой фазы.\n```\n# not a heading\n```\n")
	writeWorkbenchFile(t, folder, "README.md", "Readme without headings, rollout notes.\n")
	writeWorkbenchFile(t, folder, "main.go", "package main // роадмап\n")
	exec(t, d, `INSERT INTO projects (id, name, folder_path) VALUES (?, 'acme', ?)`, fixtureWorkbenchID, folder)
	return folder
}

func writeWorkbenchFile(t *testing.T, folder, rel, text string) {
	t.Helper()
	path := filepath.Join(folder, rel)
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o755))
	require.NoError(t, os.WriteFile(path, []byte(text), 0o600))
}

func buildWorkbenchDoc(t *testing.T, d *db.DB, key string) *Doc {
	t.Helper()
	doc, err := newWorkbenchDocSource().Build(context.Background(), d, key)
	require.NoError(t, err)
	return doc
}

func TestWorkbenchDoc_RendersSectionsAtHeadings(t *testing.T) {
	d := db.OpenTestDB(t)
	folder := seedWorkbenchDocs(t, d)
	doc := buildWorkbenchDoc(t, d, fixturePlanRef)
	require.NotNil(t, doc)
	assert.Equal(t, "docs/plans/rollout.md", doc.Title, "a file is titled by its path")
	assert.Equal(t, map[string]string{"project_id": "1", "rel_path": "docs/plans/rollout.md"}, doc.Anchor)
	assert.Equal(t, "file://"+filepath.Join(folder, "docs/plans/rollout.md"), doc.Link)
	require.Len(t, doc.Sections, 2, "the fenced # line is not a heading")
	assert.Equal(t, "Rollout plan", doc.Sections[0].Anchor)
	assert.Equal(t, "Phase 1", doc.Sections[1].Anchor)
	assert.Contains(t, doc.Sections[1].Text, "# not a heading")

	readme := buildWorkbenchDoc(t, d, fixtureReadmeRef)
	require.Len(t, readme.Sections, 1)
	assert.Empty(t, readme.Sections[0].Anchor)

	for _, key := range []string{"wbdoc:1:gone.md", "wbdoc:99:README.md", "wbdoc:x:README.md", "wbdoc:1", "project_doc:1"} {
		assert.Nil(t, buildWorkbenchDoc(t, d, key), key)
	}
}

// A symlink leading out of the folder or a named pipe is indexed by its
// path only — never read, never blocking — and the anchor says why the
// text is missing. A file that is gone has no document at all.
func TestWorkbenchDoc_UnreadableFilesArePathOnlyAndSaySo(t *testing.T) {
	d := db.OpenTestDB(t)
	folder := seedWorkbenchDocs(t, d)
	readme := filepath.Join(folder, "README.md")
	outside := t.TempDir()
	writeWorkbenchFile(t, outside, "secret.md", "top secret")

	for _, tc := range []struct {
		name, reason string
		setup        func()
	}{
		{"escaping symlink", "no longer inside the workbench folder", func() {
			require.NoError(t, os.Symlink(filepath.Join(outside, "secret.md"), readme))
		}},
		{"named pipe", "not a regular file", func() { require.NoError(t, syscall.Mkfifo(readme, 0o600)) }},
	} {
		require.NoError(t, os.RemoveAll(readme))
		tc.setup()
		doc := buildWithin(t, d, fixtureReadmeRef)
		require.NotNil(t, doc, tc.name)
		assert.Equal(t, "README.md", doc.Title, tc.name)
		assert.Empty(t, doc.Sections, tc.name)
		assert.Equal(t, tc.reason, doc.Anchor["unreadable"], tc.name)
	}
	require.NoError(t, os.RemoveAll(readme))
	assert.Nil(t, buildWorkbenchDoc(t, d, fixtureReadmeRef), "gone: no document")
}

// buildWithin builds key, failing the test instead of hanging when the
// render blocks (a named pipe opened for reading waits for a writer).
func buildWithin(t *testing.T, d *db.DB, key string) *Doc {
	t.Helper()
	done := make(chan *Doc, 1)
	go func() {
		doc, err := newWorkbenchDocSource().Build(context.Background(), d, key)
		if err != nil {
			doc = nil
		}
		done <- doc
	}()
	select {
	case doc := <-done:
		return doc
	case <-time.After(5 * time.Second):
		t.Fatal("the render blocked")
		return nil
	}
}

// One byte over 2 MiB is cut and says so; exactly 2 MiB is not.
func TestWorkbenchDoc_LongFileIsCutAndSaysSo(t *testing.T) {
	d := db.OpenTestDB(t)
	folder := seedWorkbenchDocs(t, d)
	writeWorkbenchFile(t, folder, "README.md", strings.Repeat("a", fileSetMaxBytes))
	assert.NotContains(t, buildWorkbenchDoc(t, d, fixtureReadmeRef).Anchor, "truncated")

	writeWorkbenchFile(t, folder, "README.md", strings.Repeat("a", fileSetMaxBytes+1))
	doc := buildWorkbenchDoc(t, d, fixtureReadmeRef)
	assert.Equal(t, "indexed up to 2 MiB", doc.Anchor["truncated"])

	writeWorkbenchFile(t, folder, "README.md", strings.Repeat("я", fileSetMaxBytes)) // 2 bytes a rune: twice the cap
	doc = buildWorkbenchDoc(t, d, fixtureReadmeRef)
	require.NotEmpty(t, doc.Sections)
	assert.Equal(t, fileSetMaxBytes/2, len([]rune(doc.Sections[0].Text))-1, "cut at the cap, on a rune boundary")
}

func runWorkbenchDocs(t *testing.T, d *db.DB) Stats {
	t.Helper()
	st, err := Run(context.Background(), d, Options{Sources: []string{WorkbenchDocSource}, Now: time.Now()})
	require.NoError(t, err)
	return st
}

func indexedText(t *testing.T, d *db.DB, id string) string {
	t.Helper()
	var text string
	require.NoError(t, d.QueryRow(`SELECT COALESCE(group_concat(body, ' '), '') FROM kb_chunks WHERE doc_id = ?`, id).Scan(&text))
	return text
}

func indexedIDs(t *testing.T, d *db.DB) []string {
	t.Helper()
	ids, err := queryStrings(context.Background(), d, `SELECT id FROM kb_documents WHERE source = ? ORDER BY id`, WorkbenchDocSource)
	require.NoError(t, err)
	return ids
}

// A revision is re-indexed whatever its mtime — a later one, or an older one
// (cp -p, a sync client); an untouched file is never re-read into a write; a
// file removed from disk leaves the index, and comes back with its text.
func TestWorkbenchDoc_ReindexesOnRevision(t *testing.T) {
	d := db.OpenTestDB(t)
	folder := seedWorkbenchDocs(t, d)
	readme := filepath.Join(folder, "README.md")
	assert.Equal(t, 2, runWorkbenchDocs(t, d).Written, "the two text files, not main.go")
	assert.Equal(t, []string{fixtureReadmeRef, fixturePlanRef}, indexedIDs(t, d))
	assert.Zero(t, runWorkbenchDocs(t, d).Written, "nothing changed: no write")

	writeWorkbenchFile(t, folder, "README.md", "Readme rewritten: квартальный отчёт.\n")
	later := time.Now().Add(time.Hour)
	require.NoError(t, os.Chtimes(readme, later, later))
	assert.Equal(t, 1, runWorkbenchDocs(t, d).Written)
	assert.Contains(t, indexedText(t, d, fixtureReadmeRef), "квартальный")

	writeWorkbenchFile(t, folder, "README.md", "Readme restored from a backup: годовой отчёт.\n")
	older := time.Now().Add(-48 * time.Hour)
	require.NoError(t, os.Chtimes(readme, older, older))
	assert.Equal(t, 1, runWorkbenchDocs(t, d).Written, "an edit with an older mtime is a revision too")
	assert.Contains(t, indexedText(t, d, fixtureReadmeRef), "годовой")

	require.NoError(t, os.Rename(readme, filepath.Join(folder, "README.bak")))
	assert.Equal(t, 1, runWorkbenchDocs(t, d).Deleted, "removed from disk: the entry leaves")
	assert.Equal(t, []string{fixturePlanRef}, indexedIDs(t, d))
	require.NoError(t, os.Rename(filepath.Join(folder, "README.bak"), readme)) // back with its old mtime
	runWorkbenchDocs(t, d)
	assert.Contains(t, indexedText(t, d, fixtureReadmeRef), "годовой", "back: its text is indexed again")

	writeWorkbenchFile(t, folder, "notes/new.txt", "свежая заметка\n")
	assert.Equal(t, 1, runWorkbenchDocs(t, d).Written, "a new file is indexed on the next pass")
}

// Entries keyed by attached document (before 2026-10-03) leave the index on
// the first pass; the folder's files take their place.
func TestWorkbenchDoc_AttachedDocumentKeysLeave(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedWorkbenchDocs(t, d)
	err := withTx(ctx, d, func(tx *sql.Tx) error {
		_, err := writeDoc(ctx, tx, &Doc{ID: "project_doc:7", Source: WorkbenchDocSource, Title: "old",
			Anchor: map[string]string{"project_id": "1", "document_id": "7"}})
		return err
	})
	require.NoError(t, err)
	runWorkbenchDocs(t, d)
	assert.Equal(t, []string{fixtureReadmeRef, fixturePlanRef}, indexedIDs(t, d))
}

// gitIn runs git in dir for the test's own setup, with the owner's git
// configuration kept out (or skips the test without git).
func gitIn(t *testing.T, dir string, args ...string) {
	t.Helper()
	bin, ok := gitbin.Locate()
	if !ok {
		t.Skip("git is not available")
	}
	t.Setenv("GIT_CONFIG_GLOBAL", os.DevNull)
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	c := oexec.Command(bin, args...)
	c.Dir = dir
	out, err := c.CombinedOutput()
	require.NoError(t, err, "git %s: %s", strings.Join(args, " "), out)
}

// In a git repository the documents are the text files git does not ignore:
// a tracked .md and an untracked .txt are indexed; an ignored .md and a file
// in an ignored .claude/worktrees are not. A file ignored later leaves.
func TestWorkbenchDoc_GitIgnoredFilesAreNotIndexed(t *testing.T) {
	d := db.OpenTestDB(t)
	folder := t.TempDir()
	gitIn(t, folder, "init", "-q")
	writeWorkbenchFile(t, folder, ".gitignore", "build/\n.claude/worktrees/\n")
	writeWorkbenchFile(t, folder, "docs/spec.md", "# Spec\nтрекнутая спека\n")
	gitIn(t, folder, "add", ".gitignore", "docs/spec.md")
	writeWorkbenchFile(t, folder, "notes.txt", "неотслеженные заметки\n")
	writeWorkbenchFile(t, folder, "build/out.md", "игнорируемый вывод\n")
	writeWorkbenchFile(t, folder, ".claude/worktrees/x/a.md", "копия другого дерева\n")
	exec(t, d, `INSERT INTO projects (id, name, folder_path) VALUES (1, 'acme', ?)`, folder)

	runWorkbenchDocs(t, d)
	assert.Equal(t, []string{"wbdoc:1:docs/spec.md", "wbdoc:1:notes.txt"}, indexedIDs(t, d))

	writeWorkbenchFile(t, folder, ".gitignore", "build/\n.claude/worktrees/\nnotes.txt\n")
	assert.Equal(t, 1, runWorkbenchDocs(t, d).Deleted, "a newly ignored file loses its entry")
	assert.Equal(t, []string{"wbdoc:1:docs/spec.md"}, indexedIDs(t, d))
}

// Outside git the walk skips node_modules and .git and never follows a
// symlink out of the folder.
func TestWorkbenchDoc_WalkSkipsHiddenNamesAndOutsideLinks(t *testing.T) {
	d := db.OpenTestDB(t)
	folder := seedWorkbenchDocs(t, d)
	writeWorkbenchFile(t, folder, "node_modules/pkg/README.md", "роадмап зависимости\n")
	writeWorkbenchFile(t, folder, "vendor/x/.git/notes.md", "роадмап вложенного клона\n")
	outside := t.TempDir()
	writeWorkbenchFile(t, outside, "secret.md", "роадмап снаружи\n")
	require.NoError(t, os.Symlink(outside, filepath.Join(folder, "linked")))

	runWorkbenchDocs(t, d)
	assert.Equal(t, []string{fixtureReadmeRef, fixturePlanRef}, indexedIDs(t, d))
}

// Past 2000 files the newest are indexed and the cut is logged.
func TestWorkbenchDoc_IndexesTheNewest2000(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	folder := t.TempDir()
	base := time.Now().Add(-time.Hour)
	for i := range workbenchdocs.MaxTextFiles + 1 {
		rel := fmt.Sprintf("n%04d.md", i)
		writeWorkbenchFile(t, folder, rel, "x")
		at := base.Add(time.Duration(i) * time.Second)
		require.NoError(t, os.Chtimes(filepath.Join(folder, rel), at, at))
	}
	exec(t, d, `INSERT INTO projects (id, name, folder_path) VALUES (1, 'acme', ?)`, folder)
	var logged bytes.Buffer
	log.SetOutput(&logged)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })

	documents, changed, err := IndexWorkbenchDocs(ctx, d, 1)
	require.NoError(t, err)
	assert.Equal(t, 2000, documents)
	assert.Equal(t, 2000, changed)
	assert.Len(t, indexedIDs(t, d), 2000)
	assert.NotContains(t, indexedIDs(t, d), "wbdoc:1:n0000.md", "the oldest is cut")
	assert.Contains(t, logged.String(), "2001 text files")
}

// A failing git run is an error for the pass, never an empty listing: the
// workbench's entries stay — on an explicit trigger and on the daemon pass.
func TestWorkbenchDoc_FailingGitKeepsTheEntries(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	folder := t.TempDir()
	gitIn(t, folder, "init", "-q")
	writeWorkbenchFile(t, folder, "plan.md", "# Plan\nКанареечный выкат\n")
	exec(t, d, `INSERT INTO projects (id, name, folder_path) VALUES (1, 'acme', ?)`, folder)
	_, _, err := IndexWorkbenchDocs(ctx, d, 1)
	require.NoError(t, err)
	require.Equal(t, []string{"wbdoc:1:plan.md"}, indexedIDs(t, d))

	fake := filepath.Join(t.TempDir(), "git")
	require.NoError(t, os.WriteFile(fake, []byte("#!/bin/sh\nexit 1\n"), 0o755))
	broken := workbenchdocs.Lister{Locate: func() (string, bool) { return fake, true }}.List
	require.NoError(t, os.Remove(filepath.Join(folder, "plan.md")))

	_, _, err = indexWorkbenchDocs(ctx, d, 1, broken)
	require.Error(t, err)
	assert.Equal(t, []string{"wbdoc:1:plan.md"}, indexedIDs(t, d), "the explicit trigger kept the entry")

	var logged bytes.Buffer
	log.SetOutput(&logged)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })
	r := runner{sources: func() []Source { return []Source{&workbenchDocSource{list: broken}} }, clock: time.Now}
	_, err = r.run(ctx, d, Options{Now: time.Now()})
	require.NoError(t, err, "one workbench's listing never fails the source")
	assert.Equal(t, []string{"wbdoc:1:plan.md"}, indexedIDs(t, d), "the daemon pass kept the entry")
	assert.Contains(t, logged.String(), "kb: listing workbench 1 documents")
	assert.Equal(t, 1, strings.Count(logged.String(), "kb: listing"), "listed once per run: Changed and Keys share it")
}

// The daemon never reads a folder macOS guards (~/Documents and the like):
// a background read could raise a privacy prompt. An explicit trigger
// (IndexWorkbenchDocs) indexes it, and drops what the folder no longer has;
// the daemon's pass keeps what the trigger indexed.
func TestWorkbenchDoc_DaemonSkipsProtectedFoldersExplicitIndexDoesNot(t *testing.T) {
	ctx := context.Background()
	home := t.TempDir()
	t.Setenv("HOME", home)
	d := db.OpenTestDB(t)
	folder := filepath.Join(home, "Documents", "acme")
	writeWorkbenchFile(t, folder, "plan.md", "# Plan\nКанареечный выкат\n")
	writeWorkbenchFile(t, folder, "gone.md", "скоро удалят\n")
	exec(t, d, `INSERT INTO projects (id, name, folder_path) VALUES (1, 'acme', ?)`, folder)
	other := t.TempDir()
	writeWorkbenchFile(t, other, "b.md", "beta")
	exec(t, d, `INSERT INTO projects (id, name, folder_path) VALUES (2, 'beta', ?)`, other)

	runWorkbenchDocs(t, d)
	assert.Empty(t, indexedText(t, d, "wbdoc:1:plan.md"), "the daemon did not read the protected folder")
	assert.Contains(t, indexedText(t, d, "wbdoc:2:b.md"), "beta")

	documents, changed, err := IndexWorkbenchDocs(ctx, d, 1)
	require.NoError(t, err)
	assert.Equal(t, 2, documents)
	assert.Equal(t, 2, changed)
	assert.Contains(t, indexedText(t, d, "wbdoc:1:plan.md"), "Канареечный")

	runWorkbenchDocs(t, d)
	assert.Contains(t, indexedText(t, d, "wbdoc:1:plan.md"), "Канареечный", "the daemon keeps what the trigger indexed")

	require.NoError(t, os.Remove(filepath.Join(folder, "gone.md")))
	_, changed, err = IndexWorkbenchDocs(ctx, d, 1)
	require.NoError(t, err)
	assert.Equal(t, 1, changed, "the removed file left the index")
	assert.Empty(t, indexedText(t, d, "wbdoc:1:gone.md"))
	assert.Contains(t, indexedText(t, d, "wbdoc:2:b.md"), "beta", "another workbench's entries are untouched")
}

func TestIndexWorkbenchDocs_UnknownWorkbenchIsAnError(t *testing.T) {
	d := db.OpenTestDB(t)
	_, _, err := IndexWorkbenchDocs(context.Background(), d, 42)
	require.Error(t, err)
	assert.True(t, errors.Is(err, sql.ErrNoRows), err.Error())
}

// A document symlinked into a guarded location is refused before the
// target is touched: the target's directory here cannot even be searched,
// so following the link would fail differently.
func TestWorkbenchDoc_SymlinkOutOfTheFolderIsNeverFollowed(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	guarded := filepath.Join(home, "Documents")
	writeWorkbenchFile(t, guarded, "x.md", "private")
	require.NoError(t, os.Chmod(guarded, 0o000))
	t.Cleanup(func() { _ = os.Chmod(guarded, 0o755) })
	folder := t.TempDir()
	realFolder, err := filepath.EvalSymlinks(folder)
	require.NoError(t, err)
	require.NoError(t, os.MkdirAll(filepath.Join(folder, "docs"), 0o755))
	require.NoError(t, os.Symlink(filepath.Join(guarded, "x.md"), filepath.Join(folder, "docs", "x.md")))
	require.NoError(t, os.Symlink(guarded, filepath.Join(folder, "linked")))
	require.NoError(t, os.Symlink("../docs/inner.md", filepath.Join(folder, "docs", "rel.md")))
	writeWorkbenchFile(t, folder, "docs/inner.md", "inside")

	for _, rel := range []string{"docs/x.md", "linked/x.md", "../outside.md"} {
		_, err := resolveInside(realFolder, rel)
		assert.ErrorIs(t, err, errDocOutside, rel)
	}
	got, err := resolveInside(realFolder, "docs/rel.md")
	require.NoError(t, err, "a link that stays inside is followed")
	assert.Equal(t, filepath.Join(realFolder, "docs", "inner.md"), got)
}

func TestPrivacyProtected(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	protected := []string{
		filepath.Join(home, "Documents", "acme"),
		filepath.Join(home, "documents", "acme"), // APFS ignores case
		filepath.Join(home, "Library", "CloudStorage", "x", "y"),
		filepath.Join(home, "Library", "Mobile Documents", "a"),
		"/Volumes/USB/acme",
	}
	for _, folder := range protected {
		assert.True(t, privacyProtected(folder), folder)
	}
	for _, folder := range []string{filepath.Join(home, "Code", "acme"), filepath.Join(home, "DocumentsArchive")} {
		assert.False(t, privacyProtected(folder), folder)
	}
}

// kb reindex (owner-started) loses nothing an explicit trigger indexed in a
// guarded folder the daemon skips.
func TestReindex_KeepsProtectedWorkbenchDocs(t *testing.T) {
	ctx := context.Background()
	home := t.TempDir()
	t.Setenv("HOME", home)
	d := db.OpenTestDB(t)
	folder := filepath.Join(home, "Documents", "acme")
	writeWorkbenchFile(t, folder, "plan.md", "# Plan\nКанареечный выкат\n")
	exec(t, d, `INSERT INTO projects (id, name, folder_path) VALUES (1, 'acme', ?)`, folder)
	_, _, err := IndexWorkbenchDocs(ctx, d, 1)
	require.NoError(t, err)

	_, err = Reindex(ctx, d, []string{WorkbenchDocSource}, time.Now())
	require.NoError(t, err)
	assert.Contains(t, indexedText(t, d, "wbdoc:1:plan.md"), "Канареечный")
}

// TestProj08_FolderFilesOnlyInTheirOwnWorkbenchSession (was
// ProjectDocsOnlyInTheirOwnProjectSession; PROJ-08 amended 2026-10-03): a
// workbench folder's files — none of them attached — never reach a search
// or an open that is not their own workbench's session: not the main chat,
// the Discuss chats, the CLI or another workbench.
func TestProj08_FolderFilesOnlyInTheirOwnWorkbenchSession(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedWorkbenchDocs(t, d)
	other := t.TempDir()
	writeWorkbenchFile(t, other, "plan.md", "# Other\nроадмап другого проекта\n")
	exec(t, d, `INSERT INTO projects (id, name, folder_path) VALUES (2, 'beta', ?)`, other)
	_, err := Run(ctx, d, Options{Now: testNow()})
	require.NoError(t, err)

	search := func(projectID int64, sources ...string) []string {
		res, err := Search(ctx, d, Request{Queries: []string{"роадмап"}, Sources: sources, WorkbenchID: projectID, Limit: MaxLimit, Now: testNow()})
		require.NoError(t, err)
		return hitRefs(res)
	}
	assert.Empty(t, search(0), "a non-workbench search sees no workbench document")
	assert.Empty(t, search(0, WorkbenchDocSource), "not even when it asks for the source")
	assert.Equal(t, []string{fixturePlanRef}, search(1))
	assert.Equal(t, []string{"wbdoc:2:plan.md"}, search(2), "another workbench sees only its own")

	for _, tc := range []struct {
		projectID int64
		ref       string
		visible   bool
	}{{0, fixturePlanRef, false}, {2, fixturePlanRef, false}, {1, fixturePlanRef, true}, {2, "wbdoc:2:plan.md", true}} {
		_, err := GetDocument(ctx, d, tc.ref, DocOptions{WorkbenchID: tc.projectID})
		if tc.visible {
			assert.NoError(t, err, "%s from workbench %d", tc.ref, tc.projectID)
		} else {
			assert.ErrorIs(t, err, ErrNotFound, "%s from workbench %d", tc.ref, tc.projectID)
		}
	}
}
