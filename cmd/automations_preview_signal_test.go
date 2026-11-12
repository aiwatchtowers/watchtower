package cmd

import (
	"context"
	"errors"
	"os/exec"
	"reflect"
	"sync"
	"syscall"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/digest"
)

// childGenerator stands in for the claude/codex child: Generate starts a
// long-lived process bound to its context, presses Stop (`stop`, the
// signal context's cancel) and waits for the child to end, then records
// whether its context was cancelled.
type childGenerator struct {
	stop     func()
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
	waited := false
	defer func() { // every return path reaps the child
		if !waited {
			_ = child.Wait()
		}
	}()
	g.mu.Lock()
	g.pgid = child.Process.Pid
	g.mu.Unlock()
	g.stop()
	// Ends when the cancelled context kills the child, or when the test's
	// timeout path kills its group.
	_ = child.Wait()
	waited = true
	g.mu.Lock()
	g.ctxEnded = ctx.Err() != nil
	g.mu.Unlock()
	return "", nil, "", errors.Join(ctx.Err(), errors.New("model child ended"))
}

// TestAutomationsCLI_PreviewSignalContextIsNotifyContext: the production
// preview listens for SIGINT/SIGTERM (the Desktop's Stop).
func TestAutomationsCLI_PreviewSignalContextIsNotifyContext(t *testing.T) {
	require.Equal(t, reflect.ValueOf(notifyPreviewSignals).Pointer(), reflect.ValueOf(previewSignalContext).Pointer(),
		"the preview's signal context is the real NotifyContext")
	ctx, stop := notifyPreviewSignals(context.Background())
	assert.NoError(t, ctx.Err(), "a fresh signal context is live")
	stop()
	assert.Error(t, ctx.Err(), "stop releases it")
}

// TestAutomationsCLI_PreviewSIGTERMCancelsTheModelChild: the Desktop's
// Stop (the preview's signal context cancelled) cancels the evaluation's
// context, so the model child is terminated instead of running on.
func TestAutomationsCLI_PreviewSIGTERMCancelsTheModelChild(t *testing.T) {
	newAutoCLI(t)
	// Stop, as the signal context would see it: no real signal is sent.
	stopped, stopPreview := context.WithCancel(context.Background())
	t.Cleanup(stopPreview)
	origSignals := previewSignalContext
	previewSignalContext = func(ctx context.Context) (context.Context, context.CancelFunc) {
		ctx, cancel := context.WithCancel(ctx)
		context.AfterFunc(stopped, cancel)
		return ctx, cancel
	}
	t.Cleanup(func() { previewSignalContext = origSignals })
	gen := &childGenerator{stop: stopPreview}
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
	// A child Stop did not cancel keeps the preview running: the run hangs
	// into go test's -timeout.
	<-done

	gen.mu.Lock()
	defer gen.mu.Unlock()
	require.Positive(t, gen.pgid, "the generator never started its child")
	assert.True(t, gen.ctxEnded, "the generator's context was not cancelled by Stop")
	assert.ErrorIs(t, syscall.Kill(gen.pgid, 0), syscall.ESRCH, "the model child is still alive")
}
