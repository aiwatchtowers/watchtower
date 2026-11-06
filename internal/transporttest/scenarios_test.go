package transporttest

import (
	"errors"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"watchtower/internal/chat"
	"watchtower/internal/logredact"
	"watchtower/internal/providers"
)

// Scenario is one row of the suite's table (spec §4.1). Levels are where it
// applies; Requires the capabilities it needs, and a cell whose adapter
// lacks one runs Assert with Cell.Supported false. Fixture names the
// recorded run and how it is driven. Assert returns nil when the cell
// holds.
type Scenario struct {
	Name     string
	Levels   []Level
	Requires []Cap
	Fixture  Fixture
	Assert   func(c *Cell) error
}

// Fixture is a scenario's input: the fixture file stem under
// testdata/<transport>/ (a "<File>.<level>.jsonl" wins over
// "<File>.jsonl"), and how the run is driven.
type Fixture struct {
	File       string
	Drive      Drive
	Attach     string // chat attachment kind: "image" or "pdf"
	ReadFolder bool
	MaxTurns   int
	// Session is the session level's script (sessions_test.go).
	Session []sessionStep
	// QuickConnection mounts a fake Quick Connection (an MCP server with
	// the read tool get_issue) on the adapter.
	QuickConnection bool
	// ReadFeed reads the session's feed and title after the script;
	// OlderWrite then tries a write stamped before the stored state.
	ReadFeed, OlderWrite bool
}

// Drive is how a cell's run is driven.
type Drive int

const (
	drivePlain        Drive = iota
	driveTimeout            // the context times out while the fake hangs
	driveCancelAtText       // Cancel at the first text_delta
	driveCancelAtTool       // Cancel at the first tool_start
	driveTwoTurns           // a warm transport runs t1 then t2
)

// Cell is one adapter × level × scenario run.
type Cell struct {
	A         *Adapter
	S         *Scenario
	Level     Level
	Supported bool
	O         *Outcome
	fixture   string // the fixture text, for its "# expect-…" comments
}

// llmLevels are the three LLM levels.
var llmLevels = []Level{LevelBatch, LevelStream, LevelChat}

