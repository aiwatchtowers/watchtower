//go:build smoke

// The headless hub smoke test (Go hub spec §13, phase 2 Task 8), run by
// `make hub-smoke`: the real binary in a temp HOME, `sync --daemon` against
// an in-process fake relay, a Go phone paired from the terminal-free
// `hub pair --json --stream`, a stub claude session started from the phone
// and one typed line. Linux runs the live mode (no WATCHTOWER_HUB_DIR, the
// session host found through sessionhost.DefaultSocket under the temp
// HOME); darwin runs the phase-1 test mode, because a dev Mac is a desktop
// host. CI runners have no systemd user manager, so the session host runs
// in this process (IdleExit 0) for the whole test.
package cmd

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"watchtower/internal/hub"
	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/relaytest"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
	"watchtower/internal/sessionhost"
	"watchtower/internal/sessionhost/sessionhosttest"
)

// smokeStep bounds one wait of the smoke test; admitWait bounds the admission
// after promote_pairing, which the relay announces to the hub by no event:
// the hub's short link retry after a pairing (every 2 s) must see it, not
// the minute backstop.
const (
	smokeStep = 2 * time.Minute
	admitWait = 30 * time.Second
)

// smoke is one run: the binary, its environment and the fake relay.
type smoke struct {
	t     *testing.T
	bin   string
	home  string
	env   []string
	srv   *relaytest.Server
	logs  string // the daemon's output, shown on failure
	began time.Time
}

