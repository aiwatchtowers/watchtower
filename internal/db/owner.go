package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

// ErrNoOwner is returned by owner-scoped writers when no connected account
// yields an owner identity (ResolveOwner returned an unknown Owner).
var ErrNoOwner = errors.New("no owner identity: connect Slack, Google, Jira, Linear or an email account first")

// OwnerSource names the ResolveOwner rung that produced Owner.ID.
type OwnerSource string

const (
	OwnerSourceNone   OwnerSource = ""
	OwnerSourceSlack  OwnerSource = "slack"
	OwnerSourceGoogle OwnerSource = "google"
	OwnerSourceJira   OwnerSource = "jira"
	OwnerSourceLinear OwnerSource = "linear"
	OwnerSourceEmail  OwnerSource = "email"
)

// Owner is the one person this install belongs to. ID is the stable key
// owner-scoped rows (user_profile, day plans, …) are stored under; its shape
// depends on the rung that produced it: the namespaced Slack user id
// ("1:U123"), "google:<lower-cased email>", "jira:<atlassian account id>",
// "linear:<linear user id>", or "email:<lower-cased mailbox address>".
// The other fields are enriched from every connected source.
type Owner struct {
	ID            string
	Source        OwnerSource
	SlackUserID   string
	Email         string
	JiraAccountID string
	DisplayName   string
	// LinearUserIDs is the owner's Linear user id on every enabled,
	// non-removed account (one per workspace), by account id; nil when none.
	LinearUserIDs []string
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

// ownerLinear is the Linear rung's row: the connecting person's own Linear
// identity on the first enabled, non-removed account that recorded one.
type ownerLinear struct {
	UserID      string
	Email       string
	DisplayName string
}

// ownerRungs is every rung's row, read once per ResolveOwner.
type ownerRungs struct {
	slackID     string
	googleEmail string
	jira        ownerJira
	linear      ownerLinear
	mailbox     string
}

// ResolveOwner returns the one owner identity of this install: Slack account
// #1 → Google account #1 → Jira account #1 → Linear account #1 → email
// (IMAP/Outlook) account #1 (spec 2026-09-25). The Swift twin is
// WatchtowerCore/Database/Queries/OwnerQueries.swift — change both together.
// Every field is enriched from every source, independent of which rung
// produced ID. No connected identity → the zero Owner and a nil error.
func (db *DB) ResolveOwner() (Owner, error) {
	r, err := db.readOwnerRungs()
	if err != nil {
		return Owner{}, err
	}
	o := Owner{SlackUserID: r.slackID}
	o.ID, o.Source = r.winner()
	if o.ID == "" {
		return Owner{}, nil
	}
	return db.enrichOwner(o, r)
}

// readOwnerRungs reads each rung's row.
func (db *DB) readOwnerRungs() (ownerRungs, error) {
	var r ownerRungs
	var err error
	if r.slackID, err = db.ownerSlackID(); err != nil {
		return r, err
	}
	if r.googleEmail, err = db.ownerGoogleEmail(); err != nil {
		return r, err
	}
	if r.jira, err = db.ownerJiraAccount(); err != nil {
		return r, err
	}
	if r.linear, err = db.ownerLinearAccount(); err != nil {
		return r, err
	}
	r.mailbox, err = db.ownerMailbox()
	return r, err
}

// winner is the first rung that matched: its owner id and source, or "" and
// OwnerSourceNone when none did.
func (r ownerRungs) winner() (string, OwnerSource) {
	switch {
	case r.slackID != "":
		return r.slackID, OwnerSourceSlack
	case r.googleEmail != "":
		return "google:" + strings.ToLower(r.googleEmail), OwnerSourceGoogle
	case r.jira.AccountID != "":
		return "jira:" + r.jira.AccountID, OwnerSourceJira
	case r.linear.UserID != "":
		return "linear:" + r.linear.UserID, OwnerSourceLinear
	case r.mailbox != "":
		return "email:" + strings.ToLower(r.mailbox), OwnerSourceEmail
	default:
		return "", OwnerSourceNone
	}
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

// ownerLinearAccount is the Linear rung: the first enabled, non-removed Linear
// account that recorded its connecting person's identity (viewer at connect).
func (db *DB) ownerLinearAccount() (ownerLinear, error) {
	var l ownerLinear
	err := db.QueryRow(`SELECT owner_user_id, owner_email, owner_display_name FROM linear_accounts
		WHERE enabled = 1 AND status != 'removed' AND owner_user_id != '' ORDER BY id LIMIT 1`).
		Scan(&l.UserID, &l.Email, &l.DisplayName)
	if errors.Is(err, sql.ErrNoRows) {
		return ownerLinear{}, nil
	}
	if err != nil {
		return ownerLinear{}, fmt.Errorf("resolving owner linear account: %w", err)
	}
	return l, nil
}

// ownerMailbox is the email rung: the address of the first connected
// IMAP/Outlook mailbox whose address looks like one (an '@' after at least one
// character — a bare login such as "jdoe" or "DOMAIN\jdoe" identifies no one),
// as stored (the caller lower-cases it for the ID only). It comes after every
// other rung so no existing install's owner id changes.
func (db *DB) ownerMailbox() (string, error) {
	var addr string
	err := db.QueryRow(`SELECT email_address FROM email_accounts WHERE instr(email_address, '@') > 1 ORDER BY id LIMIT 1`).Scan(&addr)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("resolving owner mailbox: %w", err)
	}
	return addr, nil
}

// ownerLinearUserIDs lists the owner's Linear user id on every enabled,
// non-removed account (one per workspace), by account id. nil when none.
func (db *DB) ownerLinearUserIDs() ([]string, error) {
	rows, err := db.Query(`SELECT owner_user_id FROM linear_accounts
		WHERE enabled = 1 AND status != 'removed' AND owner_user_id != '' ORDER BY id`)
	if err != nil {
		return nil, fmt.Errorf("listing owner linear user ids: %w", err)
	}
	defer func() { _ = rows.Close() }()
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scanning owner linear user id: %w", err)
		}
		ids = append(ids, id)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing owner linear user ids: %w", err)
	}
	return ids, nil
}

