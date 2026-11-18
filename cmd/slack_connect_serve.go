package cmd

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/slackconnect"
)

// The `slack connect serve` wire contract (the Desktop's SlackConnectListener
// decodes it; internal/slackconnect/testdata/serve_events.jsonl is its
// golden, written by TestSlackConnectServe_WireGolden). Stdout carries one
// event object per line, stdin one command object per line.

// slackPortEvent is listening and port_busy.
type slackPortEvent struct {
	Event string `json:"event"`
	Port  int    `json:"port"`
}

// slackLinkEvent: a link started a flow that waits for confirm.
type slackLinkEvent struct {
	Event    string `json:"event"`
	Flow     string `json:"flow"`
	TeamID   string `json:"team_id"`
	ClientID string `json:"client_id"`
}

// slackFlowEvent is browser (the authorize URL was opened), busy (a start
// was refused: another flow runs; flow is the running one) and link_busy (a
// link that arrived while a flow runs was refused; flow is the running one).
// The two refusals are distinct events so the Desktop never reads a link's
// refusal as the answer to its own start (review m5).
type slackFlowEvent struct {
	Event string `json:"event"`
	Flow  string `json:"flow"`
}

type slackConnectedEvent struct {
	Event     string `json:"event"`
	Flow      string `json:"flow"`
	AccountID int64  `json:"account_id"`
	TeamID    string `json:"team_id"`
	TeamName  string `json:"team_name"`
	// ReboundFrom is the client id the account was re-bound from, "" when
	// the account is new or stays on its app.
	ReboundFrom string `json:"rebound_from"`
}

// slackFailedEvent: a flow ended without a stored account. Reason is one of
// team_mismatch, other_user, denied, cancelled, exchange, policy,
// purge_running, other. Flow is "" for a start refused before a flow began
// (policy, purge running, an unknown account, bad ids): such a failed
// answers the most recent start command.
type slackFailedEvent struct {
	Event   string `json:"event"`
	Flow    string `json:"flow"`
	Reason  string `json:"reason"`
	Message string `json:"message"`
}

// slackConnectCommand is one stdin line: start (team_id, client_id and an
// optional account_id; skips the confirm), confirm (flow) or cancel (flow).
type slackConnectCommand struct {
	Cmd       string `json:"cmd"`
	TeamID    string `json:"team_id"`
	ClientID  string `json:"client_id"`
	AccountID int64  `json:"account_id"`
	Flow      string `json:"flow"`
}

func writeSlackConnectEvent(out io.Writer, ev any) error {
	if err := json.NewEncoder(out).Encode(ev); err != nil {
		return fmt.Errorf("writing a connect event: %w", err)
	}
	return nil
}

func runSlackConnectServe(cmd *cobra.Command, _ []string) error {
	cfg, database, err := openSlackCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	ctx := cmd.Context()
	if ctx == nil {
		ctx = context.Background()
	}
	return serveSlackConnect(ctx, cfg, database, cmd.InOrStdin(), cmd.OutOrStdout(), cmd.ErrOrStderr(), newSlackConnectDeps())
}

// slackConnectServer is serve's state; only its loop writes to out.
type slackConnectServer struct {
	ctx      context.Context
	cfg      *config.Config
	database *db.DB
	out      io.Writer
	logger   *log.Logger
	deps     slackConnectDeps
	reg      *slackconnect.Registry
}

