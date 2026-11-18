package cmd

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/auth"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/oauthpage"
	"watchtower/internal/policy"
	watchtowerslack "watchtower/internal/slack"
	"watchtower/internal/slackconnect"
	"watchtower/internal/slackmode"
)

var slackConnectCmd = &cobra.Command{
	Use:   "connect (--team T --client C | --code CODE) [--account N]",
	Short: "Connect a Slack workspace through its company's Watchtower app",
	Long: "Connects a Slack workspace through the company's own Watchtower app with PKCE\n" +
		"(no client secret): binds the loopback listener on 127.0.0.1:18551, opens Slack's\n" +
		"sign-in in the browser and stores the account when Slack redirects back.\n\n" +
		"The team and client come from the connect link on the app's About page, or from\n" +
		"its code <team id>:<client id>. A workspace that already has an account is\n" +
		"re-bound to the app on that same account (its history stays); --account picks\n" +
		"the account. While the Watchtower app is open it holds the port: connect from\n" +
		"Connections → Slack instead.",
	Args: cobra.NoArgs,
	RunE: runSlackConnect,
}

var slackConnectServeCmd = &cobra.Command{
	Use:   "serve",
	Short: "Hold the Slack connect listener for the Watchtower app (JSON lines on stdin/stdout)",
	Long: "The Watchtower app's child: holds 127.0.0.1:18551, reports one JSON object per\n" +
		"line on stdout (listening, port_busy, link, browser, connected, failed, busy) and\n" +
		"reads commands as JSON lines on stdin (start, confirm, cancel). It exits when\n" +
		"stdin closes.",
	Args: cobra.NoArgs,
	RunE: runSlackConnectServe,
}

func init() {
	slackConnectCmd.Flags().String("team", "", "the workspace's team id (from the connect link)")
	slackConnectCmd.Flags().String("client", "", "the company app's client id (from the connect link)")
	slackConnectCmd.Flags().String("code", "", "the connect code <team id>:<client id>")
	slackConnectCmd.Flags().Int64("account", 0, "existing account id to connect (default: the workspace's account, or a new one)")
	slackConnectCmd.Flags().Bool("no-open", false, "print the sign-in URL instead of opening a browser")
	slackConnectCmd.Flags().Bool("app-return", false, "bring the Watchtower app back to the front when done")
	slackConnectCmd.Flags().Bool("json", false, "print the result as one JSON line (the serve event)")

	slackConnectCmd.AddCommand(slackConnectServeCmd)
	slackCmd.AddCommand(slackConnectCmd)
}

// slackConnectPortBusyExitCode is the one-shot connect's exit when another
// process (the Watchtower app's child) holds the port.
const slackConnectPortBusyExitCode = 2

// slackConnectServePortBusyExitCode is serve's exit after port_busy.
const slackConnectServePortBusyExitCode = 3

// slackConnectDeps are the connect flow's outside edges; tests swap them.
type slackConnectDeps struct {
	port        int
	listen      func(port int) (net.Listener, error)
	exchange    slackconnect.Exchanger
	openBrowser func(rawURL string)
	clock       slackconnect.Clock
}

// newSlackConnectDeps returns the production edges: port 18551, Slack's
// oauth.v2.access and the default browser.
var newSlackConnectDeps = func() slackConnectDeps {
	return slackConnectDeps{
		port:        slackconnect.Port,
		listen:      slackconnect.Listen,
		exchange:    slackconnect.DefaultExchanger(),
		openBrowser: auth.OpenBrowser,
		clock:       slackconnect.SystemClock{},
	}
}

// Failure reasons of the connect flow beyond slackconnect's outcomes (the
// `reason` of a `failed` event).
const (
	slackConnectReasonOtherUser    = "other_user"
	slackConnectReasonPolicy       = "policy"
	slackConnectReasonPurgeRunning = "purge_running"
)

var (
	// errSlackOtherUser is A18: a re-bind signed in as another Slack user
	// than the account's; the account's history belongs to its user.
	errSlackOtherUser = errors.New("signed in as someone else; nothing was changed")
	// errSlackTeamMismatch marks a sign-in into another team than the one
	// the connection (or the account's data) is for.
	errSlackTeamMismatch = errors.New("signed in to another Slack workspace")
)

// slackTeamMismatchError carries a team refusal's own text while matching
// errSlackTeamMismatch.
type slackTeamMismatchError struct{ msg string }

