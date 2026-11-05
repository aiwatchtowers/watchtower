package cmd

import (
	"context"
	"errors"
	"os/exec"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/digest"
)

// childGenerator stands in for the claude/codex child: Generate starts a
// long-lived process bound to its context, sends this test process the
// Desktop's SIGTERM (Stop), and waits for the child to end.
type childGenerator struct {
	mu       sync.Mutex
	pgid     int
	ctxEnded bool
}

func (g *childGenerator) Generate(ctx context.Context, _, _, _ string) (string, *digest.Usage, string, error) {
	child := exec.CommandContext(ctx, "/bin/sleep", "30")
	child.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := child.Start(); err != nil {
		return "", nil, "", err
	}
	g.mu.Lock()
	g.pgid = child.Process.Pid
	g.mu.Unlock()
	// The preview has installed its signal context by now (EvaluateDraft
	// runs inside it), so this SIGTERM cancels the context instead of
	// ending the test process.
	if err := syscall.Kill(syscall.Getpid(), syscall.SIGTERM); err != nil {
		return "", nil, "", err
	}
	_ = child.Wait()
	g.mu.Lock()
	g.ctxEnded = ctx.Err() != nil
	g.mu.Unlock()
	return "", nil, "", errors.Join(ctx.Err(), errors.New("model child ended"))
}

// TestAutomationsCLI_PreviewSIGTERMCancelsTheModelChild: the Desktop's
// Stop (SIGTERM to `automations preview`) cancels the evaluation's context,
// so the model child is terminated instead of running on.
func TestAutomationsCLI_PreviewSIGTERMCancelsTheModelChild(t *testing.T) {
	newAutoCLI(t)
	gen := &childGenerator{}
	automationsDryRunGenerator = func(*config.Config) digest.Generator { return gen }
	t.Cleanup(func() {
		gen.mu.Lock()
		defer gen.mu.Unlock()
		if gen.pgid > 0 {
			_ = syscall.Kill(-gen.pgid, syscall.SIGKILL) // reap the stub's group whatever happened
		}
	})

	done := make(chan struct{})
	go func() {
		defer close(done)
		_, _ = runAutomationsWithStdin(t, previewRecipe, "preview", "--stdin", "--json")
	}()
	select {
	case <-done:
	case <-time.After(20 * time.Second):
		t.Fatal("preview still running 20 s after SIGTERM: the model child was not cancelled")
	}

	gen.mu.Lock()
	defer gen.mu.Unlock()
	require.Positive(t, gen.pgid, "the generator never started its child")
	assert.True(t, gen.ctxEnded, "the generator's context was not cancelled by SIGTERM")
	assert.ErrorIs(t, syscall.Kill(gen.pgid, 0), syscall.ESRCH, "the model child is still alive")
}
