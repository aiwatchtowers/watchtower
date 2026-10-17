package chat

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"watchtower/internal/claude"
)

// TestClaudeAILive_Probe drives the real `claude` CLI in the main chat's
// claude.ai mode (#737) and asserts the control-protocol
// behaviour the permission gate builds on; testdata/claude_ai_probe.md lists
// the answers. It is the one test here that runs the real CLI, so it is
// skipped unless WATCHTOWER_LIVE_CLAUDE=1: it needs a claude.ai login (no API
// key), the network and a few haiku turns. With WATCHTOWER_LIVE_CLAUDE_OUT=<dir>
// it also writes the raw transcript (<dir>/claude_ai_raw.jsonl) that
// testdata/record_fixtures.sh scrubs into the claude_ai_* fixtures.
//
// Safety: each turn answers only the tool it is about and denies (and fails
// on) any other request, so a drifting model cannot publish, pin, delete or
// create anything in the account; publish, pin, delete and the Docs calls
// other than guide are always denied; an allowed file tool must stay in the
// probe's own temp dir; --setting-sources project,local as in production (TCC
// guard); the whole process group is reaped in t.Cleanup.
func TestClaudeAILive_Probe(t *testing.T) {
	if os.Getenv("WATCHTOWER_LIVE_CLAUDE") != "1" {
		t.Skip("live claude.ai probe: set WATCHTOWER_LIVE_CLAUDE=1 (needs a logged-in claude CLI)")
	}
	for _, k := range []string{"ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK",
		"CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"} {
		if os.Getenv(k) != "" {
			t.Skipf("live claude.ai probe: %s is set, claude.ai tools are off", k)
		}
	}
	rec := newProbeRecorder(t)

	p := startLiveProbe(t, rec, "main", nil, nil)
	servers := p.settledMCPStatus("status", 15*time.Second)
	docs := probeAssertMCPStatus(t, servers)
	probeMainSession(t, p, docs)

	if !docs {
		t.Log("Q6 not probed: the account has no claude.ai Claude Docs connector")
	} else {
		dp := startLiveProbe(t, rec, "disallow", []string{"--disallowedTools", "mcp__" + probeDocsToken}, nil)
		dp.settledMCPStatus("status_disallow", 15*time.Second) // init lists servers only once fetched
		init := dp.turn("Reply with exactly: ok", probeDeny).find("system", "init")
		for _, tool := range probeStrings(init["tools"]) {
			if strings.HasPrefix(tool, "mcp__"+probeDocsToken+"__") {
				t.Errorf("Q6: --disallowedTools mcp__%s left %s in the init tools", probeDocsToken, tool)
			}
		}
		if s := probeServer(init["mcp_servers"], probeDocsName); s == nil || s["status"] != "connected" {
			t.Errorf("Q6: the hidden server should still be listed as connected, got %v", s)
		}
	}

	// Connectors off: the list must stay empty for the whole settle budget
	// the "on" sessions get (they list servers within ~2 s).
	off := startLiveProbe(t, rec, "connectors_off", nil, []string{"ENABLE_CLAUDEAI_MCP_SERVERS=0"})
	for deadline := time.Now().Add(15 * time.Second); time.Now().Before(deadline); time.Sleep(time.Second) {
		if got := off.mcpStatus("status_off"); len(got) != 0 {
			t.Fatalf("ENABLE_CLAUDEAI_MCP_SERVERS=0: mcp_status lists %d servers, want none", len(got))
		}
	}
	init := off.turn("Reply with exactly: ok", probeDeny).find("system", "init")
	if init == nil || len(probeList(init["mcp_servers"])) != 0 {
		t.Errorf("ENABLE_CLAUDEAI_MCP_SERVERS=0: init = %v, want one with no mcp_servers", init)
	}
}

const (
	probeDocsName  = "claude.ai Claude Docs"
	probeDocsToken = "claude_ai_Claude_Docs"
	probeFakeURL   = "https://claude.ai/artifact/PrbbeQQQQQQQQQQQQQQQQQ" // well-formed, never minted
	probeDenyMsg   = "Denied by the probe gate: not allowed here."
)

