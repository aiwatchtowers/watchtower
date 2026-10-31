package platform

import (
	"testing"
	"time"
)

// The darwin reader goes through the seam: no real lock or idle in CI.
func TestAwayDarwinReadsIdle(t *testing.T) {
	in := consoleInputs{hasSession: true, onConsole: true, idle: 5 * time.Second}
	a := darwinAway{read: func() consoleInputs { return in }}
	if away, err := a.Away(); err != nil || away {
		t.Fatalf("active console: away = %v, %v", away, err)
	}
	in.idle = 4 * time.Minute
	if away, _ := a.Away(); !away {
		t.Fatal("4 minutes idle reads as present")
	}
	in.idle, in.screenLocked = 0, true
	if away, _ := a.Away(); !away {
		t.Fatal("a locked screen reads as present")
	}
	// The real reader runs without a permission and never panics.
	_ = readConsole()
}

// The real assertion is taken and released (and a second release is a
// no-op); a CI Mac may refuse it, which Hold reports.
func TestAwakeDarwinHoldsAndReleases(t *testing.T) {
	release, err := NewAwake().Hold(AwakeReason)
	if err != nil {
		t.Skipf("the system refused the assertion here: %v", err)
	}
	release()
	release()
}
