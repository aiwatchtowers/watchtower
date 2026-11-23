package slackapp

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net"
	"regexp"
	"strings"

	"watchtower/internal/db"
	"watchtower/internal/fsutil"
	"watchtower/internal/slackconnect"
	"watchtower/internal/slackmode"
)

// Result kinds of a setup run (the final JSON line's "result").
const (
	KindOK          = "ok"
	KindExists      = "exists"       // the team already has a setup record: nothing created
	KindExistingApp = "existing_app" // the team has a live account on a company app: adopt it instead (ask #1425)
	// KindPendingCreate: an apps.manifest.create was sent but its answer was
	// lost (timeout, cut connection), so Slack may have made the app. Never
	// a second create: the owner checks api.slack.com/apps for "Watchtower".
	KindPendingCreate = "pending_create"
	KindConfirmApp    = "confirm_app" // adopt: the App ID came only from --app-id; re-run with --confirm-app-id after checking app_name
	KindNoPending     = "no_pending"  // pending: the team has no pending record
	KindBadIDs        = "bad_ids"     // pending --attach: an id is malformed (Code says which)
	KindNoApp         = "no_app"      // adopt: the team has no live account on a company app
	KindNoRecord      = "no_record"   // link: the team has no setup record
	KindWrongTeam     = "wrong_team"  // link, adopt: --team names another workspace than the token
	// KindWrongWorkspace: adopt's App ID belongs to an app this Mac knows in
	// another workspace than the token's (the company wizard's reuse).
	KindWrongWorkspace  = "wrong_workspace"
	KindNeedAppID       = "need_app_id"      // adopt: the App ID is unknown or does not fit (Code says which; A19)
	KindNotCollaborator = "not_collaborator" // the token's owner is not a collaborator on the app (Q11)
	KindAppNotFound     = "app_not_found"
	KindBadToken        = "bad_token"
	KindNotAllowed      = "not_allowed" // the workspace does not let this user create apps
	KindNetwork         = "network"     // Slack could not be reached; nothing was changed on Slack's side
	KindRefused         = "refused"     // any other Slack refusal; Code holds Slack's code
	KindLinkFailed      = "link_failed" // the app was created, the About link was not written
	KindStorage         = "storage"     // Slack did its part, the local database write failed (Err holds why)
	KindBusy            = "busy"        // another setup run holds the lock
	// KindNeedsPKCEConsent: adopt would turn PKCE on (one-way) and the run
	// did not opt in (--enable-pkce); nothing was changed.
	KindNeedsPKCEConsent = "needs_pkce_consent"
	// KindDryRun: adopt --dry-run read the app; Changes lists what the
	// update would do. Nothing was changed.
	KindDryRun = "dry_run"
	// KindBuiltinPKCEDeferred: the team's company app is the one this build
	// signs in through (Runner.BuiltinClientID). Create and adopt change
	// nothing: adopting would turn PKCE on, and the build's own sign-in
	// (auth.Login: loopback with the client secret, no PKCE) would stop
	// working. The build's app switches with a later update (plan B Task 18).
	KindBuiltinPKCEDeferred = "builtin_app_pkce_deferred"
)

// Codes of a KindNeedAppID or KindBadIDs result.
const (
	CodeAppIDMissing   = "app_id_missing"   // no App ID known and none given
	CodeAppIDFormat    = "app_id_format"    // --app-id is not an App ID
	CodeAppIDMismatch  = "app_id_mismatch"  // --app-id differs from the account row's App ID
	CodeClientIDFormat = "client_id_format" // pending --attach, adopt: --client-id is not a Client ID
	// CodeClientIDMismatch: adopt's --client-id differs from the connected
	// account's.
	CodeClientIDMismatch = "client_id_mismatch"
)

// Step names and states (one JSON line each).
const (
	StepCheckToken = "check_token"
	StepCreateApp  = "create_app"
	StepReadApp    = "read_app"
	StepUpdateApp  = "update_app"
	StepWriteLink  = "write_link"

	StateRunning = "running"
	StateDone    = "done"
	StateFailed  = "failed"
)

// Step is one progress event.
type Step struct {
	Name  string `json:"step"`
	State string `json:"state"`
}