// serveSlackConnect is `slack connect serve`: it binds the listener (busy:
// port_busy, exit 3), reports listening, then turns the listener's events
// and stdin's commands into events on out until stdin closes (exit 0, the
// listener closed) or ctx ends. The policy is asked per flow — at a link,
// a start and a confirm — and again by the account write, so a source the
// organization forbids gets failed/policy and never a browser.
func serveSlackConnect(ctx context.Context, cfg *config.Config, database *db.DB, in io.Reader, out, logOut io.Writer, deps slackConnectDeps) error {
	ln, err := deps.listen(deps.port)
	if errors.Is(err, slackconnect.ErrPortBusy) {
		if werr := writeSlackConnectEvent(out, slackPortEvent{Event: "port_busy", Port: deps.port}); werr != nil {
			return werr
		}
		return &exitCodeError{code: slackConnectServePortBusyExitCode, err: errQuietExit}
	}
	if err != nil {
		return fmt.Errorf("binding the Slack connect listener: %w", err)
	}
	s := &slackConnectServer{
		ctx: ctx, cfg: cfg, database: database, out: out, deps: deps,
		logger: log.New(logOut, "[slack connect] ", log.LstdFlags),
		reg:    slackconnect.NewRegistry(deps.clock, deps.exchange),
	}
	events := make(chan slackconnect.Event)
	shutdown := serveSlackConnectListener(ln, s.reg, events, make(chan struct{}))
	// The app is gone (stdin EOF): nobody answers a page any more.
	defer shutdown(true)
	if err := s.emit(slackPortEvent{Event: "listening", Port: ln.Addr().(*net.TCPAddr).Port}); err != nil {
		return err
	}

	done := make(chan struct{})
	defer close(done)
	cmds := readSlackConnectCommands(in, s.logger, done)
	for {
		var err error
		select {
		case <-ctx.Done():
			return nil
		case c, ok := <-cmds:
			if !ok {
				return nil // stdin EOF: the app is gone
			}
			err = s.handleCommand(c)
		case ev := <-events:
			err = s.handleEvent(ev)
		}
		if err != nil {
			return err
		}
	}
}

// readSlackConnectCommands decodes stdin's lines until EOF, then closes the
// returned channel. A line that is not a command is logged and skipped.
func readSlackConnectCommands(in io.Reader, logger *log.Logger, done <-chan struct{}) <-chan slackConnectCommand {
	cmds := make(chan slackConnectCommand)
	go func() {
		defer close(cmds)
		sc := bufio.NewScanner(in)
		for sc.Scan() {
			var c slackConnectCommand
			if err := json.Unmarshal(sc.Bytes(), &c); err != nil {
				logger.Printf("skipping a command that is not JSON: %v", err)
				continue
			}
			select {
			case cmds <- c:
			case <-done:
				return
			}
		}
		if err := sc.Err(); err != nil {
			logger.Printf("reading commands: %v", err)
		}
	}()
	return cmds
}

func (s *slackConnectServer) emit(ev any) error { return writeSlackConnectEvent(s.out, ev) }

func (s *slackConnectServer) failed(flow slackconnect.FlowID, reason, msg string) error {
	return s.emit(slackFailedEvent{Event: "failed", Flow: string(flow), Reason: reason, Message: msg})
}

func (s *slackConnectServer) handleCommand(c slackConnectCommand) error {
	switch c.Cmd {
	case "start":
		return s.start(c)
	case "confirm":
		return s.confirm(slackconnect.FlowID(c.Flow))
	case "cancel":
		if s.reg.Cancel(slackconnect.FlowID(c.Flow)) {
			return s.failed(slackconnect.FlowID(c.Flow), string(slackconnect.OutcomeCancelled),
				"This connection was cancelled in Watchtower.")
		}
		return nil // no such live flow: its own end was already reported
	default:
		s.logger.Printf("skipping unknown command %q", c.Cmd)
		return nil
	}
}

