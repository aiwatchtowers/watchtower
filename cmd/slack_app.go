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

	"watchtower/internal/auth"
	"watchtower/internal/config"
	"watchtower/internal/db"
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
	Long: "Adds the loopback redirect URL, any missing user scopes and the connect link to\n" +
		"the workspace's existing Watchtower app, and turns on PKCE sign-in for it. Turning\n" +
		"PKCE on is one-way: only Slack support can turn it off, and the app's refresh tokens\n" +
		"then expire after 30 days. Pass --enable-pkce to agree; without it an app that does\n" +
		"not have PKCE yet is left unchanged (needs_pkce_consent).",
	Args: noArgsToken,
	RunE: runSlackAppAdopt,
}

var slackAppLinkCmd = &cobra.Command{
	Use:   "link",
	Short: "Write the connect link to the setup app's About page (token on stdin)",
	Args:  noArgsToken,
	RunE:  runSlackAppLink,
}

var slackAppPendingCmd = &cobra.Command{
	Use:   "pending",
	Short: "Resolve a setup whose create answer was lost: --clear or --attach the app you found",
	Long: "A setup whose apps.manifest.create answer was lost stays pending, so no second\n" +
		"app is ever created. Look for \"Watchtower\" on api.slack.com/apps, then either\n" +
		"--clear (nothing is there; create can run again) or --attach --app-id A --client-id C\n" +
		"(the app is there; continue with 'slack app link').",
	Args: cobra.NoArgs,
	RunE: runSlackAppPending,
}

var slackAppStatusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show every Slack app setup and its stage",
	Args:  cobra.NoArgs,
	RunE:  runSlackAppStatus,
}

func init() {
	for _, c := range []*cobra.Command{slackAppCreateCmd, slackAppAdoptCmd, slackAppLinkCmd, slackAppPendingCmd, slackAppStatusCmd} {
		c.Flags().Bool("json", false, "print one JSON line per step and a final result line")
		slackAppCmd.AddCommand(c)
	}
	slackAppAdoptCmd.Flags().String("app-id", "", "the app's App ID (Basic Information page), when Watchtower does not know it")
	slackAppAdoptCmd.Flags().String("confirm-app-id", "", "repeat --app-id after checking the app's name (confirm_app)")
	slackAppAdoptCmd.Flags().Bool("enable-pkce", false, "agree to turn on PKCE sign-in for the app (one-way: only Slack support can turn it off)")
	slackAppLinkCmd.Flags().String("team", "", "the workspace's team id (default: the token's workspace)")
	slackAppAdoptCmd.Flags().String("team", "", "the workspace the app must be in; another workspace's token changes nothing (wrong_team)")
	slackAppPendingCmd.Flags().String("team", "", "the workspace's team id (required)")
	slackAppPendingCmd.Flags().Bool("clear", false, "no Watchtower app exists: drop the pending setup")
	slackAppPendingCmd.Flags().Bool("attach", false, "the app exists: record its --app-id and --client-id")
	slackAppPendingCmd.Flags().String("app-id", "", "the app's App ID (Basic Information page)")
	slackAppPendingCmd.Flags().String("client-id", "", "the app's Client ID (Basic Information page)")
	slackCmd.AddCommand(slackAppCmd)
}

