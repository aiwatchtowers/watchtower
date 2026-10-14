package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"watchtower/internal/db"
)

// maxEmailBodyBytes caps get_email's body (spec 2026-10-14-automations-design
// Global Constraints: email body clipped 32 KiB).
const maxEmailBodyBytes = 32 * 1024

type listEmailsArgs struct {
	Account    string `json:"account" jsonschema:"the mailbox: a connected Google or IMAP account's label or email address"`
	Since      string `json:"since,omitempty" jsonschema:"only messages received at or after this RFC 3339 time"`
	Limit      int    `json:"limit,omitempty" jsonschema:"max results, 0 = default (50), capped at 200"`
	UnreadOnly bool   `json:"unread_only,omitempty" jsonschema:"only unread messages"`
}

type getEmailArgs struct {
	Account string `json:"account" jsonschema:"the mailbox: a connected Google or IMAP account's label or email address"`
	ID      string `json:"id" jsonschema:"the message id from list_emails"`
}

type emailSummary struct {
	ID        string `json:"id"`
	ThreadID  string `json:"thread_id"`
	From      string `json:"from"`
	Subject   string `json:"subject"`
	Snippet   string `json:"snippet"`
	Date      string `json:"date"`
	Unread    bool   `json:"unread"`
	Permalink string `json:"permalink"`
}

type emailDetail struct {
	Account string `json:"account"`
	emailSummary
	To        []string `json:"to"`
	Cc        []string `json:"cc"`
	Body      string   `json:"body"`
	Truncated bool     `json:"truncated"`
}

// NewListEmails lists one mailbox's synced messages for an automation. It
// reads only the local store (gmail_messages, imap_messages) — the
// constructor takes no client, so it can never reach a live mail API (D2).
// Automation surface only, never in ReadTools(): dev-mode MCP never mounts it.
func NewListEmails() *Tool {
	return &Tool{
		Name: "list_emails",
		Description: "List one mailbox's locally synced email (Gmail or IMAP), newest first, without bodies. " +
			"Filter with since and unread_only; read one message's body with get_email.",
		InputSchema: mustSchema[listEmailsArgs]("list_emails"),
		Access:      AccessRead,
		Surfaces:    []string{AutomationSurface},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a listEmailsArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			acct, err := resolveEmailAccount(d, a.Account)
			if err != nil {
				return nil, err
			}
			since := ""
			if strings.TrimSpace(a.Since) != "" {
				ts, perr := time.Parse(time.RFC3339, strings.TrimSpace(a.Since))
				if perr != nil {
					return nil, &ValidationError{Msg: "since must be an RFC 3339 time, e.g. 2026-10-14T09:00:00Z", Err: perr}
				}
				since = ts.UTC().Format(time.RFC3339)
			}
			msgs, err := d.ListLocalEmails(ctx, db.LocalEmailQuery{
				Store: acct.store, AccountID: acct.id, Since: since, Limit: listLimit(a.Limit), UnreadOnly: a.UnreadOnly,
			})
			if err != nil {
				return nil, err
			}
			out := make([]emailSummary, 0, len(msgs))
			for _, m := range msgs {
				out = append(out, summarizeEmail(m))
			}
			return map[string]any{"account": acct.name, "messages": out}, nil
		},
	}
}

// NewGetEmail reads one synced message with its body (clipped at 32 KiB,
// truncated: true). Local store only, automation surface only — see
// NewListEmails.
func NewGetEmail() *Tool {
	return &Tool{
		Name:        "get_email",
		Description: "Read one locally synced email of a mailbox — recipients and the plain-text body (clipped at 32 KiB).",
		InputSchema: mustSchema[getEmailArgs]("get_email"),
		Access:      AccessRead,
		Surfaces:    []string{AutomationSurface},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a getEmailArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			acct, err := resolveEmailAccount(d, a.Account)
			if err != nil {
				return nil, err
			}
			m, found, err := d.GetLocalEmail(ctx, acct.store, acct.id, strings.TrimSpace(a.ID))
			if err != nil {
				return nil, err
			}
			if !found {
				return nil, &ValidationError{Msg: fmt.Sprintf("no email %s in account %s", strconv.Quote(a.ID), strconv.Quote(acct.name))}
			}
			to, err := emailRecipients(m.ToJSON)
			if err != nil {
				return nil, fmt.Errorf("reading the To list of email %s: %w", m.ID, err)
			}
			cc, err := emailRecipients(m.CcJSON)
			if err != nil {
				return nil, fmt.Errorf("reading the Cc list of email %s: %w", m.ID, err)
			}
			body, truncated := clipUTF8Bytes(m.BodyText, maxEmailBodyBytes)
			return emailDetail{
				Account: acct.name, emailSummary: summarizeEmail(m),
				To: to, Cc: cc, Body: body, Truncated: truncated,
			}, nil
		},
	}
}

