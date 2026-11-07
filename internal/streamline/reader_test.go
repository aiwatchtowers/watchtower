package streamline

import (
	"bufio"
	"errors"
	"io"
	"os/exec"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// lines reads r to its end, returning every line Next gave and the error
// that ended it.
func lines(t *testing.T, r *Reader) ([]string, error) {
	t.Helper()
	var got []string
	for {
		line, err := r.Next()
		if err != nil {
			return got, err
		}
		got = append(got, string(line))
	}
}

// A line over the limit is read to its end and skipped; the lines around
// it come through and the skip is counted.
func TestStreamline_OversizedLineIsSkippedAndCounted(t *testing.T) {
	big := strings.Repeat("x", 2<<20)
	r := NewWithLimit(strings.NewReader("one\n"+big+"\ntwo\n"), 1<<20)

	got, err := lines(t, r)
	require.ErrorIs(t, err, io.EOF)
	assert.Equal(t, []string{"one", "two"}, got)
	assert.Equal(t, 1, r.Skipped())
}

// A last line without a newline is returned, not left unread: the writer
// has exited by then and nothing will complete it.
func TestStreamline_LastLineWithoutNewline(t *testing.T) {
	r := New(strings.NewReader("first\nlast"))

	got, err := lines(t, r)
	require.ErrorIs(t, err, io.EOF)
	assert.Equal(t, []string{"first", "last"}, got)
	assert.Zero(t, r.Skipped())
}

// At the limit: a line of exactly limit bytes (newline included) is
// returned, one byte more is skipped, and the reader goes on with the next
// line either way, also when a line spans several fills of the buffer.
func TestStreamline_AtTheLimit(t *testing.T) {
	const limit = 40
	exact := strings.Repeat("a", limit-1)
	over := strings.Repeat("b", limit)
	r := &Reader{r: bufio.NewReaderSize(strings.NewReader(exact+"\n"+over+"\ntail"), 16), limit: limit}

	got, err := lines(t, r)
	require.ErrorIs(t, err, io.EOF)
	assert.Equal(t, []string{exact, "tail"}, got)
	assert.Equal(t, 1, r.Skipped())
}

// An oversized last line ends the stream with io.EOF and no line.
func TestStreamline_OversizedLastLine(t *testing.T) {
	r := NewWithLimit(strings.NewReader("ok\n"+strings.Repeat("z", 100)), 10)

	got, err := lines(t, r)
	require.ErrorIs(t, err, io.EOF)
	assert.Equal(t, []string{"ok"}, got)
	assert.Equal(t, 1, r.Skipped())
}

// errAfter yields data, then fails with err.
type errAfter struct {
	data string
	err  error
}

func (e *errAfter) Read(p []byte) (int, error) {
	if e.data == "" {
		return 0, e.err
	}
	n := copy(p, e.data)
	e.data = e.data[n:]
	return n, nil
}

// A read error comes after the text read before it: the partial line is
// returned first, then the error, and Next keeps returning it.
func TestStreamline_ReadErrorAfterPartialLine(t *testing.T) {
	boom := errors.New("boom")
	r := New(&errAfter{data: "whole\npartial", err: boom})

	got, err := lines(t, r)
	require.ErrorIs(t, err, boom)
	assert.Equal(t, []string{"whole", "partial"}, got)
	_, err = r.Next()
	require.ErrorIs(t, err, boom)
}

// The undecodable hook only counts.
func TestStreamline_UndecodableCount(t *testing.T) {
	r := New(strings.NewReader(""))
	r.MarkUndecodable()
	r.MarkUndecodable()
	assert.Equal(t, 2, r.Undecodable())
}

// Drain reads the writer's output to its end, so a child still writing
// after the caller stopped reading exits instead of blocking on a full
// pipe, and the caller's Wait returns.
func TestStreamline_DrainUnblocksAWriterBeforeWait(t *testing.T) {
	cmd := exec.Command("/bin/sh", "-c", `printf 'first\n'; head -c 4194304 /dev/zero; printf '\n'`)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	stdout, err := cmd.StdoutPipe()
	require.NoError(t, err)
	require.NoError(t, cmd.Start())
	waited := make(chan error, 1)
	t.Cleanup(func() {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		select {
		case <-waited:
		case <-time.After(5 * time.Second):
		}
	})

	r := New(stdout)
	line, err := r.Next()
	require.NoError(t, err)
	assert.Equal(t, "first", string(line))

	go func() {
		r.Drain()
		waited <- cmd.Wait()
	}()
	select {
	case err := <-waited:
		waited <- err // for the cleanup
		require.NoError(t, err)
	case <-time.After(5 * time.Second):
		t.Fatal("the writer did not exit after Drain: Wait hangs")
	}
}

// OnSkip is given the head of every skipped line (a caller tells a protocol
// line it cannot lose from a huge tool result by its type), however the
// line was split across reads.
func TestStreamline_OnSkipGetsEachHead(t *testing.T) {
	first := `{"type":"result","result":"` + strings.Repeat("x", 200<<10) + "\"}\n"
	second := `{"type":"user"` + strings.Repeat("y", 200<<10) + "\n"
	r := NewWithLimit(strings.NewReader("short\n"+first+second+"ok\n"), 1<<10)
	var heads []string
	r.OnSkip(func(head []byte) { heads = append(heads, string(head)) })
	got, err := lines(t, r)
	require.ErrorIs(t, err, io.EOF)
	assert.Equal(t, []string{"short", "ok"}, got)
	assert.Equal(t, []string{first[:SkippedHeadBytes], second[:SkippedHeadBytes]}, heads, "both skipped lines, in order")
}