// scenarios is the suite's table: the LLM rows of spec §4.1, then the
// Workbench session rows (sessionScenarios).
var scenarios = append([]*Scenario{
	{Name: "plain-answer", Levels: llmLevels, Fixture: Fixture{File: "plain_answer"}, Assert: assertPlainAnswer},
	{Name: "two-messages", Levels: []Level{LevelStream, LevelChat}, Requires: []Cap{CapTools},
		Fixture: Fixture{File: "two_messages"}, Assert: assertTwoMessages},
	{Name: "tool-ok", Levels: []Level{LevelStream, LevelChat}, Requires: []Cap{CapTools},
		Fixture: Fixture{File: "tool_ok"}, Assert: assertTool(true)},
	{Name: "tool-failed", Levels: []Level{LevelStream, LevelChat}, Requires: []Cap{CapTools},
		Fixture: Fixture{File: "tool_failed"}, Assert: assertTool(false)},
	{Name: "quick-connection-tool", Levels: []Level{LevelStream, LevelChat}, Requires: []Cap{CapQuickConnections},
		Fixture: Fixture{File: "quick_connection", QuickConnection: true}, Assert: assertQuickConnection},
	{Name: "oversized-line", Levels: llmLevels, Requires: []Cap{CapChildProcess},
		Fixture: Fixture{File: "oversized_line"}, Assert: assertOversized},
	{Name: "fail-auth", Levels: llmLevels, Fixture: Fixture{File: "fail_auth"},
		Assert: assertFailure(providers.Auth, chat.CodeAuth)},
	{Name: "fail-model", Levels: llmLevels, Fixture: Fixture{File: "fail_model"},
		Assert: assertFailure(providers.Model, "")},
	{Name: "fail-rate-limit", Levels: llmLevels, Fixture: Fixture{File: "fail_rate_limit"},
		Assert: assertFailure(providers.RateLimit, chat.CodeRateLimit)},
	{Name: "fail-quota", Levels: llmLevels, Requires: []Cap{CapQuota}, Fixture: Fixture{File: "fail_quota"},
		Assert: assertQuota},
	{Name: "fail-overload", Levels: llmLevels, Fixture: Fixture{File: "fail_overload"},
		Assert: assertFailure(providers.Overload, chat.CodeRateLimit)},
	{Name: "no-completion", Levels: llmLevels, Fixture: Fixture{File: "no_completion"}, Assert: assertNoCompletion},
	{Name: "interrupt-text", Levels: []Level{LevelChat},
		Fixture: Fixture{File: "interrupt_text", Drive: driveCancelAtText}, Assert: assertInterrupted},
	{Name: "interrupt-tool", Levels: []Level{LevelChat}, Requires: []Cap{CapTools},
		Fixture: Fixture{File: "interrupt_tool", Drive: driveCancelAtTool}, Assert: assertInterrupted},
	{Name: "timeout-kill", Levels: llmLevels, Fixture: Fixture{File: "timeout_kill", Drive: driveTimeout}, Assert: assertTimeout},
	{Name: "usage-cache", Levels: llmLevels, Requires: []Cap{CapUsageSplit}, Fixture: Fixture{File: "usage_cache"},
		Assert: assertUsageCache},
	{Name: "multi-turn-replay", Levels: []Level{LevelChat}, Fixture: Fixture{File: "multi_turn", Drive: driveTwoTurns},
		Assert: assertMultiTurn},
	{Name: "turn-cap-sequential", Levels: []Level{LevelStream}, Requires: []Cap{CapTurnCap},
		Fixture: Fixture{File: "turn_cap_sequential", MaxTurns: 2}, Assert: assertTurnCapStops},
	{Name: "turn-cap-parallel", Levels: []Level{LevelStream}, Requires: []Cap{CapTurnCap},
		Fixture: Fixture{File: "turn_cap_parallel", MaxTurns: 2}, Assert: assertTurnCapCompletes},
	{Name: "turn-cap-text", Levels: []Level{LevelStream}, Requires: []Cap{CapTurnCap},
		Fixture: Fixture{File: "turn_cap_text", MaxTurns: 1}, Assert: assertTurnCapCompletes},
	{Name: "image", Levels: []Level{LevelChat}, Requires: []Cap{CapImages},
		Fixture: Fixture{File: "image", Attach: "image"}, Assert: assertAttachment},
	{Name: "pdf", Levels: []Level{LevelChat}, Requires: []Cap{CapPDFs},
		Fixture: Fixture{File: "pdf", Attach: "pdf"}, Assert: assertAttachment},
	{Name: "read-folder", Levels: []Level{LevelStream}, Requires: []Cap{CapReadFolder},
		Fixture: Fixture{File: "read_folder", ReadFolder: true}, Assert: assertReadFolder},
	{Name: "web-search", Levels: []Level{LevelChat}, Requires: []Cap{CapWebSearch},
		Fixture: Fixture{File: "web_search"}, Assert: assertWebSearch},
}, sessionScenarios...)

// ---- outcome readers -------------------------------------------------------

func (o *Outcome) text() string {
	if o.Events == nil {
		return o.Text
	}
	var b strings.Builder
	for _, e := range o.Events {
		if e.Type == chat.EventTextDelta {
			b.WriteString(e.Text)
		}
	}
	return b.String()
}

func (o *Outcome) eventsOf(typ string) []chat.Event {
	var out []chat.Event
	for _, e := range o.Events {
		if e.Type == typ {
			out = append(out, e)
		}
	}
	return out
}

// terminal is the last turn_done or turn-scoped error, if any.
func (o *Outcome) terminal() (chat.Event, bool) {
	for i := len(o.Events) - 1; i >= 0; i-- {
		if e := o.Events[i]; e.Type == chat.EventTurnDone || (e.Type == chat.EventError && e.TurnID != "") {
			return e, true
		}
	}
	return chat.Event{}, false
}

// failure is the run's typed failure: the returned error's, else the
// terminal error event's cause.
func (o *Outcome) failure() (*providers.Failure, error) {
	err := o.Err
	if err == nil {
		if e, ok := o.terminal(); ok && e.Type == chat.EventError {
			err = e.Cause
			if err == nil {
				return nil, fmt.Errorf("error event %q has no typed cause", e.Code)
			}
		}
	}
	if err == nil {
		return nil, errors.New("the run succeeded")
	}
	var f *providers.Failure
	if !errors.As(err, &f) {
		return nil, fmt.Errorf("error is not a providers.Failure: %T", err)
	}
	return f, nil
}