// start begins a flow that skips the confirm (paste, MDM, Reconnect, the
// setup's admin connect) and opens its sign-in.
func (s *slackConnectServer) start(c slackConnectCommand) error {
	t, err := slackconnect.ParseConnectInput(c.TeamID + ":" + c.ClientID)
	if err != nil {
		return s.failed("", string(slackconnect.OutcomeOther), "This is not a Watchtower Slack link or code.")
	}
	t.AccountID = c.AccountID
	if err := s.refusal(t); err != nil {
		return s.failed("", slackConnectReason(err), err.Error())
	}
	id, err := s.reg.Begin(t, false)
	if errors.Is(err, slackconnect.ErrFlowRunning) {
		return s.emit(slackFlowEvent{Event: "busy", Flow: string(id)})
	}
	if err != nil {
		return s.failed("", string(slackconnect.OutcomeOther), "Watchtower could not start the connection.")
	}
	authorizeURL, err := s.reg.BrowserURL(id)
	if err != nil {
		s.reg.Cancel(id)
		return s.failed(id, string(slackconnect.OutcomeOther), "Watchtower could not start the connection.")
	}
	return s.openBrowser(id, authorizeURL)
}

// confirm is the owner's Connect on a link flow.
func (s *slackConnectServer) confirm(id slackconnect.FlowID) error {
	if err := s.refusal(slackconnect.Target{}); err != nil {
		s.reg.Cancel(id)
		return s.failed(id, slackConnectReason(err), err.Error())
	}
	authorizeURL, err := s.reg.Confirm(id)
	if err != nil {
		return s.failed(id, string(slackconnect.OutcomeOther), "This connection is no longer waiting; open the link again.")
	}
	return s.openBrowser(id, authorizeURL)
}

func (s *slackConnectServer) openBrowser(id slackconnect.FlowID, authorizeURL string) error {
	s.deps.openBrowser(authorizeURL)
	return s.emit(slackFlowEvent{Event: "browser", Flow: string(id)})
}

// refusal is why a flow may not go to Slack now: the policy forbids the
// slack source, or, for a start on an account, the account does not exist,
// another live account holds its team, or its purge is running.
func (s *slackConnectServer) refusal(t slackconnect.Target) error {
	if err := sourceRefusal("slack"); err != nil {
		return err
	}
	if t.AccountID == 0 {
		return nil
	}
	if _, err := slackConnectRow(s.database, t); err != nil {
		return err
	}
	return refuseLoginDuringPurge(s.database, "slack", t.AccountID)
}

func (s *slackConnectServer) handleEvent(ev slackconnect.Event) error {
	switch ev.Kind {
	case slackconnect.EventLink:
		if err := sourceRefusal("slack"); err != nil {
			s.reg.Cancel(ev.Flow)
			return s.failed(ev.Flow, slackConnectReasonPolicy, err.Error())
		}
		return s.emit(slackLinkEvent{Event: "link", Flow: string(ev.Flow), TeamID: ev.Target.TeamID, ClientID: ev.Target.ClientID})
	case slackconnect.EventBusy:
		return s.emit(slackFlowEvent{Event: "link_busy", Flow: string(ev.Flow)})
	case slackconnect.EventCallback:
		return s.callback(ev)
	}
	return nil
}

// callback reports a flow's end. A connected grant is written first and the
// listener's page gets the write's answer. A cancelled outcome was reported
// by the cancel command already; the grant Slack may have issued during the
// cancelled exchange was dropped by the registry and is not revoked (it was
// never stored; the same reasoning as A21).
func (s *slackConnectServer) callback(ev slackconnect.Event) error {
	res := ev.Result
	switch res.Outcome {
	case slackconnect.OutcomeCancelled:
		return nil
	case slackconnect.OutcomeConnected:
	default:
		return s.failed(ev.Flow, string(res.Outcome), res.Message)
	}
	accountID, rebound, err := writeConnectedAccount(s.ctx, s.cfg, s.database, ev.Target, res.Grant, s.logger.Writer())
	ev.Reply <- err
	if err != nil {
		s.logger.Printf("storing the Slack connection of flow %s: %v", ev.Flow, err)
		return s.failed(ev.Flow, slackConnectReason(err), err.Error())
	}
	return s.emit(slackConnectedEvent{
		Event: "connected", Flow: string(ev.Flow), AccountID: accountID,
		TeamID: res.Grant.TeamID, TeamName: res.Grant.TeamName, ReboundFrom: rebound,
	})
}
