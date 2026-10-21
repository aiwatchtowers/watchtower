//go:build darwin

// Command probe is the throwaway Stage 2 keychain gate probe (board #603,
// docs/superpowers/plans/2026-10-21-db-encryption-stage1.md § Stage 2 gate).
// It makes the Security.framework calls Stage 2 will make, always against the
// data protection keychain, under its own item names. Never merged.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

// version is set with -ldflags "-X main.version=…" (G4 changes it).
var version = "dev"

// callTimeout bounds every Security call. A prompt blocks SecItem*, so a
// call that does not return in time is recorded as prompt_suspected.
const callTimeout = 10 * time.Second

type step struct {
	Name      string `json:"name"`
	OSStatus  *int   `json:"osstatus"`
	ElapsedMS int64  `json:"elapsed_ms"`
	Message   string `json:"message,omitempty"`
}

type result struct {
	Op              string `json:"op"`
	OSStatus        *int   `json:"osstatus"`
	ElapsedMS       int64  `json:"elapsed_ms"`
	ConsoleLocked   *bool  `json:"console_locked"`
	PromptSuspected bool   `json:"prompt_suspected,omitempty"`
	Message         string `json:"message,omitempty"`
	SHA256          string `json:"sha256,omitempty"`
	Steps           []step `json:"steps,omitempty"`
	Version         string `json:"version"`
	PID             int    `json:"pid"`
	TS              string `json:"ts"`
	Extra           any    `json:"extra,omitempty"`
}

type run struct {
	res   result
	start time.Time
}

func newRun(op string) *run {
	return &run{
		res:   result{Op: op, Version: version, PID: os.Getpid(), TS: time.Now().UTC().Format(time.RFC3339Nano)},
		start: time.Now(),
	}
}

// call runs one Security call under callTimeout. On a timeout it prints the
// result with prompt_suspected and exits: the stuck C call cannot be undone.
func (r *run) call(name string, fn func() int) int {
	done := make(chan int, 1)
	t0 := time.Now()
	go func() { done <- fn() }()
	select {
	case s := <-done:
		st := step{Name: name, OSStatus: &s, ElapsedMS: time.Since(t0).Milliseconds()}
		if s != errSecSuccess {
			st.Message = osMessage(s)
		}
		r.res.Steps = append(r.res.Steps, st)
		if s != errSecSuccess && r.res.OSStatus == nil {
			r.res.OSStatus = &s
			r.res.Message = st.Message
		}
		return s
	case <-time.After(callTimeout):
		r.res.Steps = append(r.res.Steps, step{Name: name, ElapsedMS: time.Since(t0).Milliseconds(), Message: "timeout"})
		r.res.PromptSuspected = true
		r.res.Message = name + ": no return within " + callTimeout.String() + " (prompt suspected)"
		r.finish()
		os.Exit(3)
		return 0
	}
}

func (r *run) finish() {
	r.res.ElapsedMS = time.Since(r.start).Milliseconds()
	if r.res.OSStatus == nil && !r.res.PromptSuspected {
		ok := errSecSuccess
		r.res.OSStatus = &ok
	}
	r.res.ConsoleLocked = consoleLocked()
	b, _ := json.Marshal(r.res)
	fmt.Println(string(b))
}

func (r *run) exitCode() int {
	if r.res.PromptSuspected {
		return 3
	}
	if r.res.OSStatus != nil && *r.res.OSStatus != errSecSuccess {
		return 1
	}
	return 0
}

// consoleLocked reads IOConsoleLocked from `ioreg -n Root -d1 -a`; nil when
// the key is absent or ioreg fails.
func consoleLocked() *bool {
	out, err := exec.Command("/usr/sbin/ioreg", "-n", "Root", "-d1", "-a").Output()
	if err != nil {
		return nil
	}
	i := bytes.Index(out, []byte("<key>IOConsoleLocked</key>"))
	if i < 0 {
		return nil
	}
	rest := bytes.TrimSpace(out[i+len("<key>IOConsoleLocked</key>"):])
	v := bytes.HasPrefix(rest, []byte("<true/>"))
	if !v && !bytes.HasPrefix(rest, []byte("<false/>")) {
		return nil
	}
	return &v
}

func hexSum(b []byte) string {
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}

func opSECreate() int {
	r := newRun("se-create")
	var key uintptr
	s := r.call("copy_se_key", func() int { var s int; key, s = copySEKey(); return s })
	switch s {
	case errSecSuccess:
		release(key)
		dup := errSecDuplicateItem
		r.res.OSStatus = &dup
		r.res.Message = "SE key already exists; run cleanup first"
	case errSecItemNotFound:
		r.res.OSStatus = nil // the lookup miss is expected here
		r.res.Message = ""
		r.call("se_create", seCreate)
	}
	r.finish()
	return r.exitCode()
}

