package slackapp

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"watchtower/internal/db"
	"watchtower/internal/fsutil"
)

// Result kinds of a setup run (the final JSON line's "result").
const (
	KindOK              = "ok"
	KindExists          = "exists"           // the team already has a setup record: nothing created
	KindExistingApp     = "existing_app"     // the team has a live account on a company app: adopt it instead (ask #1425)
	KindNoApp           = "no_app"           // adopt: the team has no live account on a company app
	KindNoRecord        = "no_record"        // link: the team has no setup record
	KindWrongTeam       = "wrong_team"       // link: --team names another workspace than the token
	KindNeedAppID       = "need_app_id"      // adopt: the App ID is unknown; pass --app-id (A19)
	KindNotCollaborator = "not_collaborator" // the token's owner is not a collaborator on the app (Q11)
	KindAppNotFound     = "app_not_found"
	KindBadToken        = "bad_token"
	KindNotAllowed      = "not_allowed" // the workspace does not let this user create apps
	KindNetwork         = "network"
	KindRefused         = "refused"     // any other Slack refusal; Code holds Slack's code
	KindLinkFailed      = "link_failed" // the app was created, the About link was not written
	KindBusy            = "busy"        // another setup run holds the lock
)

// Step names and states (one JSON line each).
const (
	StepCheckToken = "check_token"
	StepCreateApp  = "create_app"
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
	Kind        string
	Code        string // Slack's error code (refused and the other Slack refusals)
	Error       string // what went wrong (network)
	TeamID      string
	TeamName    string
	AppID       string
	ClientID    string
	LinkWritten bool
}

// Slack codes, mapped to result kinds. Provisional where the spike has no
// answer yet; plan B Task 16 finalises them.
var (
	badTokenCodes = map[string]bool{
		"invalid_auth": true, "not_authed": true, "token_expired": true, "token_revoked": true,
		"account_inactive": true, "not_allowed_token_type": true,
	}
	notAllowedCodes = map[string]bool{"restricted_action": true}
	// no_permission: the creator's config token on someone else's app (Q11).
	notCollaboratorCodes = map[string]bool{"no_permission": true}
	appNotFoundCodes     = map[string]bool{"invalid_app_id": true, "app_not_found": true}
)

