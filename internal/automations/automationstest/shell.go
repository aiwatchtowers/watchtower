package automationstest

import (
	"context"
	"sync"

	"watchtower/internal/automations"
)

// FakeShell is a ShellRunner that records its commands. With Next set it
// runs each one through Next (a recording wrapper around the real runner);
// otherwise it returns Result and Err.
type FakeShell struct {
	Next   automations.ShellRunner
	Result automations.ShellResult
	Err    error

	mu    sync.Mutex
	calls []automations.ShellCommand
}

var _ automations.ShellRunner = (*FakeShell)(nil)

// Run records c and runs it through Next, or returns the scripted result.
func (s *FakeShell) Run(ctx context.Context, c automations.ShellCommand) (automations.ShellResult, error) {
	s.mu.Lock()
	s.calls = append(s.calls, c)
	s.mu.Unlock()
	if s.Next != nil {
		return s.Next.Run(ctx, c)
	}
	return s.Result, s.Err
}

// Calls returns a copy of the commands received so far.
func (s *FakeShell) Calls() []automations.ShellCommand {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]automations.ShellCommand(nil), s.calls...)
}

// FakeWorkbench is a WorkbenchResolver answering Info (or Err) for every id
// and counting its lookups.
type FakeWorkbench struct {
	Info automations.WorkbenchInfo
	Err  error

	mu sync.Mutex
	n  int
}

var _ automations.WorkbenchResolver = (*FakeWorkbench)(nil)

// Workbench counts the lookup and returns Info, Err.
func (w *FakeWorkbench) Workbench(_ context.Context, _ int64) (automations.WorkbenchInfo, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.n++
	return w.Info, w.Err
}

// CallCount returns how many lookups the fake received.
func (w *FakeWorkbench) CallCount() int {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.n
}