func opWrap(args []string) int {
	fs := flag.NewFlagSet("wrap", flag.ExitOnError)
	addOnly := fs.Bool("add-only", false, "skip the SE key and store 32 raw random bytes: exercises SecItemAdd alone (G5)")
	_ = fs.Parse(args)

	r := newRun("wrap")
	if *addOnly {
		r.res.Op = "wrap-add-only"
	}
	defer r.finish()

	var plain []byte
	if s := r.call("random", func() int { var s int; plain, s = randomBytes(32); return s }); s != errSecSuccess {
		return 1
	}
	value := plain
	if !*addOnly {
		var key uintptr
		if s := r.call("copy_se_key", func() int { var s int; key, s = copySEKey(); return s }); s != errSecSuccess {
			return 1
		}
		defer release(key)
		if s := r.call("encrypt", func() int { var s int; value, s = encrypt(key, plain); return s }); s != errSecSuccess {
			return 1
		}
	}
	if s := r.call("add_wrapped", func() int { return addWrapped(value) }); s != errSecSuccess {
		return 1
	}
	r.res.SHA256 = hexSum(plain)
	return 0
}

func opGet() int {
	r := newRun("get")
	defer r.finish()
	var wrapped, plain []byte
	var key uintptr
	if s := r.call("copy_wrapped", func() int { var s int; wrapped, s = copyWrapped(); return s }); s != errSecSuccess {
		return 1
	}
	if s := r.call("copy_se_key", func() int { var s int; key, s = copySEKey(); return s }); s != errSecSuccess {
		return 1
	}
	defer release(key)
	if s := r.call("decrypt", func() int { var s int; plain, s = decrypt(key, wrapped); return s }); s != errSecSuccess {
		return 1
	}
	r.res.SHA256 = hexSum(plain)
	return 0
}

func opCleanup() int {
	r := newRun("cleanup")
	r.call("delete_wrapped", deleteWrapped)
	r.call("delete_se_key", deleteSEKey)
	r.finish()
	return r.exitCode()
}

// opLoop runs `get` in a fresh child process on every tick (a new process
// per tick, as hooks are) and appends each JSON line to the log.
func opLoop(args []string) int {
	fs := flag.NewFlagSet("loop", flag.ExitOnError)
	every := fs.Duration("every", 5*time.Second, "tick interval")
	total := fs.Duration("for", 3*time.Minute, "total duration")
	logPath := fs.String("log", "", "JSON lines output file (required)")
	detach := fs.Bool("detach", false, "re-exec in a new session (setsid) and return at once")
	_ = fs.Parse(args)
	if *logPath == "" {
		fmt.Fprintln(os.Stderr, "loop: --log is required")
		return 2
	}
	self, err := os.Executable()
	if err != nil {
		fmt.Fprintln(os.Stderr, "loop:", err)
		return 2
	}
	if *detach {
		return detachLoop(self, *every, *total, *logPath)
	}

	f, err := os.OpenFile(*logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		fmt.Fprintln(os.Stderr, "loop:", err)
		return 2
	}
	defer f.Close()
	deadline := time.Now().Add(*total)
	for {
		line := tick(self)
		_, _ = f.Write(append(line, '\n'))
		if time.Now().Add(*every).After(deadline) {
			return 0
		}
		time.Sleep(*every)
	}
}

func tick(self string) []byte {
	cmd := exec.Command(self, "get")
	var out bytes.Buffer
	cmd.Stdout = &out
	if err := cmd.Start(); err != nil {
		return []byte(fmt.Sprintf(`{"op":"loop-tick","error":%q}`, err.Error()))
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case <-done:
	case <-time.After(callTimeout*3 + 5*time.Second):
		_ = cmd.Process.Kill()
		<-done
	}
	line := bytes.TrimSpace(out.Bytes())
	if len(line) == 0 {
		return []byte(`{"op":"loop-tick","error":"get printed nothing"}`)
	}
	return line
}

func detachLoop(self string, every, total time.Duration, logPath string) int {
	devnull, err := os.OpenFile(os.DevNull, os.O_RDWR, 0)
	if err != nil {
		fmt.Fprintln(os.Stderr, "loop:", err)
		return 2
	}
	defer devnull.Close()
	cmd := exec.Command(self, "loop", "--every", every.String(), "--for", total.String(), "--log", logPath)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = devnull, devnull, devnull
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		fmt.Fprintln(os.Stderr, "loop:", err)
		return 2
	}
	r := newRun("loop-detach")
	r.res.Extra = map[string]any{"child_pid": cmd.Process.Pid, "log": logPath, "every": every.String(), "for": total.String()}
	r.finish()
	_ = cmd.Process.Release()
	return 0
}

func usage() {
	fmt.Fprintln(os.Stderr, strings.TrimSpace(`
usage: probe <command>
  se-create                     create the SE key (com.watchtower.dbkey.se.probe)
  wrap [--add-only]             wrap 32 random bytes with the SE key, store as a generic password
  get                           read + unwrap, print the plaintext SHA-256
  loop --every 5s --for 3m --log FILE [--detach]
  cleanup                       delete both probe items
  version`))
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	cmd, args := os.Args[1], os.Args[2:]
	var code int
	switch cmd {
	case "se-create":
		code = opSECreate()
	case "wrap":
		code = opWrap(args)
	case "get":
		code = opGet()
	case "loop":
		code = opLoop(args)
	case "cleanup":
		code = opCleanup()
	case "version":
		fmt.Println(version)
	default:
		usage()
		code = 2
	}
	os.Exit(code)
}
