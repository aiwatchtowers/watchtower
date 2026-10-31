package cmd

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/hub"
	"watchtower/internal/hub/link"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/wire"
	"watchtower/internal/policy"
)

// The owner verbs (spec §10): an agent that could run them could link its
// own phone, take one away or hand a phone typing. Refused under every
// agent marker (AGENT-07); Desktop's Settings → Mobile is the path.
const (
	hubUnlinkVerb  = "unlink a phone from the hub"
	hubAllowVerb   = "change a phone's hub grant"
	hubPairVerb    = "pair a phone with the hub"
	hubNameVerb    = "rename the hub"
	hubEnableVerb  = "turn the hub on"
	hubDisableVerb = "turn the hub off"
)

// hubPhoneJSON is one `hub phones --json` element (pinned keys).
type hubPhoneJSON struct {
	DeviceID             string `json:"device_id"`
	Name                 string `json:"name"`
	Scope                string `json:"scope"`
	LinkedAt             string `json:"linked_at"`
	TypingAllowed        bool   `json:"typing_allowed"`
	TypingRequested      bool   `json:"typing_requested"`
	PermissionsAllowed   bool   `json:"permissions_allowed"`
	PermissionsRequested bool   `json:"permissions_requested"`
	StartSessionsAllowed bool   `json:"start_sessions_allowed"`
	StartSessionsGranted bool   `json:"start_sessions_granted"`
	Ordered              bool   `json:"ordered"`
	LastAppliedActionSeq uint64 `json:"last_applied_action_seq"`
	Transport            string `json:"transport"`
}

// hubUnlinkJSON is `hub unlink --json` (pinned keys).
type hubUnlinkJSON struct {
	DeviceID string `json:"device_id"`
	Unlinked bool   `json:"unlinked"`
}

// hubAllowJSON is `hub allow --json` (pinned keys).
type hubAllowJSON struct {
	DeviceID string `json:"device_id"`
	Grant    string `json:"grant"`
	Allowed  bool   `json:"allowed"`
}

// hubNameJSON is `hub name --json` (pinned keys).
type hubNameJSON struct {
	Name string `json:"name"`
}

// hubEnabledJSON is `hub enable|disable --json` (pinned keys).
type hubEnabledJSON struct {
	Enabled bool `json:"enabled"`
}

// The `hub pair --json --stream` lines (pinned keys).
type (
	hubPairQR struct {
		Event     string `json:"event"`
		URL       string `json:"url"`
		ExpiresAt string `json:"expires_at"`
	}
	hubPairEvent struct {
		Event string `json:"event"`
	}
	hubPairSAS struct {
		Event    string `json:"event"`
		DeviceID string `json:"device_id"`
		Name     string `json:"name"`
		Code     string `json:"code"`
	}
	hubPairLinked struct {
		Event    string `json:"event"`
		DeviceID string `json:"device_id"`
	}
	hubPairRefused struct {
		Event  string `json:"event"`
		Reason string `json:"reason"`
	}
	// hubPairConfirm is the owner's answer read from stdin.
	hubPairConfirm struct {
		Confirm *bool `json:"confirm"`
	}
)

// hubPairAfterConfirm bounds the wait for linked or refused once the
// owner's answer is sent; past it the stream ends refused expired_code.
var hubPairAfterConfirm = time.Minute

// hubPairGrace is how long past the code's expiry a pairing with no phone
// yet waits before it ends refused expired_code.
var hubPairGrace = time.Minute

