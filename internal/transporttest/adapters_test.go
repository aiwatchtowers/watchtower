package transporttest

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/agentloop"
	"watchtower/internal/ai"
	"watchtower/internal/chat"
	"watchtower/internal/codex"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/llmusage"
	"watchtower/internal/ollama"
	"watchtower/internal/providers"
	"watchtower/internal/tools"
)

// Level is the shape of an invocation a scenario runs at (spec §4.1).
type Level string

const (
	LevelBatch   Level = "batch"   // digest.Generator
	LevelStream  Level = "stream"  // ai.Provider / chat.Querier
	LevelChat    Level = "chat"    // chat.Backend
	LevelSession Level = "session" // a Workbench session agent
)

// Cap names one capability a scenario can require (Caps.Has).
type Cap string

const (
	CapTools        Cap = "tools"
	CapUsageSplit   Cap = "usage_split"
	CapImages       Cap = "images"
	CapPDFs         Cap = "pdfs"
	CapWebSearch    Cap = "web_search"
	CapReadFolder   Cap = "read_folder"
	CapTurnCap      Cap = "turn_cap"
	CapChildProcess Cap = "child_process"
	CapWarmSession  Cap = "warm_session"

	CapFailureSignal        Cap = "failure_signal"
	CapInterruptSignal      Cap = "interrupt_signal"
	CapIdleSignal           Cap = "idle_signal"
	CapPermissionWait       Cap = "permission_wait"
	CapMidturnInput         Cap = "midturn_input"
	CapRegistryProbe        Cap = "registry_probe"
	CapCompressedTranscript Cap = "compressed_transcript"
	CapSubagentFeed         Cap = "subagent_feed"
	CapTranscriptWatch      Cap = "transcript_watch" // FailureSignal "pull": the §3.5 rollout watch
	CapQuickConnections     Cap = "quick_connections"
	// CapQuota: the transport can report a subscription quota with its reset
	// (a local OpenAI-compatible server has no subscription).
	CapQuota Cap = "quota"
)

// Caps is an adapter's capability row, the target values of the spec's
// §3.3 table (and the session capabilities of §3.5). A cell whose adapter
// lacks a required capability runs the scenario's unsupported branch; a
// declared capability the adapter does not deliver yet fails and is
// recorded as the open gap that promises it.
type Caps struct {
	Tools        string // none / watchtower / watchtower+quick_connections
	ToolEvents   bool
	TextStream   string // token / message / final
	Usage        string // none / totals / split
	CostReported bool
	Images       bool
	PDFs         bool
	WebSearch    bool
	ReadFolder   string // none / tools / shell_sandbox
	TurnCap      string // native / counted / none
	Interrupt    string // in_turn / kill_turn
	WarmSession  bool
	ChildProcess bool // structural: the transport runs a child process
	Quota        bool // reports a subscription quota (Failure Quota, ResetAt)

	FailureSignal   string // hook / pull / none
	InterruptSignal string // hook / pull / none
	IdleSignal      bool
	PermissionWait  bool
	// MidturnInput: a line goes to the session while its agent works
	// (agentkind's TakesLineWhileWorking), not only that the TUI queues it.
	MidturnInput         bool
	RegistryProbe        bool
	CompressedTranscript bool
	SubagentFeed         bool
}

// Has reports whether the row offers c.
func (c Caps) Has(want Cap) bool {
	switch want {
	case CapTools:
		return c.Tools != "" && c.Tools != "none"
	case CapUsageSplit:
		return c.Usage == "split"
	case CapImages:
		return c.Images
	case CapPDFs:
		return c.PDFs
	case CapWebSearch:
		return c.WebSearch
	case CapReadFolder:
		return c.ReadFolder != "" && c.ReadFolder != "none"
	case CapTurnCap:
		return c.TurnCap != "" && c.TurnCap != "none"
	case CapChildProcess:
		return c.ChildProcess
	case CapWarmSession:
		return c.WarmSession
	case CapFailureSignal:
		return c.FailureSignal != "" && c.FailureSignal != "none"
	case CapInterruptSignal:
		return c.InterruptSignal != "" && c.InterruptSignal != "none"
	case CapIdleSignal:
		return c.IdleSignal
	case CapPermissionWait:
		return c.PermissionWait
	case CapMidturnInput:
		return c.MidturnInput
	case CapRegistryProbe:
		return c.RegistryProbe
	case CapCompressedTranscript:
		return c.CompressedTranscript
	case CapSubagentFeed:
		return c.SubagentFeed
	case CapQuota:
		return c.Quota
	case CapQuickConnections:
		return c.Tools == "watchtower+quick_connections"
	case CapTranscriptWatch:
		return c.FailureSignal == "pull"
	}
	panic("unknown capability " + string(want))
}