// probeMainSession runs the per-question turns on one warm session.
func probeMainSession(t *testing.T, p *liveProbe, docs bool) {
	cwd, out := p.cwd, p.outside

	// Q3/Q9: Read inside the cwd runs without a permission request.
	turn := p.turn("Use the Read tool to read "+cwd+"/inside.txt and reply with its content only.", probeDeny)
	init := turn.find("system", "init")
	if src := init["apiKeySource"]; src != "none" {
		t.Errorf("Q9: init apiKeySource = %v, want \"none\" under a claude.ai login", src)
	}
	for _, tool := range probeStrings(init["tools"]) {
		if strings.HasSuffix(tool, "__authenticate") {
			t.Errorf("Q6: init exposes %s; needs-auth connectors had no tools", tool)
		}
	}
	if r := turn.request("Read"); r != nil {
		t.Errorf("Q3: Read inside the cwd asked permission: %v", r)
	}
	if !turn.toolRan("Read") {
		t.Error("Q3: Read inside the cwd did not run")
	}

	// Q1/Q3: Read outside the cwd asks, with the workingDir reason.
	turn = p.turn("Use the Read tool to read "+out+"/outside.txt and reply with its content only.", probeAllow, "Read")
	if r := probeRequire(t, turn, "Read", "Q3: Read outside the cwd"); r != nil {
		probeAssertCanUseTool(t, turn.requestLine("Read"), "Read")
		if r["decision_reason_type"] != "workingDir" {
			t.Errorf("Q3: decision_reason_type = %v, want workingDir", r["decision_reason_type"])
		}
	}

	// Q3/Q8: a symlink inside the cwd that leaves it asks (blocked_path), and a
	// deny with a message reaches the model verbatim as an error tool_result.
	turn = p.turn("Use the Read tool to read "+cwd+"/link.txt and reply with its content only.", probeDeny, "Read")
	if r := probeRequire(t, turn, "Read", "Q3: Read through a symlink"); r != nil {
		if r["blocked_path"] == nil {
			t.Errorf("Q3: symlink request has no blocked_path: %v", r)
		}
		probeAssertDenied(t, turn, r)
	}

	// Q3: Edit asks inside the cwd and outside it.
	turn = p.turn("Use the Edit tool on "+cwd+"/inside.txt: replace 'inside file' with 'inside edited'. Then reply done.", probeAllow, "Edit")
	probeRequire(t, turn, "Edit", "Q3: Edit inside the cwd")
	turn = p.turn("Use the Edit tool on "+out+"/outside.txt: replace 'outside file' with 'outside edited'. Then reply done.", probeAllow, "Edit", "Read")
	probeRequire(t, turn, "Edit", "Q3: Edit outside the cwd")

	// Q4: Write inside the cwd asks; an allow's updatedInput replaces the input.
	turn = p.turn("Use the Write tool to create "+cwd+"/a.txt containing original. Then reply done.",
		func(r map[string]any) probeReply {
			in, ok := r["input"].(map[string]any)
			if !ok {
				t.Errorf("Q4: Write request without an input object: %v", r)
				return probeReply{}
			}
			in["content"] = "edited by gate\n"
			return probeReply{allow: true, input: in}
		}, "Write")
	probeRequire(t, turn, "Write", "Q4: Write inside the cwd")
	if b, _ := os.ReadFile(filepath.Join(cwd, "a.txt")); string(b) != "edited by gate\n" {
		t.Errorf("Q4: allow with updatedInput wrote %q, want the gate's content", b)
	}
	// An allow without updatedInput runs the call as the model sent it.
	turn = p.turn("Use the Write tool to create "+cwd+"/b.txt containing bare. Then reply done.",
		func(map[string]any) probeReply { return probeReply{allow: true, bare: true} }, "Write")
	probeRequire(t, turn, "Write", "Q4: Write inside the cwd (bare allow)")
	if _, err := os.Stat(filepath.Join(cwd, "b.txt")); err != nil {
		t.Errorf("Q4: a bare allow did not run the Write: %v", err)
	}
	turn = p.turn("Use the Write tool to create "+out+"/w.txt containing x. Then reply done.", probeDeny, "Write")
	if r := probeRequire(t, turn, "Write", "Q4: Write outside the cwd"); r != nil {
		probeAssertDenied(t, turn, r)
	}
	if _, err := os.Stat(filepath.Join(out, "w.txt")); !os.IsNotExist(err) {
		t.Errorf("Q4: the denied Write outside the cwd ran (stat: %v)", err)
	}

	// Q5: Artifact list runs without a request; publish, read of a foreign
	// URL and pin ask; delete of an unknown URL is refused by the CLI itself.
	turn = p.turn("Call the Artifact tool with action list and limit 1. Reply with only the number it returned.", probeDeny)
	if r := turn.request("Artifact"); r != nil {
		t.Errorf("Q5: Artifact list asked permission: %v", r)
	}
	if !turn.toolRan("Artifact") {
		t.Error("Q5: Artifact list did not run")
	}
	turn = p.turn("Call the Artifact tool to publish the file "+cwd+"/page.html (action publish, icon code). If it is refused, reply with the refusal text.", probeDeny, "Artifact")
	if r := probeRequire(t, turn, "Artifact", "Q5: Artifact publish"); r != nil {
		in, _ := r["input"].(map[string]any)
		if in["action"] != "publish" || in["__artifactPublishSourcePin"] == nil {
			t.Errorf("Q5: publish input lacks action or the CLI's __artifact* fields: %v", in)
		}
	}
	turn = p.turn("I own the artifact at "+probeFakeURL+" and confirm its deletion: call the Artifact tool with action delete and that url now. Reply with the result or the refusal text.", probeDeny, "Artifact") // it may try a read first
	for _, d := range turn.lines {
		if r, _ := d["request"].(map[string]any); probeIsCanUseTool(d) {
			if in, _ := r["input"].(map[string]any); in["action"] == "delete" {
				t.Errorf("Q5: delete of an unknown URL reached can_use_tool: %v", r)
			}
		}
	}
	if turn.find("system", "permission_denied") == nil {
		t.Error("Q5: delete of an unknown URL: no system/permission_denied event")
	}
	turn = p.turn("Call the Artifact tool with action read and url "+probeFakeURL+". Reply with the result or the refusal text.", probeDeny, "Artifact")
	probeRequire(t, turn, "Artifact", "Q5: Artifact read of a foreign URL")
	turn = p.turn("Call the Artifact tool with action pin and url "+probeFakeURL+". Reply with the result or the refusal text.", probeDeny, "Artifact")
	probeRequire(t, turn, "Artifact", "Q5: Artifact pin")

	if docs {
		// Q1/Q7: a connector call carries mcp_server; the share vocabulary.
		guide := "mcp__" + probeDocsToken + "__guide"
		turn = p.turn(`Call mcp__claude_ai_Claude_Docs__guide with items ["topic.sharing"]. Reply with one sentence.`, probeAllow, guide)
		if r := probeRequire(t, turn, guide, "Q1: Docs guide"); r != nil {
			probeAssertCanUseTool(t, turn.requestLine(guide), guide)
			srv, _ := r["mcp_server"].(map[string]any)
			if srv["name"] != probeDocsName {
				t.Errorf("Q1: mcp_server = %v, want an object {name: %q}", r["mcp_server"], probeDocsName)
			}
			if r["server_policy_ask_only"] != true {
				t.Errorf("Q1: connector request without server_policy_ask_only: %v", r)
			}
			if res := probeContentText(turn.toolResult(r["tool_use_id"])["content"]); !strings.Contains(res, "no docs tool shares a doc") {
				t.Errorf("Q7: topic.sharing no longer says no tool shares a doc: %.300q", res)
			}
		}
		turn = p.turn("Call mcp__claude_ai_Claude_Docs__delete for the doc with id 'doc_probe_nonexistent'. If it is refused, reply with the refusal text.", probeDeny, "mcp__"+probeDocsToken+"__delete")
		probeRequire(t, turn, "mcp__"+probeDocsToken+"__delete", "Q7: Docs delete")
	}

	// Stop while a request waits: the CLI cancels it with control_cancel_request.
	p.send(probeUserLine("Use the Write tool to create " + cwd + "/c.txt containing held. Then reply done."))
	held := p.waitFor(func(d map[string]any) bool { return probeIsCanUseTool(d) }, 3*time.Minute)
	reqID, _ := held["request_id"].(string)
	p.send(map[string]any{"type": "control_request", "request_id": "probe_interrupt",
		"request": map[string]any{"subtype": "interrupt"}})
	cancel := p.waitFor(func(d map[string]any) bool { return d["type"] == "control_cancel_request" }, time.Minute)
	if cancel["request_id"] != reqID {
		t.Errorf("interrupt: control_cancel_request %v, want request_id %q", cancel, reqID)
	}
	p.waitFor(func(d map[string]any) bool { return d["type"] == "result" }, time.Minute)
	if _, err := os.Stat(filepath.Join(cwd, "c.txt")); err == nil {
		t.Error("interrupt: the cancelled Write ran")
	}
}

