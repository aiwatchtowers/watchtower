package cmd

import (
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/hub/state"
)

// hubDirEnv names the hub state dir; phase 1 has no default (the live
// app-support folder is phase 3's), so every hub verb needs it.
const hubDirEnv = "WATCHTOWER_HUB_DIR"

// hubCmd is the `watchtower hub …` parent (Go hub spec §10). This file holds
// the parent and the sidecar opener the verbs share; plan 1a Task 15 adds its
// own verbs and the control-socket route to a running hub.
var hubCmd = &cobra.Command{
	Use:   "hub",
	Short: "The phone hub (Go hub POC)",
}

func init() { rootCmd.AddCommand(hubCmd) }

// hubLockWait is how long a CLI write waits for the hub lock (another CLI
// holds it for milliseconds).
var hubLockWait = 3 * time.Second

// withHubState opens the sidecar under the hub lock for one write and
// releases both. A running hub holds the lock: until the control-socket route
// exists the verb says so instead of writing beside it.
func withHubState(fn func(dir string, st *state.Store) error) error {
	dir := os.Getenv(hubDirEnv)
	if dir == "" {
		return fmt.Errorf("%s is not set: the hub verbs need a hub state dir in this phase", hubDirEnv)
	}
	var (
		lock *state.Lock
		err  error
	)
	deadline := time.Now().Add(hubLockWait)
	for {
		lock, err = state.AcquireLock(dir)
		if !errors.Is(err, state.ErrLocked) || time.Now().After(deadline) {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if errors.Is(err, state.ErrLocked) {
		return errors.New("a hub holds this state dir: the verb must reach it over the control socket, which is not available yet")
	}
	if err != nil {
		return err
	}
	defer func() { _ = lock.Release() }()
	st, err := state.Open(dir)
	if err != nil {
		return err
	}
	defer func() { _ = st.Close() }()
	return fn(dir, st)
}