// failure maps a Slack call's error onto a Result.
func failure(err error) Result {
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

// Runner runs the setup verbs. One run at a time per workspace: Create,
// Adopt and Link hold the flock at LockPath for the whole run.
type Runner struct {
	DB       *db.DB
	API      API
	LockPath string
	// RetiredClientID is the retired public shared app's client id; an
	// account on it is not on a company app. "" = nothing is shared.
	RetiredClientID string
	// EnablePKCEOnAdopt lets Adopt set pkce_enabled on the existing app.
	// One-way on Slack's side; false until plan B Task 16 decides.
	EnablePKCEOnAdopt bool
	// Emit receives every step; nil drops them.
	Emit func(Step)
}

func (r *Runner) emit(name, state string) {
	if r.Emit != nil {
		r.Emit(Step{Name: name, State: state})
	}
}

// step runs fn as step name, emitting running and then done or failed.
func (r *Runner) step(name string, fn func() error) error {
	r.emit(name, StateRunning)
	if err := fn(); err != nil {
		r.emit(name, StateFailed)
		return err
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
	err := r.step(StepCheckToken, func() error {
		var err error
		id, name, err = r.API.Team(ctx, cfgToken)
		return err
	})
	if err != nil {
		f := failure(err)
		return "", "", &f
	}
	return id, name, nil
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

func recordResult(kind string, s db.SlackAppSetup) Result {
	return Result{Kind: kind, TeamID: s.TeamID, TeamName: s.TeamName, AppID: s.AppID,
		ClientID: s.ClientID, LinkWritten: s.LinkWritten}
}

// companyAccount is team's oldest live account on a company app — any
// client id but "" (not known yet) and the retired shared one.
func (r *Runner) companyAccount(team string) (db.SlackAccount, bool, error) {
	accounts, err := r.DB.ListSlackAccounts()
	if err != nil {
		return db.SlackAccount{}, false, err
	}
	for _, a := range accounts {
		if a.TeamID == team && a.Status != "removed" && a.ClientID != "" && a.ClientID != r.RetiredClientID {
			return a, true, nil
		}
	}
	return db.SlackAccount{}, false, nil
}

// Create makes Watchtower's app in the token's workspace: check_token →
// create_app → write_link. A team with a setup record answers KindExists and
// a team with a live company-app account KindExistingApp; neither creates
// anything. The record is inserted right after Slack's create answer, before
// anything else can fail, so a run cut off later resumes instead of creating
// a second app.
func (r *Runner) Create(ctx context.Context, cfgToken string) (Result, error) {
	return r.locked(func() (Result, error) {
		teamID, teamName, fail := r.team(ctx, cfgToken)
		if fail != nil {
			return *fail, nil
		}
		if s, ok, err := r.record(teamID); err != nil || ok {
			return recordResult(KindExists, s), err
		}
		acct, ok, err := r.companyAccount(teamID)
		if err != nil {
			return Result{}, err
		}
		if ok {
			return Result{Kind: KindExistingApp, TeamID: teamID, TeamName: teamName,
				AppID: acct.AppID, ClientID: acct.ClientID}, nil
		}

		link := Link{TeamID: teamID, TeamName: teamName}
		var appID string
		var res *Result
		err = r.step(StepCreateApp, func() error {
			m, err := BuildManifest(link)
			if err != nil {
				return err
			}
			appID, link.ClientID, err = r.API.Create(ctx, cfgToken, m)
			if err != nil {
				f := failure(err)
				res = &f
				return err
			}
			return r.DB.InsertSlackAppSetup(db.SlackAppSetup{TeamID: teamID, TeamName: teamName,
				AppID: appID, ClientID: link.ClientID})
		})
		if res != nil {
			res.TeamID, res.TeamName = teamID, teamName
			return *res, nil
		}
		if err != nil {
			if appID != "" {
				return Result{}, fmt.Errorf("slack app %s was created but its setup record was not saved: %w", appID, err)
			}
			return Result{}, err
		}

		done := Result{Kind: KindOK, TeamID: teamID, TeamName: teamName, AppID: appID, ClientID: link.ClientID}
		if err := r.step(StepWriteLink, func() error { return r.writeLink(ctx, cfgToken, appID, link) }); err != nil {
			done.Kind = KindLinkFailed
			if f := failure(err); f.Kind != KindNetwork {
				done.Code = f.Code
			} else {
				done.Error = f.Error
			}
			return done, nil
		}
		done.LinkWritten = true
		return done, nil
	})
}

// writeLink re-reads appID's manifest, replaces only its About text with
// link's connect block and writes it back (a human edit in between is kept),
// then marks the record's link as written.
func (r *Runner) writeLink(ctx context.Context, cfgToken, appID string, link Link) error {
	theirs, err := r.API.Export(ctx, cfgToken, appID)
	if err != nil {
		return err
	}
	m, err := WithLongDescription(theirs, link)
	if err != nil {
		return err
	}
	if err := r.API.Update(ctx, cfgToken, appID, m); err != nil {
		return err
	}
	return r.DB.SetSlackAppSetupLinkWritten(link.TeamID)
}

// Adopt brings the team's existing company app (the one its live account is
// on) in line with our manifest instead of creating a second app (ask
// #1425): check_token → update_app (export, MergeManifest, update). The App
// ID comes from the account row, else appIDFlag, else KindNeedAppID (A19).
// The record (link written) is inserted only after the update succeeded.
func (r *Runner) Adopt(ctx context.Context, cfgToken, appIDFlag string) (Result, error) {
	return r.locked(func() (Result, error) {
		teamID, teamName, fail := r.team(ctx, cfgToken)
		if fail != nil {
			return *fail, nil
		}
		if s, ok, err := r.record(teamID); err != nil || ok {
			return recordResult(KindExists, s), err
		}
		acct, ok, err := r.companyAccount(teamID)
		if err != nil {
			return Result{}, err
		}
		base := Result{TeamID: teamID, TeamName: teamName}
		if !ok {
			base.Kind = KindNoApp
			return base, nil
		}
		base.ClientID = acct.ClientID
		base.AppID = acct.AppID
		if base.AppID == "" {
			base.AppID = appIDFlag
		}
		if base.AppID == "" {
			base.Kind = KindNeedAppID
			return base, nil
		}

		link := Link{TeamID: teamID, TeamName: teamName, ClientID: acct.ClientID}
		var res *Result
		err = r.step(StepUpdateApp, func() error {
			theirs, err := r.API.Export(ctx, cfgToken, base.AppID)
			if err == nil {
				var m Manifest
				if m, err = MergeManifest(theirs, link, r.EnablePKCEOnAdopt); err != nil {
					return err
				}
				err = r.API.Update(ctx, cfgToken, base.AppID, m)
			}
			if err != nil {
				f := failure(err)
				res = &f
				return err
			}
			return r.DB.InsertSlackAppSetup(db.SlackAppSetup{TeamID: teamID, TeamName: teamName,
				AppID: base.AppID, ClientID: acct.ClientID, LinkWritten: true})
		})
		if res != nil {
			base.Kind, base.Code, base.Error = res.Kind, res.Code, res.Error
			return base, nil
		}
		if err != nil {
			return Result{}, err
		}
		base.Kind = KindOK
		base.LinkWritten = true
		return base, nil
	})
}

// Link writes the connect link to the About page of the app of team's setup
// record (team "" = the token's workspace): check_token → write_link.
func (r *Runner) Link(ctx context.Context, cfgToken, team string) (Result, error) {
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
		link := Link{TeamID: s.TeamID, TeamName: s.TeamName, ClientID: s.ClientID}
		if err := r.step(StepWriteLink, func() error { return r.writeLink(ctx, cfgToken, s.AppID, link) }); err != nil {
			f := failure(err)
			res := recordResult(f.Kind, s)
			res.Code, res.Error = f.Code, f.Error
			return res, nil
		}
		s.LinkWritten = true
		return recordResult(KindOK, s), nil
	})
}

// Stages of a setup record (screens §3.4).
const (
	StageInstall     = "install"      // app created, nobody connected through it yet
	StageApproval    = "approval"     // Slack reported an admin approval request
	StageLinkMissing = "link_missing" // connected, the About page has no link
	StageDone        = "done"
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
			if a.Status == "ok" && a.ClientID == s.ClientID {
				st.Connected = true
				break
			}
		}
		switch {
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