func (e *slackTeamMismatchError) Error() string { return e.msg }
func (e *slackTeamMismatchError) Unwrap() error { return errSlackTeamMismatch }

// slackConnectReason maps an account-write error to a `failed` reason.
func slackConnectReason(err error) string {
	switch {
	case errors.Is(err, policy.ErrNotAllowed):
		return slackConnectReasonPolicy
	case errors.Is(err, errLoginDuringPurge):
		return slackConnectReasonPurgeRunning
	case errors.Is(err, errSlackOtherUser):
		return slackConnectReasonOtherUser
	case errors.Is(err, errSlackTeamMismatch):
		return string(slackconnect.OutcomeTeamMismatch)
	default:
		return string(slackconnect.OutcomeOther)
	}
}

// writeConnectedAccount stores a connect flow's grant: the one write path
// of every PKCE connect (ask #1425, A6). The row is t.AccountID when set,
// else the team's live account, else a new one. On an existing row the
// home-team check and the same-user check (A18) run before any write. Under
// the account's token lock it saves the token file first (atomic: a failure
// leaves the old file and the old token keeps syncing), then the row's
// connection, app, refresh expiry and auth state; a crash between the two
// is repaired by the next token read, which takes the file's client and app
// id (the file is the truth). The old token is dropped, not revoked (A21).
// The account id, its data and its sync position are never touched, and
// nothing is soft-removed (SLACK-01). reboundFrom is the client id the row
// had when this connect moved it to another app, else "".
func writeConnectedAccount(ctx context.Context, cfg *config.Config, database *db.DB, t slackconnect.Target, g slackconnect.Grant) (accountID int64, reboundFrom string, err error) {
	if err := sourceRefusal("slack"); err != nil {
		return 0, "", err
	}
	if g.TeamID != t.TeamID {
		return 0, "", &slackTeamMismatchError{msg: fmt.Sprintf(
			"Slack signed you in to workspace %s, not %s; nothing was connected", g.TeamID, t.TeamID)}
	}
	id, isNew, err := slackConnectRow(database, t)
	if err != nil {
		return 0, "", err
	}
	if !isNew {
		if err := refuseLoginDuringPurge(database, "slack", id); err != nil {
			return 0, "", err
		}
	}
	reboundFrom, err = writeSlackGrant(ctx, cfg, database, id, isNew, t, g)
	if err != nil {
		if isNew {
			rollbackSlackAccount(database, id, os.Stderr)
		}
		return 0, "", err
	}
	afterSlackConnect(database, t.TeamID)
	return id, reboundFrom, nil
}

// slackConnectRow picks the account a connect writes: t.AccountID, else the
// live account whose home team is t's (refuseDuplicateSlackTeam keeps it
// single), else a new row (isNew).
func slackConnectRow(database *db.DB, t slackconnect.Target) (id int64, isNew bool, err error) {
	if t.AccountID != 0 {
		if _, err := database.GetSlackAccount(t.AccountID); err != nil {
			return 0, false, fmt.Errorf("account %d not found: %w", t.AccountID, err)
		}
		return t.AccountID, false, nil
	}
	accounts, err := database.ListSlackAccounts()
	if err != nil {
		return 0, false, err
	}
	for _, a := range accounts {
		if a.Status == "removed" {
			continue
		}
		home, err := database.SlackAccountHomeTeam(a)
		if err != nil {
			return 0, false, err
		}
		if home.ID == t.TeamID {
			return a.ID, false, nil
		}
	}
	id, err = database.CreateSlackAccount(db.SlackAccount{})
	if err != nil {
		return 0, false, fmt.Errorf("creating account: %w", err)
	}
	return id, true, nil
}

