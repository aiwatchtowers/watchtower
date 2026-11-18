package claude

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

// UsageError is ReadUsage's failure: Code is one of cli_missing,
// unsupported_cli, unsupported_auth, cloud_bedrock, cloud_vertex,
// cloud_foundry, no_credentials, network, parse, timeout, cancelled (the
// constants and the sets they belong to — public, stored, account-level,
// quiet — live in internal/planusage/codes.go). It never carries the
// child's output.
type UsageError struct{ Code string }

func (e *UsageError) Error() string { return "claude usage: " + e.Code }

// UsageWindow is one plan-limit window under the stored limit keys:
// session "5-hour", weekly_all "Weekly", weekly_scoped:<slug> "Weekly · <name>".
type UsageWindow struct {
	Key, Label, Group string
	Percent           float64
	ResetsAt          *time.Time
}

// BreakdownRow is one surface's share of the weekly usage.
type BreakdownRow struct {
	Key, Label string
	Percent    float64
}

// UsageSnapshot is one get_usage answer: the plan name (empty when the CLI
// reports none), the windows, and the surface breakdown (nil when absent).
type UsageSnapshot struct {
	Plan      string
	Windows   []UsageWindow
	Breakdown []BreakdownRow
}

// Reader limits and the request (Global Constraints of the plan; pinned by
// PLANUSAGE-01).
const (
	usageBudget    = 20 * time.Second
	usageExitGrace = 5 * time.Second
	usageLineCap   = 1 << 20
	usageTotalCap  = 4 << 20
	usageRequestID = "wt-usage"
	// usageWaitDelay is how long exec's Wait, after the child has exited,
	// waits for its stdio copy goroutines before closing the pipes. The
	// reader's stdio needs none today (two pipes it owns and the null device),
	// so this is a backstop if one is ever added.
	usageWaitDelay = 2 * time.Second
)

// usageArgs is the reader's argv: stream-json control traffic only, no
// user hooks, no MCP servers, no transcript.
var usageArgs = []string{"-p", "--input-format", "stream-json", "--output-format", "stream-json",
	"--verbose", "--setting-sources", "project", "--strict-mcp-config", "--no-session-persistence"}

// usageRequest is the one stdin line. No user message is ever written, so no
// model turn can start.
var usageRequest = []byte(`{"type":"control_request","request_id":"` + usageRequestID +
	`","request":{"subtype":"get_usage","skip_behaviors":true}}` + "\n")

// ReadUsage asks the installed claude (bin) for its plan usage through the
// get_usage control request, with env as the child's whole environment. It
// never reads Claude credentials; the error is always *UsageError and the
// child's output never leaves this package.
func ReadUsage(ctx context.Context, bin string, env []string) (UsageSnapshot, error) {
	return readUsage(ctx, usageProcess(bin, env), env)
}

// usageChild is a started reader child: its pipes, a one-shot wait for its
// exit code, and a kill of its whole process group.
type usageChild struct {
	stdin  io.WriteCloser
	stdout io.Reader
	wait   func() (exitCode int, err error)
	kill   func()
}

type usageLauncher func() (*usageChild, error)

// errCLIMissing is the launcher's answer for a bin that is not there.
var errCLIMissing = errors.New("claude CLI missing")

// usageProcess starts bin with usageArgs in the neutral temp folder, in its
// own process group. Stderr is left unset, so it goes to the null device: no
// pipe a descendant could hold to stall Wait, and nothing is stored, logged
// or returned. The reader owns killing, so no CommandContext.
func usageProcess(bin string, env []string) usageLauncher {
	return func() (*usageChild, error) {
		path, err := exec.LookPath(bin)
		if err != nil {
			return nil, errCLIMissing
		}
		// A relative bin was found against our cwd; the child runs in Dir.
		// The path is only prefixed, never cleaned: cleaning "link/../x"
		// would name another file than the one LookPath checked.
		if !filepath.IsAbs(path) {
			wd, err := os.Getwd()
			if err != nil {
				return nil, err
			}
			path = wd + string(filepath.Separator) + path
		}
		cmd := exec.Command(path, usageArgs...)
		cmd.Dir = os.TempDir()
		cmd.Env = env
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		cmd.WaitDelay = usageWaitDelay
		stdin, err := cmd.StdinPipe()
		if err != nil {
			return nil, err
		}
		stdout, err := cmd.StdoutPipe()
		if err != nil {
			_ = stdin.Close()
			return nil, err
		}
		if err := cmd.Start(); err != nil {
			return nil, err
		}
		pid := cmd.Process.Pid
		return &usageChild{
			stdin:  stdin,
			stdout: stdout,
			wait: func() (int, error) {
				err := cmd.Wait()
				if cmd.ProcessState == nil {
					return -1, err
				}
				return cmd.ProcessState.ExitCode(), err
			},
			kill: func() { _ = syscall.Kill(-pid, syscall.SIGKILL) },
		}, nil
	}
}

// usageEnvelope is a stdout line that may be our control_response.
type usageEnvelope struct {
	Type     string `json:"type"`
	Response struct {
		Subtype   string          `json:"subtype"`
		RequestID string          `json:"request_id"`
		Response  json.RawMessage `json:"response"`
		Error     string          `json:"error"`
		ErrorCode string          `json:"error_code"`
	} `json:"response"`
}

// usageScan is how the stdout scan ended.
type usageScan struct {
	answer  *usageEnvelope // the wt-usage control_response
	capped  bool           // a line or the total went over its cap
	sawData bool           // stdout carried any byte (on EOF)
}

