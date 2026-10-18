package ownerconfirm

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
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

// desktopRequirement is the code requirement the Desktop must satisfy: the
// identifier, and with a team the Apple-issued certificate of that team.
func desktopRequirement(team string) string {
	if team == "" {
		return fmt.Sprintf(`=identifier "%s"`, DesktopBundleID)
	}
	return fmt.Sprintf(`=identifier "%s" and anchor apple generic and certificate leaf[subject.OU] = "%s"`,
		DesktopBundleID, team)
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