// Result is how a run ended.
type Result struct {
	Kind     string
	Code     string // Slack's error code, or a CodeAppID* for KindNeedAppID
	Error    string // what went wrong, for the owner (network, pending_create, need_app_id)
	TeamID   string
	TeamName string
	AppID    string
	AppName  string // adopt: the exported app's display name (confirm_app)
	// AppTeamID: wrong_workspace — the workspace this Mac knows the app in.
	AppTeamID   string
	ClientID    string
	LinkWritten bool
	// Changes: adopt read the app; what the update makes (or made) differ.
	Changes *Changes
	// Err is the Go error behind KindStorage; for stderr only, never in the
	// JSON result line.
	Err error
}

// Slack codes, mapped to result kinds: the error tables of
// apps.manifest.create/update/export (docs.slack.dev/reference/methods) and
// the plan B spike.
var (
	badTokenCodes = map[string]bool{
		"invalid_auth": true, "not_authed": true, "token_expired": true, "token_revoked": true,
		"account_inactive": true, "not_allowed_token_type": true,
	}
	notAllowedCodes = map[string]bool{"restricted_action": true}
	// createNotAllowedCodes are apps.manifest.create's codes for "this user
	// may not make apps here" (its error table); only a create maps them to
	// KindNotAllowed — on adopt/link no_permission is not_collaborator.
	createNotAllowedCodes = map[string]bool{
		"no_permission": true, "access_denied": true, "feature_not_enabled": true,
		"team_access_not_granted": true,
	}
	// no_permission: the creator's config token on someone else's app (Q11).
	notCollaboratorCodes = map[string]bool{"no_permission": true}
	appNotFoundCodes     = map[string]bool{"invalid_app_id": true, "app_not_found": true}
)

// storageError marks a local database failure after Slack's part succeeded.
type storageError struct{ err error }

func (e storageError) Error() string { return e.err.Error() }
func (e storageError) Unwrap() error { return e.err }

func storage(err error) Result { return Result{Kind: KindStorage, Err: err} }

// failure maps a step's error onto a Result.
func failure(err error) Result {
	var st storageError
	if errors.As(err, &st) {
		return storage(st.err)
	}
	var se *SlackError
	if !errors.As(err, &se) {
		return Result{Kind: KindNetwork, Error: err.Error()}
	}
	r := Result{Code: se.Code}
	switch {
	case badTokenCodes[se.Code]:
		r.Kind = KindBadToken
	case notAllowedCodes[se.Code]:
		r.Kind = KindNotAllowed
	case notCollaboratorCodes[se.Code]:
		r.Kind = KindNotCollaborator
	case appNotFoundCodes[se.Code]:
		r.Kind = KindAppNotFound
	default:
		r.Kind = KindRefused
	}
	return r
}

// notCreatedCodes are the ok:false codes of apps.manifest.create that
// certainly made no app: the call, the token, the caller or the manifest was
// refused before anything was made. Taken from the method's error table
// (https://docs.slack.dev/reference/methods/apps.manifest.create), plus
// restricted_action (an admin's app-creation restriction). Left out on
// purpose, because Slack may have made the app: fatal_error and
// internal_error ("part of the operation may have succeeded"),
// failed_adding_collaborator, failed_creating_app,
// failed_datastore_operation, failed_generating_app_token,
// service_unavailable and any code not listed here.
var notCreatedCodes = map[string]bool{
	// The token or the caller.
	"invalid_auth": true, "not_authed": true, "token_expired": true, "token_revoked": true,
	"account_inactive": true, "not_allowed_token_type": true, "missing_scope": true,
	"no_permission": true, "access_denied": true, "team_access_not_granted": true,
	"not_in_team": true, "two_factor_setup_required": true, "ekm_access_denied": true,
	"enterprise_is_restricted": true, "org_login_required": true, "accesslimited": true,
	// The workspace or an admin.
	"restricted_action": true, "feature_not_enabled": true, "invalid_team_id": true,
	// The request or the manifest.
	"invalid_manifest": true, "invalid_app": true, "socket_mode_not_enabled": true,
	"invalid_arguments": true, "invalid_arg_name": true, "invalid_array_arg": true,
	"invalid_charset": true, "invalid_form_data": true, "invalid_post_type": true,
	"missing_argument": true, "missing_post_type": true, "request_timeout": true,
	"unknown_method": true, "method_deprecated": true, "deprecated_endpoint": true,
	// Refused before running.
	"ratelimited": true,
}

// notCreated reports that a failed apps.manifest.create certainly made no
// app: Slack answered an explicit ok:false with a known not-created code, or
// the connection was never made. Anything else (a timeout, a cut
// connection, an unreadable answer or one without ok, an unknown code) may
// have.
func notCreated(err error) bool {
	var se *SlackError
	if errors.As(err, &se) {
		return notCreatedCodes[se.Code]
	}
	var op *net.OpError
	return errors.As(err, &op) && op.Op == "dial"
}