// Adapter is one transport as the suite drives it: through today's public
// constructors, configured the way production configures them. A nil level
// function means the transport has no such level (no cell). The wiring
// mirrors cmd's by hand, so a task that changes how cmd configures a
// transport (a turn cap, web search, a new option) changes the matching
// adapter here in the same change and flips its cells.
type Adapter struct {
	Name    string // the matrix name prefix and the testdata/<Name>/ fixture dir
	Caps    Caps
	Batch   func(r *run) digest.Generator
	Stream  func(r *run) chat.Querier
	Chat    func(r *run) chat.Backend
	Session *sessionAgent
}

func (a *Adapter) levels() []Level {
	var out []Level
	if a.Batch != nil {
		out = append(out, LevelBatch)
	}
	if a.Stream != nil {
		out = append(out, LevelStream)
	}
	if a.Chat != nil {
		out = append(out, LevelChat)
	}
	if a.Session != nil {
		out = append(out, LevelSession)
	}
	return out
}

const (
	fakeModel    = "fixture-model"
	codexVersion = "codex-cli 0.159.2"
	sysPrompt    = "SYSTEM PROMPT"
	userPrompt   = "Reply with exactly three words."
)

// adapters is every transport of the suite.
var adapters = []*Adapter{
	{
		Name: "claude",
		Caps: Caps{Tools: "watchtower+quick_connections", ToolEvents: true, TextStream: "token", Usage: "split",
			CostReported: true, Images: true, PDFs: true, WebSearch: true, ReadFolder: "tools", TurnCap: "native",
			Interrupt: "in_turn", WarmSession: true, ChildProcess: true, Quota: true,
			FailureSignal: "hook", InterruptSignal: "hook", IdleSignal: true, PermissionWait: true,
			MidturnInput: true, RegistryProbe: true, SubagentFeed: true},
		Batch: func(r *run) digest.Generator {
			g := digest.NewClaudeGenerator(fakeModel, fakeModel, bins.claude)
			g.SetIsolatedChild() // cmd/generator.go routedGenerator
			return g
		},
		Stream: func(r *run) chat.Querier {
			c := ai.NewClient(fakeModel, r.mcpDB(), bins.claude)
			c.EmitToolEvents() // `ai query --events v2`
			c.SetExternalMCPServers(r.external)
			if r.readFolder != "" {
				c.SetReadFolder(r.readFolder)
			}
			if r.maxTurns > 0 {
				c.SetMaxTurns(r.maxTurns)
				r.capApplied = true
			}
			return c
		},
		Chat: func(r *run) chat.Backend {
			// The main chat's tool flags (cmd/ai_session.go claudeSessionOptions).
			opts := chat.ClaudeOptions{Binary: bins.claude, Model: fakeModel,
				SystemPrompt: sysPrompt, WorkDir: r.workDir(), Warn: io.Discard,
				Tools: ai.SessionBuiltinTools, AllowedTools: ai.AllowedTools(r.external) + "," + ai.WebSearchTool,
				DisallowedTools: ai.WithExternalDisallowed(ai.SessionDisallowedTools, r.external),
				InterruptGrace:  2 * time.Second, CloseGrace: time.Second}
			if len(r.external) > 0 {
				opts.MCPConfig = ai.ChatMCPConfig(r.mcpDB(), nil, r.external)
			}
			return chat.NewClaudeBackend(opts)
		},
		Session: claudeSession,
	},
	{
		Name: "codex",
		Caps: Caps{Tools: "watchtower+quick_connections", ToolEvents: true, TextStream: "message", Usage: "split",
			Images: true, WebSearch: true, ReadFolder: "shell_sandbox", TurnCap: "counted",
			Interrupt: "kill_turn", ChildProcess: true, Quota: true,
			// The session row's targets (§3.5): pulled failure and interrupt
			// (S1, S2), the probe (S6), compressed rollouts (S7, N1). G7's
			// spikes on codex 0.159.2 settled the rest (agentkind.SessionCaps):
			// no permission wait (S3, owner ask #521), no line while it works
			// (S5: its MCP forms raise no state), no idle signal (S10).
			FailureSignal: "pull", InterruptSignal: "pull",
			RegistryProbe: true, CompressedTranscript: true, SubagentFeed: true},
		Batch: func(r *run) digest.Generator {
			g := codex.NewCodexGenerator(fakeModel, fakeModel, bins.codex)
			g.SetIsolatedChild() // cmd/generator.go routedGenerator
			return g
		},
		Stream: func(r *run) chat.Querier { return codexClient(r) },
		Chat: func(r *run) chat.Backend {
			return chat.NewTurnBackend(codexClient(r), r.chatDB(), r.conv, chat.WithSystemPrompt(sysPrompt))
		},
		Session: codexSession,
	},
	{
		Name:  "ollama",
		Caps:  Caps{Tools: "none", TextStream: "token", Usage: "totals", ReadFolder: "none", TurnCap: "none", Interrupt: "kill_turn"},
		Batch: func(r *run) digest.Generator { return ollama.NewGenerator(fakeModel, fakeModel, r.serverURL()) },
		Stream: func(r *run) chat.Querier {
			c := ollama.NewClient(fakeModel, r.serverURL())
			c.EmitToolEvents() // `ai query --events v2`
			return readFolderRefusal(r, c)
		},
	},
	{
		Name: "runtime-b",
		Caps: Caps{Tools: "watchtower+quick_connections", ToolEvents: true, TextStream: "token", Usage: "totals",
			ReadFolder: "none", TurnCap: "native", Interrupt: "kill_turn"},
		Stream: func(r *run) chat.Querier { return readFolderRefusal(r, runtimeB(r)) },
		Chat: func(r *run) chat.Backend {
			return chat.NewTurnBackend(runtimeB(r), r.chatDB(), r.conv, chat.WithSystemPrompt(sysPrompt))
		},
	},
}

