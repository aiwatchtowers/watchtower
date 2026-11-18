package cmd

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
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
// else the team's live account, else a new one, created only after the
// grant passed every check. On an existing row the home-team check and the
// same-user check (A18) run before any write, and an explicit target is
// refused while another live account holds the team. Under the account's
// token lock the purge is checked once more (a purge that started meanwhile
// wins, PURGE-02), then the token file is saved first (atomic: a failure
// leaves the old file and the old token keeps syncing), then the row's
// connection, app, refresh expiry and auth state; a crash between the two
// is repaired by the next token read, which takes the file's client and app
// id (the file is the truth). The old token is dropped, not revoked (A21).
// The account id, its data and its sync position are never touched, and
// nothing is soft-removed (SLACK-01). reboundFrom is the client id the row
// had when this connect moved it to another app, else "". Warnings go to
// warn.
func writeConnectedAccount(ctx context.Context, cfg *config.Config, database *db.DB, t slackconnect.Target, g slackconnect.Grant, warn io.Writer) (accountID int64, reboundFrom string, err error) {
	if err := sourceRefusal("slack"); err != nil {
		return 0, "", err
	}
	if g.TeamID != t.TeamID {
		return 0, "", &slackTeamMismatchError{msg: fmt.Sprintf(
			"Slack signed you in to workspace %s, not %s; nothing was connected", g.TeamID, t.TeamID)}
	}
	id, err := slackConnectRow(database, t)
	if err != nil {
		return 0, "", err
	}
	if id != 0 {
		// Early, before the network; checked again under the lock.
		if err := refuseLoginDuringPurge(database, "slack", id); err != nil {
			return 0, "", err
		}
	}
	identity, err := resolveSlackIdentity(ctx, g.AccessToken)
	if err != nil {
		return 0, "", fmt.Errorf("resolving slack identity: %w", err)
	}
	if identity.TeamID != t.TeamID {
		return 0, "", &slackTeamMismatchError{msg: fmt.Sprintf(
			"the Slack token is for workspace %s, not %s; nothing was connected", identity.TeamID, t.TeamID)}
	}
	if id == 0 {
		return writeNewSlackAccount(ctx, cfg, database, identity, g, warn)
	}
	reboundFrom, err = writeSlackGrant(ctx, cfg, database, id, identity, g, warn)
	if err != nil {
		return 0, "", err
	}
	afterSlackConnect(database, t.TeamID, warn)
	return id, reboundFrom, nil
}

// errSlackTeamHasLiveRow refuses an explicit target while another live
// account already holds the team: the connect would leave two live rows.
var errSlackTeamHasLiveRow = errors.New("another Slack account is already connected to this workspace")

// slackConnectRow picks the account a connect writes: t.AccountID (refused
// while another live account holds t's team), else the live account whose
// home team is t's (refuseDuplicateSlackTeam keeps it single), else 0: a
// new row, created by writeNewSlackAccount once the grant is checked.
func slackConnectRow(database *db.DB, t slackconnect.Target) (int64, error) {
	if t.AccountID != 0 {
		if _, err := database.GetSlackAccount(t.AccountID); err != nil {
			return 0, fmt.Errorf("account %d not found: %w", t.AccountID, err)
		}
	}
	live, err := liveSlackAccountForTeam(database, t.TeamID, t.AccountID)
	if err != nil {
		return 0, err
	}
	switch {
	case t.AccountID != 0 && live != 0:
		return 0, fmt.Errorf("account %d is on this workspace already; use Reconnect on it: %w", live, errSlackTeamHasLiveRow)
	case t.AccountID != 0:
		return t.AccountID, nil
	default:
		return live, nil
	}
}

// liveSlackAccountForTeam returns the live (not removed) account other than
// except whose home team is team, or 0.
func liveSlackAccountForTeam(database *db.DB, team string, except int64) (int64, error) {
	accounts, err := database.ListSlackAccounts()
	if err != nil {
		return 0, err
	}
	for _, a := range accounts {
		if a.ID == except || a.Status == "removed" {
			continue
		}
		home, err := database.SlackAccountHomeTeam(a)
		if err != nil {
			return 0, err
		}
		if home.ID == team {
			return a.ID, nil
		}
	}
	return 0, nil
}

// writeNewSlackAccount creates the row for a checked grant and writes it; a
// failure rolls the row back (and drops its token).
func writeNewSlackAccount(ctx context.Context, cfg *config.Config, database *db.DB, identity slackIdentity, g slackconnect.Grant, warn io.Writer) (int64, string, error) {
	if err := refuseDuplicateSlackTeam(database, 0, identity); err != nil {
		return 0, "", err
	}
	id, err := database.CreateSlackAccount(db.SlackAccount{})
	if err != nil {
		return 0, "", fmt.Errorf("creating account: %w", err)
	}
	store := watchtowerslack.NewTokenStore(cfg.WorkspaceDir(), id)
	err = withSlackTokenLock(ctx, store, func() error {
		tok := slackGrantToken(g, identity, time.Now())
		if err := store.Save(tok); err != nil {
			return fmt.Errorf("saving token: %w", err)
		}
		if err := writeSlackGrantRow(database, id, identity, watchtowerslack.Namespace(id, identity.UserID), tok); err != nil {
			// The token was saved for this row only: a rolled-back row keeps no token.
			if delErr := store.Delete(); delErr != nil {
				err = errors.Join(err, fmt.Errorf("removing the token of rolled-back slack account %d: %w", id, delErr))
			}
			return err
		}
		return nil
	})
	if err != nil {
		rollbackSlackAccount(database, id, warn)
		return 0, "", err
	}
	afterSlackConnect(database, identity.TeamID, warn)
	return id, "", nil
}