// Runner runs the setup verbs. One run at a time per workspace: Create,
// Adopt and Link hold the flock at LockPath for the whole run.
type Runner struct {
	DB       *db.DB
	API      API
	LockPath string
	// RetiredClientID is the retired public shared app's client id; an
	// account on it is not on a company app. "" = nothing is shared.
	RetiredClientID string
	// BuiltinClientID is the client id of the app this build signs in
	// through (auth.BuiltinApp); "" = none. Its team gets
	// KindBuiltinPKCEDeferred from create and adopt.
	BuiltinClientID string
	// Emit receives every step; nil drops them.
	Emit func(Step)
}

func (r *Runner) emit(name, state string) {
	if r.Emit != nil {
		r.Emit(Step{Name: name, State: state})
	}
}

// step runs fn as step name, emitting running and then done (fn returned
// nil) or failed.
func (r *Runner) step(name string, fn func() *Result) *Result {
	r.emit(name, StateRunning)
	if res := fn(); res != nil {
		r.emit(name, StateFailed)
		return res
	}
	r.emit(name, StateDone)
	return nil
}

// locked runs fn under the setup lock; a held lock is KindBusy.
func (r *Runner) locked(fn func() (Result, error)) (Result, error) {
	unlock, ok, err := fsutil.TryLockFile(r.LockPath)
	if err != nil {
		return Result{}, err
	}
	if !ok {
		return Result{Kind: KindBusy}, nil
	}
	defer unlock()
	return fn()
}

// team runs the check_token step.
func (r *Runner) team(ctx context.Context, cfgToken string) (id, name string, fail *Result) {
	fail = r.step(StepCheckToken, func() *Result {
		var err error
		if id, name, err = r.API.Team(ctx, cfgToken); err != nil {
			f := failure(err)
			return &f
		}
		return nil
	})
	return id, name, fail
}

// record returns team's setup record; ok=false when there is none.
func (r *Runner) record(team string) (db.SlackAppSetup, bool, error) {
	s, err := r.DB.GetSlackAppSetup(team)
	if errors.Is(err, sql.ErrNoRows) {
		return db.SlackAppSetup{}, false, nil
	}
	if err != nil {
		return db.SlackAppSetup{}, false, err
	}
	return s, true, nil
}

// pendingCreateHelp is the owner's way out of KindPendingCreate.
const pendingCreateHelp = "Slack may have created the app without telling us: look for \"Watchtower\" on api.slack.com/apps before trying again"

// existingRecord is the answer for a team that already has a record: a
// pending one (no app id yet) is KindPendingCreate, any other KindExists.
func existingRecord(s db.SlackAppSetup) Result {
	if s.AppID == "" {
		res := recordResult(KindPendingCreate, s)
		res.Error = pendingCreateHelp
		return res
	}
	return recordResult(KindExists, s)
}

func recordResult(kind string, s db.SlackAppSetup) Result {
	return Result{Kind: kind, TeamID: s.TeamID, TeamName: s.TeamName, AppID: s.AppID,
		ClientID: s.ClientID, LinkWritten: s.LinkWritten}
}

// companyAccount is team's oldest live account on a company app — any
// client id but "" (not known yet) and the retired shared one, which a row
// tied to a company is not (slackmode.SharedApp, ask #1644).
func (r *Runner) companyAccount(team string) (db.SlackAccount, bool, error) {
	accounts, err := r.DB.ListSlackAccounts()
	if err != nil {
		return db.SlackAccount{}, false, err
	}
	for _, a := range accounts {
		if a.TeamID == team && a.Status != "removed" && a.ClientID != "" && !slackmode.SharedApp(a, r.RetiredClientID) {
			return a, true, nil
		}
	}
	return db.SlackAccount{}, false, nil
}

// builtin reports whether acct is on the app this build signs in through.
func (r *Runner) builtin(acct db.SlackAccount) bool {
	return r.BuiltinClientID != "" && acct.ClientID == r.BuiltinClientID
}

