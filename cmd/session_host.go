package cmd

import (
	"errors"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/spf13/cobra"
	"golang.org/x/sys/unix"

	"watchtower/internal/sessionhost"
)

// sessionHostIdleExit and sessionHostRingSize are the host's fixed policy:
// exit after 60 s with no sessions and no clients, keep 2 MiB per session.
const (
	sessionHostIdleExit = 60 * time.Second
	sessionHostRingSize = 2 << 20
)

var flagSessionHostSocket string

var sessionHostCmd = &cobra.Command{
	Use:   "session-host --socket PATH",
	Short: "Own workbench terminal sessions so they survive an app restart",
	Long: `Run the workbench session host on a unix socket. The Desktop starts it
detached; it owns each workbench terminal's PTY so the session keeps running
while the app quits or updates, and exits on its own after 60 s with no
sessions and no clients. A host already running on the socket makes this a
no-op (exit 0).`,
	Args: cobra.NoArgs,
	// No config or database: the host only serves terminals.
	PersistentPreRunE: func(*cobra.Command, []string) error { return nil },
	Hidden:            true,
	RunE:              runSessionHost,
}

func init() {
	sessionHostCmd.Flags().StringVar(&flagSessionHostSocket, "socket", "", "unix socket path to serve on")
	rootCmd.AddCommand(sessionHostCmd)
}

func runSessionHost(cmd *cobra.Command, _ []string) error {
	if flagSessionHostSocket == "" {
		return usageError("session-host: --socket is required")
	}
	// Leave the launching app's session so its exit does not reach us. A
	// process already leading a group cannot do this; it carries on.
	if _, err := unix.Setsid(); err != nil {
		fmt.Fprintf(cmd.ErrOrStderr(), "session-host: setsid: %v\n", err)
	}
	defer sessionhost.DiscardHangup()()

	l, err := sessionhost.Listen(flagSessionHostSocket)
	if errors.Is(err, sessionhost.ErrHostRunning) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("session-host: %w", err)
	}
	ctx, stop := signal.NotifyContext(cmd.Context(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	srv := sessionhost.NewServer(sessionhost.Options{IdleExit: sessionHostIdleExit, RingSize: sessionHostRingSize})
	if err := srv.Serve(ctx, l); err != nil {
		return fmt.Errorf("session-host: %w", err)
	}
	return nil
}