// scanUsageAnswer reads stdout lines under the caps until the wt-usage
// control_response, the end of output or a cap. Every other line is skipped.
func scanUsageAnswer(stdout io.Reader) usageScan {
	r := bufio.NewReaderSize(stdout, 64<<10)
	var total int
	var line []byte
	for {
		chunk, err := r.ReadSlice('\n')
		total += len(chunk)
		line = append(line, chunk...)
		if total > usageTotalCap || len(bytes.TrimSuffix(line, []byte("\n"))) > usageLineCap {
			return usageScan{capped: true}
		}
		if errors.Is(err, bufio.ErrBufferFull) {
			continue
		}
		if env, ok := matchUsageAnswer(line); ok {
			return usageScan{answer: env}
		}
		line = line[:0]
		if err != nil {
			return usageScan{sawData: total > 0}
		}
	}
}

// matchUsageAnswer reports whether line is the wt-usage control_response.
// The match reads only type and request_id; an answer whose other fields do
// not decode comes back with an empty subtype, which classifies as parse.
func matchUsageAnswer(line []byte) (*usageEnvelope, bool) {
	var head struct {
		Type     string `json:"type"`
		Response struct {
			RequestID string `json:"request_id"`
		} `json:"response"`
	}
	if json.Unmarshal(line, &head) != nil || head.Type != "control_response" || head.Response.RequestID != usageRequestID {
		return nil, false
	}
	var env usageEnvelope
	if json.Unmarshal(line, &env) != nil {
		return &usageEnvelope{}, true
	}
	return &env, true
}

// readUsage runs one get_usage conversation over launch. Every return after
// a start kills the child's group and waits for it.
func readUsage(ctx context.Context, launch usageLauncher, env []string) (UsageSnapshot, error) {
	if ctx.Err() != nil {
		return UsageSnapshot{}, &UsageError{Code: "cancelled"}
	}
	budget := time.NewTimer(usageBudget)
	defer budget.Stop()
	c, err := launch()
	if errors.Is(err, errCLIMissing) {
		return UsageSnapshot{}, &UsageError{Code: "cli_missing"}
	}
	if err != nil {
		return UsageSnapshot{}, &UsageError{Code: "network"}
	}
	go func() {
		// A write error (the CLI exited without reading) is classified by
		// how the child ends, not here.
		_, _ = c.stdin.Write(usageRequest)
	}()
	scanned := make(chan usageScan, 1)
	go func() { scanned <- scanUsageAnswer(c.stdout) }()

	exited := make(chan int, 1)
	// release closes stdin and starts waiting for the exit code.
	release := sync.OnceFunc(func() {
		_ = c.stdin.Close()
		go func() { code, _ := c.wait(); exited <- code }()
	})
	// fail kills the group, reaps it and returns code.
	fail := func(code string) error {
		release()
		c.kill()
		<-exited
		return &UsageError{Code: code}
	}

	var s usageScan
	select {
	case <-ctx.Done():
		return UsageSnapshot{}, fail("cancelled")
	case <-budget.C:
		return UsageSnapshot{}, fail("timeout")
	case s = <-scanned:
	}
	if s.capped {
		return UsageSnapshot{}, fail("parse")
	}
	release()
	if s.answer == nil {
		// Stdout ended without an answer: the exit code decides, within
		// what is left of the budget.
		select {
		case <-ctx.Done():
			return UsageSnapshot{}, fail("cancelled")
		case <-budget.C:
			return UsageSnapshot{}, fail("timeout")
		case code := <-exited:
			c.kill() // stragglers left in the group
			if code != 0 && !s.sawData {
				return UsageSnapshot{}, &UsageError{Code: "unsupported_cli"}
			}
			return UsageSnapshot{}, &UsageError{Code: "network"}
		}
	}
	// Answered: the child gets usageExitGrace to exit on its own.
	grace := time.NewTimer(usageExitGrace)
	defer grace.Stop()
	select {
	case <-exited:
		c.kill() // stragglers left in the group
	case <-ctx.Done():
		return UsageSnapshot{}, fail("cancelled")
	case <-grace.C:
		c.kill()
		<-exited
	}
	if ctx.Err() != nil {
		return UsageSnapshot{}, &UsageError{Code: "cancelled"}
	}
	return usageFromAnswer(s.answer, env)
}

// usageFromAnswer classifies the wt-usage control_response (spec §1).
func usageFromAnswer(a *usageEnvelope, env []string) (UsageSnapshot, error) {
	switch a.Response.Subtype {
	case "success":
	case "error":
		if a.Response.ErrorCode == "unsupported_request" ||
			strings.HasPrefix(a.Response.Error, "Unsupported control request subtype") {
			return UsageSnapshot{}, &UsageError{Code: "unsupported_cli"}
		}
		return UsageSnapshot{}, &UsageError{Code: "network"}
	default:
		return UsageSnapshot{}, &UsageError{Code: "parse"}
	}
	snap, available, limitsNull, err := parseClaudeUsage(a.Response.Response)
	switch {
	case err != nil:
		return UsageSnapshot{}, &UsageError{Code: "parse"}
	case !available:
		kind, ok := LoginOverride(env)
		switch {
		case !ok:
			return UsageSnapshot{}, &UsageError{Code: "no_credentials"}
		case kind == "api_key":
			return UsageSnapshot{}, &UsageError{Code: "unsupported_auth"}
		default:
			return UsageSnapshot{}, &UsageError{Code: "cloud_" + kind}
		}
	case limitsNull:
		return UsageSnapshot{}, &UsageError{Code: "network"}
	case len(snap.Windows) == 0:
		return UsageSnapshot{}, &UsageError{Code: "parse"}
	}
	return snap, nil
}