// completed checks the run ended as a success.
func (c *Cell) completed() error {
	if c.O.Err != nil {
		return fmt.Errorf("run failed: %s", logredact.Full(c.O.Err))
	}
	if c.Level == LevelBatch {
		return nil
	}
	e, ok := c.O.terminal()
	if !ok {
		return errors.New("no terminal event")
	}
	if e.Type != chat.EventTurnDone || e.Status != chat.StatusComplete {
		return fmt.Errorf("terminal event %s/%s %q", e.Type, e.Status, e.Message)
	}
	return nil
}

// refusedBeforeStart is the unsupported branch of a refusable capability
// (spec §4.3): an owner-readable refusal before any child or HTTP request.
func (c *Cell) refusedBeforeStart() error {
	err := c.O.Err
	if e, ok := c.O.terminal(); err == nil && ok && e.Type == chat.EventError {
		err = e.Cause
	}
	var f *providers.Failure
	var ae *chat.AttachmentError
	switch {
	case err == nil:
		return errors.New("not refused")
	case errors.As(err, &f) && f.Category == providers.Capability:
	case errors.As(err, &ae) && ae.CapabilityMissing:
		// Today's refusal of a binary file by a text-only backend (A2 makes
		// it a capability refusal).
	default:
		return fmt.Errorf("refused with %T, not a capability refusal", err)
	}
	if strings.TrimSpace(logredact.Full(err)) == "" {
		return errors.New("the refusal has no reason")
	}
	return c.nothingStarted()
}

func (c *Cell) nothingStarted() error {
	if n := len(c.O.Launches); n > 0 {
		return fmt.Errorf("%d child process(es) started", n)
	}
	if n := len(c.O.Requests); n > 0 {
		return fmt.Errorf("%d HTTP request(s) made", n)
	}
	return nil
}

// noToolsOffered is the unsupported branch of a tool scenario: the
// transport was offered no tool and ran none.
func (c *Cell) noToolsOffered() error {
	for _, body := range c.O.Requests {
		if strings.Contains(body, `"tools"`) {
			return errors.New("the request offered tools")
		}
	}
	if len(c.O.eventsOf(chat.EventToolStart)) > 0 {
		return errors.New("a tool ran")
	}
	return nil
}

// expect reads a "# expect-<key> …" comment of the fixture.
func (c *Cell) expect(key string) (string, bool) {
	for _, line := range strings.Split(c.fixture, "\n") {
		if v, ok := strings.CutPrefix(strings.TrimSpace(line), "# expect-"+key); ok {
			return strings.TrimSpace(v), true
		}
	}
	return "", false
}