// Create makes Watchtower's app in the token's workspace: check_token →
// create_app → write_link. A team with a setup record answers KindExists
// (KindPendingCreate while its create is unresolved) and a team with a live
// company-app account KindExistingApp (KindBuiltinPKCEDeferred when that app
// is the build's own); none creates anything. A pending
// record (no ids) is inserted before apps.manifest.create and filled from
// its answer, so neither a run cut off after the create nor a lost answer
// ever leads to a second app.
func (r *Runner) Create(ctx context.Context, cfgToken string) (Result, error) {
	return r.CreateWith(ctx, cfgToken, CreateOptions{})
}

// CreateOptions are create's flags.
type CreateOptions struct {
	// NewApp is the owner's explicit choice of a second app when the team's
	// company app cannot be adopted (Slack refused the token on it): the
	// KindExistingApp answer is skipped. A setup record and the build's own
	// app still stop the create.
	NewApp bool
}

// CreateWith is Create with the company wizard's --new-app.
func (r *Runner) CreateWith(ctx context.Context, cfgToken string, opts CreateOptions) (Result, error) {
	return r.locked(func() (Result, error) {
		teamID, teamName, fail := r.team(ctx, cfgToken)
		if fail != nil {
			return *fail, nil
		}
		if s, ok, err := r.record(teamID); err != nil {
			return Result{}, err
		} else if ok {
			return existingRecord(s), nil
		}
		acct, ok, err := r.companyAccount(teamID)
		if err != nil {
			return Result{}, err
		}
		if ok && (!opts.NewApp || r.builtin(acct)) {
			kind := KindExistingApp
			if r.builtin(acct) {
				kind = KindBuiltinPKCEDeferred // never offer the adopt
			}
			return Result{Kind: kind, TeamID: teamID, TeamName: teamName,
				AppID: acct.AppID, ClientID: acct.ClientID}, nil
		}

		link := Link{TeamID: teamID, TeamName: teamName}
		var appID string
		fail = r.step(StepCreateApp, func() *Result {
			var res *Result
			appID, link.ClientID, res = r.createApp(ctx, cfgToken, link)
			return res
		})
		if fail != nil {
			fail.TeamID, fail.TeamName = teamID, teamName
			return *fail, nil
		}

		done := Result{Kind: KindOK, TeamID: teamID, TeamName: teamName, AppID: appID, ClientID: link.ClientID}
		if fail := r.step(StepWriteLink, func() *Result { return r.writeLink(ctx, cfgToken, appID, link) }); fail != nil {
			if fail.Kind == KindStorage {
				done.Kind, done.Err = KindStorage, fail.Err
			} else {
				done.Kind, done.Code, done.Error = KindLinkFailed, fail.Code, fail.Error
			}
			return done, nil
		}
		done.LinkWritten = true
		return done, nil
	})
}

// createApp is the create_app step: pending record, apps.manifest.create,
// then the record's ids.
func (r *Runner) createApp(ctx context.Context, cfgToken string, link Link) (appID, clientID string, fail *Result) {
	m, err := BuildManifest(link)
	if err != nil {
		f := storage(err)
		return "", "", &f
	}
	if err := r.DB.InsertSlackAppSetup(db.SlackAppSetup{TeamID: link.TeamID, TeamName: link.TeamName}); err != nil {
		f := storage(err)
		return "", "", &f
	}
	appID, clientID, err = r.API.Create(ctx, cfgToken, m)
	if err != nil {
		if !notCreated(err) {
			// Slack may have made the app: the pending record stays.
			return "", "", &Result{Kind: KindPendingCreate, Error: pendingCreateHelp + " (" + err.Error() + ")"}
		}
		f := failure(err)
		if createNotAllowedCodes[f.Code] {
			f.Kind = KindNotAllowed
		}
		if dErr := r.DB.DeleteSlackAppSetup(link.TeamID); dErr != nil {
			f = storage(dErr)
		}
		return "", "", &f
	}
	if err := r.DB.SetSlackAppSetupApp(link.TeamID, appID, clientID); err != nil {
		f := storage(err)
		f.AppID, f.ClientID = appID, clientID
		return "", "", &f
	}
	return appID, clientID, nil
}

// writeLink re-reads appID's manifest, replaces only its About text with
// link's connect block and writes it back (a human edit in between is kept),
// then marks the record's link as written.
func (r *Runner) writeLink(ctx context.Context, cfgToken, appID string, link Link) *Result {
	theirs, err := r.API.Export(ctx, cfgToken, appID)
	if err == nil {
		var m Manifest
		if m, err = WithLongDescription(theirs, link); err != nil {
			f := storage(err)
			return &f
		}
		err = r.API.Update(ctx, cfgToken, appID, m)
	}
	if err != nil {
		f := failure(err)
		return &f
	}
	if err := r.DB.SetSlackAppSetupLinkWritten(link.TeamID); err != nil {
		f := storage(err)
		return &f
	}
	return nil
}