func TestHeadlessSmoke_PairStartTypeEcho(t *testing.T) {
	live := runtime.GOOS == "linux"
	s := &smoke{t: t, srv: relaytest.Start(t), began: time.Now()}
	s.home = shortTempDir(t)
	s.bin = buildWatchtower(t, s.home)
	t.Logf("%5.1fs built", time.Since(s.began).Seconds())

	stubDir := filepath.Join(s.home, "stub")
	mustMkdir(t, stubDir)
	mustMkdir(t, filepath.Join(s.home, "tmp"))
	// The session's login shell finds the stub claude through the owner's
	// profile, as a real install finds claude (a hosted launch passes no PATH).
	profile := "export PATH=" + sessionShellQuote(stubDir) + ":\"$PATH\"\n"
	for _, name := range []string{".bash_profile", ".profile"} {
		mustWrite(t, filepath.Join(s.home, name), profile, 0o600)
	}
	s.env = []string{
		"HOME=" + s.home, "PATH=" + stubDir + ":" + os.Getenv("PATH"), "SHELL=/bin/bash",
		"TMPDIR=" + filepath.Join(s.home, "tmp"), "LANG=en_US.UTF-8",
		"USER=" + os.Getenv("USER"), "LOGNAME=" + os.Getenv("LOGNAME"),
	}

	// The session host, in process, on the socket the hub will use.
	t.Setenv("HOME", s.home)
	t.Setenv(sessionhost.SocketEnv, "")
	var socket string
	if live {
		var err error
		if socket, err = sessionhost.DefaultSocket(); err != nil {
			t.Fatal(err)
		}
		dctx, cancel := context.WithTimeout(t.Context(), 2*time.Second)
		if c, err := sessionhost.Dial(dctx, socket); err == nil {
			_ = c.Close()
			cancel()
			t.Fatalf("another session host already answers on %s", socket)
		}
		cancel()
	} else {
		socket = filepath.Join(s.home, "sh.sock")
		s.env = append(s.env,
			hub.EnvHubDir+"="+filepath.Join(s.home, "hub"),
			hub.EnvTestWorkspace+"=hubtest-smoke",
			hub.EnvRelayOrigin+"="+s.srv.URL,
			sessionhost.SocketEnv+"="+socket)
	}
	sessionhosttest.ServeInProcess(t, socket)

	if live {
		s.run("workspace", "init", "--headless")
	} else {
		s.run("workspace", "init", "--headless", "--name", "hubtest-smoke")
	}
	s.run("config", "set", "hub.relay_origin", s.srv.URL)
	s.run("hub", "enable")
	s.startDaemon()
	s.waitStatus("the hub up", func(st hub.Status) bool {
		return (st.State == hub.StateRunning || st.State == hub.StatePaused) && st.RelayDeviceID != ""
	})

	phone := s.pair()

	repo := filepath.Join(s.home, "repo")
	mustMkdir(t, repo)
	for _, args := range [][]string{
		{"init", "-q"}, {"-c", "user.name=Smoke", "-c", "user.email=smoke@example.com", "commit", "-q", "--allow-empty", "-m", "init"},
	} {
		if out, err := exec.Command("git", append([]string{"-C", repo}, args...)...).CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
	}
	var wb struct {
		ID int64 `json:"id"`
	}
	s.runJSON(&wb, "workbench", "create", "--folder", repo, "--json")
	device := phone.ID().String()
	s.run("hub", "allow", device, "start_sessions")
	s.run("hub", "allow", device, "typing")

	out, ready := filepath.Join(s.home, "typed"), filepath.Join(s.home, "ready")
	writeStubClaude(t, stubDir, s.bin, wb.ID, out, ready)

	// The host still answers, so the daemon's Ensure finds it and spawns none.
	hctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	c, err := sessionhost.Dial(hctx, socket)
	if err == nil {
		_, err = c.List(hctx)
		_ = c.Close()
	}
	cancel()
	if err != nil {
		t.Fatalf("the in-process session host does not answer: %v", err)
	}

	marker := "wt-canary-smoke-" + randomHex(t)
	start := phone.NewAction("session_start")
	setParams(t, start, map[string]any{"workbench_id": wb.ID, "mode": "new", "plan_first": false,
		"bring_forward": false, "brief": "Smoke " + marker})
	seq := s.send(phone, start)
	echo := s.waitApplied(phone, seq)
	var sessionID int64
	if err := json.Unmarshal(echo.Result["session_id"], &sessionID); err != nil || sessionID <= 0 {
		t.Fatalf("session_start result %v: %v", echo.Result, err)
	}
	s.eventually("the stub claude reported idle", func() bool { _, err := os.Stat(ready); return err == nil })

	input := phone.NewAction("session_input")
	entity := strconv.FormatInt(sessionID, 10)
	input.EntityID = &entity
	setParams(t, input, map[string]any{"text": "hello"})
	s.waitApplied(phone, s.send(phone, input))
	want := []byte("\x1b[200~hello\x1b[201~")
	s.eventually("the typed line and its submit in the stub", func() bool {
		b, _ := os.ReadFile(out)
		i := bytes.Index(b, want)
		return i >= 0 && bytes.Equal(b[i+len(want):], []byte("\r"))
	})

	for _, f := range s.srv.Frames() {
		if bytes.Contains(f, []byte(marker)) {
			t.Fatal("the action's plaintext marker reached the relay")
		}
	}

	// The phone stops paying. The two modes answer differently by design:
	//  - live (linux): a headless hub runs the relay-only rules (spec §7.3), so
	//    with no paying phone it pauses — state paused, reason needs_relay;
	//  - test mode (darwin): the phase-1 hub has no relay-only rules (they are
	//    live-mode only), so it keeps running and reports the relay's answer:
	//    the hub is in no paying phone's slot, reason not_admitted.
	var offStatus func(hub.Status) bool
	var reason string
	if live {
		reason = hub.ReasonNeedsRelay
		offStatus = func(st hub.Status) bool { return st.State == hub.StatePaused && st.Reason == reason }
	} else {
		reason = hub.ReasonNotAdmitted
		offStatus = func(st hub.Status) bool { return st.State == hub.StateRunning && st.Reason == reason }
	}
	s.srv.SetPaying(phone.RelayDeviceID(), false)
	s.waitStatus("reason "+reason, offStatus)
}