// enrichOwner fills Email, JiraAccountID, DisplayName and LinearUserIDs from
// every source, whichever rung produced o.ID.
func (db *DB) enrichOwner(o Owner, r ownerRungs) (Owner, error) {
	var slackUser *User
	if o.SlackUserID != "" {
		u, err := db.GetUserByID(o.SlackUserID)
		if err != nil {
			return Owner{}, fmt.Errorf("resolving owner slack user: %w", err)
		}
		slackUser = u
	}
	o.Email = ownerEmail(slackUser, r)
	jiraID, err := db.ownerJiraID(o.SlackUserID, r.jira)
	if err != nil {
		return Owner{}, err
	}
	o.JiraAccountID = jiraID
	o.DisplayName = ownerDisplayName(slackUser, r.jira, r.linear, o.Email)
	linearIDs, err := db.ownerLinearUserIDs()
	if err != nil {
		return Owner{}, err
	}
	o.LinearUserIDs = linearIDs
	return o, nil
}

// ownerEmail: the Slack user's email, else the Google email, else the Jira
// owner email, else the Linear owner email, else the mailbox address.
func ownerEmail(slackUser *User, r ownerRungs) string {
	if slackUser != nil && slackUser.Email != "" {
		return slackUser.Email
	}
	for _, e := range []string{r.googleEmail, r.jira.Email, r.linear.Email} {
		if e != "" {
			return e
		}
	}
	return r.mailbox
}

// ownerDisplayName: the Slack user's display name (else real name), else the
// Jira owner display name, else the Linear one, else the email's local part with its case kept.
func ownerDisplayName(slackUser *User, jira ownerJira, linear ownerLinear, email string) string {
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
	if linear.DisplayName != "" {
		return linear.DisplayName
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