// writeSlackGrant checks the grant's identity against existing account id
// and, when it may be stored, writes the token file and then the row under
// the account's token lock.
func writeSlackGrant(ctx context.Context, cfg *config.Config, database *db.DB, id int64, identity slackIdentity, g slackconnect.Grant, warn io.Writer) (string, error) {
	moved, err := checkSlackLoginTeam(database, id, identity, false)
	if err != nil {
		return "", err
	}
	acct, err := database.GetSlackAccount(id)
	if err != nil {
		return "", err
	}
	user := watchtowerslack.Namespace(id, identity.UserID)
	if acct.CurrentUserID != "" && acct.CurrentUserID != user {
		return "", errSlackOtherUser
	}

	store := watchtowerslack.NewTokenStore(cfg.WorkspaceDir(), id)
	var reboundFrom string
	err = withSlackTokenLock(ctx, store, func() error {
		// Right before the first write: a purge that started while the grant
		// was checked would delete what this writes (PURGE-02).
		if err := refuseLoginDuringPurge(database, "slack", id); err != nil {
			return err
		}
		if moved {
			covered, err := rewindMovedSlackAccount(database, id)
			if err != nil {
				return fmt.Errorf("rewinding the search of slack account %d: %w", id, err)
			}
			if !covered {
				fmt.Fprintf(warn, "warning: slack account %d is back on its workspace, but the next sync may not fetch the days it missed\n", id)
			}
		}
		reboundFrom = acct.ClientID
		if old, _ := store.Load(); reboundFrom == "" && old != nil {
			reboundFrom = old.ClientID
		}
		if reboundFrom == g.ClientID {
			reboundFrom = ""
		}
		tok := slackGrantToken(g, identity, time.Now())
		if err := store.Save(tok); err != nil {
			return fmt.Errorf("saving token: %w", err)
		}
		return writeSlackGrantRow(database, id, identity, user, tok)
	})
	if err != nil {
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
// happened) and runs the client id backfill (A17); both best-effort, their
// failures go to warn.
func afterSlackConnect(database *db.DB, team string, warn io.Writer) {
	if _, err := database.GetSlackAppSetup(team); err == nil {
		if err := database.SetSlackAppSetupInstallRequested(team, time.Time{}); err != nil {
			fmt.Fprintf(warn, "warning: %v\n", err)
		}
	} else if !errors.Is(err, sql.ErrNoRows) {
		fmt.Fprintf(warn, "warning: %v\n", err)
	}
	if _, err := slackmode.BackfillClientIDs(database); err != nil {
		fmt.Fprintf(warn, "warning: %v\n", err)
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
	// The flow takes the registry's one slot before the listener answers a
	// request, so a link opened right after the bind cannot take it first.
	id, err := reg.Begin(t, false)
	if err != nil {
		_ = ln.Close()
		return err
	}
	authorizeURL, err := reg.BrowserURL(id)
	if err != nil {
		_ = ln.Close()
		return err
	}
	events := make(chan slackconnect.Event)
	shutdown := serveSlackConnectListener(ln, reg, events, make(chan struct{}), nil)
	defer shutdown(false)
	if opts.noOpen {
		fmt.Fprintf(errOut, "Open this URL to connect Slack:\n%s\n", authorizeURL)
	} else {
		fmt.Fprintln(errOut, "Opening Slack in your browser…")
		deps.openBrowser(authorizeURL)
	}
	accountID, res, rebound, err := waitSlackConnectOnce(ctx, cfg, database, reg, id, events, errOut)
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
	id slackconnect.FlowID, events <-chan slackconnect.Event, warn io.Writer) (int64, slackconnect.Result, string, error) {
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
			accountID, rebound, err := writeConnectedAccount(ctx, cfg, database, ev.Target, res.Grant, warn)
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

// slackConnectDrain bounds how long a shutdown waits for the listener's
// requests in flight to write their pages.
const slackConnectDrain = 2 * time.Second

// serveSlackConnectListener serves the connect listener on ln until the
// returned shutdown runs; it waits at most slackConnectDrain for requests in
// flight to finish their pages, then closes the server and waits for it.
// stopFirst (serve at stdin EOF: nobody reads events any more) closes stop
// before the drain, so a handler blocked handing an event over gives up and
// answers its page. Without it (the one-shot connect, whose owner already
// answered its callback) the drain runs first, so the answered callback
// writes its result page rather than "check the app"; stop is closed after.
// company, when set (serve), takes the company link's paths.
func serveSlackConnectListener(ln net.Listener, reg *slackconnect.Registry, events chan<- slackconnect.Event,
	stop chan struct{}, company http.Handler) (shutdown func(stopFirst bool)) {
	handler := slackconnect.Handler(reg, events, ln.Addr().String(), stop)
	if company != nil {
		handler = withCompanyPaths(handler, company)
	}
	srv := &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
	}
	served := make(chan struct{})
	go func() {
		defer close(served)
		_ = srv.Serve(ln)
	}()
	return func(stopFirst bool) {
		if stopFirst {
			close(stop)
		}
		ctx, cancel := context.WithTimeout(context.Background(), slackConnectDrain)
		_ = srv.Shutdown(ctx)
		cancel()
		if !stopFirst {
			close(stop)
		}
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
