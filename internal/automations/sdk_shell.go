package automations

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strconv"
	"time"
	"unicode/utf8"

	"github.com/dop251/goja"

	"watchtower/internal/db"
)

// StepKindShell is the step kind of a shell() call.
const StepKindShell = "shell"

// errShellProtected is the D9 refusal of a workbench in a privacy-protected
// folder (spec §13.2): the daemon never touches such a folder.
const errShellProtected = "this workbench is in a protected folder; use session() or move the folder"

// shellEnvKeys are the daemon variables a shell() command gets, in this
// order; one the daemon does not have is left out. RunEnvMarker follows.
var shellEnvKeys = []string{"PATH", "HOME", "LANG", "USER"}

// ShellModule defines shell(cmd) (spec §5, §13.2; AUTO-13): only in a
// workbench automation, only a command byte-equal to a `shell:` entry, run
// in the workbench folder with the §13.2 environment and the run's remaining
// active time as its deadline. The result is {exit_code, stdout, stderr,
// truncated?}; a non-zero exit is a result. Output beyond the SDK result
// limit is cut to fit (fitShellResult), never refused (D19, ask #272). A dry
// run starts no process.
func ShellModule(b Backends) Module {
	return sdkModule{name: "shell", fns: map[string]SDKFunc{"shell": func(env *Env, call goja.FunctionCall, rt *goja.Runtime) (any, error) {
		cmd, cmdErr := parseShellCall(env, rt, call)
		return env.Call(StepKindShell, "shell", map[string]string{"cmd": cmd}, func(step *Step) (any, error) {
			if cmdErr != nil {
				return nil, cmdErr
			}
			return runShell(env, b, step, cmd)
		})
	}}}
}

// parseShellCall reads shell(cmd): one non-empty string.
func parseShellCall(env *Env, rt *goja.Runtime, call goja.FunctionCall) (string, error) {
	v, _, err := argAt(env, rt, call, 0)
	if err != nil {
		return "", tooLargeAs(err, ErrNameValidation, fmt.Sprintf("shell(): the command is larger than %d bytes", maxSDKArgBytes))
	}
	cmd, ok := v.(string)
	if !ok || cmd == "" {
		return "", validationf("shell(cmd): cmd must be a non-empty string")
	}
	return cmd, nil
}

// runShell applies the checks in their order — workbench scope, the
// manifest, dry run, the folder — and then runs the command.
func runShell(env *Env, b Backends, step *Step, cmd string) (any, error) {
	wbID := env.Binding().WorkbenchID
	if wbID == 0 {
		return nil, &SDKError{Name: ErrNamePermissionDenied,
			Message: "shell() is only available to a workbench automation"}
	}
	m, err := manifestOf(env)
	if err != nil {
		return nil, err
	}
	entry, err := m.AllowShell(cmd)
	if err != nil {
		return nil, err
	}
	step.SetPermission(entry)
	if env.DryRun {
		return dryRunResult(step, map[string]string{"cmd": cmd}), nil
	}
	folder, err := shellFolder(env.Ctx, b, wbID)
	if err != nil {
		return nil, err
	}
	if b.Shell == nil {
		return nil, notAvailable("no shell runner is configured")
	}
	res, err := b.Shell.Run(env.Ctx, ShellCommand{Cmd: cmd, Dir: folder, Env: shellEnv(env), Deadline: shellDeadline(env)})
	if err != nil {
		return nil, shellError(env, cmd, err)
	}
	raw, cut, err := fitShellResult(res)
	if err != nil {
		return nil, err
	}
	step.Finish(db.StepFinish{Status: StepOK, ResultSummary: marshalForStep(shellSummary{ExitCode: res.ExitCode, Truncated: cut})})
	return encodedResult(raw), nil
}

// shellFolder resolves the workbench's folder: a protected one is refused
// before anything looks at it (D9), a missing one is NotAvailable.
func shellFolder(ctx context.Context, b Backends, wbID int64) (string, error) {
	if b.Workbench == nil {
		return "", notAvailable("no workbench resolver is configured")
	}
	wb, err := b.Workbench.Workbench(ctx, wbID)
	switch {
	case errors.Is(err, db.ErrWorkbenchNotFound):
		return "", notAvailable("the workbench no longer exists")
	case err != nil:
		return "", &SDKError{Name: ErrNameTool, Message: fmt.Sprintf("reading workbench %d: %v", wbID, err)}
	case wb.Protected:
		return "", notAvailable(errShellProtected)
	}
	if fi, err := os.Stat(wb.Folder); wb.Folder == "" || err != nil || !fi.IsDir() {
		return "", notAvailable("the workbench folder is missing")
	}
	return wb.Folder, nil
}

// shellEnv is the command's whole environment (spec §13.2): PATH, HOME,
// LANG and USER from the daemon's, then the run marker. Nothing else of the
// daemon's environment — no token, no session marker — reaches it.
func shellEnv(env *Env) []string {
	out := make([]string, 0, len(shellEnvKeys)+1)
	for _, k := range shellEnvKeys {
		if v, ok := os.LookupEnv(k); ok {
			out = append(out, k+"="+v)
		}
	}
	return append(out, RunEnvMarker+"="+strconv.FormatInt(env.Binding().AutomationRunID, 10))
}

