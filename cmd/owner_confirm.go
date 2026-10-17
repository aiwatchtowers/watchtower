package cmd

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"errors"
	"fmt"
	"io"
	"math/big"
	"os"
	"strings"

	"golang.org/x/term"

	"watchtower/internal/automations"
	"watchtower/internal/config"
	"watchtower/internal/ownerconfirm"
	"watchtower/internal/tools"
)

// agentEnvMarkers are the variables an AI coding agent's shell carries:
// Claude Code sets CLAUDECODE=1; Codex sets CODEX_THREAD_ID on every command
// it runs and CODEX_SANDBOX when it runs one sandboxed; a Watchtower
// workbench terminal hands its agent tools.TerminalSessionEnv (a plain shell
// terminal does not get it); a child an automation run starts carries
// automations.RunEnvMarker.
var agentEnvMarkers = []string{"CLAUDECODE", "CODEX_THREAD_ID", "CODEX_SANDBOX", tools.TerminalSessionEnv,
	automations.RunEnvMarker}

// agentMarker is the first AGENT-07 marker set in this process's
// environment, "" when none is. Any non-empty value counts.
func agentMarker() string {
	for _, name := range agentEnvMarkers {
		if os.Getenv(name) != "" {
			return name
		}
	}
	return ""
}

// The owner gate's seams, replaced by tests: the Desktop round trip, the
// terminal the fallback code is typed on, and the code itself.
var (
	askOwnerDesktop = ownerconfirm.Ask
	ownerTerminal   = func() (io.Reader, io.Writer, bool) {
		ok := term.IsTerminal(int(os.Stdin.Fd())) && term.IsTerminal(int(os.Stderr.Fd()))
		return os.Stdin, os.Stderr, ok
	}
	ownerConfirmCode = randomConfirmCode
)

// requireOwnerConfirmation keeps the owner's decision the owner's (AGENT-07,
// board #568, ask #306): an agent that can run `watchtower` could otherwise
// approve or apply its own proposal (a prompt-injected send_slack_message,
// then `actions approve` on the id its receipt names), and since an
// environment marker can be unset (`env -u CLAUDECODE …`), the markers alone
// do not decide. Every owner-only gesture asks the owner:
//
//  1. The running Watchtower Desktop of this workspace (ownerconfirm): it
//     shows a confirmation window and answers with the owner's click. A
//     command the Desktop started itself (a button the owner pressed) is
//     answered at once, without a window.
//  2. With no Desktop running: under an agent marker, refused; otherwise only
//     on an interactive terminal (stdin and stderr), where the owner types
//     back a one-time code. Without a terminal, refused.
//
// The gestures: `actions approve`/`apply` and an execute trust grant;
// `automations confirm`, `save --confirm-hash`, `dry-run` of a recipe not
// confirmed yet, `enable`, `delete`, `auto … on`, `session-launched`,
// `session-ended`; `workbench methodology` check writes; review lessons and
// `review revert-hunk`. Reject and the read verbs stay open. detail, when not
// empty, is one line about the object shown with the request.
func requireOwnerConfirmation(verb, detail string) error {
	marker := agentMarker()
	ctx, cancel := context.WithTimeout(context.Background(), ownerconfirm.Wait)
	defer cancel()
	rep, err := askOwnerDesktop(ctx, ownerConfirmSocket(), ownerconfirm.Request{
		Verb: verb, Detail: detail, Args: os.Args[1:], Agent: marker,
	})
	switch {
	case err == nil && rep.Decision == ownerconfirm.Confirmed:
		return nil
	case err == nil:
		why := "the owner did not confirm it"
		if rep.Reason != "" {
			why = rep.Reason
		}
		return fmt.Errorf("refusing to %s: %s in Watchtower Desktop", verb, why)
	case !errors.Is(err, ownerconfirm.ErrNoDesktop):
		return fmt.Errorf("refusing to %s: %w", verb, err)
	case marker != "":
		return fmt.Errorf("refusing to %s under an AI agent (%s is set): the owner confirms it in Watchtower "+
			"Desktop, which is not running", verb, marker)
	}
	return confirmOnTerminal(verb, detail)
}

// ownerConfirmSocket is the Desktop's socket for the workspace this command
// works on; "" (no Desktop) when the config cannot be read.
func ownerConfirmSocket() string {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return ""
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	if cfg.ValidateWorkspace() != nil {
		return ""
	}
	return ownerconfirm.SocketPath(cfg.DBPath())
}

// confirmOnTerminal is the fallback without a Desktop: the owner types back
// a one-time code on an interactive terminal.
func confirmOnTerminal(verb, detail string) error {
	in, out, ok := ownerTerminal()
	if !ok {
		return fmt.Errorf("refusing to %s without the owner's confirmation: open Watchtower Desktop and run this "+
			"again to confirm it there, or run it from a Terminal", verb)
	}
	code := ownerConfirmCode()
	if code == "" {
		return fmt.Errorf("refusing to %s: no confirmation code could be made", verb)
	}
	if detail != "" {
		fmt.Fprintf(out, "%s\n", detail)
	}
	fmt.Fprintf(out, "Watchtower Desktop is not running. To %s, type %s and press Return: ", verb, code)
	line, err := bufio.NewReader(in).ReadString('\n')
	if err != nil && line == "" {
		return fmt.Errorf("refusing to %s: no confirmation code was typed", verb)
	}
	if subtle.ConstantTimeCompare([]byte(strings.TrimSpace(line)), []byte(code)) != 1 {
		return fmt.Errorf("refusing to %s: the confirmation code did not match", verb)
	}
	return nil
}

// randomConfirmCode is six random digits.
func randomConfirmCode() string {
	n, err := rand.Int(rand.Reader, big.NewInt(1_000_000))
	if err != nil {
		return "" // confirmOnTerminal refuses without a code
	}
	return fmt.Sprintf("%06d", n.Int64())
}