// pair links a fresh phone through `hub pair --json --stream`, the way a
// headless owner does from a terminal, and waits for the phone to read its
// device_grant from the data zone.
func (s *smoke) pair() *hubtest.Phone {
	t := s.t
	cmd := exec.Command(s.bin, "hub", "pair", "--json", "--stream")
	cmd.Env = s.env
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer reapGroup(cmd)
	lines := make(chan map[string]string, 16)
	go func() {
		defer close(lines)
		sc := bufio.NewScanner(stdout)
		for sc.Scan() {
			var m map[string]string
			if json.Unmarshal(sc.Bytes(), &m) == nil {
				lines <- m
			}
		}
	}()
	next := func(event string) map[string]string {
		t.Helper()
		deadline := time.After(smokeStep)
		for {
			select {
			case m, ok := <-lines:
				if !ok {
					t.Fatalf("hub pair ended before %s: %s", event, stderr.String())
				}
				if m["event"] == "refused" {
					t.Fatalf("hub pair refused: %s", m["reason"])
				}
				if m["event"] == event {
					return m
				}
			case <-deadline:
				t.Fatalf("no %s from hub pair: %s", event, stderr.String())
			}
		}
	}

	lp, err := wire.ParseLinkURL(next("qr")["url"])
	if err != nil {
		t.Fatal(err)
	}
	store := &hubtest.RelayStore{}
	phone, err := hubtest.FromLink(lp, store, nil)
	if err != nil {
		t.Fatal(err)
	}
	store.C = hubtest.NewPhoneClient(s.srv.URL, phone)
	if _, err := store.Register(t.Context()); err != nil {
		t.Fatal(err)
	}
	slot, err := store.OpenPairing(t.Context(), lp.RelayDeviceID)
	if err != nil {
		t.Fatal(err)
	}
	pair := transport.PairZone(slot)
	if err := phone.Hello(pair); err != nil {
		t.Fatal(err)
	}
	sas := next("sas")
	if sas["device_id"] != phone.ID().String() {
		t.Fatalf("sas for %s, want %s", sas["device_id"], phone.ID())
	}
	var awaiting wire.Keybox
	s.eventually("the awaiting keybox", func() bool {
		kb, ok, err := phone.ReadKeybox(pair)
		awaiting = kb
		return err == nil && ok && kb.Grant.ConfirmNonce != nil
	})
	code, err := phone.SAS(*awaiting.Grant.ConfirmNonce)
	if err != nil {
		t.Fatal(err)
	}
	if code != sas["code"] {
		t.Fatal("the phone's code differs from the hub's")
	}
	if _, err := io.WriteString(stdin, `{"confirm":true}`+"\n"); err != nil {
		t.Fatal(err)
	}
	if l := next("linked"); l["device_id"] != phone.ID().String() {
		t.Fatalf("linked %v", l)
	}
	s.eventually("the keys in the pair zone", func() bool {
		kb, ok, err := phone.ReadKeybox(pair)
		return err == nil && ok && kb.Keys != nil
	})
	if err := store.PromotePairing(t.Context(), slot); err != nil {
		t.Fatal(err)
	}
	st := s.waitStatusWithin(admitWait, "the hub running with one phone", func(st hub.Status) bool {
		return st.State == hub.StateRunning && st.Reason == "" && st.Phones == 1
	})
	data := transport.DataZone(st.RelayDeviceID)
	s.eventually("the device_grant in the data zone", func() bool {
		kb, ok, err := phone.ReadKeybox(data)
		return err == nil && ok && kb.Grant.Linked
	})
	return phone
}

func (s *smoke) send(p *hubtest.Phone, a wire.ActionRequest) uint64 {
	s.t.Helper()
	seq, err := p.Queue(a)
	if err != nil {
		s.t.Fatal(err)
	}
	if err := p.Send(seq); err != nil {
		s.t.Fatal(err)
	}
	return seq
}

// waitApplied syncs the phone until seq's echo is applied; a failed final
// echo fails the test with its message.
func (s *smoke) waitApplied(p *hubtest.Phone, seq uint64) wire.ActionRequest {
	s.t.Helper()
	s.eventually(fmt.Sprintf("an applied echo for action %d", seq), func() bool {
		if _, err := p.Sync(); err != nil {
			return false
		}
		if e := p.Echoes[seq]; e.Status == wire.StatusFailed {
			msg, reason := "", ""
			if e.ErrorMessage != nil {
				msg = *e.ErrorMessage
			}
			if e.Reason != nil {
				reason = *e.Reason
			}
			s.t.Fatalf("action %d failed: %s (%s)", seq, msg, reason)
		}
		return p.Echoes[seq].Status == wire.StatusApplied
	})
	return p.Echoes[seq]
}

func (s *smoke) startDaemon() {
	t := s.t
	logPath := filepath.Join(s.home, "daemon.out")
	f, err := os.Create(logPath)
	if err != nil {
		t.Fatal(err)
	}
	s.logs = logPath
	cmd := exec.Command(s.bin, "sync", "--daemon")
	cmd.Env, cmd.Stdout, cmd.Stderr = s.env, f, f
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		stop := exec.Command(s.bin, "sync", "stop")
		stop.Env = s.env
		_ = runWithTimeout(stop, 15*time.Second)
		reapGroup(cmd)
		_ = f.Close()
		if t.Failed() {
			if b, err := os.ReadFile(logPath); err == nil {
				t.Logf("daemon output:\n%s", tail(b, 8000))
			}
		}
	})
}

// waitStatus polls `hub status --json` until ok accepts it.
func (s *smoke) waitStatus(what string, ok func(hub.Status) bool) hub.Status {
	s.t.Helper()
	return s.waitStatusWithin(smokeStep, what, ok)
}

