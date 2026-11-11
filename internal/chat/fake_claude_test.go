package chat

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"

	"watchtower/internal/fsutil"
)

// fakeCLI is testdata/fake_claude.sh run in process, behind
// ClaudeOptions.start: the same $FAKE_* environment, the same log files,
// the same stream-json lines, but its stdio are channel pipes and its
// "process" a goroutine, so a test runs inside testing/synctest and waits
// on no wall clock. The shell script stays for the few tests of the
// process wiring itself (spawn, pipes, process-group kill).
type fakeCLI struct {
	mu   sync.Mutex
	kids []*fakeChild
}

// children returns the children started so far, in order.
func (c *fakeCLI) children() []*fakeChild {
	c.mu.Lock()
	defer c.mu.Unlock()
	return slices.Clone(c.kids)
}

// last is the most recently started child.
func (c *fakeCLI) last() *fakeChild {
	kids := c.children()
	if len(kids) == 0 {
		return nil
	}
	return kids[len(kids)-1]
}

// fakeChild is one in-process fake claude.
type fakeChild struct {
	env      map[string]string
	args     []string
	payloads []string
	mode     string

	stdin, stdout, stderr *chanPipe
	in                    *bufio.Reader

	mu       sync.Mutex    // guards sigName and closing done
	signaled chan struct{} // closed by a fatal signal
	sigName  string        // the fatal signal ("" = none)
	done     chan struct{} // closed once run returned
	code     int           // exit code (set before done closes)
	statusN  int
}

// exited is closed once the child is gone.
func (k *fakeChild) exited() <-chan struct{} { return k.done }

// kill is SIGKILL from outside (a test killing the child).
func (k *fakeChild) kill() { k.signal(syscall.SIGKILL) }

// alive reports whether the child still runs.
func (k *fakeChild) alive() bool {
	select {
	case <-k.done:
		return false
	default:
		return true
	}
}

func (k *fakeChild) signal(sig syscall.Signal) {
	if sig == syscall.SIGTERM && k.mode == "stubborn" {
		return // trap '' TERM
	}
	k.mu.Lock()
	defer k.mu.Unlock()
	if !k.alive() || k.sigName != "" {
		return
	}
	k.sigName = sig.String()
	close(k.signaled)
	// The kernel closes a dead process's pipe ends.
	k.stdin.closeRead()
	k.stdout.closeWrite()
	k.stderr.closeWrite()
}

func (k *fakeChild) wait() (bool, string) {
	<-k.done
	k.mu.Lock()
	defer k.mu.Unlock()
	if k.sigName != "" {
		return false, "signal: " + k.sigName
	}
	return k.code == 0, "exit status " + strconv.Itoa(k.code)
}

func envMap(env []string) map[string]string {
	m := map[string]string{}
	for _, kv := range env {
		if k, v, ok := strings.Cut(kv, "="); ok {
			m[k] = v // the last one wins, as exec.Cmd's dedup
		}
	}
	return m
}