// codexClient is the codex chat/query client as cmd builds it
// (codexSessionClient, newQueryClient): the v2 tool events.
func codexClient(r *run) *codex.Client {
	c := codex.NewClient(fakeModel, r.mcpDB(), bins.codex)
	c.EmitToolEvents()
	c.SetExternalMCPServers(r.external)
	if r.readFolder != "" {
		c.SetReadFolder(r.readFolder)
	}
	if r.maxTurns > 0 {
		// As agent() and the spec reviewer run it: a private home whose
		// rollout the cap counts (N5, ask #522).
		home := filepath.Join(r.dir, "codex-home")
		if err := os.MkdirAll(home, 0o700); err != nil {
			r.t.Fatal(err)
		}
		c.SetRunHome(home)
		c.SetMaxTurns(r.maxTurns)
		r.capApplied = true
	}
	return c
}

// runtimeB is the in-process tool loop over the fake HTTP server with the
// two read tools the fixtures call.
func runtimeB(r *run) *agentloop.Client {
	reg := tools.New(r.chatDB())
	for _, tl := range []*tools.Tool{tools.NewListTargets(), tools.NewGetTarget()} {
		if err := reg.Register(tl); err != nil {
			r.t.Fatal(err)
		}
	}
	c := agentloop.NewClientWithOptions(fakeModel, r.serverURL(), reg,
		tools.Binding{Surface: "main", ConversationID: r.conv, TurnID: "t2"},
		agentloop.Options{MaxIterations: r.maxTurns})
	r.capApplied = r.maxTurns > 0
	c.EmitToolEvents()
	if len(r.external) > 0 {
		c.SetExternalMCPServers(r.external)
	}
	return c
}

// readFolderRefusal is `ai query --read-folder`'s rule in cmd/ai.go: a
// client with no SetReadFolder is refused with a capability error before
// it is called (L9).
func readFolderRefusal(r *run, q chat.Querier) chat.Querier {
	if _, ok := q.(interface{ SetReadFolder(string) }); ok || r.readFolder == "" {
		return q
	}
	return refusingQuerier{providers.CapabilityError("ollama", providers.ReviewReadonly,
		errors.New("--read-folder: the ollama provider has no file tools, so it cannot read the folder"))}
}