// writeSlackGrant checks the grant's identity against account id and, when
// it may be stored, writes the token file and then the row under the
// account's token lock.
func writeSlackGrant(ctx context.Context, cfg *config.Config, database *db.DB, id int64, isNew bool, t slackconnect.Target, g slackconnect.Grant) (string, error) {
	identity, err := resolveSlackIdentity(ctx, g.AccessToken)
	if err != nil {
		return "", fmt.Errorf("resolving slack identity: %w", err)
	}
	if identity.TeamID != t.TeamID {
		return "", &slackTeamMismatchError{msg: fmt.Sprintf(
			"the Slack token is for workspace %s, not %s; nothing was connected", identity.TeamID, t.TeamID)}
	}
	moved, err := checkSlackLoginTeam(database, id, identity, isNew)
	if err != nil {
		return "", err
	}
	acct, err := database.GetSlackAccount(id)
	if err != nil {
		return "", err
	}
	user := watchtowerslack.Namespace(id, identity.UserID)
	if !isNew && acct.CurrentUserID != "" && acct.CurrentUserID != user {
		return "", errSlackOtherUser
	}
	if moved {
		if err := rewindMovedSlackAccountOrWarn(database, id, os.Stderr); err != nil {
			return "", err
		}
	}

	store := watchtowerslack.NewTokenStore(cfg.WorkspaceDir(), id)
	unlock, err := store.Lock(ctx)
	if err != nil {
		return "", err
	}
	defer unlock()
	reboundFrom := ""
	if !isNew {
		reboundFrom = acct.ClientID
		if old, _ := store.Load(); reboundFrom == "" && old != nil {
			reboundFrom = old.ClientID
		}
		if reboundFrom == g.ClientID {
			reboundFrom = ""
		}
	}
	tok := slackGrantToken(g, identity, time.Now())
	if err := store.Save(tok); err != nil {
		return "", fmt.Errorf("saving token: %w", err)
	}
	if err := writeSlackGrantRow(database, id, identity, user, tok); err != nil {
		if isNew {
			// The token was saved for a row that is rolled back.
			if delErr := store.Delete(); delErr != nil {
				err = errors.Join(err, fmt.Errorf("removing the token of rolled-back slack account %d: %w", id, delErr))
			}
		}
		return "", err
	}
	return reboundFrom, nil
}

// slackGrantToken is the token file a grant writes. A refresh token's expiry
// is set only when Slack sends its lifetime.
func slackGrantToken(g slackconnect.Grant, identity slackIdentity, now time.Time) *watchtowerslack.Token {
	tok := &watchtowerslack.Token{
		AccessToken:  g.AccessToken,
		TeamID:       identity.TeamID,
		TeamName:     identity.TeamName,
		UserID:       identity.UserID,
		Scope:        g.Scope,
		RefreshToken: g.RefreshToken,
		ClientID:     g.ClientID,
		AppID:        g.AppID,
	}
	if g.ExpiresIn > 0 {
		tok.ExpiresAt = now.Add(time.Duration(g.ExpiresIn) * time.Second).UTC()
	}
	if g.RefreshToken != "" && g.RefreshExpiresIn > 0 {
		tok.RefreshExpiresAt = now.Add(time.Duration(g.RefreshExpiresIn) * time.Second).UTC()
	}
	return tok
}

// writeSlackGrantRow is the row half of a connect, after the token file:
// the connection, the app (an unknown App ID keeps the row's for the same
// client), the refresh expiry and auth state ok.
func writeSlackGrantRow(database *db.DB, id int64, identity slackIdentity, user string, tok *watchtowerslack.Token) error {
	if err := database.UpdateSlackAccountConnection(id, identity.TeamID, identity.TeamName, identity.TeamDomain, user); err != nil {
		return fmt.Errorf("recording connection: %w", err)
	}
	if tok.AppID != "" {
		if err := database.SetSlackAccountApp(id, tok.ClientID, tok.AppID); err != nil {
			return err
		}
	} else if err := recordSlackClientID(database, id, tok.ClientID); err != nil {
		return err
	}
	if err := database.SetSlackRefreshExpiry(id, tok.RefreshExpiresAt); err != nil {
		return err
	}
	return database.SetSlackAccountAuthState(id, "ok", "")
}

// afterSlackConnect clears the team's setup approval request (the install
// happened) and runs the client id backfill (A17); both best-effort.
func afterSlackConnect(database *db.DB, team string) {
	if _, err := database.GetSlackAppSetup(team); err == nil {
		if err := database.SetSlackAppSetupInstallRequested(team, time.Time{}); err != nil {
			fmt.Fprintf(os.Stderr, "warning: %v\n", err)
		}
	} else if !errors.Is(err, sql.ErrNoRows) {
		fmt.Fprintf(os.Stderr, "warning: %v\n", err)
	}
	if _, err := slackmode.BackfillClientIDs(database); err != nil {
		fmt.Fprintf(os.Stderr, "warning: %v\n", err)
	}
}

// slackConnectOptions are the one-shot connect's flags.
type slackConnectOptions struct {
	noOpen, appReturn, asJSON bool
}