func init() {
	status := &cobra.Command{Use: "status", Short: "Show whether the hub runs and why not", Args: cobra.NoArgs, RunE: runHubStatus}
	phones := &cobra.Command{Use: "phones", Short: "List the linked phones", Args: cobra.NoArgs, RunE: runHubPhones}
	unlink := &cobra.Command{Use: "unlink <device>", Short: "Unlink a phone", Args: cobra.ExactArgs(1), RunE: runHubUnlink}
	allow := &cobra.Command{Use: "allow <device> typing|permissions|start_sessions", Short: "Give a phone a grant (or take it with --revoke)",
		Args: cobra.ExactArgs(2), RunE: runHubAllow}
	allow.Flags().Bool("revoke", false, "take the grant away")
	pair := &cobra.Command{Use: "pair", Short: "Pair a phone with the running hub", Args: cobra.NoArgs, RunE: runHubPair}
	pair.Flags().Bool("stream", false, "stream the pairing as JSON lines and read the confirmation from stdin")
	name := &cobra.Command{Use: "name <name>", Short: "Set the name phones show for this hub", Args: cobra.ExactArgs(1), RunE: runHubName}
	enable := &cobra.Command{Use: "enable", Short: "Turn the hub on", Args: cobra.NoArgs, RunE: runHubSetEnabled(true)}
	disable := &cobra.Command{Use: "disable", Short: "Turn the hub off", Args: cobra.NoArgs, RunE: runHubSetEnabled(false)}
	for _, c := range []*cobra.Command{status, phones, unlink, allow, pair, name, enable, disable} {
		c.Flags().Bool("json", false, "print JSON")
		hubCmd.AddCommand(c)
	}
}

func runHubStatus(cmd *cobra.Command, _ []string) error {
	asJSON, _ := cmd.Flags().GetBool("json")
	dir, err := hubDir()
	if err != nil {
		return err
	}
	s, err := hub.ReadStatus(dir)
	if err != nil {
		return err
	}
	if s.State == hub.StateOff && !hubTestWorkspaceOK() {
		s.Reason = hub.ReasonNotTestWorkspace
	}
	line := "hub: " + s.State
	if s.Reason != "" {
		line += " (" + s.Reason + ")"
	}
	if s.State == hub.StateRunning {
		line += fmt.Sprintf(", %s, %d phone(s)", s.Transport, s.Phones)
	}
	return hubPrint(cmd, asJSON, s, line)
}

func runHubPhones(cmd *cobra.Command, _ []string) error {
	asJSON, _ := cmd.Flags().GetBool("json")
	dir, err := hubDir()
	if err != nil {
		return err
	}
	out := []hubPhoneJSON{}
	st, err := state.OpenReadOnly(dir)
	switch {
	case errors.Is(err, fs.ErrNotExist): // no sidecar yet: no phones
	case err != nil:
		return err
	default:
		devices, err := st.Devices()
		_ = st.Close()
		if err != nil {
			return err
		}
		for _, d := range devices {
			out = append(out, hubPhone(d))
		}
	}
	if asJSON {
		return hubPrint(cmd, true, out, "")
	}
	if len(out) == 0 {
		_, err := fmt.Fprintln(cmd.OutOrStdout(), "no linked phones")
		return err
	}
	for _, p := range out {
		if _, err := fmt.Fprintf(cmd.OutOrStdout(), "%s  %s  linked %s  %s\n", p.DeviceID, p.Name, p.LinkedAt, p.Transport); err != nil {
			return err
		}
	}
	return nil
}

// hubPhone is a linked devices row as `hub phones` shows it; a phone that
// came over the relay has its relay device id, one adopted from the Swift
// hub's sidecar does not.
func hubPhone(d state.Device) hubPhoneJSON {
	tr := wire.TransportCloudKit
	if d.RelayDeviceID != "" {
		tr = wire.TransportRelay
	}
	return hubPhoneJSON{
		DeviceID: d.ID, Name: d.Name, Scope: d.Scope, LinkedAt: d.LinkedAt.UTC().Format(time.RFC3339),
		TypingAllowed: d.TypingAllowed, TypingRequested: d.TypingRequested,
		PermissionsAllowed: d.PermissionsAllowed, PermissionsRequested: d.PermissionsRequested,
		StartSessionsAllowed: d.StartSessionsAllowed, StartSessionsGranted: d.StartSessionsGranted,
		Ordered: d.Ordered, LastAppliedActionSeq: d.LastAppliedActionSeq, Transport: tr,
	}
}