func readFixture(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// ---- assertions ------------------------------------------------------------

// The fixtures' marker texts.
const (
	markFirst  = "First message."
	markSecond = "Second message."
	markAfter  = "After the big line."
	markThird  = "THIRD RESPONSE"
	markOwner  = "OWNER-VISIBLE"
)

func assertPlainAnswer(c *Cell) error {
	if err := c.completed(); err != nil {
		return err
	}
	if strings.TrimSpace(c.O.text()) == "" {
		return errors.New("blank answer")
	}
	switch c.Level {
	case LevelBatch:
		if c.O.Usage == nil {
			return errors.New("no usage")
		}
	default:
		if len(c.O.eventsOf(chat.EventUsage)) == 0 {
			return errors.New("no usage event")
		}
	}
	return oneCall(c, true)
}

// oneCall checks exactly one llm_calls row (LLMUSAGE-01) with ok.
func oneCall(c *Cell, ok bool) error {
	if n := len(c.O.Calls); n != 1 {
		return fmt.Errorf("%d llm_calls rows, want 1", n)
	}
	if c.O.Calls[0].OK != ok {
		return fmt.Errorf("llm_calls ok=%v, want %v", c.O.Calls[0].OK, ok)
	}
	return nil
}

func assertTwoMessages(c *Cell) error {
	if !c.Supported {
		return c.noToolsOffered()
	}
	if err := c.completed(); err != nil {
		return err
	}
	text := c.O.text()
	i, j := strings.Index(text, markFirst), strings.Index(text, markSecond)
	switch {
	case i < 0:
		return errors.New("the first message was wiped")
	case j < 0:
		return errors.New("the second message is missing")
	case j < i:
		return errors.New("the messages are out of order")
	case !strings.Contains(text[i+len(markFirst):j], "\n\n"):
		return errors.New("no separator between the messages")
	}
	return nil
}

func assertTool(wantOK bool) func(c *Cell) error {
	return func(c *Cell) error {
		if !c.Supported {
			return c.noToolsOffered()
		}
		if err := c.completed(); err != nil {
			return err
		}
		starts, ends := c.O.eventsOf(chat.EventToolStart), c.O.eventsOf(chat.EventToolEnd)
		if len(starts) != 1 || len(ends) != 1 {
			return fmt.Errorf("%d tool_start / %d tool_end, want 1/1", len(starts), len(ends))
		}
		if starts[0].ID == "" || starts[0].ID != ends[0].ID {
			return fmt.Errorf("tool ids %q/%q do not match", starts[0].ID, ends[0].ID)
		}
		if ends[0].OK == nil || *ends[0].OK != wantOK {
			return fmt.Errorf("tool_end ok=%v, want %v", ends[0].OK, wantOK)
		}
		if !wantOK && strings.TrimSpace(ends[0].Summary) == "" {
			return errors.New("a failed tool has no reason (CHAT-02)")
		}
		if first, ok := c.expect("first"); ok && !strings.Contains(c.O.text(), first) {
			return errors.New("the text before the tool was not kept")
		}
		return nil
	}
}

func assertOversized(c *Cell) error {
	if !c.Supported {
		return nil // no child process: no stdout lines to cap
	}
	if err := c.completed(); err != nil {
		return err
	}
	if !strings.Contains(c.O.text(), markAfter) {
		return errors.New("the answer after the oversized line is missing")
	}
	return nil
}

func assertFailure(want providers.ErrorCategory, wantCode string) func(c *Cell) error {
	return func(c *Cell) error {
		f, err := c.O.failure()
		if err != nil {
			return err
		}
		if f.Category != want {
			return fmt.Errorf("category %q, want %q", f.Category, want)
		}
		if _, ok := c.expect("reset"); ok && f.ResetAt.IsZero() {
			return errors.New("the reset time was lost")
		}
		owner := logredact.Full(f)
		if c.Level == LevelChat {
			e, _ := c.O.terminal()
			if e.Type != chat.EventError {
				return fmt.Errorf("terminal event %s, want error", e.Type)
			}
			if wantCode != "" && e.Code != wantCode {
				return fmt.Errorf("chat code %q, want %q", e.Code, wantCode)
			}
			owner = e.Message
		}
		want := markOwner
		if v, ok := c.expect("owner"); ok {
			want = v
		}
		if !strings.Contains(owner, want) {
			return fmt.Errorf("the owner text %q was lost", want)
		}
		return nil
	}
}

// assertNoCompletion: a run that ends without its completion is a typed
// failure, never success. A CLI's is invalid_output; an HTTP stream that
// ends without [DONE] may be transport, since a clean close cannot be told
// from a dropped connection (spec §4.1).
func assertNoCompletion(c *Cell) error {
	f, err := c.O.failure()
	if err != nil {
		return fmt.Errorf("not a typed failure: %w", err)
	}
	if f.Category == providers.InvalidOutput || (!c.A.Caps.ChildProcess && c.Level == LevelStream && f.Category == providers.Transport) {
		return nil
	}
	return fmt.Errorf("category %q, want %q", f.Category, providers.InvalidOutput)
}

func assertInterrupted(c *Cell) error {
	if !c.Supported {
		return c.noToolsOffered()
	}
	if c.S.Fixture.Drive == driveCancelAtTool && len(c.O.eventsOf(chat.EventToolStart)) == 0 {
		return errors.New("no tool call was shown before the interrupt")
	}
	e, ok := c.O.terminal()
	if !ok || e.Type != chat.EventTurnDone || e.Status != chat.StatusInterrupted {
		return fmt.Errorf("terminal %s/%s, want turn_done interrupted", e.Type, e.Status)
	}
	if !strings.Contains(c.O.text(), markFirst) {
		return errors.New("the partial text was not delivered")
	}
	switch c.A.Caps.Interrupt {
	case "in_turn":
		if len(c.O.Alive) == 0 || !c.O.Alive[0] {
			return errors.New("the warm child did not survive the interrupt")
		}
	case "kill_turn":
		return c.groupGone()
	}
	return nil
}

// groupGone checks every fake pid of the cell, grandchildren included, is
// gone (spec §4.1 "timeout and context kill").
func (c *Cell) groupGone() error {
	for _, l := range c.O.Launches {
		for _, pid := range append([]int{l.PID}, l.Grandchildren...) {
			if !pidGone(pid, 3*time.Second) {
				return fmt.Errorf("pid %d survived", pid)
			}
		}
	}
	return nil
}

func assertTimeout(c *Cell) error {
	if c.O.Err == nil {
		e, ok := c.O.terminal()
		if !ok || (e.Type == chat.EventTurnDone && e.Status == chat.StatusComplete) {
			return errors.New("a timed-out run did not end in an error")
		}
	}
	if c.A.Caps.ChildProcess && len(c.O.Launches) == 0 {
		return errors.New("the fake never started")
	}
	return c.groupGone()
}

var usageRE = regexp.MustCompile(`(\w+)=(\d+)`)

// expectedUsage reads "# expect-usage fresh=N read=N write=N out=N".
func (c *Cell) expectedUsage() (map[string]int64, error) {
	v, ok := c.expect("usage")
	if !ok {
		return nil, errors.New("the fixture has no # expect-usage")
	}
	out := map[string]int64{}
	for _, m := range usageRE.FindAllStringSubmatch(v, -1) {
		n, _ := strconv.ParseInt(m[2], 10, 64)
		out[m[1]] = n
	}
	return out, nil
}

func assertUsageCache(c *Cell) error {
	want, err := c.expectedUsage()
	if err != nil {
		return err
	}
	if err := c.completed(); err != nil {
		return err
	}
	if err := oneCall(c, true); err != nil {
		return err
	}
	row := c.O.Calls[0]
	got := map[string]int64{"fresh": row.Input, "read": row.CacheRead, "write": row.CacheWrite5m + row.CacheWrite1h, "out": row.Output}
	for k, v := range want {
		if got[k] != v {
			return fmt.Errorf("llm_calls %s=%d, want %d", k, got[k], v)
		}
	}
	if row.Estimated {
		return errors.New("the reported usage was estimated")
	}
	if !c.Supported { // totals only: all input as fresh, no cache split (AUTO-08)
		return nil
	}
	all := want["fresh"] + want["read"] + want["write"]
	switch c.Level {
	case LevelBatch:
		if c.O.Usage == nil || int64(c.O.Usage.TotalAPITokens) != all {
			return fmt.Errorf("batch usage %+v, want %d API tokens", c.O.Usage, all)
		}
	default:
		u := c.O.eventsOf(chat.EventUsage)
		if len(u) == 0 {
			return errors.New("no usage event")
		}
		last := u[len(u)-1]
		if int64(last.TokensIn) != all || int64(last.TokensOut) != want["out"] {
			return fmt.Errorf("usage event in=%d out=%d, want in=%d (fresh + cache) out=%d", last.TokensIn, last.TokensOut, all, want["out"])
		}
	}
	return nil
}

func assertMultiTurn(c *Cell) error {
	if err := c.completed(); err != nil {
		return err
	}
	if c.A.Caps.WarmSession {
		if n := len(c.O.Launches); n != 1 {
			return fmt.Errorf("%d launches over two turns, want the warm child reused", n)
		}
		if n := len(c.O.eventsOf(chat.EventTurnDone)); n != 2 {
			return fmt.Errorf("%d turns done, want 2", n)
		}
		return nil
	}
	// A replay transport: turn 2 carries turn 1. A CLI fake checks its stdin
	// itself (stdin-has); an HTTP request body is checked here.
	for _, body := range c.O.Requests {
		if !strings.Contains(body, replayAnswer) {
			return errors.New("turn 2 did not carry turn 1's answer")
		}
	}
	return nil
}

func assertTurnCapStops(c *Cell) error {
	if !c.Supported {
		return nil // no turn cap: nothing to assert beyond the cell itself
	}
	if !c.O.CapApplied {
		return errors.New("no turn cap in force")
	}
	if strings.Contains(c.O.text(), markThird) {
		return errors.New("a response past the cap ran")
	}
	if n := len(c.O.Requests); n > c.S.Fixture.MaxTurns {
		return fmt.Errorf("%d model calls, cap %d", n, c.S.Fixture.MaxTurns)
	}
	if c.O.Err != nil {
		f, err := c.O.failure()
		if err != nil {
			return err
		}
		if f.Category != providers.Budget {
			return fmt.Errorf("stopped with %q, want %q", f.Category, providers.Budget)
		}
	} else {
		return errors.New("the run reached its cap without a budget failure")
	}
	return nil
}

func assertTurnCapCompletes(c *Cell) error {
	if !c.Supported {
		return nil
	}
	if !c.O.CapApplied {
		return errors.New("no turn cap in force")
	}
	if err := c.completed(); err != nil {
		return err
	}
	if !strings.Contains(c.O.text(), markSecond) {
		return errors.New("the final answer is missing")
	}
	return nil
}

func assertAttachment(c *Cell) error {
	if !c.Supported {
		return c.refusedBeforeStart()
	}
	return c.completed()
}

func assertReadFolder(c *Cell) error {
	if !c.Supported {
		return c.refusedBeforeStart()
	}
	return c.completed()
}

func assertWebSearch(c *Cell) error {
	if !c.Supported {
		return c.noWebSearchOffered()
	}
	if err := c.completed(); err != nil {
		return err
	}
	if len(c.O.eventsOf(chat.EventToolStart)) == 0 {
		return errors.New("the web search was not shown as a step")
	}
	// The child is told to search: Claude's WebSearch tool, or codex's
	// web_search set to anything but disabled (L5: today codex is neither
	// offered nor denied it).
	for _, l := range c.O.Launches {
		if !webSearchOn.MatchString(strings.Join(l.Argv, " ")) {
			return errors.New("the command line does not switch web search on")
		}
	}
	return nil
}

var webSearchOn = regexp.MustCompile(`WebSearch|web_search="(live|cached)"`)

func (c *Cell) noWebSearchOffered() error {
	for _, body := range c.O.Requests {
		if strings.Contains(strings.ToLower(body), "web_search") {
			return errors.New("the request offered a web search")
		}
	}
	return nil
}

// assertQuickConnection: a Quick Connection's read tool runs as a visible
// step (L8). An HTTP transport's loop calls the server itself; a CLI's
// fixture checks its argv names the server (argv-has).
func assertQuickConnection(c *Cell) error {
	if !c.Supported {
		return c.noToolsOffered()
	}
	if err := c.completed(); err != nil {
		return err
	}
	ends := c.O.eventsOf(chat.EventToolEnd)
	starts := c.O.eventsOf(chat.EventToolStart)
	if len(starts) != 1 || len(ends) != 1 || !strings.Contains(starts[0].Name, "get_issue") {
		return fmt.Errorf("want one get_issue step, got %d start(s) %v", len(starts), starts)
	}
	if ends[0].OK == nil || !*ends[0].OK {
		return errors.New("the Quick Connection call failed")
	}
	if !c.A.Caps.ChildProcess && len(c.O.QCCalls) != 1 {
		return fmt.Errorf("the Quick Connection server ran %v, want one get_issue", c.O.QCCalls)
	}
	return nil
}

// assertQuota: a subscription quota is Quota with its reset; a transport
// with no subscription reads the same quota-like refusal as a rate limit,
// never as a quota.
func assertQuota(c *Cell) error {
	if c.Supported {
		return assertFailure(providers.Quota, chat.CodeRateLimit)(c)
	}
	f, err := c.O.failure()
	if err != nil {
		return err
	}
	if f.Category != providers.RateLimit || !f.ResetAt.IsZero() {
		return fmt.Errorf("category %q (reset %v), want a rate limit with no reset", f.Category, f.ResetAt)
	}
	return nil
}