// probeAssertMCPStatus checks the settled mcp_status shape (Q2) and reports
// whether Claude Docs is connected (the account-dependent questions need it).
func probeAssertMCPStatus(t *testing.T, servers []any) bool {
	t.Helper()
	if len(servers) == 0 {
		t.Fatal("Q2: mcp_status listed no claude.ai servers within 15 s — is the CLI logged in to claude.ai?")
	}
	docs := false
	if d := probeServer(servers, probeDocsName); d != nil && d["status"] != "connected" {
		t.Errorf("Q2: Claude Docs is listed but %v, not connected", d["status"])
	}
	for _, s := range servers {
		m, _ := s.(map[string]any)
		name, _ := m["name"].(string)
		if !strings.HasPrefix(name, "claude.ai ") || m["status"] == nil || m["source"] != "claudeai" {
			t.Errorf("Q2: unexpected server entry %v", m)
		}
		if m["status"] != "connected" {
			continue
		}
		for _, tool := range probeList(m["tools"]) {
			tm, _ := tool.(map[string]any)
			if _, ok := tm["annotations"].(map[string]any); !ok || tm["name"] == nil {
				t.Errorf("Q2: tool entry without name/annotations object: %v", tm)
			}
		}
		if name == probeDocsName {
			docs = true
			want := map[string]string{"read": "readOnly", "query": "readOnly", "guide": "readOnly",
				"export": "readOnly", "delete": "destructive", "create": "", "update": "", "batch": ""}
			for _, tool := range probeList(m["tools"]) {
				tm, _ := tool.(map[string]any)
				ann, _ := tm["annotations"].(map[string]any)
				tool, _ := tm["name"].(string)
				hint, ok := want[tool]
				if ok && (hint == "" && len(ann) != 0 || hint != "" && ann[hint] != true) {
					t.Errorf("Q7: Claude Docs %s annotations = %v, want %q", tool, ann, hint)
				}
				delete(want, tool)
			}
			for tool := range want {
				t.Errorf("Q7: Claude Docs no longer lists the %s tool", tool)
			}
		}
	}
	return docs
}