type refusingQuerier struct{ err error }

func (q refusingQuerier) Query(context.Context, string, string, string) (<-chan ai.StreamChunk, <-chan error, <-chan string) {
	textCh, errCh, sidCh := make(chan ai.StreamChunk), make(chan error, 1), make(chan string)
	errCh <- q.err
	close(textCh)
	close(errCh)
	close(sidCh)
	return textCh, errCh, sidCh
}

// run is one cell's environment.
type run struct {
	t          *testing.T
	dir        string
	fixture    string // the fixture file
	fakeLog    string // the fake CLI's invocation log
	readFolder string // set: a read-folder run
	maxTurns   int
	// external are the Quick Connections a quick-connection cell mounts
	// (a fake MCP server); nil = none.
	external []ai.ExternalMCPServer
	// capApplied is set by an adapter that put maxTurns in force.
	capApplied bool

	srvOnce sync.Once
	srv     *fakeServer

	dbOnce sync.Once
	db     *db.DB
	conv   int64
}

func newRun(t *testing.T, fixture string) *run {
	r := &run{t: t, dir: t.TempDir(), fixture: fixture}
	r.fakeLog = filepath.Join(r.dir, "fake.log")
	t.Setenv("WT_FAKECLI_FIXTURE", fixture)
	t.Setenv("WT_FAKECLI_LOG", r.fakeLog)
	t.Setenv("WT_FAKECLI_VERSION", codexVersion)
	t.Cleanup(func() { reapAll(t, readLaunches(t, r.fakeLog)) })
	return r
}

// mcpDB is the database path a CLI client mounts its MCP servers with when
// the cell has Quick Connections: the fake CLI never starts the servers,
// but the argv the client builds names them. "" otherwise (no mount).
func (r *run) mcpDB() string {
	if len(r.external) == 0 {
		return ""
	}
	return filepath.Join(r.dir, "mcp.db")
}

func (r *run) workDir() string {
	d := filepath.Join(r.dir, "work")
	if err := os.MkdirAll(d, 0o700); err != nil {
		r.t.Fatal(err)
	}
	return d
}

func (r *run) serverURL() string {
	r.srvOnce.Do(func() { r.srv = newFakeServer(r.t, r.fixture) })
	return r.srv.URL
}

func (r *run) requests() []string {
	if r.srv == nil {
		return nil
	}
	return r.srv.bodies()
}

// chatDB is the cell's database, the conversation seeded as the Desktop
// leaves it before a turn (CHAT-01): turn t1 finished, the owner message of
// turn t2 persisted. The conversation is r.conv after the first call.
func (r *run) chatDB() *db.DB {
	r.dbOnce.Do(func() {
		path := filepath.Join(r.dir, "chat.db")
		raw, err := os.ReadFile(migratedDB(r.t))
		if err != nil {
			r.t.Fatal(err)
		}
		writeFile(r.t, path, string(raw))
		if r.db, err = db.Open(path); err != nil {
			r.t.Fatal(err)
		}
		r.t.Cleanup(func() { _ = r.db.Close() })
		res, err := r.db.Exec(`INSERT INTO chat_conversations (title, created_at, updated_at) VALUES ('', 1, 1)`)
		if err != nil {
			r.t.Fatal(err)
		}
		r.conv, _ = res.LastInsertId()
		var parent any
		for _, m := range []struct{ role, text, turn string }{
			{"user", "what slipped?", "t1"}, {"assistant", replayAnswer, "t1"}, {"user", userPrompt, "t2"},
		} {
			res, err := r.db.Exec(`INSERT INTO chat_messages (conversation_id, parent_id, role, text, turn_id, created_at)
				VALUES (?, ?, ?, ?, ?, 1)`, r.conv, parent, m.role, m.text, m.turn)
			if err != nil {
				r.t.Fatal(err)
			}
			parent, _ = res.LastInsertId()
		}
	})
	return r.db
}

// replayAnswer is turn t1's answer, which a replay transport carries into
// turn t2.
const replayAnswer = "the refunds launch slipped"

