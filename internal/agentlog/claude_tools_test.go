package agentlog

import (
	"encoding/json"
	"maps"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func toolUse(id, name string, input map[string]any) map[string]any {
	return map[string]any{"type": "tool_use", "id": id, "name": name, "input": input}
}

func toolResultLine(t *testing.T, sid, uuid, id, content string, isErr bool, extra map[string]any) string {
	m := map[string]any{"type": "user", "sessionId": sid, "uuid": uuid, "timestamp": "2026-10-01T10:00:03.000Z",
		"message": map[string]any{"role": "user", "content": []map[string]any{{"type": "tool_result", "tool_use_id": id, "content": content, "is_error": isErr}}}}
	maps.Copy(m, extra)
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
	assert.Equal(t, map[string]string{"t1": "error/exit_code", "t2": "ok/", "t4": "denied/user-rejected", "t5": "interrupted/"}, got)
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

func TestShellTarget_FirstRealCommand(t *testing.T) {
	cases := map[string]string{
		"cd /x/y && make test":                        "make test",
		"cd /x && FOO=1 go test ./internal/db":        "go test",
		"S=/tmp/a; timeout 300 swift test --filter X": "swift test",
		"export A=1; pushd d && git status":           "git status",
		"time nice -n 5 go build ./...":               "go build",
		"go test ./... | tail -5":                     "go test",
		"bash scripts/dev-health.sh --quiet":          "bash dev-health.sh",
		"sh ./run.sh":                                 "sh run.sh",
		"bash -c 'echo hi'":                           "bash",
		"cd /only/cd":                                 "",
		"env X=1 gh pr create --title secret":         "gh pr",
	}
	for in, want := range cases {
		assert.Equal(t, want, shellTarget(in), in)
	}
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

func TestParseClaude_KnownSkillsSeedAndLaterListingsUnion(t *testing.T) {
	slash := func(uuid, name string) string {
		return line(t, map[string]any{"type": "user", "sessionId": "s1", "uuid": uuid,
			"message": map[string]any{"role": "user", "content": "<command-name>/" + name + "</command-name>"}})
	}
	s := line(t, map[string]any{"type": "attachment", "sessionId": "s1", "attachment": map[string]any{"type": "skill_listing", "names": []string{"other"}}}) +
		slash("o1", "review") + slash("o2", "other") + slash("o3", "clear")
	r := parse(t, s, ParseOptions{KnownSkills: []string{"review"}})
	var got []string
	for _, e := range r.Events {
		if e.Kind == "skill" {
			got = append(got, e.Name)
		}
	}
	assert.ElementsMatch(t, []string{"review", "other"}, got)
}

func TestToolUses_AgentCallTargetAndBackground(t *testing.T) {
	s := line(t, assistant("s1", "u1", "m1", "r1", 5,
		toolUse("t1", "Agent", map[string]any{"subagent_type": "Explore", "run_in_background": true, "prompt": "SENTINEL"}),
		toolUse("t2", "Task", map[string]any{"description": "SENTINEL", "prompt": "SENTINEL"})))
	r := parse(t, s, ParseOptions{})
	got := map[string]string{}
	bg := map[string]bool{}
	for _, e := range r.Events {
		if e.Kind == "tool" {
			got[e.Key], bg[e.Key] = e.Target, e.Background
		}
	}
	assert.Equal(t, map[string]string{"tool:t1": "Explore", "tool:t2": "general-purpose"}, got)
	assert.Equal(t, map[string]bool{"tool:t1": true, "tool:t2": false}, bg)
	b, _ := json.Marshal(r)
	assert.NotContains(t, string(b), "SENTINEL")
}

func TestToolResults_AgentIDAndAsync(t *testing.T) {
	s := toolResultLine(t, "s1", "r1", "t1", "launched", false, map[string]any{"toolUseResult": map[string]any{
		"isAsync": true, "status": "async_launched", "agentId": "a1", "prompt": "SENTINEL"}}) +
		toolResultLine(t, "s1", "r2", "t2", "done", false, map[string]any{"toolUseResult": map[string]any{"agentId": "a2"}}) +
		toolResultLine(t, "s1", "r3", "t3", "launched", false, map[string]any{"toolUseResult": map[string]any{"status": "async_launched"}})
	r := parse(t, s, ParseOptions{})
	require.Len(t, r.ToolResults, 3)
	assert.Equal(t, "a1", r.ToolResults[0].SpawnedAgentID)
	assert.True(t, r.ToolResults[0].Background)
	assert.Equal(t, "a2", r.ToolResults[1].SpawnedAgentID)
	assert.False(t, r.ToolResults[1].Background)
	assert.True(t, r.ToolResults[2].Background)
	b, _ := json.Marshal(r)
	assert.NotContains(t, string(b), "SENTINEL")
}

func TestToolTarget_WorkbenchTargetID(t *testing.T) {
	tt := func(name, in string) string { return toolTarget(name, json.RawMessage(in), "/w") }
	assert.Equal(t, "#298", tt("mcp__watchtower-workbench__update_target", `{"target_id":298,"reason":"SENTINEL"}`))
	assert.Equal(t, "#298", tt("mcp__watchtower_workbench__add_comment", `{"target_id":298,"text":"SENTINEL"}`))
	assert.Equal(t, "#296", tt("mcp__watchtower-workbench__create_targets", `{"items":[{"text":"x"},{"text":"SENTINEL","parent_id":296},{"parent_id":5}]}`))
	assert.Equal(t, "", tt("mcp__watchtower-workbench__create_targets", `{"items":[{"text":"x"}]}`))
	assert.Equal(t, "", tt("mcp__watchtower-workbench__ask_owner", `{"question":"SENTINEL"}`))
	assert.Equal(t, "", tt("mcp__watchtower-workbench__list_targets", `{"target_id":3}`))
	assert.Equal(t, "", tt("mcp__other__update_target", `{"target_id":3}`))
}

// #571: the listings before an incremental read's offset are loaded only
// when a slash command needs them, never on a plain scan.
func TestParseClaude_PriorSkillsLoadedOnlyForUnknownSlashCommand(t *testing.T) {
	loads := 0
	prior := func() ([]string, error) { loads++; return []string{"review"}, nil }
	plain := line(t, assistant("s1", "u1", "m1", "r1", 5))
	parse(t, plain, ParseOptions{PriorSkills: prior})
	assert.Zero(t, loads)

	slash := func(uuid, name string) string {
		return line(t, map[string]any{"type": "user", "sessionId": "s1", "uuid": uuid,
			"message": map[string]any{"role": "user", "content": "<command-name>/" + name + "</command-name>"}})
	}
	r := parse(t, slash("o1", "review")+slash("o2", "nope")+slash("o3", "nope"), ParseOptions{PriorSkills: prior})
	assert.Equal(t, 1, loads)
	var skills []string
	for _, e := range r.Events {
		if e.Kind == "skill" {
			skills = append(skills, e.Name)
		}
	}
	assert.Equal(t, []string{"review"}, skills)
	assert.Equal(t, []string{"review"}, r.Skills)
}

func TestErrorClass_V3Classes(t *testing.T) {
	cases := map[string]string{
		"Command failed with exit code 1":                                       ClassExitCode,
		"File does not exist.":                                                  ClassNotFound,
		"Command timed out after 2m":                                            ClassTimeout,
		"String to replace not found in file.\nString: x":                       ClassEditNoMatch,
		"Found 3 matches of the string to replace, but replace_all is false.":   ClassEditMultiMatch,
		"File has been modified since read, either by the user or by a linter.": ClassStaleRead,
		"File content (300KB) exceeds maximum allowed size (256KB).":            ClassTooLarge,
		"File content (40000 tokens) exceeds maximum allowed tokens (25000).":   ClassTooLarge,
		"InputValidationError: Edit failed due to the following issue":          ClassInputInvalid,
		"<tool_use_error>Error: No such tool available: Foo</tool_use_error>":   ClassNoSuchTool,
		"Agent type 'nope' not found. Available agents: a, b":                   ClassUnknownAgent,
		"This session is isolated to its worktree; the path is outside it":      ClassIsolation,
		"Blocked: sleep 100 is not allowed; use run_in_background":              ClassSleepBlocked,
		"Too many concurrent agents: the limit is 10":                           ClassAgentLimit,
		"boom": ClassOther,
		// A Bash failure is exit_code whatever its output says.
		"Exit code 1\n--- FAIL: TestRead (0.00s)\n    file too large":                 ClassExitCode,
		"Exit code 2\nBlocked: sleep 100 is not allowed; use run_in_background":       ClassExitCode,
		"Exit code 1\nToo many concurrent agents: the limit is 10":                    ClassExitCode,
		"Exit code 1\nAgent type 'nope' not found. Available agents: a, b":            ClassExitCode,
		"Exit code 127\nInputValidationError: no such tool; this session is isolated": ClassExitCode,
	}
	for in, want := range cases {
		assert.Equal(t, want, errorClass(in), in)
	}
}

func TestParseClaude_ResultBytesAndThinking(t *testing.T) {
	a := assistant("s1", "u1", "m1", "r1", 5, toolUse("t1", "Bash", map[string]any{"command": "go test"}),
		toolUse("t2", "Read", map[string]any{"file_path": "/w/a.go"}))
	a["message"].(map[string]any)["usage"].(map[string]any)["output_tokens_details"] = map[string]any{"thinking_tokens": 77}
	s := line(t, a) +
		toolResultLine(t, "s1", "r1", "t1", "short", false, map[string]any{"toolUseResult": map[string]any{"persistedOutputSize": 123456}}) +
		toolResultLine(t, "s1", "r2", "t2", "0123456789", false, nil) +
		line(t, map[string]any{"type": "user", "sessionId": "s1", "uuid": "r3", "message": map[string]any{"role": "user",
			"content": []map[string]any{{"type": "tool_result", "tool_use_id": "t3", "content": []map[string]any{
				{"type": "text", "text": "abc"}, {"type": "image", "source": map[string]any{"data": "AAAA"}}, {"type": "text", "text": "de"}}}}}}) +
		line(t, map[string]any{"type": "user", "sessionId": "s1", "uuid": "r4", "message": map[string]any{"role": "user",
			"content": []map[string]any{{"type": "tool_result", "tool_use_id": "t4", "content": []map[string]any{
				{"type": "image", "source": map[string]any{"data": "AAAA"}}}}}}})
	r := parse(t, s, ParseOptions{})
	for _, e := range r.Events {
		if e.Kind == "api_call" {
			assert.Equal(t, int64(77), e.ThinkingTokens)
		}
	}
	require.Len(t, r.ToolResults, 4)
	require.NotNil(t, r.ToolResults[2].ResultBytes)
	assert.Equal(t, int64(5), *r.ToolResults[2].ResultBytes, "every text block counts")
	assert.Nil(t, r.ToolResults[3].ResultBytes, "no text: not measured")
	require.NotNil(t, r.ToolResults[0].ResultBytes)
	assert.Equal(t, int64(123456), *r.ToolResults[0].ResultBytes)
	require.NotNil(t, r.ToolResults[1].ResultBytes)
	assert.Equal(t, int64(10), *r.ToolResults[1].ResultBytes)
}

func TestParseClaude_DenialKind(t *testing.T) {
	s := line(t, assistant("s1", "u1", "m1", "r1", 5, toolUse("t1", "Bash", map[string]any{"command": "make deploy"}))) +
		toolResultLine(t, "s1", "r1", "t1", "denied", true, map[string]any{"toolDenialKind": "automode-blocked"}) +
		toolResultLine(t, "s1", "r2", "t2", "denied", true, map[string]any{"toolDenialKind": "permission-rule"}) +
		toolResultLine(t, "s1", "r3", "t3", "nope", true, map[string]any{"permissionDecision": map[string]any{"decision": "reject"}}) +
		toolResultLine(t, "s1", "r4", "t4", "The user doesn't want to proceed with this tool use.", true, nil) +
		toolResultLine(t, "s1", "r5", "t5", "denied", true, map[string]any{"toolDenialKind": "SENTINEL free text"})
	r := parse(t, s, ParseOptions{})
	got := map[string]string{}
	for _, tr := range r.ToolResults {
		got[tr.ToolUseID] = tr.Outcome + "/" + tr.ErrorClass
	}
	assert.Equal(t, map[string]string{"t1": "denied/automode-blocked", "t2": "denied/permission-rule",
		"t3": "denied/user-rejected", "t4": "denied/user-rejected", "t5": "denied/other"}, got)
	b, _ := json.Marshal(r)
	assert.NotContains(t, string(b), "SENTINEL")
}