func runSlackConnect(cmd *cobra.Command, _ []string) error {
	t, err := slackConnectTargetFromFlags(cmd)
	if err != nil {
		return err
	}
	cfg, database, err := openSlackCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	if t.AccountID != 0 {
		if _, err := database.GetSlackAccount(t.AccountID); err != nil {
			return fmt.Errorf("account %d not found: %w", t.AccountID, err)
		}
		if err := refuseLoginDuringPurge(database, "slack", t.AccountID); err != nil {
			return err
		}
	}
	var opts slackConnectOptions
	opts.noOpen, _ = cmd.Flags().GetBool("no-open")
	opts.appReturn, _ = cmd.Flags().GetBool("app-return")
	opts.asJSON, _ = cmd.Flags().GetBool("json")
	return runSlackConnectOnce(cmd, cfg, database, t, opts)
}

// slackConnectTargetFromFlags reads --team/--client or --code and --account.
func slackConnectTargetFromFlags(cmd *cobra.Command) (slackconnect.Target, error) {
	team, _ := cmd.Flags().GetString("team")
	client, _ := cmd.Flags().GetString("client")
	code, _ := cmd.Flags().GetString("code")
	account, _ := cmd.Flags().GetInt64("account")
	var input string
	switch {
	case code != "" && (team != "" || client != ""):
		return slackconnect.Target{}, usageError("use either --code or --team with --client")
	case code != "":
		input = code
	case team != "" && client != "":
		input = team + ":" + client
	default:
		return slackconnect.Target{}, usageError("connect needs --team and --client, or --code")
	}
	t, err := slackconnect.ParseConnectInput(input)
	if err != nil {
		return slackconnect.Target{}, usageError("%v", err)
	}
	t.AccountID = account
	return t, nil
}

// runSlackConnectOnce is the one-shot connect: it binds the listener, opens
// the sign-in (no confirm: the owner ran the command), waits for Slack's
// redirect with no deadline (Ctrl-C ends it), writes the account and prints
// the result.
func runSlackConnectOnce(cmd *cobra.Command, cfg *config.Config, database *db.DB, t slackconnect.Target, opts slackConnectOptions) error {
	ctx := cmd.Context()
	if ctx == nil {
		ctx = context.Background()
	}
	out, errOut := cmd.OutOrStdout(), cmd.ErrOrStderr()
	deps := newSlackConnectDeps()
	ln, err := deps.listen(deps.port)
	if errors.Is(err, slackconnect.ErrPortBusy) {
		return &exitCodeError{code: slackConnectPortBusyExitCode, err: fmt.Errorf(
			"port %d is busy (is Watchtower open? connect from Connections → Slack)", slackconnect.Port)}
	}
	if err != nil {
		return fmt.Errorf("binding the Slack connect listener: %w", err)
	}
	reg := slackconnect.NewRegistry(deps.clock, deps.exchange)
	events := make(chan slackconnect.Event)
	stop := make(chan struct{})
	shutdown := serveSlackConnectListener(ln, reg, events, stop)
	defer shutdown(true)

	id, err := reg.Begin(t, false)
	if err != nil {
		return err
	}
	authorizeURL, err := reg.BrowserURL(id)
	if err != nil {
		return err
	}
	if opts.noOpen {
		fmt.Fprintf(errOut, "Open this URL to connect Slack:\n%s\n", authorizeURL)
	} else {
		fmt.Fprintln(errOut, "Opening Slack in your browser…")
		deps.openBrowser(authorizeURL)
	}
	accountID, res, rebound, err := waitSlackConnectOnce(ctx, cfg, database, reg, id, events)
	oauthpage.ReturnAfterLogin(opts.appReturn, err, errOut)
	if opts.asJSON {
		if encErr := writeSlackConnectResultJSON(out, accountID, res, rebound, err); encErr != nil {
			return encErr
		}
	}
	if err != nil {
		return err
	}
	if !opts.asJSON {
		name := res.Grant.TeamName
		if name == "" {
			name = res.Grant.TeamID
		}
		fmt.Fprintf(out, "Connected Slack workspace %q (team: %s) as account %d\n", name, res.Grant.TeamID, accountID)
		if rebound != "" {
			fmt.Fprintf(out, "The account moved from Slack app %s; its history stays.\n", rebound)
		}
	}
	return nil
}