// probeAssertCanUseTool checks the request envelope the gate decodes (Q1).
func probeAssertCanUseTool(t *testing.T, d map[string]any, tool string) {
	t.Helper()
	r, _ := d["request"].(map[string]any)
	if s, _ := d["request_id"].(string); s == "" {
		t.Errorf("Q1: %s request without request_id: %v", tool, d)
	}
	if r["tool_name"] != tool || r["tool_use_id"] == nil || r["input"] == nil || r["display_name"] == nil {
		t.Errorf("Q1: %s request lacks tool_name/tool_use_id/input/display_name: %v", tool, r)
	}
	if _, ok := r["title"]; ok {
		t.Errorf("Q1: %s request now carries a title field: %v", tool, r)
	}
}

func probeAssertDenied(t *testing.T, turn *probeTurn, r map[string]any) {
	t.Helper()
	res := turn.toolResult(r["tool_use_id"])
	if res == nil || res["is_error"] != true || probeContentText(res["content"]) != probeDenyMsg {
		t.Errorf("Q8: denied tool_result = %v, want is_error with the message verbatim", res)
	}
	found := false
	for _, d := range probeList(turn.find("result", "")["permission_denials"]) {
		if m, _ := d.(map[string]any); m["tool_use_id"] == r["tool_use_id"] {
			found = true
		}
	}
	if !found {
		t.Error("Q8: the denied call is missing from result.permission_denials")
	}
	if meta := turn.toolResultMeta(r["tool_use_id"]); meta["non_execution_kind"] != "permission-rule" {
		t.Errorf("Q8: tool_result_meta = %v, want non_execution_kind permission-rule", meta)
	}
}