// emailAccountRef is a resolved mailbox: which store holds its mail, its row
// id there, and the name results echo back (label, else address).
type emailAccountRef struct {
	store db.EmailStore
	id    int64
	name  string
}

// resolveEmailAccount matches ref against the label or address of every
// Google account and email_accounts mailbox, case-insensitively. No match, or
// a ref naming two mailboxes, is a model-facing *ValidationError.
func resolveEmailAccount(d *db.DB, ref string) (emailAccountRef, error) {
	ref = strings.TrimSpace(ref)
	if ref == "" {
		return emailAccountRef{}, &ValidationError{Msg: "account is required: a mailbox label or email address"}
	}
	matches := func(label, address string) bool {
		return strings.EqualFold(label, ref) || strings.EqualFold(address, ref)
	}
	nameOf := func(label, address string) string {
		if label != "" {
			return label
		}
		return address
	}
	var found []emailAccountRef
	google, err := d.ListGoogleAccounts()
	if err != nil {
		return emailAccountRef{}, fmt.Errorf("resolving email account: %w", err)
	}
	for _, a := range google {
		if matches(a.Label, a.Email) {
			found = append(found, emailAccountRef{store: db.EmailStoreGmail, id: a.ID, name: nameOf(a.Label, a.Email)})
		}
	}
	mailboxes, err := d.ListEmailAccounts()
	if err != nil {
		return emailAccountRef{}, fmt.Errorf("resolving email account: %w", err)
	}
	for _, a := range mailboxes {
		if matches(a.Label, a.EmailAddress) {
			found = append(found, emailAccountRef{store: db.EmailStoreIMAP, id: a.ID, name: nameOf(a.Label, a.EmailAddress)})
		}
	}
	switch len(found) {
	case 0:
		return emailAccountRef{}, &ValidationError{Msg: "unknown account " + strconv.Quote(ref) + ": use a connected mailbox's label or email address"}
	case 1:
		return found[0], nil
	}
	return emailAccountRef{}, &ValidationError{Msg: fmt.Sprintf("ambiguous account %s: it names %d mailboxes; use the email address", strconv.Quote(ref), len(found))}
}

func summarizeEmail(m db.LocalEmail) emailSummary {
	from := m.FromEmail
	switch {
	case m.FromName != "" && m.FromEmail != "":
		from = m.FromName + " <" + m.FromEmail + ">"
	case m.FromName != "":
		from = m.FromName
	}
	return emailSummary{
		ID: m.ID, ThreadID: m.ThreadID, From: from, Subject: m.Subject, Snippet: m.Snippet,
		Date: m.InternalDate, Unread: m.IsUnread, Permalink: m.Permalink,
	}
}

// emailRecipients decodes a stored to_json/cc_json array; empty or null is [].
func emailRecipients(raw string) ([]string, error) {
	out := []string{}
	if strings.TrimSpace(raw) == "" {
		return out, nil
	}
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		return nil, err
	}
	if out == nil {
		out = []string{}
	}
	return out, nil
}

// clipUTF8Bytes cuts s to at most maxBytes bytes on a rune boundary and
// reports whether it cut anything.
func clipUTF8Bytes(s string, maxBytes int) (string, bool) {
	if len(s) <= maxBytes {
		return s, false
	}
	cut := maxBytes
	for cut > 0 && !utf8.RuneStart(s[cut]) {
		cut--
	}
	return s[:cut], true
}
