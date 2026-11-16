package ownerconfirm

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// DesktopBundleID is the Watchtower app's code-signing identifier; every
// build flavor shares it (scripts/build-app.sh BUNDLE_ID).
const DesktopBundleID = "com.watchtower.desktop"

// DevTrustUnsignedEnv lets a development CLI — one with no Team ID in its
// own signature (`go build`, `make build`) — accept an ad-hoc signed
// development Desktop, as long as its identifier is DesktopBundleID. A
// release CLI is signed with a Team ID and ignores it: there the Desktop must
// carry the same Team ID.
const DevTrustUnsignedEnv = "WATCHTOWER_DEV_TRUST_UNSIGNED_DESKTOP"

// codesignPath is the system tool; codesignTimeout bounds each call.
var (
	codesignPath    = "/usr/bin/codesign"
	codesignTimeout = 5 * time.Second
)

var teamIDPattern = regexp.MustCompile(`^[A-Z0-9]{10}$`)

// ErrDevBuild is VerifyDesktop's error for a CLI without a Team ID.
var ErrDevBuild = errors.New("this watchtower binary is not signed with a Team ID (a development build), so it cannot " +
	"check that the app answering is Watchtower; use a release build, or set " + DevTrustUnsignedEnv +
	"=1 for a development Desktop")

// VerifyDesktop checks that pid is the running Watchtower app signed by the
// same team as this CLI: codesign's dynamic validation of the process (the
// kernel's view of the running code, not a file on disk) against the
// requirement identifier = DesktopBundleID, an Apple-issued certificate, and
// leaf subject OU = this CLI's own Team ID. A development CLI (no Team ID)
// refuses unless DevTrustUnsignedEnv is set, and then still requires the
// identifier (an ad-hoc signature carries one; a bare `swift build`
// executable is named after itself and fails).
//
// The peer is named by pid, not by an audit token: a pid reused between the
// socket read and codesign's check is a known gap (within the non-goal: a
// process that can race it runs as the owner). The check is only as strong
// as the secrecy of the team's signing key.
func VerifyDesktop(ctx context.Context, pid int) error {
	team, err := teamOf(ctx, os.Getpid())
	if err != nil {
		return err
	}
	if team == "" && os.Getenv(DevTrustUnsignedEnv) != "1" {
		return ErrDevBuild
	}
	req := desktopRequirement(team)
	if _, err := codesign(ctx, "-v", "-R", req, strconv.Itoa(pid)); err != nil {
		return fmt.Errorf("process %d does not satisfy %s: %w", pid, req, err)
	}
	return nil
}

// desktopRequirement is the code requirement the Desktop must satisfy, in
// codesign's command-line form ("=" + appRequirement).
func desktopRequirement(team string) string {
	return "=" + appRequirement(team)
}

// CLIIdentifier is the watchtower CLI's code-signing identifier (the binary's
// name; scripts/build-app.sh signs Contents/MacOS/watchtower without its
// own --identifier).
const CLIIdentifier = "watchtower"

// appRequirement is the Watchtower app's code requirement: its identifier,
// and with a team the Apple-issued certificate of that team.
func appRequirement(team string) string {
	if team == "" {
		return fmt.Sprintf(`identifier "%s"`, DesktopBundleID)
	}
	return fmt.Sprintf(`identifier "%s" and anchor apple generic and certificate leaf[subject.OU] = "%s"`,
		DesktopBundleID, team)
}

// cliRequirement is the watchtower CLI's code requirement for a team: its
// identifier as well as the team, so neither the app nor any other binary
// of the team passes as the CLI (and the CLI in the app bundle never passes
// as the app: appRequirement names the app's identifier).
func cliRequirement(team string) string {
	return fmt.Sprintf(`identifier "%s" and anchor apple generic and certificate leaf[subject.OU] = "%s"`,
		CLIIdentifier, team)
}

// teamOf is the Team ID in pid's code signature, "" when it has none
// (unsigned or ad-hoc).
func teamOf(ctx context.Context, pid int) (string, error) {
	out, err := codesign(ctx, "-d", "--verbose=2", strconv.Itoa(pid))
	if err != nil {
		if strings.Contains(out, "not signed") {
			return "", nil
		}
		return "", fmt.Errorf("reading this binary's signature: %w", err)
	}
	for _, line := range strings.Split(out, "\n") {
		if v, ok := strings.CutPrefix(strings.TrimSpace(line), "TeamIdentifier="); ok {
			if teamIDPattern.MatchString(v) {
				return v, nil
			}
			return "", nil // "not set"
		}
	}
	return "", nil
}

// ErrNotSameCLI is VerifySameTeamCLI's error for a peer that is not this
// CLI's build.
var ErrNotSameCLI = errors.New("the process is not a watchtower binary of this build's team")

// ErrNotDesktop is VerifyDesktopPeer's error for a peer that is not the
// Watchtower app.
var ErrNotDesktop = errors.New("the process is not the Watchtower app signed by this build's team")

// VerifyDesktopPeer checks that the process image t names is the
// Watchtower app signed by this CLI's team (the chat socket's client, D17).
// Unlike VerifyDesktop the peer is named by its audit token, read when it
// connected, not by its pid: a process that execs the signed app after it
// connected no longer matches the token, so it is refused. A development
// CLI keeps VerifyDesktop's rule (refused unless DevTrustUnsignedEnv is set,
// and then the identifier is still checked).
func VerifyDesktopPeer(ctx context.Context, t PeerToken) error {
	team, err := teamOf(ctx, os.Getpid())
	if err != nil {
		return err
	}
	if team == "" && os.Getenv(DevTrustUnsignedEnv) != "1" {
		return ErrDevBuild
	}
	if err := checkToken(t, appRequirement(team)); err != nil {
		return fmt.Errorf("%w: %v", ErrNotDesktop, err)
	}
	return nil
}

// VerifySameTeamCLI checks, by the audit token like VerifyDesktopPeer, that
// the process image t names is the watchtower CLI signed by this CLI's own
// team (identifier and team). A development CLI (no Team ID) accepts only a
// process running its own executable file, by the path of the code the
// token names.
func VerifySameTeamCLI(ctx context.Context, t PeerToken) error {
	team, err := teamOf(ctx, os.Getpid())
	if err != nil {
		return err
	}
	if team != "" {
		if err := checkToken(t, cliRequirement(team)); err != nil {
			return fmt.Errorf("%w: %v", ErrNotSameCLI, err)
		}
		return nil
	}
	own, err := os.Executable()
	if err != nil {
		return fmt.Errorf("%w: this executable is unknown: %v", ErrNotSameCLI, err)
	}
	peer, err := tokenPath(t)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrNotSameCLI, err)
	}
	if !samePath(own, peer) {
		return fmt.Errorf("%w: the peer runs another executable than this development build", ErrNotSameCLI)
	}
	return nil
}

// samePath compares two executables' paths with their symlinks resolved.
func samePath(a, b string) bool {
	ra, err := filepath.EvalSymlinks(a)
	if err != nil {
		return false
	}
	rb, err := filepath.EvalSymlinks(b)
	return err == nil && ra == rb
}

// codesign runs the tool and returns its combined output (it reports on
// stderr).
func codesign(ctx context.Context, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, codesignTimeout)
	defer cancel()
	var out bytes.Buffer
	c := exec.CommandContext(ctx, codesignPath, args...)
	c.Stdout, c.Stderr = &out, &out
	err := c.Run()
	return out.String(), err
}
