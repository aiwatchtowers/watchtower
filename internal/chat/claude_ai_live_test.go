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
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"watchtower/internal/claude"
)

// TestClaudeAILive_Probe drives the real `claude` CLI in the main chat's
// claude.ai mode (#737, plan Task 2) and asserts the control-protocol
// behaviour the permission gate builds on; testdata/claude_ai_probe.md lists
// the answers. It is the one test here that runs the real CLI, so it is
// skipped unless WATCHTOWER_LIVE_CLAUDE=1: it needs a claude.ai login (no API
// key), the network and a few haiku turns. With WATCHTOWER_LIVE_CLAUDE_OUT=<dir>
// it also writes the raw transcript (<dir>/claude_ai_raw.jsonl) that
// testdata/record_fixtures.sh scrubs into the claude_ai_* fixtures.
//
// Safety: every publish, pin, delete and out-of-dir write is denied, so
// nothing is sent to the account; the only paths are in the probe's own temp
// dir; --setting-sources project,local as in production (TCC guard); the
// whole process group is reaped in t.Cleanup.
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
		t.Log("Q6 not probed: the account has no connected claude.ai Claude Docs")
	} else {
		p := startLiveProbe(t, rec, "disallow", []string{"--disallowedTools", "mcp__" + probeDocsToken}, nil)
		p.settledMCPStatus("status_disallow", 15*time.Second) // init lists servers only once fetched
		turn := p.turn("Reply with exactly: ok", probeAllowAll)
		init := turn.find("system", "init")
		for _, tool := range probeStrings(init["tools"]) {
			if strings.HasPrefix(tool, "mcp__"+probeDocsToken+"__") {
				t.Errorf("Q6: --disallowedTools mcp__%s left %s in the init tools", probeDocsToken, tool)
			}
		}
		if s := probeServer(init["mcp_servers"], probeDocsName); s == nil || s["status"] != "connected" {
			t.Errorf("Q6: the hidden server should still be listed as connected, got %v", s)
		}
	}

	off := startLiveProbe(t, rec, "connectors_off", nil, []string{"ENABLE_CLAUDEAI_MCP_SERVERS=0"})
	time.Sleep(4 * time.Second) // the account fetch settles within ~2 s when on
	if got := off.mcpStatus("status_off"); len(got) != 0 {
		t.Errorf("ENABLE_CLAUDEAI_MCP_SERVERS=0: mcp_status lists %d servers, want none", len(got))
	}
	if init := off.turn("Reply with exactly: ok", probeAllowAll).find("system", "init"); len(probeList(init["mcp_servers"])) != 0 {
		t.Errorf("ENABLE_CLAUDEAI_MCP_SERVERS=0: init lists servers %v", init["mcp_servers"])
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
	turn := p.turn("Use the Read tool to read "+cwd+"/inside.txt and reply with its content only.", probeAllowAll)
	if src := turn.find("system", "init")["apiKeySource"]; src != "none" {
		t.Errorf("Q9: init apiKeySource = %v, want \"none\" under a claude.ai login", src)
	}
	if r := turn.request("Read"); r != nil {
		t.Errorf("Q3: Read inside the cwd asked permission: %v", r)
	}
	if !turn.toolRan("Read") {
		t.Error("Q3: Read inside the cwd did not run")
	}

	// Q1/Q3: Read outside the cwd asks, with the workingDir reason.
	turn = p.turn("Use the Read tool to read "+out+"/outside.txt and reply with its content only.", probeAllowAll)
	if r := probeRequire(t, turn, "Read", "Q3: Read outside the cwd"); r != nil {
		probeAssertCanUseTool(t, turn.requestLine("Read"), "Read")
		if r["decision_reason_type"] != "workingDir" {
			t.Errorf("Q3: decision_reason_type = %v, want workingDir", r["decision_reason_type"])
		}
	}

	// Q3/Q8: a symlink inside the cwd that leaves it asks (blocked_path), and a
	// deny with a message reaches the model verbatim as an error tool_result.
	turn = p.turn("Use the Read tool to read "+cwd+"/link.txt and reply with its content only.", probeDenyAll)
	if r := probeRequire(t, turn, "Read", "Q3: Read through a symlink"); r != nil {
		if r["blocked_path"] == nil {
			t.Errorf("Q3: symlink request has no blocked_path: %v", r)
		}
		probeAssertDenied(t, turn, r)
	}

	// Q3: Edit asks inside the cwd and outside it.
	turn = p.turn("Use the Edit tool on "+cwd+"/inside.txt: replace 'inside file' with 'inside edited'. Then reply done.", probeAllowAll)
	probeRequire(t, turn, "Edit", "Q3: Edit inside the cwd")
	turn = p.turn("Use the Edit tool on "+out+"/outside.txt: replace 'outside file' with 'outside edited'. Then reply done.", probeAllowAll)
	probeRequire(t, turn, "Edit", "Q3: Edit outside the cwd")

	// Q4: Write inside the cwd asks; an allow's updatedInput replaces the input.
	turn = p.turn("Use the Write tool to create "+cwd+"/a.txt containing original. Then reply done.",
		func(r map[string]any) probeReply {
			in, ok := r["input"].(map[string]any)
			if !ok {
				return probeReply{}
			}
			in["content"] = "edited by gate\n"
			return probeReply{allow: true, input: in}
		})
	probeRequire(t, turn, "Write", "Q4: Write inside the cwd")
	if b, _ := os.ReadFile(filepath.Join(cwd, "a.txt")); string(b) != "edited by gate\n" {
		t.Errorf("Q4: allow with updatedInput wrote %q, want the gate's content", b)
	}
	// An allow without updatedInput runs the call as the model sent it.
	turn = p.turn("Use the Write tool to create "+cwd+"/b.txt containing bare. Then reply done.",
		func(map[string]any) probeReply { return probeReply{allow: true, bare: true} })
	probeRequire(t, turn, "Write", "Q4: Write inside the cwd (bare allow)")
	if _, err := os.Stat(filepath.Join(cwd, "b.txt")); err != nil {
		t.Errorf("Q4: a bare allow did not run the Write: %v", err)
	}
	turn = p.turn("Use the Write tool to create "+out+"/w.txt containing x. Then reply done.", probeDenyAll)
	probeRequire(t, turn, "Write", "Q4: Write outside the cwd")

	// Q5: Artifact list runs without a request; publish, read of a foreign
	// URL and pin ask; delete of an unknown URL is refused by the CLI itself.
	turn = p.turn("Call the Artifact tool with action list and limit 1. Reply with only the number it returned.", probeAllowAll)
	if r := turn.request("Artifact"); r != nil {
		t.Errorf("Q5: Artifact list asked permission: %v", r)
	}
	turn = p.turn("Call the Artifact tool to publish the file "+cwd+"/page.html (action publish, icon code). If it is refused, reply with the refusal text.", probeDenyAll)
	if r := probeRequire(t, turn, "Artifact", "Q5: Artifact publish"); r != nil {
		in, _ := r["input"].(map[string]any)
		if in["action"] != "publish" || in["__artifactPublishSourcePin"] == nil {
			t.Errorf("Q5: publish input lacks action or the CLI's __artifact* fields: %v", in)
		}
	}
	turn = p.turn("I own the artifact at "+probeFakeURL+" and confirm its deletion: call the Artifact tool with action delete and that url now. Reply with the result or the refusal text.", probeDenyAll)
	if r := turn.request("Artifact"); r != nil {
		t.Errorf("Q5: delete of an unknown URL reached can_use_tool: %v", r)
	}
	if turn.find("system", "permission_denied") == nil {
		t.Error("Q5: delete of an unknown URL: no system/permission_denied event")
	}
	turn = p.turn("Call the Artifact tool with action read and url "+probeFakeURL+". Reply with the result or the refusal text.", probeDenyAll)
	probeRequire(t, turn, "Artifact", "Q5: Artifact read of a foreign URL")
	turn = p.turn("Call the Artifact tool with action pin and url "+probeFakeURL+". Reply with the result or the refusal text.", probeDenyAll)
	probeRequire(t, turn, "Artifact", "Q5: Artifact pin")

	if docs {
		// Q1/Q7: a connector call carries mcp_server; the share vocabulary.
		turn = p.turn(`Call mcp__claude_ai_Claude_Docs__guide with items ["topic.sharing"]. Reply with one sentence.`, probeAllowAll)
		if r := probeRequire(t, turn, "mcp__"+probeDocsToken+"__guide", "Q1: Docs guide"); r != nil {
			probeAssertCanUseTool(t, turn.requestLine("mcp__"+probeDocsToken+"__guide"), "mcp__"+probeDocsToken+"__guide")
			srv, _ := r["mcp_server"].(map[string]any)
			if srv["name"] != probeDocsName {
				t.Errorf("Q1: mcp_server = %v, want {name: %q}", r["mcp_server"], probeDocsName)
			}
			if res := turn.toolResultText(r["tool_use_id"]); !strings.Contains(res, "no docs tool shares a doc") {
				t.Errorf("Q7: topic.sharing no longer says no tool shares a doc: %.300q", res)
			}
		}
		turn = p.turn("Call mcp__claude_ai_Claude_Docs__delete for the doc with id 'doc_probe_nonexistent'. If it is refused, reply with the refusal text.", probeDenyAll)
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
				name, _ := tm["name"].(string)
				if hint, ok := want[name]; ok && (hint == "" && len(ann) != 0 || hint != "" && ann[hint] != true) {
					t.Errorf("Q7: Claude Docs %s annotations = %v, want %q", name, ann, hint)
				}
			}
		}
	}
	return docs
}