func probeRequire(t *testing.T, turn *probeTurn, tool, what string) map[string]any {
	t.Helper()
	r := turn.request(tool)
	if r == nil {
		t.Errorf("%s: no can_use_tool request for %s", what, tool)
	}
	return r
}

type probeReply struct {
	allow bool
	bare  bool           // allow without updatedInput
	input map[string]any // allow: updatedInput; nil = the request's input
}

func probeAllow(map[string]any) probeReply { return probeReply{allow: true} }
func probeDeny(map[string]any) probeReply  { return probeReply{} }

func probeReplyLine(requestID string, req map[string]any, rep probeReply) map[string]any {
	resp := map[string]any{"behavior": "deny", "message": probeDenyMsg}
	if rep.allow {
		resp = map[string]any{"behavior": "allow"}
		if !rep.bare {
			in := rep.input
			if in == nil {
				in, _ = req["input"].(map[string]any)
			}
			resp["updatedInput"] = in
		}
	}
	return map[string]any{"type": "control_response",
		"response": map[string]any{"subtype": "success", "request_id": requestID, "response": resp}}
}

func probeUserLine(text string) map[string]any {
	return map[string]any{"type": "user", "message": map[string]any{"role": "user",
		"content": []any{map[string]any{"type": "text", "text": text}}}}
}

func probeIsCanUseTool(d map[string]any) bool {
	r, _ := d["request"].(map[string]any)
	return d["type"] == "control_request" && r["subtype"] == "can_use_tool"
}

// probeTurn is every stdout line of one turn, up to its result.
type probeTurn struct{ lines []map[string]any }

func (pt *probeTurn) find(typ, subtype string) map[string]any {
	for _, d := range pt.lines {
		if d["type"] == typ && (subtype == "" || d["subtype"] == subtype) {
			return d
		}
	}
	return nil
}

func (pt *probeTurn) requestLine(tool string) map[string]any {
	for _, d := range pt.lines {
		if r, _ := d["request"].(map[string]any); probeIsCanUseTool(d) && r["tool_name"] == tool {
			return d
		}
	}
	return nil
}

func (pt *probeTurn) request(tool string) map[string]any {
	r, _ := pt.requestLine(tool)["request"].(map[string]any)
	return r
}

func (pt *probeTurn) toolRan(tool string) bool {
	for _, id := range pt.toolUseIDs(tool) {
		if res := pt.toolResult(id); res != nil && res["is_error"] != true {
			return true
		}
	}
	return false
}