var appIDPattern = regexp.MustCompile(`^A[A-Z0-9]+$`)

// appName is the exported manifest's display name, "" when it has none.
func appName(m Manifest) string {
	info, _ := m["display_information"].(map[string]any)
	name, _ := info["name"].(string)
	return name
}

// adoptAppID picks the App ID adopt works on (A19): the account row's, else
// appIDFlag. fromFlag reports that only the flag supplied it (then the
// owner must confirm the app by name first); fail is a KindNeedAppID.
func adoptAppID(acct db.SlackAccount, appIDFlag string) (appID string, fromFlag bool, fail *Result) {
	need := func(code, msg string) (string, bool, *Result) {
		return "", false, &Result{Kind: KindNeedAppID, Code: code, Error: msg}
	}
	if appIDFlag != "" && !appIDPattern.MatchString(appIDFlag) {
		return need(CodeAppIDFormat, fmt.Sprintf("%q is not an App ID (it starts with A, e.g. A0123ABCD; Basic Information page)", appIDFlag))
	}
	if acct.AppID != "" {
		if appIDFlag != "" && appIDFlag != acct.AppID {
			return need(CodeAppIDMismatch, "App ID doesn't match this workspace's connected app ("+acct.AppID+")")
		}
		return acct.AppID, false, nil
	}
	if appIDFlag == "" {
		return need(CodeAppIDMissing, "the App ID of the workspace's Watchtower app is not known: give it (Basic Information page)")
	}
	return appIDFlag, true, nil
}

// Adopt brings the team's existing company app (the one its live account is
// on) in line with our manifest instead of creating a second app (ask
// #1425). The App ID comes from the account row, else appIDFlag (A19); a
// flag that is not an App ID or differs from the row's is KindNeedAppID.
//
// Row's App ID: check_token → update_app (export, MergeManifest, update).
// Flag-only App ID (Slack cannot tie an App ID to the row's client id):
// check_token → read_app, answering KindConfirmApp with the app's name and
// changing nothing, until confirmAppID repeats that App ID; then
// check_token → read_app → update_app. The record (link written) is
// inserted only after the update succeeded.
//
// The team's app being the build's own (BuiltinClientID) is
// KindBuiltinPKCEDeferred before any Slack call but check_token.
//
// The update turns PKCE on (MergeManifest), which Slack cannot undo without
// its support. Unless enablePKCE (the owner's opt-in, --enable-pkce) is set
// or the app already has PKCE on, update_app answers KindNeedsPKCEConsent
// after reading the app and before changing anything.
func (r *Runner) Adopt(ctx context.Context, cfgToken, team, appIDFlag, confirmAppID string, enablePKCE bool) (Result, error) {
	return r.AdoptWith(ctx, cfgToken, AdoptOptions{Team: team, AppID: appIDFlag, ConfirmAppID: confirmAppID, EnablePKCE: enablePKCE})
}

// AdoptOptions are adopt's flags.
type AdoptOptions struct {
	Team         string // the workspace the app must be in ("" = the token's)
	AppID        string // --app-id
	ClientID     string // --client-id: the app's Client ID when no account here is on it yet
	ConfirmAppID string // --confirm-app-id
	EnablePKCE   bool
	DryRun       bool // read the app and answer KindDryRun with its Changes; change nothing
}

