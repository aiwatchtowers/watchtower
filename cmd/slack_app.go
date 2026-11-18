package cmd

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/slackapp"
)

var slackAppCmd = &cobra.Command{
	Use:   "app",
	Short: "Set up Watchtower's Slack app in your company's workspace",
	Long: "Creates (or adopts) Watchtower's own Slack app in a workspace from a\n" +
		"configuration token and writes the connect link to the app's About page.\n" +
		"The token is read from stdin (one line), used for this run and never stored.",
}

// noArgsToken refuses positional arguments without echoing them: a token
// pasted on the command line would otherwise land in the error text (and it
// is already in the shell history and the process list).
func noArgsToken(_ *cobra.Command, args []string) error {
	if len(args) > 0 {
		return errors.New("this command takes no arguments: pipe the configuration token on stdin, never on the command line")
	}
	return nil
}

var slackAppCreateCmd = &cobra.Command{
	Use:   "create",
	Short: "Create Watchtower's app in the token's workspace (token on stdin)",
	Args:  noArgsToken,
	RunE:  runSlackAppCreate,
}

var slackAppAdoptCmd = &cobra.Command{
	Use:   "adopt",
	Short: "Bring the workspace's existing Watchtower app in line with ours (token on stdin)",
	Args:  noArgsToken,
	RunE:  runSlackAppAdopt,
}

var slackAppLinkCmd = &cobra.Command{
	Use:   "link",
	Short: "Write the connect link to the setup app's About page (token on stdin)",
	Args:  noArgsToken,
	RunE:  runSlackAppLink,
}

var slackAppStatusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show every Slack app setup and its stage",
	Args:  cobra.NoArgs,
	RunE:  runSlackAppStatus,
}

func init() {
	for _, c := range []*cobra.Command{slackAppCreateCmd, slackAppAdoptCmd, slackAppLinkCmd, slackAppStatusCmd} {
		c.Flags().Bool("json", false, "print one JSON line per step and a final result line")
		slackAppCmd.AddCommand(c)
	}
	slackAppAdoptCmd.Flags().String("app-id", "", "the app's App ID (Basic Information page), when Watchtower does not know it")
	slackAppLinkCmd.Flags().String("team", "", "the workspace's team id (default: the token's workspace)")
	slackCmd.AddCommand(slackAppCmd)
}

// Seams for the tests: the Slack API the setup calls and the retired shared
// app's client id.
var (
	slackAppAPI = func() slackapp.API { return slackapp.NewClient(slackapp.DefaultBaseURL) }
	// slackAppRetiredClientID is the retired public shared app's client id;
	// an account on it is not on a company app. Plan B Task 3 adds
	// auth.RetiredSharedClientID; until it lands nothing counts as shared.
	slackAppRetiredClientID = func() string { return "" }
)

// slackAppSetupLock is the setup's lock file in the workspace directory.
const slackAppSetupLock = "slack_app_setup.lock"

// maxConfigTokenLine bounds the stdin line the token is read from.
const maxConfigTokenLine = 4096

// readConfigToken reads the configuration token: the first line of stdin.
func readConfigToken(in io.Reader) (string, error) {
	line, err := bufio.NewReaderSize(io.LimitReader(in, maxConfigTokenLine), maxConfigTokenLine).ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return "", fmt.Errorf("reading the configuration token from stdin: %w", err)
	}
	tok := strings.TrimSpace(line)
	if tok == "" {
		return "", errors.New("no configuration token on stdin: pipe it in as one line")
	}
	return tok, nil
}

// slackAppResultJSON is the final line of a setup verb's --json output.
type slackAppResultJSON struct {
	Result      string `json:"result"`
	TeamID      string `json:"team_id"`
	TeamName    string `json:"team_name"`
	AppID       string `json:"app_id"`
	ClientID    string `json:"client_id"`
	LinkWritten bool   `json:"link_written"`
	Code        string `json:"code,omitempty"`
	Error       string `json:"error,omitempty"`
}

