package mcp

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

// newSkillsSession wires an in-memory MCP client to a server that knows a
// skills directory. The connection is read-only like production: load_skill
// never touches the database at all.
func newSkillsSession(t *testing.T, database *db.DB, skillsDir string) *mcpsdk.ClientSession {
	t.Helper()
	if err := database.SetReadOnly(); err != nil {
		t.Fatalf("setting read-only: %v", err)
	}
	ctx := context.Background()
	srv := NewServer(database, WithSkillsDir(skillsDir))
	client := mcpsdk.NewClient(&mcpsdk.Implementation{Name: "test", Version: "v0"}, nil)
	st, ct := mcpsdk.NewInMemoryTransports()
	if _, err := srv.s.Connect(ctx, st, nil); err != nil {
		t.Fatalf("server connect: %v", err)
	}
	cs, err := client.Connect(ctx, ct, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	t.Cleanup(func() { _ = cs.Close() })
	return cs
}

// seedSkillsDir writes a small catalog: one enabled secretary skill and one
// disabled one.
func seedSkillsDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	files := map[string]string{
		"status-update.md": "---\ndescription: Draft a status update.\npersona: secretary\n---\n" +
			"# Draft a status update\n\nAsk the owner what it should say.\n",
		"quiet-skill.md": "---\ndescription: Switched off.\npersona: assistant\nenabled: false\n---\n" +
			"# Quiet\n\nBody.\n",
	}
	for name, content := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
			t.Fatalf("writing %s: %v", name, err)
		}
	}
	return dir
}

// callLoadSkill runs the tool and returns the result.
func callLoadSkill(t *testing.T, cs *mcpsdk.ClientSession, args map[string]any) *mcpsdk.CallToolResult {
	t.Helper()
	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name: "load_skill", Arguments: args,
	})
	if err != nil {
		t.Fatalf("call load_skill: %v", err)
	}
	return res
}

func TestLoadSkillHappyPath(t *testing.T) {
	cs := newSkillsSession(t, seedDB(t), seedSkillsDir(t))

	res := callLoadSkill(t, cs, map[string]any{"name": "status-update"})
	if res.IsError {
		t.Fatalf("unexpected error result: %s", textContent(t, res))
	}
	var got struct {
		Name        string `json:"name"`
		Description string `json:"description"`
		Persona     string `json:"persona"`
		Enabled     bool   `json:"enabled"`
		Body        string `json:"body"`
	}
	if err := json.Unmarshal([]byte(textContent(t, res)), &got); err != nil {
		t.Fatalf("decoding result: %v", err)
	}
	if got.Name != "status-update" || got.Persona != "secretary" || !got.Enabled {
		t.Errorf("unexpected metadata: %+v", got)
	}
	if got.Description != "Draft a status update." {
		t.Errorf("description = %q", got.Description)
	}
	if !strings.Contains(got.Body, "Ask the owner what it should say.") {
		t.Errorf("body does not carry the instructions: %q", got.Body)
	}
	if strings.Contains(got.Body, "persona:") {
		t.Errorf("body must not include the frontmatter block: %q", got.Body)
	}
}

// TestLoadSkillDisabledStillLoads: the enable toggle gates what the SKILLS
// block lists, not what a read returns — a model holding a stale list must get
// the instructions, not a confusing error.
func TestLoadSkillDisabledStillLoads(t *testing.T) {
	cs := newSkillsSession(t, seedDB(t), seedSkillsDir(t))

	res := callLoadSkill(t, cs, map[string]any{"name": "quiet-skill"})
	if res.IsError {
		t.Fatalf("a disabled skill must still load: %s", textContent(t, res))
	}
	if !strings.Contains(textContent(t, res), `"enabled": false`) {
		t.Errorf("the result must report the skill as disabled: %s", textContent(t, res))
	}
}

func TestLoadSkillUnknownName(t *testing.T) {
	cs := newSkillsSession(t, seedDB(t), seedSkillsDir(t))

	res := callLoadSkill(t, cs, map[string]any{"name": "does-not-exist"})
	if !res.IsError {
		t.Fatalf("expected an error result for an unknown skill")
	}
	if !strings.Contains(textContent(t, res), "no skill named") {
		t.Errorf("unexpected message: %s", textContent(t, res))
	}
}

// TestLoadSkillRejectsTraversal: every name that could escape the skills
// directory is rejected on the name itself. The "../secret" case has a real
// file waiting one level up, so a handler that built the path first would
// return its contents.
func TestLoadSkillRejectsTraversal(t *testing.T) {
	dir := seedSkillsDir(t)
	secret := filepath.Join(filepath.Dir(dir), "secret.md")
	if err := os.WriteFile(secret, []byte("---\ndescription: S.\npersona: secretary\n---\ntop secret\n"), 0o644); err != nil {
		t.Fatalf("writing secret: %v", err)
	}
	cs := newSkillsSession(t, seedDB(t), dir)

	for _, name := range []string{"../secret", "../../etc/passwd", "sub/dir", "Status-Update", "status_update", ".."} {
		res := callLoadSkill(t, cs, map[string]any{"name": name})
		if !res.IsError {
			t.Errorf("load_skill(%q) succeeded: %s", name, textContent(t, res))
			continue
		}
		body := textContent(t, res)
		if !strings.Contains(body, "invalid skill name") {
			t.Errorf("load_skill(%q) = %q, want an invalid-name rejection", name, body)
		}
		if strings.Contains(body, "top secret") {
			t.Errorf("load_skill(%q) leaked a file outside the skills directory", name)
		}
	}
}

func TestLoadSkillMissingName(t *testing.T) {
	cs := newSkillsSession(t, seedDB(t), seedSkillsDir(t))

	res := callLoadSkill(t, cs, map[string]any{"name": "  "})
	if !res.IsError || !strings.Contains(textContent(t, res), "name is required") {
		t.Errorf("expected a name-required error, got %v / %s", res.IsError, textContent(t, res))
	}
}

// TestLoadSkillWithoutSkillsDir: the tool is registered even when no workspace
// was resolved (the tool set must not vary between sessions) and degrades to a
// soft "unavailable" answer.
func TestLoadSkillWithoutSkillsDir(t *testing.T) {
	cs := newTestSession(t, seedDB(t))

	res := callLoadSkill(t, cs, map[string]any{"name": "status-update"})
	if !res.IsError || !strings.Contains(textContent(t, res), "no skills directory is configured") {
		t.Errorf("expected the not-configured answer, got %v / %s", res.IsError, textContent(t, res))
	}
}

// TestLoadSkillMalformedFileIsSoftError: a broken skill file is a skipped
// skill, never a crash and never a half-parsed body.
func TestLoadSkillMalformedFileIsSoftError(t *testing.T) {
	dir := seedSkillsDir(t)
	if err := os.WriteFile(filepath.Join(dir, "broken.md"), []byte("no frontmatter here\n"), 0o644); err != nil {
		t.Fatalf("writing broken skill: %v", err)
	}
	cs := newSkillsSession(t, seedDB(t), dir)

	res := callLoadSkill(t, cs, map[string]any{"name": "broken"})
	if !res.IsError {
		t.Fatalf("expected an error result for a malformed skill file")
	}
	if !strings.Contains(textContent(t, res), "frontmatter") {
		t.Errorf("unexpected message: %s", textContent(t, res))
	}
}