// AdoptWith is Adopt with the company wizard's additions (#1887): an app no
// account here is on yet is adopted from opts.AppID and opts.ClientID (the
// Basic Information page; confirmed by name like a flag-only App ID), and
// DryRun answers the changes the update would make. confirm_app and dry_run
// carry those Changes.
func (r *Runner) AdoptWith(ctx context.Context, cfgToken string, opts AdoptOptions) (Result, error) {
	team, appIDFlag, confirmAppID, enablePKCE := opts.Team, opts.AppID, opts.ConfirmAppID, opts.EnablePKCE
	return r.locked(func() (Result, error) {
		teamID, teamName, fail := r.team(ctx, cfgToken)
		if fail != nil {
			return *fail, nil
		}
		// The sheet names the workspace it offered to update: a token of
		// another workspace changes nothing there.
		if team != "" && team != teamID {
			return Result{Kind: KindWrongTeam, TeamID: teamID, TeamName: teamName}, nil
		}
		// An App ID this Mac knows in another workspace (a setup record or
		// an account row) is not the token's app: nothing is read or changed.
		if other, err := r.appTeam(appIDFlag); err != nil {
			return Result{}, err
		} else if other != "" && other != teamID {
			return Result{Kind: KindWrongWorkspace, TeamID: teamID, TeamName: teamName, AppID: appIDFlag, AppTeamID: other}, nil
		}
		if s, ok, err := r.record(teamID); err != nil {
			return Result{}, err
		} else if ok {
			if appIDFlag != "" && s.AppID != "" && s.AppID != appIDFlag {
				res := recordResult(KindNeedAppID, s)
				res.Code, res.Error = CodeAppIDMismatch, "this workspace's Watchtower app is "+s.AppID+", not "+appIDFlag
				return res, nil
			}
			return existingRecord(s), nil
		}
		acct, ok, err := r.companyAccount(teamID)
		if err != nil {
			return Result{}, err
		}
		base := Result{TeamID: teamID, TeamName: teamName}
		switch {
		case opts.ClientID != "" && !slackconnect.ClientIDPattern.MatchString(opts.ClientID):
			base.Kind, base.Code = KindBadIDs, CodeClientIDFormat
			base.Error = fmt.Sprintf("%q is not a Client ID (digits.digits; Basic Information page)", opts.ClientID)
			return base, nil
		case ok && opts.ClientID != "" && opts.ClientID != acct.ClientID:
			base.Kind, base.Code = KindBadIDs, CodeClientIDMismatch
			base.Error = "Client ID doesn't match this workspace's connected app (" + acct.ClientID + ")"
			return base, nil
		case !ok && appIDFlag != "" && opts.ClientID != "":
			// No account here is on the app yet: the ids the person gave.
			acct, ok = db.SlackAccount{ClientID: opts.ClientID}, true
		}
		if !ok {
			base.Kind = KindNoApp
			return base, nil
		}
		base.ClientID = acct.ClientID
		if r.builtin(acct) {
			// Before anything is read or changed, --enable-pkce or not.
			base.Kind, base.AppID = KindBuiltinPKCEDeferred, acct.AppID
			return base, nil
		}
		appID, fromFlag, fail := adoptAppID(acct, appIDFlag)
		if fail != nil {
			base.Kind, base.Code, base.Error = fail.Kind, fail.Code, fail.Error
			return base, nil
		}
		base.AppID = appID

		var theirs Manifest
		read := func() *Result {
			var err error
			if theirs, err = r.API.Export(ctx, cfgToken, appID); err != nil {
				f := failure(err)
				return &f
			}
			base.AppName = appName(theirs)
			return nil
		}
		// before is an answer given before anything changes: it shows what
		// the update would do.
		before := func(kind string) (Result, error) {
			changes := ManifestChanges(theirs)
			base.Kind, base.Changes = kind, &changes
			return base, nil
		}
		if fromFlag || opts.DryRun {
			if fail := r.step(StepReadApp, read); fail != nil {
				base.Kind, base.Code, base.Error = fail.Kind, fail.Code, fail.Error
				return base, nil
			}
			if fromFlag && confirmAppID != appID {
				return before(KindConfirmApp)
			}
			if opts.DryRun {
				return before(KindDryRun)
			}
		}

		link := Link{TeamID: teamID, TeamName: teamName, ClientID: acct.ClientID}
		fail = r.step(StepUpdateApp, func() *Result {
			if theirs == nil {
				if f := read(); f != nil {
					return f
				}
			}
			if !enablePKCE && !theirs.PKCEEnabled() {
				return &Result{Kind: KindNeedsPKCEConsent}
			}
			m, err := MergeManifest(theirs, link)
			if err != nil {
				f := storage(err)
				return &f
			}
			if err := r.API.Update(ctx, cfgToken, appID, m); err != nil {
				f := failure(err)
				return &f
			}
			if err := r.DB.InsertSlackAppSetup(db.SlackAppSetup{TeamID: teamID, TeamName: teamName,
				AppID: appID, ClientID: acct.ClientID, LinkWritten: true}); err != nil {
				f := storage(err)
				return &f
			}
			return nil
		})
		if fail != nil {
			base.Kind, base.Code, base.Error, base.Err = fail.Kind, fail.Code, fail.Error, fail.Err
			return base, nil
		}
		base.Kind = KindOK
		base.LinkWritten = true
		return base, nil
	})
}