func runSlackAppCreate(cmd *cobra.Command, _ []string) error {
	return runSlackAppSetup(cmd, func(ctx context.Context, r *slackapp.Runner, tok string) (slackapp.Result, error) {
		return r.Create(ctx, tok)
	})
}

func runSlackAppAdopt(cmd *cobra.Command, _ []string) error {
	appID, _ := cmd.Flags().GetString("app-id")
	return runSlackAppSetup(cmd, func(ctx context.Context, r *slackapp.Runner, tok string) (slackapp.Result, error) {
		return r.Adopt(ctx, tok, strings.TrimSpace(appID))
	})
}

func runSlackAppLink(cmd *cobra.Command, _ []string) error {
	team, _ := cmd.Flags().GetString("team")
	return runSlackAppSetup(cmd, func(ctx context.Context, r *slackapp.Runner, tok string) (slackapp.Result, error) {
		return r.Link(ctx, tok, strings.TrimSpace(team))
	})
}

// runSlackAppSetup reads the token, runs one setup verb and prints its steps
// and result. A result that is not ok/exists is still a finished run: exit 0
// with --json (the result line says what happened), an error without it.
func runSlackAppSetup(cmd *cobra.Command, run func(context.Context, *slackapp.Runner, string) (slackapp.Result, error)) error {
	asJSON, _ := cmd.Flags().GetBool("json")
	tok, err := readConfigToken(cmd.InOrStdin())
	if err != nil {
		return err
	}
	cfg, database, err := openSlackCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()

	out := cmd.OutOrStdout()
	enc := json.NewEncoder(out)
	r := &slackapp.Runner{
		DB:              database,
		API:             slackAppAPI(),
		LockPath:        filepath.Join(cfg.WorkspaceDir(), slackAppSetupLock),
		RetiredClientID: slackAppRetiredClientID(),
		Emit: func(s slackapp.Step) {
			if asJSON {
				_ = enc.Encode(s)
			} else if s.State != slackapp.StateRunning {
				fmt.Fprintf(out, "%s: %s\n", s.Name, s.State)
			}
		},
	}
	ctx := cmd.Context()
	if ctx == nil {
		ctx = context.Background()
	}
	res, err := run(ctx, r, tok)
	if err != nil {
		return err
	}
	if asJSON {
		return enc.Encode(slackAppResultJSON{Result: res.Kind, TeamID: res.TeamID, TeamName: res.TeamName,
			AppID: res.AppID, ClientID: res.ClientID, LinkWritten: res.LinkWritten, Code: res.Code, Error: res.Error})
	}
	return printSlackAppResult(out, res)
}

// printSlackAppResult is the human form of a setup result.
func printSlackAppResult(out io.Writer, res slackapp.Result) error {
	switch res.Kind {
	case slackapp.KindOK:
		fmt.Fprintf(out, "Watchtower's app %s is ready in %s. Connect code: %s:%s\n", res.AppID, res.TeamName, res.TeamID, res.ClientID)
		return nil
	case slackapp.KindExists:
		fmt.Fprintf(out, "%s already has Watchtower's app %s (client id %s); nothing was created.\n", res.TeamName, res.AppID, res.ClientID)
		return nil
	}
	detail := res.Code
	if res.Error != "" {
		detail = res.Error
	}
	if detail != "" {
		detail = ": " + detail
	}
	return fmt.Errorf("slack app setup ended with %s%s", res.Kind, detail)
}

func runSlackAppStatus(cmd *cobra.Command, _ []string) error {
	asJSON, _ := cmd.Flags().GetBool("json")
	_, database, err := openSlackCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	setups, err := slackapp.Status(database)
	if err != nil {
		return err
	}
	out := cmd.OutOrStdout()
	if asJSON {
		return json.NewEncoder(out).Encode(struct {
			Setups []slackapp.SetupStatus `json:"setups"`
		}{setups})
	}
	if len(setups) == 0 {
		fmt.Fprintln(out, "No Slack app setups.")
		return nil
	}
	for _, s := range setups {
		fmt.Fprintf(out, "%s (%s)  app %s  client %s  stage %s\n", s.TeamName, s.TeamID, s.AppID, s.ClientID, s.Stage)
	}
	return nil
}
