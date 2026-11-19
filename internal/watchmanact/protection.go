package watchmanact

import (
	"bytes"
	"context"
	"encoding/json"
	"net/url"
	"strings"
)

// GitHub, at the server (spec 2026-11-16-watchman-design §5 item 2): a PR
// merge never goes through local git, so at arm time Watchman reads the
// default branch's protection and the arm sheet warns when nothing there
// stops an agent's `gh pr merge`.

// Warnings shown on the arm sheet (spec copy, verbatim).
const (
	ProtectionWarningUnprotected = "main is not protected on GitHub — an agent's gh pr merge cannot be stopped here"
	ProtectionWarningUnreadable  = "Could not read main's protection on GitHub — treat it as unprotected"
)

// Protection is what the check found: the default branch, whether merging
// into it needs an approving review that admins cannot bypass (an agent
// runs gh with the owner's token, so `gh pr merge --admin` would otherwise
// get through), and the arm sheet's warning ("" = none).
type Protection struct {
	DefaultBranch       string
	OwnerReviewRequired bool
	Warning             string
}

// CheckProtection reads the repository in folder's default branch and its
// protection through gh (`gh api repos/{owner}/{repo}/branches/{branch}/protection`;
// gh fills {owner}/{repo} from the folder's remote). run runs a command in
// dir and returns its stdout — on a failure too, which is where gh puts an
// API error's body. A 404 is an unprotected branch; a protection without
// a required approving review, or with enforce_admins off, warns the same; gh missing or any other
// failure warns that the protection could not be read.
func CheckProtection(ctx context.Context, run func(ctx context.Context, dir, name string, args ...string) ([]byte, error), folder string) Protection {
	out, err := run(ctx, folder, "gh", "api", "repos/{owner}/{repo}", "--jq", ".default_branch")
	branch := strings.TrimSpace(string(out))
	if err != nil || branch == "" || strings.ContainsAny(branch, " \n") {
		return Protection{Warning: ProtectionWarningUnreadable}
	}
	p := Protection{DefaultBranch: branch}
	out, err = run(ctx, folder, "gh", "api", "repos/{owner}/{repo}/branches/"+url.PathEscape(branch)+"/protection")
	var body struct {
		Status  json.RawMessage `json:"status"`
		Message string          `json:"message"`
		Reviews *struct {
			Count int `json:"required_approving_review_count"`
		} `json:"required_pull_request_reviews"`
		EnforceAdmins *struct {
			Enabled bool `json:"enabled"`
		} `json:"enforce_admins"`
	}
	parsed := json.Unmarshal(bytes.TrimSpace(out), &body) == nil
	switch {
	case err != nil && parsed && (strings.Trim(string(body.Status), `"`) == "404" || body.Message == "Branch not protected"):
		p.Warning = ProtectionWarningUnprotected
	case err != nil || !parsed:
		p.Warning = ProtectionWarningUnreadable
	case body.Reviews == nil || body.Reviews.Count < 1 || body.EnforceAdmins == nil || !body.EnforceAdmins.Enabled:
		p.Warning = ProtectionWarningUnprotected
	default:
		p.OwnerReviewRequired = true
	}
	return p
}