// launch is one fake CLI invocation from its log.
type launch struct {
	PID           int      `json:"pid"`
	PGID          int      `json:"pgid"`
	Argv          []string `json:"argv"`
	Grandchildren []int    `json:"-"`
}

func readLaunches(t *testing.T, path string) []launch {
	t.Helper()
	l, _ := readFakeLog(t, path)
	return l
}

// readFakeLog reads the fake CLI's log: its launches (with their
// grandchildren) and the errors it exited on.
func readFakeLog(t *testing.T, path string) (out []launch, fakeErrors []string) {
	t.Helper()
	f, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 16<<20)
	for sc.Scan() {
		var line struct {
			launch
			Grandchild int    `json:"grandchild"`
			FakeError  string `json:"fake_error"`
		}
		if err := json.Unmarshal(sc.Bytes(), &line); err != nil {
			t.Errorf("fake log line %q: %v", sc.Text(), err)
			continue
		}
		switch {
		case line.FakeError != "":
			fakeErrors = append(fakeErrors, line.FakeError)
		case line.Grandchild > 0 && len(out) > 0:
			out[len(out)-1].Grandchildren = append(out[len(out)-1].Grandchildren, line.Grandchild)
		case line.PID > 0:
			out = append(out, line.launch)
		}
	}
	return out, fakeErrors
}

// fakeServer replays a fixture as an OpenAI-compatible endpoint: section n
// answers the n-th request (the last repeats; sections split as the fake
// CLI splits them, fakecli/main.go). Directives: "#! status N", "#! sleep
// D", "#! hang" (until the request is cancelled), and the CLI's "#! exit
// N", which over HTTP answers 599; "#! stderr" is the CLI's only. Every
// other non-comment line is written as a body line and flushed. An unknown
// or unparsable directive fails the cell.
type fakeServer struct {
	*httptest.Server
	mu   sync.Mutex
	reqs []string
}

// httpStep is one parsed line of a fakeServer section.
type httpStep struct {
	status int           // > 0: set the status
	sleep  time.Duration // > 0: sleep
	hang   bool
	line   string // a body line when the others are zero
}

func parseHTTPFixture(t *testing.T, fixture string) [][]httpStep {
	t.Helper()
	raw, err := os.ReadFile(fixture)
	if err != nil {
		t.Fatal(err)
	}
	sections := [][]httpStep{nil}
	for _, line := range strings.Split(string(raw), "\n") {
		directive, isDirective := strings.CutPrefix(line, "#!")
		name, arg, _ := strings.Cut(strings.TrimSpace(directive), " ")
		var step httpStep
		switch {
		case isDirective && name == "next-invocation":
			sections = append(sections, nil)
			continue
		case isDirective && name == "status":
			if step.status, err = strconv.Atoi(arg); err != nil || step.status < 100 {
				t.Fatalf("%s: bad status %q", fixture, arg)
			}
		case isDirective && name == "exit":
			step.status = 599
		case isDirective && name == "sleep":
			if step.sleep, err = time.ParseDuration(arg); err != nil {
				t.Fatalf("%s: bad sleep %q", fixture, arg)
			}
		case isDirective && name == "hang":
			step.hang = true
		case isDirective && name == "stderr":
			continue
		case isDirective:
			t.Fatalf("%s: directive %q has no HTTP meaning", fixture, name)
		case strings.HasPrefix(line, "#") || strings.TrimSpace(line) == "":
			continue
		default:
			step.line = line
		}
		sections[len(sections)-1] = append(sections[len(sections)-1], step)
	}
	return sections
}

func newFakeServer(t *testing.T, fixture string) *fakeServer {
	sections := parseHTTPFixture(t, fixture)
	s := &fakeServer{}
	s.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		body, _ := io.ReadAll(req.Body)
		s.mu.Lock()
		n := len(s.reqs)
		s.reqs = append(s.reqs, string(body))
		s.mu.Unlock()
		status := http.StatusOK
		var out []string
		for _, step := range sections[min(n, len(sections)-1)] {
			switch {
			case step.status > 0:
				status = step.status
			case step.sleep > 0:
				time.Sleep(step.sleep)
			case step.hang:
				w.WriteHeader(status)
				writeLines(w, out)
				<-req.Context().Done()
				return
			default:
				out = append(out, step.line)
			}
		}
		w.WriteHeader(status)
		writeLines(w, out)
	}))
	t.Cleanup(s.Close)
	return s
}