// Seams for the tests: the Slack API the setup calls and the retired shared
// app's client id.
var (
	slackAppAPI = func() slackapp.API { return slackapp.NewClient(slackapp.DefaultBaseURL) }
	// slackAppRetiredClientID is the retired public shared app's client id;
	// an account on it is not on a company app.
	slackAppRetiredClientID = func() string { return auth.RetiredSharedClientID }
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
	AppName     string `json:"app_name,omitempty"`
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
	confirm, _ := cmd.Flags().GetString("confirm-app-id")
	team, _ := cmd.Flags().GetString("team")
	enablePKCE, _ := cmd.Flags().GetBool("enable-pkce")
	return runSlackAppSetup(cmd, func(ctx context.Context, r *slackapp.Runner, tok string) (slackapp.Result, error) {
		return r.Adopt(ctx, tok, strings.TrimSpace(team), strings.TrimSpace(appID), strings.TrimSpace(confirm), enablePKCE)
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
	r, enc := newSlackAppRunner(cmd, cfg, database, asJSON)
	ctx := cmd.Context()
	if ctx == nil {
		ctx = context.Background()
	}
	res, err := run(ctx, r, tok)
	if err != nil {
		return err
	}
	return finishSlackAppRun(cmd, enc, res, asJSON)
}

// newSlackAppRunner is a Runner on database whose steps print to cmd's
// stdout (JSON lines, or "step: state" for finished steps).
func newSlackAppRunner(cmd *cobra.Command, cfg *config.Config, database *db.DB, asJSON bool) (*slackapp.Runner, *json.Encoder) {
	out := cmd.OutOrStdout()
	enc := json.NewEncoder(out)
	return &slackapp.Runner{
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
	}, enc
}

// finishSlackAppRun prints res: the final JSON line, or the human line (an
// error for a result that is not ok/exists); a storage failure's Go detail
// goes to stderr only.
func finishSlackAppRun(cmd *cobra.Command, enc *json.Encoder, res slackapp.Result, asJSON bool) error {
	out := cmd.OutOrStdout()
	if res.Err != nil {
		// The Go detail of a storage failure: stderr only, never the result line.
		fmt.Fprintf(cmd.ErrOrStderr(), "slack app setup: %v\n", res.Err)
	}
	if asJSON {
		return enc.Encode(slackAppResultJSON{Result: res.Kind, TeamID: res.TeamID, TeamName: res.TeamName,
			AppID: res.AppID, AppName: res.AppName, ClientID: res.ClientID, LinkWritten: res.LinkWritten, Code: res.Code, Error: res.Error})
	}
	return printSlackAppResult(out, res)
}

// printSlackAppResult is the human form of a setup result.
func printSlackAppResult(out io.Writer, res slackapp.Result) error {
	switch res.Kind {
	case slackapp.KindOK:
		if res.AppID == "" {
			fmt.Fprintf(out, "The pending setup of %s was cleared; 'slack app create' can run again.\n", res.TeamID)
			return nil
		}
		fmt.Fprintf(out, "Watchtower's app %s is ready in %s. Connect code: %s:%s\n", res.AppID, res.TeamName, res.TeamID, res.ClientID)
		return nil
	case slackapp.KindConfirmApp:
		fmt.Fprintf(out, "App %s is %q. If that is your Watchtower app, run again with --confirm-app-id %s; nothing was changed.\n",
			res.AppID, res.AppName, res.AppID)
		return nil
	case slackapp.KindNeedsPKCEConsent:
		return fmt.Errorf("adopting app %s turns on PKCE sign-in, which only Slack support can turn off; "+
			"run again with --enable-pkce to agree. Nothing was changed", res.AppID)
	case slackapp.KindExists:
		fmt.Fprintf(out, "%s already has Watchtower's app %s (client id %s); nothing was created.\n", res.TeamName, res.AppID, res.ClientID)
		return nil
	}
	detail := res.Code
	if res.Error != "" {
		detail = res.Error
	}
	if res.AppID != "" {
		detail += fmt.Sprintf(" (app %s, client id %s)", res.AppID, res.ClientID)
	}
	if detail != "" {
		detail = ": " + detail
	}
	return fmt.Errorf("slack app setup ended with %s%s", res.Kind, detail)
}

func runSlackAppPending(cmd *cobra.Command, _ []string) error {
	asJSON, _ := cmd.Flags().GetBool("json")
	team, _ := cmd.Flags().GetString("team")
	doClear, _ := cmd.Flags().GetBool("clear")
	attach, _ := cmd.Flags().GetBool("attach")
	appID, _ := cmd.Flags().GetString("app-id")
	clientID, _ := cmd.Flags().GetString("client-id")
	team = strings.TrimSpace(team)
	if team == "" {
		return errors.New("--team is required")
	}
	if doClear == attach {
		return errors.New("give exactly one of --clear and --attach")
	}
	if doClear && (appID != "" || clientID != "") {
		return errors.New("--app-id and --client-id go with --attach only")
	}
	cfg, database, err := openSlackCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	r, enc := newSlackAppRunner(cmd, cfg, database, asJSON)
	var res slackapp.Result
	if doClear {
		res, err = r.ClearPending(team)
	} else {
		res, err = r.AttachPending(team, strings.TrimSpace(appID), strings.TrimSpace(clientID))
	}
	if err != nil {
		return err
	}
	if attach && !asJSON && res.Kind == slackapp.KindOK {
		fmt.Fprintf(cmd.OutOrStdout(), "Recorded app %s (client id %s) for %s. Next: pipe a configuration token into 'watchtower slack app link' to write the connect link.\n",
			res.AppID, res.ClientID, res.TeamID)
		return nil
	}
	return finishSlackAppRun(cmd, enc, res, asJSON)
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