// SetupByAppID is the setup record of appID; ok=false when appID is "" or
// no record has it.
func SetupByAppID(d *db.DB, appID string) (db.SlackAppSetup, bool, error) {
	if appID == "" {
		return db.SlackAppSetup{}, false, nil
	}
	setups, err := d.ListSlackAppSetups()
	if err != nil {
		return db.SlackAppSetup{}, false, fmt.Errorf("listing slack app setups: %w", err)
	}
	for _, s := range setups {
		if s.AppID == appID {
			return s, true, nil
		}
	}
	return db.SlackAppSetup{}, false, nil
}

// appTeam is the workspace this Mac knows appID in (a setup record first,
// else an account row that is not removed); "" when appID is "" or unknown.
// An App ID this Mac has never seen is not checked here: apps.manifest.*
// answer with Slack's own error for another workspace's app, and the
// exported manifest names no workspace.
func (r *Runner) appTeam(appID string) (string, error) {
	if s, ok, err := SetupByAppID(r.DB, appID); err != nil || ok {
		return s.TeamID, err
	}
	if appID == "" {
		return "", nil
	}
	accounts, err := r.DB.ListSlackAccounts()
	if err != nil {
		return "", fmt.Errorf("listing slack accounts: %w", err)
	}
	for _, a := range accounts {
		if a.AppID == appID && a.Status != "removed" {
			return a.TeamID, nil
		}
	}
	return "", nil
}

// appIDInputPattern is an App ID as a person enters it: the bare id, or a
// link to the app on api.slack.com/apps/<id> or app.slack.com/app(s)/<id>,
// with or without the scheme, and any sub-page, query or fragment after it.
var appIDInputPattern = regexp.MustCompile(
	`(?i)^(?:(A[A-Z0-9]+)|(?:https?://)?(?:api\.slack\.com/apps|app\.slack\.com/apps?)/(A[A-Z0-9]+)(?:[/?#].*)?)$`)

// ParseSlackAppID is the App ID in what a person entered for an app: the
// bare id (any case) or a link to the app (see appIDInputPattern), surrounding
// spaces ignored, the id upper-cased. Anything but printable ASCII inside is
// refused. The Desktop's CompanySetupWizardModel.slackAppID(from:) reads the
// same inputs (shared fixture testdata/app_id_inputs.json).
func ParseSlackAppID(s string) (appID string, ok bool) {
	s = strings.TrimSpace(s)
	for i := 0; i < len(s); i++ {
		if s[i] <= ' ' || s[i] > '~' {
			return "", false
		}
	}
	m := appIDInputPattern.FindStringSubmatch(s)
	if m == nil {
		return "", false
	}
	return strings.ToUpper(m[1] + m[2]), true
}

// ClearPending deletes team's pending setup record: the owner checked
// api.slack.com/apps and no Watchtower app was made. KindNoPending when the
// team has no pending record.
func (r *Runner) ClearPending(team string) (Result, error) {
	return r.locked(func() (Result, error) {
		s, fail, err := r.pending(team, false)
		if fail != nil || err != nil {
			return derefResult(fail), err
		}
		if err := r.DB.DeleteSlackAppSetup(team); err != nil {
			return storage(err), nil
		}
		return recordResult(KindOK, s), nil
	})
}

// AttachPending fills team's pending setup record with the app the owner
// found on api.slack.com/apps (its App ID and Client ID, format-checked);
// the setup then continues with `slack app link`. Until the link is
// written it may run again to correct a mistyped id; once the link is
// written the record is no longer pending (KindNoPending).
func (r *Runner) AttachPending(team, appID, clientID string) (Result, error) {
	return r.locked(func() (Result, error) {
		if !appIDPattern.MatchString(appID) {
			return Result{Kind: KindBadIDs, Code: CodeAppIDFormat, TeamID: team,
				Error: fmt.Sprintf("%q is not an App ID (it starts with A; Basic Information page)", appID)}, nil
		}
		if !slackconnect.ClientIDPattern.MatchString(clientID) {
			return Result{Kind: KindBadIDs, Code: CodeClientIDFormat, TeamID: team,
				Error: fmt.Sprintf("%q is not a Client ID (digits.digits; Basic Information page)", clientID)}, nil
		}
		s, fail, err := r.pending(team, true)
		if fail != nil || err != nil {
			return derefResult(fail), err
		}
		if err := r.DB.SetSlackAppSetupApp(team, appID, clientID); err != nil {
			return storage(err), nil
		}
		s.AppID, s.ClientID = appID, clientID
		return recordResult(KindOK, s), nil
	})
}