// probeAssertCanUseTool checks the request envelope Task 3 decodes (Q1).
func probeAssertCanUseTool(t *testing.T, d map[string]any, tool string) {
	t.Helper()
	r, _ := d["request"].(map[string]any)
	if s, _ := d["request_id"].(string); s == "" {
		t.Errorf("Q1: %s request without request_id: %v", tool, d)
	}
	if r["tool_name"] != tool || r["tool_use_id"] == nil || r["input"] == nil {
		t.Errorf("Q1: %s request lacks tool_name/tool_use_id/input: %v", tool, r)
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

func probeAllowAll(map[string]any) probeReply { return probeReply{allow: true} }
func probeDenyAll(map[string]any) probeReply  { return probeReply{} }

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

func (pt *probeTurn) toolResultText(id any) string {
	return probeContentText(pt.toolResult(id)["content"])
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
	t.Cleanup(func() { f.Close() })
	return &probeRecorder{w: f}
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
	fmt.Fprintf(r.w, `{"scenario":%q,"dir":%q,"line":%s}`+"\n", scenario, dir, bytes.TrimSpace(line))
}

// liveProbe is one claude child in claude.ai mode.
type liveProbe struct {
	t        *testing.T
	scenario string
	rec      *probeRecorder
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
	p := &liveProbe{t: t, scenario: scenario, rec: rec,
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

	// The claude.ai-mode argv of the main chat session (plan, Global Constraints).
	args := append([]string{"-p", "--input-format", "stream-json", "--output-format", "stream-json",
		"--verbose", "--setting-sources", "project,local", "--permission-prompt-tool", "stdio",
		"--model", "haiku", "--tools", "ToolSearch,WebSearch,Artifact,Write,Edit,Read"}, extraArgs...)
	cmd := exec.Command(bin, args...)
	cmd.Dir = p.cwd
	cmd.Env = append(append(os.Environ(), "PATH="+claude.RichPATH(),
		"CLAUDE_CODE_ARTIFACT=1", "CLAUDE_CODE_ARTIFACT_AUTO_OPEN=0"), extraEnv...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
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
	go func() {
		br := bufio.NewReaderSize(stdout, 1<<20)
		for {
			line, err := br.ReadBytes('\n')
			if len(bytes.TrimSpace(line)) > 0 {
				rec.write(scenario, "in", line)
				var d map[string]any
				if json.Unmarshal(line, &d) == nil {
					p.lines <- d
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
		p.stdin.Close()
		_ = syscall.Kill(-pgid, syscall.SIGTERM)
		select {
		case <-waited:
		case <-time.After(5 * time.Second):
		}
		_ = syscall.Kill(-pgid, syscall.SIGKILL)
		<-waited
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

// turn sends one user message and answers every can_use_tool with decide
// until the turn's result.
func (p *liveProbe) turn(text string, decide func(map[string]any) probeReply) *probeTurn {
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
			p.send(probeReplyLine(id, req, decide(req)))
		}
		if d["type"] == "result" {
			return pt
		}
	}
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
// list first, then pending entries) or the budget runs out.
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
		if settled || time.Now().After(deadline) {
			return servers
		}
		time.Sleep(time.Second)
	}
}