func runHubUnlink(cmd *cobra.Command, args []string) error {
	if err := refuseUnderAgent(hubUnlinkVerb); err != nil {
		return err
	}
	asJSON, _ := cmd.Flags().GetBool("json")
	device := strings.ToUpper(args[0])
	_, err := hubWrite(hub.ControlRequest{Op: hub.OpUnlink, Device: device},
		func(dir string, st *state.Store) (hub.ControlAnswer, error) {
			if err := hub.UnlinkOffline(dir, st, device, hubNow); err != nil {
				return hub.ControlAnswer{Error: hub.LinkErrClass(err)}, nil // worded as over the socket
			}
			return hub.ControlAnswer{OK: true, DeviceID: device}, nil
		})
	if err != nil {
		return err
	}
	return hubPrint(cmd, asJSON, hubUnlinkJSON{DeviceID: device, Unlinked: true}, "unlinked "+device)
}

func runHubAllow(cmd *cobra.Command, args []string) error {
	if err := refuseUnderAgent(hubAllowVerb); err != nil {
		return err
	}
	asJSON, _ := cmd.Flags().GetBool("json")
	revoke, _ := cmd.Flags().GetBool("revoke")
	device, grant, on := strings.ToUpper(args[0]), args[1], !revoke
	switch link.Grant(grant) {
	case link.GrantTyping, link.GrantPermissions, link.GrantStartSessions:
	default:
		return hubAnswerError(hub.ControlAnswer{Error: hub.ErrClassUnknownGrant})
	}
	_, err := hubWrite(hub.ControlRequest{Op: hub.OpAllow, Device: device, Grant: grant, On: on},
		func(_ string, st *state.Store) (hub.ControlAnswer, error) {
			if err := hub.AllowOffline(st, device, link.Grant(grant), on, hubNow); err != nil {
				return hub.ControlAnswer{Error: hub.LinkErrClass(err)}, nil
			}
			return hub.ControlAnswer{OK: true}, nil
		})
	if err != nil {
		return err
	}
	verb := "allowed"
	if !on {
		verb = "revoked"
	}
	return hubPrint(cmd, asJSON, hubAllowJSON{DeviceID: device, Grant: grant, Allowed: on}, fmt.Sprintf("%s %s for %s", verb, grant, device))
}

func runHubName(cmd *cobra.Command, args []string) error {
	if err := refuseUnderAgent(hubNameVerb); err != nil {
		return err
	}
	asJSON, _ := cmd.Flags().GetBool("json")
	name := strings.TrimSpace(args[0])
	if name == "" || len([]rune(name)) > wire.MaxMacNameLength {
		return fmt.Errorf("the hub name must be 1 to %d characters", wire.MaxMacNameLength)
	}
	_, err := hubWrite(hub.ControlRequest{Op: hub.OpName, Name: name},
		func(_ string, st *state.Store) (hub.ControlAnswer, error) {
			return hub.ControlAnswer{OK: true, Name: name}, st.SetMeta(state.MetaDisplayName, name)
		})
	if err != nil {
		return err
	}
	return hubPrint(cmd, asJSON, hubNameJSON{Name: name}, "hub name set")
}

