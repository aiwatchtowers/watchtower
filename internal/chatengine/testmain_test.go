package chatrun

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"testing"
	"time"

	"watchtower/internal/db"
)

// stubEnv turns the test binary into a stand-in `watchtower ai session`
// (TestChatrun_SweepKillsOrphanGroup): it starts one grandchild in its own
// group, says "ready" and sleeps.
const stubEnv = "WATCHTOWER_CHATRUN_STUB"

// TestMain migrates one template database; every test file opened from a
// new path starts from it instead of running every migration again.
func TestMain(m *testing.M) {
	if os.Getenv(stubEnv) == "1" {
		runStub()
		return
	}
	if err := db.InitTestFileTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}

func runStub() {
	kid := exec.Command("sleep", "600") // same process group
	if err := kid.Start(); err != nil {
		os.Exit(2)
	}
	w := bufio.NewWriter(os.Stdout)
	_, _ = w.WriteString("ready\n")
	_ = w.Flush()
	time.Sleep(10 * time.Minute)
	os.Exit(0)
}
