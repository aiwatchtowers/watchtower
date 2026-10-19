package authoring

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/tools"
)

type fakeWB struct {
	folder string
	err    error
	ids    []int64
}

func (f *fakeWB) Workbench(_ context.Context, id int64) (automations.WorkbenchInfo, error) {
	f.ids = append(f.ids, id)
	if f.err != nil {
		return automations.WorkbenchInfo{}, f.err
	}
	return automations.WorkbenchInfo{ID: id, Folder: f.folder}, nil
}

func writeFile(t *testing.T, path, text string) {
	t.Helper()
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o755))
	require.NoError(t, os.WriteFile(path, []byte(text), 0o644))
}

func skillsFixture(t *testing.T) *fakeWB {
	t.Helper()
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, ".claude/commands/release.md"), "---\ndescription: Release Command\n---\nbody\n")
	writeFile(t, filepath.Join(dir, ".claude/commands/big.md"), strings.Repeat("x", 70*1024))
	writeFile(t, filepath.Join(dir, ".claude/skills/deploy/SKILL.md"), "# Deploy\n\nShips to stage.\n")
	writeFile(t, filepath.Join(dir, ".agents/skills/lint/SKILL.md"), "---\nname: lint\ndescription: Runs lint\n---\n")
	outside := filepath.Join(t.TempDir(), "secret.md")
	writeFile(t, outside, "secret")
	require.NoError(t, os.MkdirAll(filepath.Join(dir, ".claude/skills/evil"), 0o755))
	require.NoError(t, os.Symlink(outside, filepath.Join(dir, ".claude/skills/evil/SKILL.md")))
	return &fakeWB{folder: dir}
}

func runSkills(t *testing.T, wb *fakeWB, args string) (map[string]any, error) {
	t.Helper()
	tool := NewWorkbenchSkills(Deps{Workbench: wb})
	res, err := tool.Execute(context.Background(), nil, tools.Call{Args: json.RawMessage(args)})
	if err != nil {
		return nil, err
	}
	raw, err := json.Marshal(res)
	require.NoError(t, err)
	var out map[string]any
	require.NoError(t, json.Unmarshal(raw, &out))
	return out, nil
}

func TestWorkbenchSkills_ListsCommandsAndSkills(t *testing.T) {
	out, err := runSkills(t, skillsFixture(t), `{"workbench_id":7}`)
	require.NoError(t, err)
	var names []string
	desc := map[string]string{}
	for _, s := range out["skills"].([]any) {
		m := s.(map[string]any)
		names = append(names, m["name"].(string))
		desc[m["name"].(string)] = m["description"].(string)
	}
	assert.Equal(t, []string{"/big", "/release", "deploy", "lint"}, names)
	assert.Equal(t, "Release Command", desc["/release"])
	assert.Equal(t, "Ships to stage.", desc["deploy"])
	assert.Equal(t, "Runs lint", desc["lint"])
}

func TestWorkbenchSkills_ReadsOneByName(t *testing.T) {
	wb := skillsFixture(t)
	out, err := runSkills(t, wb, `{"workbench_id":7,"name":"/release"}`)
	require.NoError(t, err)
	assert.Equal(t, "command", out["kind"])
	assert.Contains(t, out["text"], "Release Command")
	assert.Equal(t, false, out["truncated"])
	out, err = runSkills(t, wb, `{"workbench_id":7,"name":"/big"}`)
	require.NoError(t, err)
	assert.Len(t, out["text"], 65536)
	assert.Equal(t, true, out["truncated"])
	out, err = runSkills(t, wb, `{"workbench_id":7,"name":"deploy"}`)
	require.NoError(t, err)
	assert.Equal(t, "skill", out["kind"])
	_, err = runSkills(t, wb, `{"workbench_id":7,"name":"evil"}`)
	require.Error(t, err)
}

func TestWorkbenchSkills_RefusesPathNames(t *testing.T) {
	wb := skillsFixture(t)
	for _, n := range []string{"../x", "a/b", `a\b`, "/a/b"} {
		_, err := runSkills(t, wb, `{"workbench_id":7,"name":`+mustJSON(n)+`}`)
		var ve *tools.ValidationError
		assert.True(t, errors.As(err, &ve), "name %q", n)
	}
}

func mustJSON(s string) string { b, _ := json.Marshal(s); return string(b) }

func TestWorkbenchSkills_UnknownWorkbench(t *testing.T) {
	_, err := runSkills(t, &fakeWB{err: errors.New("no such workbench")}, `{"workbench_id":9}`)
	require.Error(t, err)
	_, err = runSkills(t, &fakeWB{folder: filepath.Join(t.TempDir(), "gone")}, `{"workbench_id":9}`)
	require.Error(t, err)
	_, err = runSkills(t, skillsFixture(t), `{}`)
	require.Error(t, err)
}

func TestWorkbenchSkills_ResolvesOnlyItsWorkbench(t *testing.T) {
	wb := skillsFixture(t)
	_, err := runSkills(t, wb, `{"workbench_id":7}`)
	require.NoError(t, err)
	assert.Equal(t, []int64{7}, wb.ids)
}
