package agentlog

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
)

func toolUse(id, name string, input map[string]any) map[string]any {
	return map[string]any{"type": "tool_use", "id": id, "name": name, "input": input}
}

func toolResultLine(t *testing.T, sid, uuid, id, content string, isErr bool, extra map[string]any) string {
	m := map[string]any{"type": "user", "sessionId": sid, "uuid": uuid, "timestamp": "2026-10-01T10:00:03.000Z",
		"message": map[string]any{"role": "user", "content": []map[string]any{{"type": "tool_result", "tool_use_id": id, "content": content, "is_error": isErr}}}}
	for k, v := range extra {
		m[k] = v
	}
	return line(t, m)
}

func TestParseClaude_ToolPairingOutcomesAndTargets(t *testing.T) {
	s := line(t, assistant("s1", "u1", "m1", "r1", 5,
		toolUse("t1", "Bash", map[string]any{"command": "FOO=1 git commit -m SENTINEL-MSG && echo done"}),
		toolUse("t2", "Edit", map[string]any{"file_path": "/w/app/main.go", "old_string": "SENTINEL-OLD"}),
		toolUse("t3", "Read", map[string]any{"file_path": "/etc/hosts"}),
		toolUse("t4", "Bash", map[string]any{"command": "rm -rf build"}),
		toolUse("t5", "Bash", map[string]any{"command": "sleep 100"}))) +
		toolResultLine(t, "s1", "r1", "t1", "Command failed with exit code 1", true, nil) +
		toolResultLine(t, "s1", "r2", "t2", "ok", false, map[string]any{"toolUseResult": map[string]any{
			"structuredPatch": []map[string]any{{"lines": []string{"+a", "+b", "-c", " d"}}}}}) +
		toolResultLine(t, "s1", "r3", "t4", "The user doesn't want to proceed with this tool use.", true, nil) +
		toolResultLine(t, "s1", "r4", "t5", "[Request interrupted by user]", true, map[string]any{"toolUseResult": map[string]any{"interrupted": true}})
	r := parse(t, s, ParseOptions{})
	targets := map[string]string{}
	for _, e := range r.Events {
		if e.Kind == "tool" {
			targets[e.Key] = e.Target
			assert.Equal(t, "pending", e.Outcome)
		}
	}
	assert.Equal(t, map[string]string{"tool:t1": "git commit", "tool:t2": "app/main.go", "tool:t3": "<outside>",
		"tool:t4": "rm", "tool:t5": "sleep"}, targets)
	got := map[string]string{}
	for _, tr := range r.ToolResults {
		got[tr.ToolUseID] = tr.Outcome + "/" + tr.ErrorClass
		if tr.ToolUseID == "t2" {
			assert.Equal(t, 2, tr.LinesAdded)
			assert.Equal(t, 1, tr.LinesRemoved)
		}
	}
	assert.Equal(t, map[string]string{"t1": "error/exit_code", "t2": "ok/", "t4": "denied/", "t5": "interrupted/"}, got)
	b, _ := json.Marshal(r)
	assert.NotContains(t, string(b), "SENTINEL")
}

func TestParseClaude_DenialKindMarksDenied(t *testing.T) {
	s := line(t, assistant("s1", "u1", "m1", "r1", 5, toolUse("t1", "Bash", map[string]any{"command": "make deploy"}))) +
		toolResultLine(t, "s1", "r1", "t1", "denied", true, map[string]any{"toolDenialKind": "automode-unavailable"})
	r := parse(t, s, ParseOptions{})
	assert.Equal(t, "denied", r.ToolResults[0].Outcome)
}

func TestParseClaude_SkillActivations(t *testing.T) {
	s := line(t, map[string]any{"type": "attachment", "sessionId": "s1", "attachment": map[string]any{"type": "skill_listing", "names": []string{"brainstorming", "review"}}}) +
		line(t, map[string]any{"type": "user", "sessionId": "s1", "uuid": "o1", "timestamp": "2026-10-01T09:00:00Z",
			"message": map[string]any{"role": "user", "content": "<command-name>/review</command-name><command-args>SENTINEL</command-args>"}}) +
		line(t, map[string]any{"type": "user", "sessionId": "s1", "uuid": "o2", "timestamp": "2026-10-01T09:00:01Z",
			"message": map[string]any{"role": "user", "content": "<command-name>/clear</command-name>"}}) +
		line(t, assistant("s1", "u1", "m1", "r1", 5,
			toolUse("t1", "Skill", map[string]any{"skill": "superpowers:brainstorming", "args": "SENTINEL"}),
			toolUse("t2", "Read", map[string]any{"file_path": "/h/.claude/skills/pdf/SKILL.md"})))
	r := parse(t, s, ParseOptions{})
	var got []string
	for _, e := range r.Events {
		if e.Kind == "skill" {
			got = append(got, e.Name+"/"+e.Trigger)
		}
	}
	assert.ElementsMatch(t, []string{"review/slash", "superpowers:brainstorming/proactive", "pdf/read"}, got)
}

func TestErrorClass(t *testing.T) {
	assert.Equal(t, "exit_code", errorClass("Exit code 2"))
	assert.Equal(t, "not_found", errorClass("File does not exist."))
	assert.Equal(t, "timeout", errorClass("Command timed out after 2m"))
	assert.Equal(t, "other", errorClass("boom"))
}

func TestShellTarget_ContentSafe(t *testing.T) {
	cases := map[string]string{
		`TOKEN="abc def" git status`: "git status",
		`A='x y' B=2 make test`:      "make test",
		`/usr/bin/git push`:          "git push",
		`git -C d commit`:            "git",
		`"$(evil)" x`:                "",
		`echo SECRET | tee f`:        "echo",
	}
	for in, want := range cases {
		got := shellTarget(in)
		assert.Equal(t, want, got, in)
		for _, bad := range []string{"abc", "def", "SECRET", "x y"} {
			assert.NotContains(t, got, bad)
		}
	}
}

func TestParseClaude_RejectDecisionMarksDenied(t *testing.T) {
	s := line(t, assistant("s1", "u1", "m1", "r1", 5, toolUse("t1", "Bash", map[string]any{"command": "make deploy"}))) +
		toolResultLine(t, "s1", "r1", "t1", "nope", true, map[string]any{"permissionDecision": map[string]any{"decision": "reject"}}) +
		toolResultLine(t, "s1", "r2", "t1", "fine", false, map[string]any{"permissionDecision": map[string]any{"decision": "accept"}})
	r := parse(t, s, ParseOptions{})
	assert.Equal(t, "denied", r.ToolResults[0].Outcome)
	assert.Equal(t, "ok", r.ToolResults[1].Outcome)
}