func runHubSetEnabled(on bool) func(*cobra.Command, []string) error {
	return func(cmd *cobra.Command, _ []string) error {
		verb := hubDisableVerb
		if on {
			verb = hubEnableVerb
		}
		if err := refuseUnderAgent(verb); err != nil {
			return err
		}
		asJSON, _ := cmd.Flags().GetBool("json")
		op := hub.OpDisable
		if on {
			op = hub.OpEnable
		}
		_, err := hubWrite(hub.ControlRequest{Op: op},
			func(_ string, st *state.Store) (hub.ControlAnswer, error) {
				// The running hub's own rule: on is refused while the policy is off.
				if on && policy.MobileSync() == policy.MobileOff {
					return hub.ControlAnswer{Error: hub.ErrClassPolicyOff}, nil
				}
				return hub.ControlAnswer{OK: true}, st.SetMeta(state.MetaEnabled, strconv.Itoa(boolInt(on)))
			})
		if err != nil {
			return err
		}
		line := "hub turned off"
		if on {
			line = "hub turned on"
		}
		return hubPrint(cmd, asJSON, hubEnabledJSON{Enabled: on}, line)
	}
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// runHubPair is `hub pair --json --stream`: one connection to the running
// hub for the whole pairing, so the confirm is checked against the code this
// stream showed. The terminal QR and its [y/N] prompt are phase 2.
func runHubPair(cmd *cobra.Command, _ []string) error {
	if err := refuseUnderAgent(hubPairVerb); err != nil {
		return err
	}
	asJSON, _ := cmd.Flags().GetBool("json")
	stream, _ := cmd.Flags().GetBool("stream")
	if !asJSON || !stream {
		return errors.New("only `hub pair --json --stream` is available in this phase")
	}
	dir, err := hubDir()
	if err != nil {
		return err
	}
	c, err := hub.Dial(dir)
	if err != nil {
		return errors.New("the hub is not running")
	}
	defer func() { _ = c.Close() }()
	if err := c.Send(hub.ControlRequest{Op: hub.OpPair}); err != nil {
		return errors.New("the hub is not running")
	}
	in := bufio.NewScanner(cmd.InOrStdin())
	var device string // the phone whose code was shown, once a sas came
	for {
		a, err := c.Next()
		if err != nil {
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() {
				return hubPrint(cmd, true, hubPairRefused{Event: link.EventRefused, Reason: wire.RefusedExpiredCode}, "")
			}
			return fmt.Errorf("the hub closed the pairing: %w", err)
		}
		if a.Event == "" {
			if a.Error == hub.ErrClassHubOff {
				return errors.New("the hub is not running")
			}
			if a.Op == hub.OpConfirm && (a.Error == hub.ErrClassNoCode || a.Error == hub.ErrClassNoRequest) {
				// The request expired while the owner looked at the code.
				return hubPrint(cmd, true, hubPairRefused{Event: link.EventRefused, Reason: wire.RefusedExpiredCode}, "")
			}
			if err := hubAnswerError(a); err != nil {
				return err
			}
			continue
		}
		switch a.Event {
		case link.EventQR:
			var expires string
			if a.ExpiresAt != nil {
				expires = a.ExpiresAt.UTC().Format(time.RFC3339)
				if device == "" {
					_ = c.SetReadDeadline(a.ExpiresAt.Add(hubPairGrace))
				}
			}
			if err := hubPrint(cmd, true, hubPairQR{Event: a.Event, URL: a.URL, ExpiresAt: expires}, ""); err != nil {
				return err
			}
		case link.EventWaiting:
			if err := hubPrint(cmd, true, hubPairEvent{Event: a.Event}, ""); err != nil {
				return err
			}
		case link.EventSAS:
			if device != "" {
				continue // another phone while this one waits for the owner
			}
			device = a.DeviceID
			_ = c.SetReadDeadline(time.Time{})
			if err := hubPrint(cmd, true, hubPairSAS{Event: a.Event, DeviceID: a.DeviceID, Name: a.Name, Code: a.Code}, ""); err != nil {
				return err
			}
			if err := c.Send(hub.ControlRequest{Op: hub.OpConfirm, Device: device, Confirm: readPairConfirm(in)}); err != nil {
				return fmt.Errorf("the hub closed the pairing: %w", err)
			}
			_ = c.SetReadDeadline(time.Now().Add(hubPairAfterConfirm))
		case link.EventLinked:
			if device == "" || !strings.EqualFold(a.DeviceID, device) {
				continue
			}
			return hubPrint(cmd, true, hubPairLinked{Event: a.Event, DeviceID: a.DeviceID}, "")
		case link.EventRefused:
			if device != "" && !strings.EqualFold(a.DeviceID, device) {
				continue
			}
			return hubPrint(cmd, true, hubPairRefused{Event: a.Event, Reason: a.Reason}, "")
		}
	}
}

// readPairConfirm reads the owner's {"confirm":true|false} line; anything
// else, or stdin closing, is a no.
func readPairConfirm(in *bufio.Scanner) bool {
	for in.Scan() {
		line := strings.TrimSpace(in.Text())
		if line == "" {
			continue
		}
		var c hubPairConfirm
		if json.Unmarshal([]byte(line), &c) != nil || c.Confirm == nil {
			return false
		}
		return *c.Confirm
	}
	return false
}
