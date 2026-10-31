package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"runtime"
	"strconv"

	"github.com/spf13/cobra"

	"watchtower/internal/hub/hostkind"
	"watchtower/internal/service"
)

// Owner verbs (refused under every agent marker, AGENT-07): the service runs
// the daemon with the owner's data and the phone hub.
const (
	serviceInstallVerb   = "install the Watchtower service"
	serviceUninstallVerb = "remove the Watchtower service"
)

// errServiceDesktopHost refuses `service install` on a Mac with the app.
var errServiceDesktopHost = errors.New("This Mac has the Watchtower app, which runs the daemon itself.") //nolint:staticcheck // ST1005: the owner's sentence

// serviceGOOS and serviceRunner are test seams: tests never run a real
// systemctl, launchctl or loginctl.
var (
	serviceGOOS                  = runtime.GOOS
	serviceRunner service.Runner = runServiceCommand
)

var serviceCmd = &cobra.Command{
	Use:   "service",
	Short: "Run the daemon under this host's service manager (headless hosts)",
	Long: `Installs the Watchtower daemon as a systemd user unit (Linux) or a
LaunchAgent (a Mac without the Watchtower app), so it starts on its own and
restarts after a failure. Watchtower never runs sudo: when the host should
keep running after you log out, it prints the one command to run yourself.`,
}

// serviceStatusJSON is `service status|install|uninstall --json` (pinned
// keys; linger is null on darwin or when loginctl is missing).
type serviceStatusJSON struct {
	Manager   string `json:"manager"`
	Installed bool   `json:"installed"`
	Running   bool   `json:"running"`
	Linger    *bool  `json:"linger"`
}

func init() {
	install := &cobra.Command{
		Use:   "install",
		Short: "Set up the workspace and the hub, and start the daemon as a service",
		Long: `Creates the workspace (the headless profile: only the core features on),
turns the phone hub on, writes the service unit and starts it. Idempotent:
an unchanged unit is not rewritten or restarted.`,
		Args: cobra.NoArgs,
		RunE: runServiceInstall,
	}
	uninstall := &cobra.Command{
		Use:   "uninstall",
		Short: "Stop the daemon service and remove its unit (keeps every data file)",
		Args:  cobra.NoArgs,
		RunE:  runServiceUninstall,
	}
	status := &cobra.Command{
		Use:   "status",
		Short: "Show whether the daemon service is installed and running",
		Args:  cobra.NoArgs,
		RunE:  runServiceStatus,
	}
	for _, c := range []*cobra.Command{install, uninstall, status} {
		c.Flags().Bool("json", false, `print {"manager","installed","running","linger"}`)
		serviceCmd.AddCommand(c)
	}
	rootCmd.AddCommand(serviceCmd)
}

// runServiceCommand is the production Runner: combined output; a missing
// binary answers with an error wrapping exec.ErrNotFound.
func runServiceCommand(ctx context.Context, name string, args ...string) ([]byte, error) {
	return exec.CommandContext(ctx, name, args...).CombinedOutput()
}

// newServiceInstaller builds the installer for this host. Hints go to stdout,
// or to stderr under --json so the JSON line stays alone.
func newServiceInstaller(cmd *cobra.Command, asJSON bool) (service.Installer, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return service.Installer{}, fmt.Errorf("finding the home directory: %w", err)
	}
	u, err := user.Current()
	if err != nil {
		return service.Installer{}, fmt.Errorf("finding the current user: %w", err)
	}
	uid, err := strconv.Atoi(u.Uid)
	if err != nil {
		return service.Installer{}, fmt.Errorf("reading the current user's id: %w", err)
	}
	var out io.Writer = cmd.OutOrStdout()
	if asJSON {
		out = cmd.ErrOrStderr()
	}
	return service.Installer{
		GOOS:       serviceGOOS,
		Home:       home,
		ConfigHome: os.Getenv("XDG_CONFIG_HOME"),
		User:       u.Username,
		UID:        uid,
		Run:        serviceRunner,
		Out:        out,
	}, nil
}

func runServiceInstall(cmd *cobra.Command, _ []string) error {
	if err := refuseUnderAgent(serviceInstallVerb); err != nil {
		return err
	}
	asJSON, _ := cmd.Flags().GetBool("json")
	inst, err := newServiceInstaller(cmd, asJSON)
	if err != nil {
		return err
	}
	inst.HostCheck = func() error {
		if k, _ := hostkind.Detect(hubProbe()); k == hostkind.Desktop {
			return errServiceDesktopHost
		}
		return nil
	}
	// After the service manager answered, before the unit is written: the
	// workspace (headless profile for a new config), then the hub on — a
	// direct write, no hub runs yet.
	inst.Prepare = func(context.Context) error {
		if _, err := initWorkspace(flagConfig, flagWorkspace, defaultWorkspaceName, true); err != nil {
			return err
		}
		return setHubEnabled(true)
	}
	unit, err := serviceUnit()
	if err != nil {
		return err
	}
	st, err := inst.Install(cmd.Context(), unit)
	if err != nil {
		return err
	}
	if err := printServiceStatus(cmd, asJSON, st); err != nil {
		return err
	}
	if !asJSON {
		_, err = fmt.Fprintln(cmd.OutOrStdout(), "Next: watchtower hub pair")
	}
	return err
}

func runServiceUninstall(cmd *cobra.Command, _ []string) error {
	if err := refuseUnderAgent(serviceUninstallVerb); err != nil {
		return err
	}
	asJSON, _ := cmd.Flags().GetBool("json")
	inst, err := newServiceInstaller(cmd, asJSON)
	if err != nil {
		return err
	}
	st, err := inst.Uninstall(cmd.Context())
	if err != nil {
		return err
	}
	return printServiceStatus(cmd, asJSON, st)
}

func runServiceStatus(cmd *cobra.Command, _ []string) error {
	asJSON, _ := cmd.Flags().GetBool("json")
	inst, err := newServiceInstaller(cmd, asJSON)
	if err != nil {
		return err
	}
	st, err := inst.Status(cmd.Context())
	if err != nil {
		return err
	}
	return printServiceStatus(cmd, asJSON, st)
}

// serviceUnit is this binary (symlinks resolved, so an update that swaps a
// symlink target still runs the real file) with the installing shell's PATH.
func serviceUnit() (service.Unit, error) {
	exe, err := os.Executable()
	if err != nil {
		return service.Unit{}, fmt.Errorf("finding this binary: %w", err)
	}
	exe, err = filepath.EvalSymlinks(exe)
	if err != nil {
		return service.Unit{}, fmt.Errorf("resolving this binary's path: %w", err)
	}
	return service.Unit{Exe: exe, Path: os.Getenv("PATH")}, nil
}

func printServiceStatus(cmd *cobra.Command, asJSON bool, st service.Status) error {
	out := cmd.OutOrStdout()
	if asJSON {
		return json.NewEncoder(out).Encode(serviceStatusJSON{
			Manager: st.Manager, Installed: st.Installed, Running: st.Running, Linger: st.Linger,
		})
	}
	yesNo := func(b bool) string {
		if b {
			return "yes"
		}
		return "no"
	}
	if _, err := fmt.Fprintf(out, "manager: %s\ninstalled: %s\nrunning: %s\n",
		st.Manager, yesNo(st.Installed), yesNo(st.Running)); err != nil {
		return err
	}
	if st.Manager != "systemd" {
		return nil
	}
	linger := "unknown"
	if st.Linger != nil {
		linger = yesNo(*st.Linger)
	}
	_, err := fmt.Fprintf(out, "linger: %s\n", linger)
	return err
}
