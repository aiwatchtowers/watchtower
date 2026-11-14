package slacklive

import (
	"bufio"
	"bytes"
	"context"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"
)

// child is a CLI process in its own process group whose stdout lines arrive
// on lines. The whole group dies with the context and is always reaped.
type child struct {
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	lines  chan string
	stderr *capBuf
	cancel context.CancelFunc
}

// capBuf keeps the first stderrCap bytes written to it.
type capBuf struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

const stderrCap = 8 << 10

func (b *capBuf) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if room := stderrCap - b.buf.Len(); room > 0 {
		b.buf.Write(p[:min(room, len(p))])
	}
	return len(p), nil
}

func (b *capBuf) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// startChild launches bin with args and env. observe, when set, sees every
// stdout line in the reader goroutine before it is queued.
func startChild(ctx context.Context, bin string, args, env []string, observe func(string)) (*child, error) {
	cctx, cancel := context.WithCancel(ctx)
	cmd := exec.CommandContext(cctx, bin, args...)
	cmd.Env = env
	cmd.Dir = os.TempDir()
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = 2 * time.Second
	c := &child{cmd: cmd, lines: make(chan string, 256), stderr: &capBuf{}, cancel: cancel}
	cmd.Stderr = c.stderr
	stdin, err := cmd.StdinPipe()
	if err != nil {
		cancel()
		return nil, err
	}
	c.stdin = stdin
	outR, outW, err := os.Pipe()
	if err != nil {
		cancel()
		return nil, err
	}
	cmd.Stdout = outW
	if err := cmd.Start(); err != nil {
		outR.Close()
		outW.Close()
		cancel()
		return nil, err
	}
	outW.Close()
	go func() {
		defer close(c.lines)
		defer outR.Close()
		r := bufio.NewReaderSize(outR, 64<<10)
		for {
			line, err := r.ReadString('\n')
			if line = strings.TrimRight(line, "\r\n"); line != "" {
				if observe != nil {
					observe(line)
				}
				select {
				case c.lines <- line:
				case <-cctx.Done():
					return
				}
			}
			if err != nil {
				return
			}
		}
	}()
	return c, nil
}

// write sends one line (a newline is appended) to the child's stdin.
func (c *child) write(line string) error {
	_, err := io.WriteString(c.stdin, line+"\n")
	return err
}

// stop kills the process group and waits for the child.
func (c *child) stop() {
	c.stdin.Close()
	c.cancel()
	_ = c.cmd.Wait()
}
