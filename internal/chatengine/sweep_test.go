package chatengine

import (
	"bufio"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// child is a real process the test started in its own group; Cleanup kills
// the group, reaps the child and fails if anything of the group outlived it.
type child struct {
	cmd    *exec.Cmd
	waited chan struct{}
}

func startChild(t *testing.T, cmd *exec.Cmd) *child {
	t.Helper()
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	c := &child{cmd: cmd, waited: make(chan struct{})}
	require.NoError(t, cmd.Start())
	go func() {
		_ = cmd.Wait()
		close(c.waited)
	}()
	pgid := cmd.Process.Pid
	t.Cleanup(func() {
		_ = syscall.Kill(-pgid, syscall.SIGKILL)
		<-c.waited
		if !groupGoneSoon(pgid) {
			t.Errorf("process group %d outlived the test", pgid)
		}
	})
	return c
}

// groupGoneSoon: the group is gone, or goes within a bound (an orphaned
// grandchild is reaped by init, not by the test).
func groupGoneSoon(pgid int) bool {
	for range 250 {
		if err := syscall.Kill(-pgid, 0); errors.Is(err, syscall.ESRCH) {
			return true
		}
		time.Sleep(20 * time.Millisecond)
	}
	return false
}

func (c *child) running() bool {
	select {
	case <-c.waited:
		return false
	default:
		return syscall.Kill(c.cmd.Process.Pid, 0) == nil
	}
}

func writeGroupFile(t *testing.T, dir string, conv int64, pgid int) string {
	t.Helper()
	require.NoError(t, os.MkdirAll(dir, 0o700))
	path := filepath.Join(dir, strconv.FormatInt(conv, 10)+".pgid")
	require.NoError(t, os.WriteFile(path, []byte(strconv.Itoa(pgid)), 0o600))
	return path
}

// TestChatengine_SweepKillsOrphanGroup: a session child whose runner died
// without Close (a kill -9 of the daemon) is killed with its whole group by
// the next runner's sweep, and its group file removed; a group file naming
// a process that is not `ai session`, or nothing at all, is removed
// without a kill.
func TestChatengine_SweepKillsOrphanGroup(t *testing.T) {
	exe, err := os.Executable()
	require.NoError(t, err)
	hubDir := t.TempDir()
	dir := filepath.Join(hubDir, "sessions")

	stubCmd := exec.Command(exe, "ai", "session", "--conversation", "7", "--surface", "main")
	stubCmd.Env = append(os.Environ(), stubEnv+"=1")
	out, err := stubCmd.StdoutPipe()
	require.NoError(t, err)
	stub := startChild(t, stubCmd)
	line, err := bufio.NewReader(out).ReadString('\n')
	require.NoError(t, err)
	require.Equal(t, "ready\n", line, "the stub started its grandchild")
	stubFile := writeGroupFile(t, dir, 7, stubCmd.Process.Pid)

	other := startChild(t, exec.Command("sleep", "600"))
	otherFile := writeGroupFile(t, dir, 8, other.cmd.Process.Pid)

	gone := exec.Command("true")
	require.NoError(t, gone.Run())
	goneFile := writeGroupFile(t, dir, 9, gone.Process.Pid)

	r := New(Config{DB: openDB(t), Dir: hubDir})
	require.NoError(t, r.Start(context.Background()))

	<-stub.waited
	assert.True(t, groupGoneSoon(stubCmd.Process.Pid), "the stub's grandchild died with its group")
	assert.True(t, other.running(), "a process that is not ai session is never killed")
	for _, p := range []string{stubFile, otherFile, goneFile} {
		_, err := os.Stat(p)
		assert.True(t, os.IsNotExist(err), "%s removed", filepath.Base(p))
	}
}

// TestChatengine_ExecSessionWritesAndRemovesGroupFile: a real child gets its
// own process group, recorded in its 0600 group file while it runs and
// removed once it was reaped.
func TestChatengine_ExecSessionWritesAndRemovesGroupFile(t *testing.T) {
	p, err := execStart("/bin/sh")([]string{"-c", "read line; exit 0"})
	require.NoError(t, err)
	pgid := p.PGID()
	t.Cleanup(func() {
		_ = syscall.Kill(-pgid, syscall.SIGKILL)
		<-p.Exited()
		_ = p.Stdout().Close()
	})
	got, err := syscall.Getpgid(pgid)
	require.NoError(t, err)
	assert.Equal(t, pgid, got, "the child leads its own group")

	hubDir := t.TempDir()
	r := New(Config{Dir: hubDir})
	s := &session{r: r, conv: 3, proc: p}
	s.writePGID(pgid)
	info, err := os.Stat(filepath.Join(hubDir, "sessions", "3.pgid"))
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), info.Mode().Perm())

	_, err = p.Stdin().Write([]byte("bye\n"))
	require.NoError(t, err)
	<-p.Exited()
	s.removePGID()
	_, err = os.Stat(filepath.Join(hubDir, "sessions", "3.pgid"))
	assert.True(t, os.IsNotExist(err))
}