func (pt *probeTurn) toolUseIDs(tool string) []any {
	var ids []any
	for _, d := range pt.lines {
		if d["type"] != "assistant" {
			continue
		}
		msg, _ := d["message"].(map[string]any)
		for _, c := range probeList(msg["content"]) {
			if m, _ := c.(map[string]any); m["type"] == "tool_use" && m["name"] == tool {
				ids = append(ids, m["id"])
			}
		}
	}
	return ids
}

func (pt *probeTurn) toolResult(id any) map[string]any {
	for _, d := range pt.lines {
		if d["type"] != "user" {
			continue
		}
		msg, _ := d["message"].(map[string]any)
		for _, c := range probeList(msg["content"]) {
			if m, _ := c.(map[string]any); m["type"] == "tool_result" && m["tool_use_id"] == id {
				return m
			}
		}
	}
	return nil
}

func (pt *probeTurn) toolResultMeta(id any) map[string]any {
	for _, d := range pt.lines {
		for _, m := range probeList(d["tool_result_meta"]) {
			if mm, _ := m.(map[string]any); mm["id"] == id {
				return mm
			}
		}
	}
	return nil
}

func probeContentText(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	var b strings.Builder
	for _, c := range probeList(v) {
		if m, _ := c.(map[string]any); m["type"] == "text" {
			s, _ := m["text"].(string)
			b.WriteString(s)
		}
	}
	return b.String()
}

func probeList(v any) []any { l, _ := v.([]any); return l }

