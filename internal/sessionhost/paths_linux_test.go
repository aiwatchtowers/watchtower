//go:build linux

package sessionhost

import (
	"context"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

// asClientEnv makes the test binary the client half of
// TestAClientWithoutXDGRuntimeDirFindsTheRunningHost: it prints
// DefaultSocket and dials it.
const asClientEnv = "SESSIONHOST_TEST_AS_SOCKET_CLIENT"

// A host started with XDG_RUNTIME_DIR set and a client process without it
// agree on the socket (the OS-parameterised rule is
// TestSocketDirLinuxIgnoresXDGRuntimeDir).
func TestAClientWithoutXDGRuntimeDirFindsTheRunningHost(t *testing.T) {
	if os.Getenv(asClientEnv) == "1" {
		path, err := DefaultSocket()
		if err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		c, err := Dial(ctx, path)
		if err != nil {
			t.Fatalf("dial %s: %v", path, err)
		}
		_ = c.Close()
		_, _ = os.Stdout.WriteString("socket=" + path + "\n")
		return
	}
	home := shortTemp(t)
	t.Setenv("HOME", home)
	t.Setenv(SocketEnv, "")
	t.Setenv("XDG_RUNTIME_DIR", shortTemp(t))
	path, err := DefaultSocket()
	if err != nil {
		t.Fatal(err)
	}
	l, err := Listen(path)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- NewServer(Options{}).Serve(ctx, l) }()
	t.Cleanup(func() {
		cancel()
		_ = l.Close()
		<-done
	})

	cmd := exec.Command(os.Args[0], "-test.run=^TestAClientWithoutXDGRuntimeDirFindsTheRunningHost$")
	var env []string
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "XDG_RUNTIME_DIR=") && !strings.HasPrefix(kv, SocketEnv+"=") {
			env = append(env, kv)
		}
	}
	cmd.Env = append(env, asClientEnv+"=1", "HOME="+home)
	out, err := cmd.CombinedOutput() // waits: the child is reaped
	if err != nil {
		t.Fatalf("client: %v\n%s", err, out)
	}
	if !strings.Contains(string(out), "socket="+path+"\n") {
		t.Fatalf("the client computed another socket than the host's %q:\n%s", path, out)
	}
}