// pending returns team's pending record, or KindNoPending. withIDs also
// accepts a record with ids whose link is not written yet (attach's
// correction); clear never does: a record with ids may be one create made,
// and dropping it would let create make a second app.
func (r *Runner) pending(team string, withIDs bool) (db.SlackAppSetup, *Result, error) {
	s, ok, err := r.record(team)
	if err != nil {
		return db.SlackAppSetup{}, nil, err
	}
	if !ok || (s.AppID != "" && (!withIDs || s.LinkWritten)) {
		return db.SlackAppSetup{}, &Result{Kind: KindNoPending, TeamID: team}, nil
	}
	return s, nil, nil
}

func derefResult(r *Result) Result {
	if r == nil {
		return Result{}
	}
	return *r
}

// Link writes the connect link to the About page of the app of team's setup
// record (team "" = the token's workspace): check_token → write_link.
func (r *Runner) Link(ctx context.Context, cfgToken, team string) (Result, error) {
	return r.LinkAbout(ctx, cfgToken, team, "")
}

// LinkAbout is Link writing about (a company's connect text, `company
// publish`) in place of the Slack-only block; about "" is Link.
func (r *Runner) LinkAbout(ctx context.Context, cfgToken, team, about string) (Result, error) {
	return r.locked(func() (Result, error) {
		teamID, teamName, fail := r.team(ctx, cfgToken)
		if fail != nil {
			return *fail, nil
		}
		if team != "" && team != teamID {
			return Result{Kind: KindWrongTeam, TeamID: teamID, TeamName: teamName}, nil
		}
		s, ok, err := r.record(teamID)
		if err != nil {
			return Result{}, err
		}
		if !ok {
			return Result{Kind: KindNoRecord, TeamID: teamID, TeamName: teamName}, nil
		}
		if s.AppID == "" {
			return existingRecord(s), nil
		}
		link := Link{TeamID: s.TeamID, TeamName: s.TeamName, ClientID: s.ClientID, About: about}
		if fail := r.step(StepWriteLink, func() *Result { return r.writeLink(ctx, cfgToken, s.AppID, link) }); fail != nil {
			res := recordResult(fail.Kind, s)
			res.Code, res.Error, res.Err = fail.Code, fail.Error, fail.Err
			return res, nil
		}
		s.LinkWritten = true
		return recordResult(KindOK, s), nil
	})
}

// Stages of a setup record (screens §3.4).
const (
	StagePendingCreate = "pending_create" // the create's answer was lost: no app id yet
	StageInstall       = "install"        // app created, nobody connected through it yet
	StageApproval      = "approval"       // Slack reported an admin approval request
	StageLinkMissing   = "link_missing"   // connected, the About page has no link
	StageDone          = "done"
)

// SetupStatus is one record with its derived state.
type SetupStatus struct {
	TeamID           string `json:"team_id"`
	TeamName         string `json:"team_name"`
	AppID            string `json:"app_id"`
	ClientID         string `json:"client_id"`
	Connected        bool   `json:"connected"` // an ok account row with this client id (A5)
	LinkWritten      bool   `json:"link_written"`
	InstallRequested bool   `json:"install_requested"`
	Stage            string `json:"stage"`
}

// Status lists every setup record, oldest first, with its derived stage.
func Status(d *db.DB) ([]SetupStatus, error) {
	setups, err := d.ListSlackAppSetups()
	if err != nil {
		return nil, err
	}
	accounts, err := d.ListSlackAccounts()
	if err != nil {
		return nil, err
	}
	out := make([]SetupStatus, 0, len(setups))
	for _, s := range setups {
		st := SetupStatus{TeamID: s.TeamID, TeamName: s.TeamName, AppID: s.AppID, ClientID: s.ClientID,
			LinkWritten: s.LinkWritten, InstallRequested: s.InstallRequestedAt != ""}
		for _, a := range accounts {
			if s.ClientID != "" && a.Status == "ok" && a.ClientID == s.ClientID {
				st.Connected = true
				break
			}
		}
		switch {
		case s.AppID == "":
			st.Stage = StagePendingCreate
		case !st.Connected && st.InstallRequested:
			st.Stage = StageApproval
		case !st.Connected:
			st.Stage = StageInstall
		case !st.LinkWritten:
			st.Stage = StageLinkMissing
		default:
			st.Stage = StageDone
		}
		out = append(out, st)
	}
	return out, nil
}