func writeLines(w http.ResponseWriter, lines []string) {
	for _, l := range lines {
		_, _ = io.WriteString(w, l+"\n")
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
	}
}

func (s *fakeServer) bodies() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.reqs...)
}

// Outcome is what one cell's run produced, in the normalized vocabulary:
// v2 chat events for the stream and chat levels (a stream's chunks through
// chat.ChunkEvents), the text, usage and error of a batch call.
type Outcome struct {
	Events   []chat.Event
	Text     string
	Usage    *digest.Usage
	Err      error
	Calls    []llmusage.Call
	Launches []launch
	Requests []string
	// Alive is, per launch, whether its pid still ran when the turn ended
	// (before Close): the warm child surviving an interrupt.
	Alive []bool
	// Session is the session level's result.
	Session *sessionResult
	// FakeErrors are what the fake CLI rejected (argv, stdin, a directive).
	FakeErrors []string
	// CapApplied says the adapter put the scenario's turn cap in force.
	CapApplied bool
	// QCCalls are the tools the fake Quick Connection server ran.
	QCCalls []string
}

func driveBatch(ctx context.Context, r *run, a *Adapter, o *Outcome) {
	o.Text, o.Usage, _, o.Err = a.Batch(r).Generate(ctx, sysPrompt, userPrompt, "")
}

func driveStream(ctx context.Context, r *run, a *Adapter, o *Outcome) {
	textCh, errCh, sidCh := a.Stream(r).Query(ctx, sysPrompt, userPrompt, "")
	for c := range textCh {
		o.Events = append(o.Events, chat.ChunkEvents("t2", c)...)
	}
	for range sidCh {
	}
	for err := range errCh {
		if err != nil && o.Err == nil {
			o.Err = err
		}
	}
	if o.Err == nil {
		o.Events = append(o.Events, chat.Event{Type: chat.EventTurnDone, TurnID: "t2", Status: chat.StatusComplete})
	}
}

func driveChat(ctx context.Context, r *run, a *Adapter, s *Scenario, o *Outcome) {
	b := a.Chat(r)
	defer func() { _ = b.Close() }()
	if _, err := b.Start(ctx); err != nil {
		o.Err = err
		return
	}
	turns := []string{"t2"}
	if s.Fixture.Drive == driveTwoTurns && a.Caps.WarmSession {
		turns = []string{"t1", "t2"}
	}
	for _, turn := range turns {
		cmd := chat.Command{Type: chat.CommandTurn, TurnID: turn, Text: userPrompt}
		if s.Fixture.Attach != "" {
			cmd.Attachments = []chat.Attachment{r.attachment(s.Fixture.Attach)}
		}
		var once sync.Once
		if s.Fixture.Drive == driveCancelAtText || s.Fixture.Drive == driveCancelAtTool {
			// A transport that shows nothing to cancel at is cancelled
			// anyway, so the cell ends instead of waiting out its timeout.
			timer := time.AfterFunc(3*time.Second, func() { once.Do(func() { _ = b.Cancel() }) })
			defer timer.Stop()
		}
		emit := func(e chat.Event) {
			o.Events = append(o.Events, e)
			// Cancel at text once the whole first message has arrived: a
			// fixture may split it across deltas, and cancelling at the
			// first one races the rest of it.
			if (s.Fixture.Drive == driveCancelAtText && e.Type == chat.EventTextDelta && strings.Contains(o.text(), markFirst)) ||
				(s.Fixture.Drive == driveCancelAtTool && e.Type == chat.EventToolStart) {
				once.Do(func() { go func() { _ = b.Cancel() }() })
			}
		}
		if err := b.Turn(ctx, cmd, emit); err != nil {
			o.Err = err
			break
		}
	}
	for _, l := range readLaunches(r.t, r.fakeLog) {
		o.Alive = append(o.Alive, !pidGone(l.PID, 0))
	}
}