// waitSlackConnectOnce waits for flow id's callback and writes its grant.
func waitSlackConnectOnce(ctx context.Context, cfg *config.Config, database *db.DB, reg *slackconnect.Registry,
	id slackconnect.FlowID, events <-chan slackconnect.Event) (int64, slackconnect.Result, string, error) {
	for {
		select {
		case <-ctx.Done():
			reg.Cancel(id)
			return 0, slackconnect.Result{Flow: id, Outcome: slackconnect.OutcomeCancelled}, "", ctx.Err()
		case ev := <-events:
			if ev.Kind != slackconnect.EventCallback || ev.Flow != id {
				continue // a link opened meanwhile: the one flow is busy
			}
			res := ev.Result
			if res.Outcome != slackconnect.OutcomeConnected {
				return 0, res, "", &slackConnectFailure{reason: string(res.Outcome), msg: res.Message}
			}
			accountID, rebound, err := writeConnectedAccount(ctx, cfg, database, ev.Target, res.Grant)
			ev.Reply <- err
			if err != nil {
				return 0, res, "", err
			}
			return accountID, res, rebound, nil
		}
	}
}

// slackConnectFailure is a flow that ended without a grant.
type slackConnectFailure struct{ reason, msg string }

func (e *slackConnectFailure) Error() string { return e.msg }

// writeSlackConnectResultJSON prints the one-shot result as serve's
// connected or failed event.
func writeSlackConnectResultJSON(out io.Writer, accountID int64, res slackconnect.Result, rebound string, err error) error {
	if err == nil {
		return writeSlackConnectEvent(out, slackConnectedEvent{
			Event: "connected", Flow: string(res.Flow), AccountID: accountID,
			TeamID: res.Grant.TeamID, TeamName: res.Grant.TeamName, ReboundFrom: rebound,
		})
	}
	reason := slackConnectReason(err)
	var f *slackConnectFailure
	if errors.As(err, &f) {
		reason = f.reason
	}
	return writeSlackConnectEvent(out, slackFailedEvent{Event: "failed", Flow: string(res.Flow), Reason: reason, Message: err.Error()})
}

// slackConnectDrain bounds how long the one-shot connect's shutdown lets
// an answered callback finish its page.
const slackConnectDrain = 2 * time.Second

// serveSlackConnectListener serves the connect listener on ln until the
// returned shutdown runs. A graceful shutdown first lets requests in flight
// finish (the callback page the owner just answered), bounded by
// slackConnectDrain; then stop is closed so no handler stays blocked on
// events, and the server is closed and waited for.
func serveSlackConnectListener(ln net.Listener, reg *slackconnect.Registry, events chan<- slackconnect.Event, stop chan struct{}) (shutdown func(graceful bool)) {
	srv := &http.Server{
		Handler:           slackconnect.Handler(reg, events, ln.Addr().String(), stop),
		ReadHeaderTimeout: 10 * time.Second,
	}
	served := make(chan struct{})
	go func() {
		defer close(served)
		_ = srv.Serve(ln)
	}()
	return func(graceful bool) {
		if graceful {
			ctx, cancel := context.WithTimeout(context.Background(), slackConnectDrain)
			_ = srv.Shutdown(ctx)
			cancel()
		}
		close(stop)
		_ = srv.Close()
		<-served
	}
}

// slackLoginConnect is `slack login --account N` for an account that signs
// in again through the connect flow (relogin "connect"): the one-shot PKCE
// flow on the account's own client id.
func slackLoginConnect(cmd *cobra.Command, cfg *config.Config, database *db.DB, acct db.SlackAccount) error {
	if acct.ClientID == "" {
		return fmt.Errorf("slack account %d has no Slack app on record; connect it with the link or code from "+
			"your company's Watchtower app (`watchtower slack connect --code ...`)", acct.ID)
	}
	t, err := slackconnect.ParseConnectInput(acct.TeamID + ":" + acct.ClientID)
	if err != nil {
		return fmt.Errorf("slack account %d: its team or client id is not usable for a connect: %w", acct.ID, err)
	}
	t.AccountID = acct.ID
	if err := refuseLoginDuringPurge(database, "slack", acct.ID); err != nil {
		return err
	}
	var opts slackConnectOptions
	opts.noOpen, _ = cmd.Flags().GetBool("no-open")
	opts.appReturn, _ = cmd.Flags().GetBool("app-return")
	return runSlackConnectOnce(cmd, cfg, database, t, opts)
}

// slackBuiltinClientID is the client id of the build's own Slack app, "" when
// it has none (auth.BuiltinApp).
func slackBuiltinClientID() string {
	if builtin, ok := auth.BuiltinApp(); ok {
		return builtin.ClientID
	}
	return ""
}
