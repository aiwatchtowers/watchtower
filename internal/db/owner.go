package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

// ErrNoOwner is returned by owner-scoped writers when no connected account
// yields an owner identity (ResolveOwner returned an unknown Owner).
var ErrNoOwner = errors.New("no owner identity: connect Slack, Google or Jira first")

// OwnerSource names the ResolveOwner rung that produced Owner.ID.
type OwnerSource string

const (
	OwnerSourceNone   OwnerSource = ""
	OwnerSourceSlack  OwnerSource = "slack"
	OwnerSourceGoogle OwnerSource = "google"
	OwnerSourceJira   OwnerSource = "jira"
)

// Owner is the one person this install belongs to. ID is the stable key
// owner-scoped rows (user_profile, day plans, …) are stored under; its shape
// depends on the rung that produced it: the namespaced Slack user id
// ("1:U123"), "google:<lower-cased email>", or "jira:<atlassian account id>".
// The other fields are enriched from every connected source.
type Owner struct {
	ID            string
	Source        OwnerSource
	SlackUserID   string
	Email         string
	JiraAccountID string
	DisplayName   string
}

// Known reports whether any rung produced an owner identity.
func (o Owner) Known() bool { return o.ID != "" }

// ownerJira is the Jira rung's row: the connecting person's own Atlassian
// identity on the first enabled, non-removed account that recorded one.
type ownerJira struct {
	AccountID   string
	Email       string
	DisplayName string
}

// ResolveOwner returns the one owner identity of this install: Slack account
// #1 → Google account #1 → Jira account #1 (spec 2026-09-25). The Swift twin
// is WatchtowerCore/Database/Queries/OwnerQueries.swift — change both
// together. Every field is enriched from every source, independent of which
// rung produced ID. No connected identity → the zero Owner and a nil error.
func (db *DB) ResolveOwner() (Owner, error) {
	slackID, err := db.ownerSlackID()
	if err != nil {
		return Owner{}, err
	}
	google, err := db.ownerGoogleEmail()
	if err != nil {
		return Owner{}, err
	}
	jira, err := db.ownerJiraAccount()
	if err != nil {
		return Owner{}, err
	}

	o := Owner{SlackUserID: slackID}
	switch {
	case slackID != "":
		o.ID, o.Source = slackID, OwnerSourceSlack
	case google != "":
		o.ID, o.Source = "google:"+strings.ToLower(google), OwnerSourceGoogle
	case jira.AccountID != "":
		o.ID, o.Source = "jira:"+jira.AccountID, OwnerSourceJira
	default:
		return Owner{}, nil
	}
	return db.enrichOwner(o, google, jira)
}

// RequireOwner is ResolveOwner for callers that cannot act without an owner
// (OWNER-02): an unknown owner is ErrNoOwner, never a silent empty key.
func (db *DB) RequireOwner() (Owner, error) {
	o, err := db.ResolveOwner()
	if err != nil {
		return Owner{}, err
	}
	if !o.Known() {
		return Owner{}, ErrNoOwner
	}
	return o, nil
}

// ownerSlackID is the Slack rung: account #1's namespaced current_user_id,
// unless that account was removed. "" when there is no such account.
func (db *DB) ownerSlackID() (string, error) {
	var id string
	err := db.QueryRow(`SELECT current_user_id FROM slack_accounts WHERE id = 1 AND status != 'removed'`).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("resolving owner slack id: %w", err)
	}
	return id, nil
}

// ownerGoogleEmail is the Google rung: the first connected Google account's
// email, as stored (the caller lower-cases it for the ID only).
func (db *DB) ownerGoogleEmail() (string, error) {
	var email string
	err := db.QueryRow(`SELECT email FROM google_accounts WHERE email != '' ORDER BY id LIMIT 1`).Scan(&email)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("resolving owner google email: %w", err)
	}
	return email, nil
}

// ownerJiraAccount is the Jira rung: the first enabled, non-removed Jira
// account that recorded its connecting person's identity (migration 00071).
func (db *DB) ownerJiraAccount() (ownerJira, error) {
	var j ownerJira
	err := db.QueryRow(`SELECT owner_account_id, owner_email, owner_display_name FROM jira_accounts
		WHERE enabled = 1 AND status != 'removed' AND owner_account_id != '' ORDER BY id LIMIT 1`).
		Scan(&j.AccountID, &j.Email, &j.DisplayName)
	if errors.Is(err, sql.ErrNoRows) {
		return ownerJira{}, nil
	}
	if err != nil {
		return ownerJira{}, fmt.Errorf("resolving owner jira account: %w", err)
	}
	return j, nil
}

// enrichOwner fills Email, JiraAccountID and DisplayName from every source,
// whichever rung produced o.ID.
func (db *DB) enrichOwner(o Owner, googleEmail string, jira ownerJira) (Owner, error) {
	var slackUser *User
	if o.SlackUserID != "" {
		u, err := db.GetUserByID(o.SlackUserID)
		if err != nil {
			return Owner{}, fmt.Errorf("resolving owner slack user: %w", err)
		}
		slackUser = u
	}
	o.Email = ownerEmail(slackUser, googleEmail, jira)
	jiraID, err := db.ownerJiraID(o.SlackUserID, jira)
	if err != nil {
		return Owner{}, err
	}
	o.JiraAccountID = jiraID
	o.DisplayName = ownerDisplayName(slackUser, jira, o.Email)
	return o, nil
}

// ownerEmail: the Slack user's email, else the Google email, else the Jira
// owner email.
func ownerEmail(slackUser *User, googleEmail string, jira ownerJira) string {
	if slackUser != nil && slackUser.Email != "" {
		return slackUser.Email
	}
	if googleEmail != "" {
		return googleEmail
	}
	return jira.Email
}

// ownerDisplayName: the Slack user's display name (else real name), else the
// Jira owner display name, else the email's local part with its case kept.
func ownerDisplayName(slackUser *User, jira ownerJira, email string) string {
	if slackUser != nil {
		if slackUser.DisplayName != "" {
			return slackUser.DisplayName
		}
		if slackUser.RealName != "" {
			return slackUser.RealName
		}
	}
	if jira.DisplayName != "" {
		return jira.DisplayName
	}
	local, _, _ := strings.Cut(email, "@")
	return local
}

// ownerJiraID: the authoritative Jira owner id (GET /myself, 00071), else the
// fuzzy jira_user_map bridge from the Slack user id.
func (db *DB) ownerJiraID(slackUserID string, jira ownerJira) (string, error) {
	if jira.AccountID != "" {
		return jira.AccountID, nil
	}
	return db.ownerJiraFromUserMap(slackUserID)
}

// ownerJiraFromUserMap returns the first Atlassian account id jira_user_map
// maps to slackUserID, matching both the namespaced and the bare form (the
// map was namespaced by migration 00048, but older rows may carry the bare
// id — the inbox atlassianIDsForUser rule). "" when unmapped.
func (db *DB) ownerJiraFromUserMap(slackUserID string) (string, error) {
	if slackUserID == "" {
		return "", nil
	}
	alt := "1:" + slackUserID
	if trimmed, ok := strings.CutPrefix(slackUserID, "1:"); ok {
		alt = trimmed
	}
	var id string
	err := db.QueryRow(`SELECT jira_account_id FROM jira_user_map WHERE slack_user_id IN (?, ?)
		ORDER BY slack_user_id = ? DESC, jira_account_id LIMIT 1`, slackUserID, alt, slackUserID).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("resolving owner jira id from user map: %w", err)
	}
	return id, nil
}