func probeStrings(v any) []string {
	var out []string
	for _, x := range probeList(v) {
		if s, ok := x.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

func probeServer(v any, name string) map[string]any {
	for _, s := range probeList(v) {
		if m, _ := s.(map[string]any); m["name"] == name {
			return m
		}
	}
	return nil
}

// probeRecorder appends every line both ways to the raw transcript, with the
// probe's temp root rewritten to /tmp/probe (scrub_fixtures.py does the rest).
type probeRecorder struct {
	mu    sync.Mutex
	w     io.Writer
	roots []string
	err   error // the first write error, reported at cleanup
}

func newProbeRecorder(t *testing.T) *probeRecorder {
	dir := os.Getenv("WATCHTOWER_LIVE_CLAUDE_OUT")
	if dir == "" {
		dir = t.TempDir()
	}
	f, err := os.Create(filepath.Join(dir, "claude_ai_raw.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	r := &probeRecorder{w: f}
	t.Cleanup(func() {
		r.mu.Lock()
		defer r.mu.Unlock()
		if err := f.Close(); err != nil && r.err == nil {
			r.err = err
		}
		if r.err != nil {
			t.Errorf("raw transcript is incomplete: %v", r.err)
		}
	})
	return r
}

func (r *probeRecorder) addRoot(resolved, link string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	// The resolved form first: it ends with the link form (/private/var/… vs
	// /var/…), which would otherwise leave a stray /private prefix.
	r.roots = append(r.roots, resolved, link)
}

func (r *probeRecorder) write(scenario, dir string, line []byte) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, root := range r.roots {
		line = bytes.ReplaceAll(line, []byte(root), []byte("/tmp/probe"))
	}
	line = bytes.TrimSpace(line)
	if !json.Valid(line) { // keep the transcript valid JSONL; the scrub fails on it
		line, _ = json.Marshal(map[string]string{"non_json": string(line)})
	}
	if _, err := fmt.Fprintf(r.w, `{"scenario":%q,"dir":%q,"line":%s}`+"\n", scenario, dir, line); err != nil && r.err == nil {
		r.err = err
	}
}

// liveProbe is one claude child in claude.ai mode.
type liveProbe struct {
	t        *testing.T
	scenario string
	rec      *probeRecorder
	base     string // the temp root every allowed file tool must stay in
	cwd      string
	outside  string
	stdin    io.WriteCloser
	lines    chan map[string]any
}

func startLiveProbe(t *testing.T, rec *probeRecorder, scenario string, extraArgs, extraEnv []string) *liveProbe {
	t.Helper()
	bin := claude.FindBinary("")
	if bin == "" {
		t.Skip("live claude.ai probe: no claude binary found")
	}
	link, err := os.MkdirTemp("", "wtprobe")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(link) })
	base, err := filepath.EvalSymlinks(link)
	if err != nil {
		t.Fatal(err)
	}
	rec.addRoot(base, link)
	p := &liveProbe{t: t, scenario: scenario, rec: rec, base: base,
		cwd: filepath.Join(base, "cwd"), outside: filepath.Join(base, "outside"),
		lines: make(chan map[string]any, 1024)}
	for _, d := range []string{p.cwd, p.outside} {
		if err := os.Mkdir(d, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	files := map[string]string{
		filepath.Join(p.cwd, "inside.txt"):      "inside file\n",
		filepath.Join(p.cwd, "page.html"):       "<h1>Probe</h1>\n",
		filepath.Join(p.outside, "outside.txt"): "outside file\n",
	}
	for path, body := range files {
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink(filepath.Join(p.outside, "outside.txt"), filepath.Join(p.cwd, "link.txt")); err != nil {
		t.Fatal(err)
	}

	// The claude.ai-mode argv of the main chat session (#737 plan, Global Constraints).
	args := append([]string{"-p", "--input-format", "stream-json", "--output-format", "stream-json",
		"--verbose", "--setting-sources", "project,local", "--permission-prompt-tool", "stdio",
		"--model", "haiku", "--tools", "ToolSearch,WebSearch,Artifact,Write,Edit,Read"}, extraArgs...)
	cmd := exec.Command(bin, args...)
	cmd.Dir = p.cwd
	cmd.Env = append(append(os.Environ(), "PATH="+claude.RichPATH(),
		"CLAUDE_CODE_ARTIFACT=1", "CLAUDE_CODE_ARTIFACT_AUTO_OPEN=0"), extraEnv...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.WaitDelay = 5 * time.Second // bounds the stderr copy if a grandchild keeps it open
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if p.stdin, err = cmd.StdinPipe(); err != nil {
		t.Fatal(err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	pgid := cmd.Process.Pid
	waited := make(chan struct{})
	stop := make(chan struct{}) // closed at cleanup: the reader stops handing lines over
	go func() {
		br := bufio.NewReaderSize(stdout, 1<<20)
		for {
			line, err := br.ReadBytes('\n')
			if len(bytes.TrimSpace(line)) > 0 {
				rec.write(scenario, "in", line)
				var d map[string]any
				if json.Unmarshal(line, &d) != nil {
					d = map[string]any{"type": "probe_non_json"}
				}
				select {
				case p.lines <- d:
				case <-stop:
				}
			}
			if err != nil {
				break
			}
		}
		_ = cmd.Wait()
		close(p.lines)
		close(waited)
	}()
	t.Cleanup(func() {
		close(stop)
		p.stdin.Close()
		_ = syscall.Kill(-pgid, syscall.SIGTERM)
		select {
		case <-waited:
		case <-time.After(5 * time.Second):
		}
		_ = syscall.Kill(-pgid, syscall.SIGKILL)
		_ = stdout.Close() // unblocks the reader if a process outside the group holds stdout
		select {
		case <-waited:
		case <-time.After(10 * time.Second):
			t.Errorf("%s: claude (pgid %d) not reaped", scenario, pgid)
			return // stderr may still be written to
		}
		if t.Failed() && stderr.Len() > 0 {
			t.Logf("%s stderr: %.2000s", scenario, stderr.String())
		}
	})
	return p
}

func (p *liveProbe) send(v map[string]any) {
	p.t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		p.t.Fatal(err)
	}
	p.rec.write(p.scenario, "out", b)
	if _, err := p.stdin.Write(append(b, '\n')); err != nil {
		p.t.Fatalf("%s: writing to claude: %v", p.scenario, err)
	}
}

func (p *liveProbe) next(timeout time.Duration) map[string]any {
	p.t.Helper()
	select {
	case d, ok := <-p.lines:
		if !ok {
			p.t.Fatalf("%s: claude exited", p.scenario)
		}
		if d["type"] == "probe_non_json" {
			p.t.Errorf("%s: claude wrote a non-JSON stdout line (see the raw transcript)", p.scenario)
		}
		return d
	case <-time.After(timeout):
		p.t.Fatalf("%s: no output within %s", p.scenario, timeout)
		return nil
	}
}

func (p *liveProbe) waitFor(match func(map[string]any) bool, timeout time.Duration) map[string]any {
	p.t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		if d := p.next(time.Until(deadline)); match(d) {
			return d
		}
	}
}

// turn sends one user message and, until the turn's result, answers each
// can_use_tool for one of tools with decide. A request for any other tool is
// denied and fails the test (a drifting model never gets an unplanned allow),
// and so is an allow whose file_path leaves the probe's temp root.
func (p *liveProbe) turn(text string, decide func(map[string]any) probeReply, tools ...string) *probeTurn {
	p.t.Helper()
	p.send(probeUserLine(text))
	pt := &probeTurn{}
	deadline := time.Now().Add(3 * time.Minute)
	for {
		d := p.next(time.Until(deadline))
		pt.lines = append(pt.lines, d)
		if probeIsCanUseTool(d) {
			req, _ := d["request"].(map[string]any)
			id, _ := d["request_id"].(string)
			rep := probeReply{}
			if name, _ := req["tool_name"].(string); !slices.Contains(tools, name) {
				p.t.Errorf("%s: unexpected can_use_tool for %s (denied): %v", p.scenario, name, req)
			} else if rep = decide(req); rep.allow && !p.inBase(req) {
				p.t.Errorf("%s: %s asked for a path outside the probe dir (denied): %v", p.scenario, name, req)
				rep = probeReply{}
			}
			p.send(probeReplyLine(id, req, rep))
		}
		if d["type"] == "result" {
			return pt
		}
	}
}

// inBase reports whether a request's file_path (if any) is in the temp root.
func (p *liveProbe) inBase(req map[string]any) bool {
	in, _ := req["input"].(map[string]any)
	path, ok := in["file_path"].(string)
	if !ok {
		return true
	}
	rel, err := filepath.Rel(p.base, filepath.Clean(path))
	return filepath.IsAbs(path) && err == nil && rel != ".." && !strings.HasPrefix(rel, "../")
}

// mcpStatus sends one mcp_status control request and returns mcpServers.
func (p *liveProbe) mcpStatus(id string) []any {
	p.t.Helper()
	p.send(map[string]any{"type": "control_request", "request_id": id,
		"request": map[string]any{"subtype": "mcp_status"}})
	d := p.waitFor(func(d map[string]any) bool {
		r, _ := d["response"].(map[string]any)
		return d["type"] == "control_response" && r["request_id"] == id
	}, 30*time.Second)
	r, _ := d["response"].(map[string]any)
	body, _ := r["response"].(map[string]any)
	return probeList(body["mcpServers"])
}

// settledMCPStatus polls mcp_status every second until it lists servers and
// none is "pending" (the claude.ai fetch and the connects are async: an empty
// list first, then pending entries). A list still pending at the end of the
// budget fails the test rather than reading as "no Claude Docs".
func (p *liveProbe) settledMCPStatus(id string, budget time.Duration) []any {
	p.t.Helper()
	deadline := time.Now().Add(budget)
	for i := 0; ; i++ {
		servers := p.mcpStatus(fmt.Sprintf("%s_%d", id, i))
		settled := len(servers) > 0
		for _, s := range servers {
			if m, _ := s.(map[string]any); m["status"] == "pending" {
				settled = false
			}
		}
		if settled || len(servers) == 0 && time.Now().After(deadline) {
			return servers
		}
		if time.Now().After(deadline) {
			p.t.Fatalf("%s: connectors still pending after %s: %v", p.scenario, budget, servers)
		}
		time.Sleep(time.Second)
	}
}