// shellDeadline is the wall-clock moment the run's active time runs out
// (the meter's deadline is on the run's clock).
func shellDeadline(env *Env) time.Time {
	return time.Now().Add(env.Meter.Deadline().Sub(env.Meter.clock.Now()))
}

// shellError maps a runner failure: its own deadline passing is the run's
// timeout; the run's context ending is the interrupt already under way; any
// other failure (the shell did not start) is a ToolError.
func shellError(env *Env, cmd string, err error) error {
	switch {
	case env.Ctx.Err() != nil:
		return err
	case errors.Is(err, context.DeadlineExceeded):
		return &RunInterrupted{Reason: InterruptTimeout}
	}
	return &SDKError{Name: ErrNameTool, Message: fmt.Sprintf("shell(%q): %v", cmd, err)}
}

// shellResult is what the script gets.
type shellResult struct {
	ExitCode  int    `json:"exit_code"`
	Stdout    string `json:"stdout"`
	Stderr    string `json:"stderr"`
	Truncated bool   `json:"truncated,omitempty"`
}

// shellSummary is the step's result_summary: the exit code and the streams
// that were cut.
type shellSummary struct {
	ExitCode  int      `json:"exit_code"`
	Truncated []string `json:"truncated,omitempty"`
}

// fitShellResult serialises res within MaxSDKResultBytes (D19, ask #272):
// while it is too large both tails are cut further — each stream keeps at
// most half of the room the envelope leaves, a shorter stream's unused share
// going to the other, every cut on a UTF-8 boundary and measured as JSON
// escapes it — and it is measured again. It returns the serialised result
// and the streams cut (by the runner or here).
func fitShellResult(res ShellResult) ([]byte, []string, error) {
	out := shellResult{ExitCode: res.ExitCode, Stdout: res.Stdout, Stderr: res.Stderr}
	cutOut, cutErr := res.StdoutTruncated, res.StderrTruncated
	slack := 0 // grows when a measurement disagrees with jsonRuneLen's
	for {
		out.Truncated = cutOut || cutErr
		raw, err := json.Marshal(out)
		if err != nil {
			return nil, nil, &SDKError{Name: ErrNameTool, Message: "the result is not JSON: " + err.Error()}
		}
		if len(raw) <= MaxSDKResultBytes {
			return raw, cutStreams(cutOut, cutErr), nil
		}
		envelope, _ := json.Marshal(shellResult{ExitCode: out.ExitCode, Truncated: true})
		room := max(MaxSDKResultBytes-len(envelope)-slack, 0)
		shareOut, shareErr := splitRoom(room, jsonStringLen(out.Stdout), jsonStringLen(out.Stderr))
		stdout, stderr := tailWithin(out.Stdout, shareOut), tailWithin(out.Stderr, shareErr)
		cutOut = cutOut || len(stdout) < len(out.Stdout)
		cutErr = cutErr || len(stderr) < len(out.Stderr)
		out.Stdout, out.Stderr = stdout, stderr
		slack += len(raw) - MaxSDKResultBytes
	}
}

func cutStreams(stdout, stderr bool) []string {
	var cut []string
	if stdout {
		cut = append(cut, "stdout")
	}
	if stderr {
		cut = append(cut, "stderr")
	}
	return cut
}

// splitRoom shares room between two streams of escaped lengths a and b: each
// gets at most half, a shorter one's unused share goes to the other.
func splitRoom(room, a, b int) (int, int) {
	half := room / 2
	switch {
	case a <= half:
		return a, room - a
	case b <= half:
		return room - b, b
	}
	return half, room - half
}

// tailWithin is the longest tail of s whose JSON escaping takes at most n
// bytes; it starts on a rune boundary.
func tailWithin(s string, n int) string {
	i, used := len(s), 0
	for i > 0 {
		r, size := utf8.DecodeLastRuneInString(s[:i])
		w := jsonRuneLen(r, size)
		if used+w > n {
			break
		}
		used += w
		i -= size
	}
	return s[i:]
}

func jsonStringLen(s string) int {
	n := 0
	for i := 0; i < len(s); {
		r, size := utf8.DecodeRuneInString(s[i:])
		n += jsonRuneLen(r, size)
		i += size
	}
	return n
}

// jsonRuneLen is how many bytes encoding/json writes for one decoded rune
// of a string (size is the bytes it was decoded from).
func jsonRuneLen(r rune, size int) int {
	switch {
	case r == utf8.RuneError && size == 1:
		return len(`�`) // an invalid byte
	case r == '"' || r == '\\' || r == '\b' || r == '\f' || r == '\n' || r == '\r' || r == '\t':
		return 2
	case r < 0x20 || r == '<' || r == '>' || r == '&' || r == ' ' || r == ' ':
		return len(`\u0000`)
	}
	return size
}