// waitStatusWithin is waitStatus bounded by d.
func (s *smoke) waitStatusWithin(d time.Duration, what string, ok func(hub.Status) bool) hub.Status {
	s.t.Helper()
	var st hub.Status
	s.within(d, what, func() bool {
		var cur hub.Status
		cmd := exec.Command(s.bin, "hub", "status", "--json")
		cmd.Env = s.env
		b, err := cmd.Output()
		if err != nil || json.Unmarshal(b, &cur) != nil {
			return false
		}
		st = cur
		return ok(cur)
	})
	return st
}

func (s *smoke) eventually(what string, cond func() bool) {
	s.t.Helper()
	s.within(smokeStep, what, cond)
}

// within polls cond until it holds, failing the test after d.
func (s *smoke) within(d time.Duration, what string, cond func() bool) {
	s.t.Helper()
	deadline := time.Now().Add(d)
	for !cond() {
		if time.Now().After(deadline) {
			s.t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(200 * time.Millisecond)
	}
	s.t.Logf("%5.1fs %s", time.Since(s.began).Seconds(), what)
}

func (s *smoke) run(args ...string) []byte {
	s.t.Helper()
	cmd := exec.Command(s.bin, args...)
	cmd.Env = s.env
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		s.t.Fatalf("watchtower %s: %v\n%s%s", strings.Join(args, " "), err, out, stderr.String())
	}
	return out
}

func (s *smoke) runJSON(v any, args ...string) {
	s.t.Helper()
	out := s.run(args...)
	if err := json.Unmarshal(out, v); err != nil {
		s.t.Fatalf("watchtower %s: %v: %s", strings.Join(args, " "), err, out)
	}
}

// writeStubClaude is the `claude` the session starts: it turns bracketed
// paste on, reports the Stop hook (the agent waits for input) for its
// session, marks itself ready and appends its raw terminal input to out.
// Any other call (not a session launch) exits at once.
func writeStubClaude(t *testing.T, dir, bin string, workbench int64, out, ready string) {
	t.Helper()
	script := `#!/bin/sh
[ "$1" = "--session-id" ] || exit 0
printf '\033[?2004h'
printf '{"hook_event_name":"Stop","session_id":"%s"}' "$2" | ` + sessionShellQuote(bin) +
		` workbench session-state --workbench ` + strconv.FormatInt(workbench, 10) + `
stty raw -echo
: > ` + sessionShellQuote(ready) + `
exec cat >> ` + sessionShellQuote(out) + `
`
	mustWrite(t, filepath.Join(dir, "claude"), script, 0o755)
}

// buildWatchtower builds the binary under dir.
func buildWatchtower(t *testing.T, dir string) string {
	t.Helper()
	bin := filepath.Join(dir, "bin", "watchtower")
	cmd := exec.Command("go", "build", "-o", bin, ".")
	cmd.Dir = ".."
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("go build: %v\n%s", err, out)
	}
	return bin
}

// shortTempDir is a temp dir short enough for unix socket paths (darwin's
// t.TempDir is too long), symlinks resolved, removed at the end.
func shortTempDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "wt-smoke-")
	if err != nil {
		t.Fatal(err)
	}
	if dir, err = filepath.EvalSymlinks(dir); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return dir
}

// reapGroup kills cmd's process group and waits for cmd.
func reapGroup(cmd *exec.Cmd) {
	if cmd.Process == nil {
		return
	}
	_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	_ = cmd.Wait()
}

func runWithTimeout(cmd *exec.Cmd, d time.Duration) error {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return err
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		return err
	case <-time.After(d):
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		return <-done
	}
}

func setParams(t *testing.T, a wire.ActionRequest, params map[string]any) {
	t.Helper()
	for k, v := range params {
		raw, err := json.Marshal(v)
		if err != nil {
			t.Fatal(err)
		}
		a.Params[k] = raw
	}
}

func randomHex(t *testing.T) string {
	t.Helper()
	b := make([]byte, 8)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	return hex.EncodeToString(b)
}

// sessionShellQuote wraps v in POSIX single quotes.
func sessionShellQuote(v string) string { return "'" + strings.ReplaceAll(v, "'", `'\''`) + "'" }

func mustMkdir(t *testing.T, dir string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
}

func mustWrite(t *testing.T, path, content string, mode os.FileMode) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), mode); err != nil {
		t.Fatal(err)
	}
}

func tail(b []byte, n int) []byte {
	if len(b) > n {
		return b[len(b)-n:]
	}
	return b
}