// attachment writes an attachment file of kind ("image" or "pdf").
func (r *run) attachment(kind string) chat.Attachment {
	switch kind {
	case "image":
		p := filepath.Join(r.dir, "shot.png")
		writeFile(r.t, p, "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\rIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00\x05\x18\xd8N\x00\x00\x00\x00IEND\xaeB`\x82")
		return chat.Attachment{Path: p, Mime: "image/png", Name: "shot.png"}
	case "pdf":
		p := filepath.Join(r.dir, "doc.pdf")
		writeFile(r.t, p, "%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Count 0/Kids[]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n")
		return chat.Attachment{Path: p, Mime: "application/pdf", Name: "doc.pdf"}
	}
	r.t.Fatalf("unknown attachment kind %q", kind)
	return chat.Attachment{}
}

// runCell runs scenario s on adapter a at level, supported or not, and
// returns the outcome. The cell's fake processes are reaped at its end.
func runCell(t *testing.T, a *Adapter, s *Scenario, level Level) *Outcome {
	if level == LevelSession {
		return &Outcome{Session: a.Session.run(t, s)}
	}
	path, _ := fixturePath(t, a, s, level)
	r := newRun(t, path)
	r.maxTurns = s.Fixture.MaxTurns
	var qc *fakeMCP
	if s.Fixture.QuickConnection {
		qc = newFakeMCP(t)
		r.external = []ai.ExternalMCPServer{qc.server()}
	}
	if s.Fixture.ReadFolder {
		r.readFolder = r.workDir()
	}
	timeout := 10 * time.Second
	if raceEnabled {
		timeout = 40 * time.Second
	}
	if s.Fixture.Drive == driveTimeout {
		timeout = 1500 * time.Millisecond
	}
	r.chatDB() // set up before the run's deadline starts
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	ledger.take()
	o := &Outcome{}
	switch level {
	case LevelBatch:
		driveBatch(ctx, r, a, o)
	case LevelStream:
		driveStream(ctx, r, a, o)
	case LevelChat:
		driveChat(ctx, r, a, s, o)
	case LevelSession:
		t.Fatal("a session cell has no LLM run") // handled above
	}
	o.Launches, o.FakeErrors = readFakeLog(t, r.fakeLog)
	o.CapApplied = r.capApplied
	if qc != nil {
		o.QCCalls = qc.seen()
	}
	o.Requests = r.requests()
	o.Calls = ledger.take()
	return o
}

// fixturePath is testdata/<transport>/<file>.<level>.jsonl when it exists,
// else testdata/<transport>/<file>.jsonl; found is false when neither does,
// and the path is then the shared "never started" fixture (an unsupported
// cell must not start anything).
func fixturePath(t *testing.T, a *Adapter, s *Scenario, level Level) (path string, found bool) {
	t.Helper()
	dir := filepath.Join("testdata", a.Name)
	for _, name := range []string{s.Fixture.File + "." + string(level) + ".jsonl", s.Fixture.File + ".jsonl"} {
		p, err := filepath.Abs(filepath.Join(dir, name))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := os.Stat(p); err == nil {
			return p, true
		}
	}
	p, err := filepath.Abs(filepath.Join("testdata", "never_started.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	return p, false
}

// fakeMCP is a Quick Connection: an MCP server over streamable HTTP with
// one allowed read tool, get_issue.
type fakeMCP struct {
	url   string
	mu    sync.Mutex
	calls []string
}

func newFakeMCP(t *testing.T) *fakeMCP {
	t.Helper()
	f := &fakeMCP{}
	server := mcp.NewServer(&mcp.Implementation{Name: "fake", Version: "1"}, nil)
	server.AddTool(&mcp.Tool{Name: "get_issue", Description: "Read one issue.",
		InputSchema: map[string]any{"type": "object", "properties": map[string]any{"key": map[string]any{"type": "string"}}}},
		func(context.Context, *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			f.mu.Lock()
			f.calls = append(f.calls, "get_issue")
			f.mu.Unlock()
			return &mcp.CallToolResult{StructuredContent: map[string]any{"key": "PAY-1", "status": "open"}}, nil
		})
	srv := httptest.NewServer(mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server { return server }, nil))
	t.Cleanup(srv.Close)
	f.url = srv.URL
	return f
}

func (f *fakeMCP) seen() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.calls...)
}

func (f *fakeMCP) server() ai.ExternalMCPServer {
	return ai.ExternalMCPServer{ID: 1, Name: "acme", Kind: "http", URL: f.url, AllowTools: []string{"get_issue"}}
}