func appendFile(path, s string) {
	if path == "" {
		return
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	_, _ = f.WriteString(s)
	_ = f.Close()
}

// start "execs" the fake: it fails as exec does for a missing binary or
// folder, emulates the testSandbox stand-in (records its argv, runs what
// follows "--"), logs argv, prompt, mcp config and cwd as the script does
// before it reads a line, and runs the protocol on a goroutine.
func (c *fakeCLI) start(spec childSpec) (*claudeChild, error) {
	if _, err := os.Stat(spec.name); err != nil {
		return nil, fmt.Errorf("starting claude: fork/exec %s: %w", spec.name, err)
	}
	if _, err := os.Stat(spec.dir); err != nil {
		return nil, fmt.Errorf("starting claude: chdir %s: %w", spec.dir, err)
	}
	env := envMap(spec.env)
	args := spec.args
	if filepath.Base(spec.name) == "sandbox-exec" {
		if rec := env["FAKE_SANDBOX_ARGV"]; rec != "" {
			var b strings.Builder
			for _, a := range args {
				b.WriteString(a + "\x00")
			}
			appendFile(rec, b.String()+"\n")
		}
		i := slices.Index(args, "--")
		if i < 0 || i+1 >= len(args) {
			return nil, errors.New("fake sandbox-exec: no command after --")
		}
		if _, err := os.Stat(args[i+1]); err != nil {
			return nil, fmt.Errorf("fake sandbox-exec: %w", err)
		}
		args = args[i+2:]
	}
	k := &fakeChild{
		env: env, args: args, payloads: spec.payloads, mode: env["FAKE_MODE"],
		stdin: newChanPipe(), stdout: newChanPipe(), stderr: newChanPipe(),
		signaled: make(chan struct{}), done: make(chan struct{}),
	}
	if k.mode == "" {
		k.mode = "normal"
	}
	k.in = bufio.NewReader(pipeReader{k.stdin})
	appendFile(env["FAKE_ARGV"], strings.Join(args, "\n")+"\n--\n")
	for i := 1; i < len(args); i++ {
		dest := map[string]string{"--system-prompt-file": env["FAKE_PROMPT"], "--mcp-config": env["FAKE_MCP"]}[args[i-1]]
		if dest == "" {
			continue
		}
		content := ""
		for j, p := range spec.payloads {
			if fsutil.PayloadPath(j) == args[i] {
				content = p
			}
		}
		appendFile(dest, content+"\n--\n")
	}
	if cwd := env["FAKE_CWD"]; cwd != "" {
		dir, _ := filepath.EvalSymlinks(spec.dir)
		appendFile(cwd, dir+"\n")
	}
	c.mu.Lock()
	c.kids = append(c.kids, k)
	c.mu.Unlock()
	go k.main()
	return &claudeChild{
		stdin: pipeWriter{k.stdin}, stdout: pipeReader{k.stdout}, stderr: pipeReader{k.stderr},
		wait: k.wait, signal: k.signal,
	}, nil
}

// fakeExit ends the fake's run with an exit code (a failed write — the
// child was killed — ends it too).
type fakeExit struct{ code int }

func (k *fakeChild) main() {
	defer func() {
		if r := recover(); r != nil {
			e, ok := r.(fakeExit)
			if !ok {
				panic(r)
			}
			k.code = e.code
		}
		k.stdout.closeWrite()
		k.stderr.closeWrite()
		k.stdin.closeRead()
		k.mu.Lock()
		close(k.done)
		k.mu.Unlock()
	}()
	k.run()
}

func (k *fakeChild) exit(code int) { panic(fakeExit{code}) }

// out prints one stdout line; a killed child stops at it.
func (k *fakeChild) out(line string) {
	if _, err := k.stdout.write([]byte(line + "\n")); err != nil {
		k.exit(1)
	}
}

func (k *fakeChild) errLine(line string) { _, _ = k.stderr.write([]byte(line + "\n")) }

// readLine reads one stdin line and logs it to $FAKE_STDIN; false at EOF.
func (k *fakeChild) readLine() (string, bool) {
	line, err := k.in.ReadString('\n')
	if err != nil {
		return "", false // an unterminated last line is dropped, as read -r does
	}
	line = strings.TrimSuffix(line, "\n")
	appendFile(k.env["FAKE_STDIN"], line+"\n")
	return line, true
}

// firstTime is the script's first_time over $FAKE_MARK.
func (k *fakeChild) firstTime() bool {
	mark := k.env["FAKE_MARK"]
	if _, err := os.Stat(mark); err == nil {
		return false
	}
	appendFile(mark, "")
	return true
}

var fakeFieldRes sync.Map // name → *regexp.Regexp

// fakeField is the script's field: the last "name":"value" in s.
func fakeField(s, name string) string {
	re, ok := fakeFieldRes.Load(name)
	if !ok {
		re, _ = fakeFieldRes.LoadOrStore(name, regexp.MustCompile(`.*"`+regexp.QuoteMeta(name)+`":"([^"]*)"`))
	}
	m := re.(*regexp.Regexp).FindStringSubmatch(s)
	if m == nil {
		return ""
	}
	return m[1]
}

func (k *fakeChild) mcpStatusAnswer(req string) {
	k.statusN++
	list := "[]"
	if path := k.env["FAKE_MCP_STATUS"]; path != "" {
		if data, err := os.ReadFile(path); err == nil && len(data) > 0 {
			lines := strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
			list = lines[len(lines)-1]
			if k.statusN <= len(lines) && lines[k.statusN-1] != "" {
				list = lines[k.statusN-1]
			}
		}
	}
	k.out(fmt.Sprintf(`{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{"mcpServers":%s}}}`,
		fakeField(req, "request_id"), list))
}

func (k *fakeChild) toolResult(toolUseID, content, isError string) {
	k.out(fmt.Sprintf(`{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","content":"%s","is_error":%s}]}}`,
		toolUseID, content, isError))
}

const fakeResultOK = `{"type":"result","subtype":"success","is_error":false,"result":"ok","session_id":"sess-fake","usage":{"input_tokens":3,"output_tokens":2}}`
const fakeResultInterrupted = `{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"sess-fake","usage":{"input_tokens":1,"output_tokens":0}}`

var (
	fakeInputRe   = regexp.MustCompile(`.*"input":(.*),"tool_use_id".*`)
	fakeMessageRe = regexp.MustCompile(`.*"message":"(.*)"}}}$`)
)

// gateTurn runs the scripted permission requests; false when interrupted.
func (k *fakeChild) gateTurn() bool {
	type pend struct{ rid, tuid string }
	var pending []pend
	data, _ := os.ReadFile(k.env["FAKE_CLAUDE_GATE_REQUESTS"])
	for req := range strings.SplitSeq(string(data), "\n") {
		if req == "" {
			continue
		}
		rid, tuid, tname := fakeField(req, "request_id"), fakeField(req, "tool_use_id"), fakeField(req, "tool_name")
		k.out(fmt.Sprintf(`{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"%s","name":"%s"}}}`, tuid, tname))
		input := ""
		if m := fakeInputRe.FindStringSubmatch(req); m != nil {
			input = strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(m[1])
		}
		k.out(fmt.Sprintf(`{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"%s"}}}`, input))
		k.out(`{"type":"stream_event","event":{"type":"content_block_stop","index":1}}`)
		k.out(req)
		pending = append(pending, pend{rid, tuid})
	}
	for len(pending) > 0 {
		line, ok := k.readLine()
		if !ok {
			return true
		}
		switch {
		case strings.Contains(line, `"subtype":"mcp_status"`):
			k.mcpStatusAnswer(line)
			continue
		case strings.Contains(line, `"subtype":"interrupt"`):
			for _, p := range pending {
				k.out(fmt.Sprintf(`{"type":"control_cancel_request","request_id":"%s"}`, p.rid))
				k.toolResult(p.tuid, "The user doesn't want to proceed with this tool use.", "true")
			}
			k.out(`{"type":"control_response","response":{"subtype":"success","request_id":"interrupt","response":{"still_queued":[]}}}`)
			k.out(fakeResultInterrupted)
			return false
		}
		var rest []pend
		for _, p := range pending {
			if !strings.Contains(line, `"request_id":"`+p.rid+`"`) {
				rest = append(rest, p)
				continue
			}
			if strings.Contains(line, `"behavior":"allow"`) {
				if k.env["FAKE_GATE_DIE_ON_ALLOW"] != "" {
					k.exit(3)
				}
				result := k.env["FAKE_GATE_RESULT"]
				if result == "" {
					result = "ran"
				}
				k.toolResult(p.tuid, result, "false")
				continue
			}
			msg := ""
			if m := fakeMessageRe.FindStringSubmatch(line); m != nil {
				msg = m[1]
			}
			k.toolResult(p.tuid, msg, "true")
		}
		pending = rest
	}
	return true
}

func (k *fakeChild) reply(text string) {
	k.out(`{"type":"stream_event","event":{"type":"message_start","message":{"model":"fake-model"}}}`)
	if k.mode == "internal_tool" {
		k.out(`{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"ts1","name":"ToolSearch"}}}`)
		k.out(`{"type":"stream_event","event":{"type":"content_block_stop","index":1}}`)
		k.out(`{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"ts1","content":"loaded"}]}}`)
		k.out(`{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"lt1","name":"mcp__watchtower__list_targets"}}}`)
		k.out(`{"type":"stream_event","event":{"type":"content_block_stop","index":1}}`)
		k.out(`{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"lt1","content":"[]"}]}}`)
	}
	k.out(`{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text"}}}`)
	k.out(fmt.Sprintf(`{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"%s"}}}`, text))
	k.out(`{"type":"stream_event","event":{"type":"content_block_stop","index":0}}`)
	k.out(fakeResultOK)
}

// printfB is printf's %b over the escapes the tests use.
var printfB = strings.NewReplacer(`\\`, `\`, `\n`, "\n", `\t`, "\t")

func (k *fakeChild) run() {
	switch k.mode {
	case "stubborn", "noread":
		// Never reads stdin; stubborn also ignores SIGTERM (see signal).
		<-k.signaled
		return
	}
	n := 0
	open := false // a turn was left unfinished (slow, ignore_interrupt)
	for {
		line, ok := k.readLine()
		if !ok {
			return
		}
		switch {
		case strings.Contains(line, `"subtype":"mcp_status"`):
			k.mcpStatusAnswer(line)
		case strings.Contains(line, `"subtype":"interrupt"`):
			if k.mode == "ignore_interrupt" {
				continue
			}
			k.out(`{"type":"control_response","response":{"subtype":"success"}}`)
			if open {
				k.out(fakeResultInterrupted)
			}
			open = false
		case strings.Contains(line, `"type":"user"`):
			n++
			k.userTurn(n, &open)
		}
	}
}

// userTurn answers one user message as the script's "type":"user" case.
func (k *fakeChild) userTurn(n int, open *bool) {
	if sid, src := k.env["FAKE_INIT_SID"], k.env["FAKE_API_KEY_SOURCE"]; sid+src != "" {
		auth := ""
		if src != "" {
			auth = `,"apiKeySource":"` + src + `"`
		}
		if sid == "" {
			sid = "sess-fake"
		}
		k.out(fmt.Sprintf(`{"type":"system","subtype":"init","session_id":"%s"%s}`, sid, auth))
	}
	switch k.mode {
	case "crash_once":
		if k.firstTime() {
			k.exit(3)
		}
	case "exit_clean":
		// Exit 0 mid-turn with partial text and no result line (L12).
		k.out(`{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text"}}}`)
		k.out(`{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"partial"}}}`)
		if s := k.env["FAKE_STDERR"]; s != "" {
			k.errLine(s)
		}
		k.exit(0)
	case "long_line":
		k.out(`{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text"}}}`)
		k.out(`{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"before "}}}`)
		typ := k.env["FAKE_LONG_TYPE"]
		if typ == "" {
			typ = "user"
		}
		size := 4096
		if v, err := strconv.Atoi(k.env["FAKE_LONG_BYTES"]); err == nil {
			size = v
		}
		k.out(`{"type":"` + typ + `","pad":"` + strings.Repeat("x", size) + `"}`)
		if typ == "result" {
			return
		}
		k.out(`{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"after"}}}`)
		k.out(`{"type":"stream_event","event":{"type":"content_block_stop","index":0}}`)
		k.out(fakeResultOK)
		return
	case "crash_always":
		crash := k.env["FAKE_CRASH"]
		if crash == "" {
			crash = "panic: cannot decode content block"
		}
		k.errLine(printfB.Replace(crash))
		k.exit(3)
	case "error_once", "error_always":
		if k.mode == "error_always" || k.firstTime() {
			msg := k.env["FAKE_ERROR"]
			if msg == "" {
				msg = "request too large"
			}
			k.out(`{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"sess-fake","usage":{"input_tokens":0,"output_tokens":0},"errors":["` + msg + `"]}`)
			return
		}
	case "quota":
		// Go only (a routing test): every message ends in a quota error
		// result, after a partial text with $TASK8_PARTIAL=yes.
		tokens := `"input_tokens":0,"output_tokens":0`
		if k.env["TASK8_PARTIAL"] == "yes" {
			k.out(`{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"partial before quota"}}}`)
			tokens = `"input_tokens":2,"output_tokens":1`
		}
		k.out(`{"type":"result","subtype":"error_during_execution","is_error":true,"result":"quota exhausted","error":{"type":"usage_limit_reached"},"usage":{` + tokens + `}}`)
		return
	case "gate":
		if k.gateTurn() {
			k.reply("turn " + strconv.Itoa(n))
		}
		return
	case "slow", "ignore_interrupt":
		if k.firstTime() {
			k.out(`{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"partial"}}}`)
			*open = true
			return
		}
	}
	k.reply("turn " + strconv.Itoa(n))
}

// chanPipe is an in-process pipe over a channel of chunks: a bounded
// buffer (16 × 4 KiB, a real pipe's size), so a writer to a child that
// stopped reading blocks as on a real pipe — on a channel, which
// testing/synctest sees as durably blocked. A write after the reader
// closed fails with EPIPE, as on a dead child's stdin.
type chanPipe struct {
	ch           chan []byte
	rdone, wdone chan struct{}
	rOnce, wOnce sync.Once
	buf          []byte // the reader's leftover chunk
}

func newChanPipe() *chanPipe {
	return &chanPipe{ch: make(chan []byte, 16), rdone: make(chan struct{}), wdone: make(chan struct{})}
}

func (p *chanPipe) closeRead()  { p.rOnce.Do(func() { close(p.rdone) }) }
func (p *chanPipe) closeWrite() { p.wOnce.Do(func() { close(p.wdone) }) }

func (p *chanPipe) write(b []byte) (int, error) {
	n := 0
	for n < len(b) {
		select {
		case <-p.wdone:
			return n, os.ErrClosed
		case <-p.rdone:
			return n, syscall.EPIPE
		default:
		}
		end := min(len(b), n+4096)
		select {
		case p.ch <- append([]byte(nil), b[n:end]...):
			n = end
		case <-p.rdone:
			return n, syscall.EPIPE
		case <-p.wdone:
			return n, os.ErrClosed
		}
	}
	return n, nil
}

func (p *chanPipe) read(b []byte) (int, error) {
	if len(p.buf) == 0 {
		select {
		case c := <-p.ch:
			p.buf = c
		case <-p.rdone:
			return 0, os.ErrClosed
		case <-p.wdone:
			select {
			case c := <-p.ch:
				p.buf = c
			default:
				return 0, io.EOF
			}
		}
	}
	n := copy(b, p.buf)
	p.buf = p.buf[n:]
	return n, nil
}

type pipeReader struct{ p *chanPipe }

func (r pipeReader) Read(b []byte) (int, error) { return r.p.read(b) }
func (r pipeReader) Close() error               { r.p.closeRead(); return nil }

type pipeWriter struct{ p *chanPipe }

func (w pipeWriter) Write(b []byte) (int, error) { return w.p.write(b) }
func (w pipeWriter) Close() error                { w.p.closeWrite(); return nil }
