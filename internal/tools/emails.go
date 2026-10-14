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
	Account    string `json:"account" jsonschema:"the mailbox: a connected Google or IMAP account's label or email address, or gmail:<id> / imap:<id> when those are ambiguous"`
	Since      string `json:"since,omitempty" jsonschema:"only messages received at or after this RFC 3339 time"`
	Limit      int    `json:"limit,omitempty" jsonschema:"max results, 0 = default (50), capped at 200"`
	UnreadOnly bool   `json:"unread_only,omitempty" jsonschema:"only messages that were unread when synced (may be stale)"`
}

type getEmailArgs struct {
	Account string `json:"account" jsonschema:"the mailbox: a connected Google or IMAP account's label or email address, or gmail:<id> / imap:<id> when those are ambiguous"`
	ID      string `json:"id" jsonschema:"the message id from list_emails"`
}

type emailSummary struct {
	ID        string `json:"id"`
	ThreadID  string `json:"thread_id"`
	From      string `json:"from"`
	Subject   string `json:"subject"`
	Snippet   string `json:"snippet"`
	Date      string `json:"date"`
	Unread    bool   `json:"unread"` // the state when synced; may be stale
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
			"Filter with since and unread_only. unread is the state when the message was synced and may be stale. " +
			"Read one message's body with get_email.",
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
		Name: "get_email",
		Description: "Read one locally synced email of a mailbox — recipients and the plain-text body (clipped at 32 KiB). " +
			"unread is the state when the message was synced and may be stale.",
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

// qualified is the store-qualified ref ("gmail:<google_accounts.id>",
// "imap:<email_accounts.id>") that always names exactly this mailbox.
func (r emailAccountRef) qualified() string { return fmt.Sprintf("%s:%d", r.store, r.id) }

// emailMailbox is one connected mailbox an account ref may name. gmailOff
// marks a Google account with Gmail not enabled (Calendar only): it has no
// synced mail, so it is never resolved.
type emailMailbox struct {
	emailAccountRef
	label, address string
	gmailOff       bool
}

func (b emailMailbox) matches(ref string) bool {
	return strings.EqualFold(b.qualified(), ref) || strings.EqualFold(b.label, ref) || strings.EqualFold(b.address, ref)
}

func (b emailMailbox) describe() string {
	return fmt.Sprintf("%s (%s, %s)", b.qualified(), b.label, b.address)
}

// listEmailMailboxes is every Google account and email_accounts mailbox.
func listEmailMailboxes(d *db.DB) ([]emailMailbox, error) {
	nameOf := func(label, address string) string {
		if label != "" {
			return label
		}
		return address
	}
	google, err := d.ListGoogleAccounts()
	if err != nil {
		return nil, fmt.Errorf("resolving email account: %w", err)
	}
	mailboxes, err := d.ListEmailAccounts()
	if err != nil {
		return nil, fmt.Errorf("resolving email account: %w", err)
	}
	out := make([]emailMailbox, 0, len(google)+len(mailboxes))
	for _, a := range google {
		out = append(out, emailMailbox{
			emailAccountRef: emailAccountRef{store: db.EmailStoreGmail, id: a.ID, name: nameOf(a.Label, a.Email)},
			label:           a.Label, address: a.Email, gmailOff: !a.GmailEnabled,
		})
	}
	for _, a := range mailboxes {
		out = append(out, emailMailbox{
			emailAccountRef: emailAccountRef{store: db.EmailStoreIMAP, id: a.ID, name: nameOf(a.Label, a.EmailAddress)},
			label:           a.Label, address: a.EmailAddress,
		})
	}
	return out, nil
}

// resolveEmailAccount matches ref, case-insensitively, against each mailbox's
// label, address and store-qualified ref (gmail:<id>, imap:<id>). Google
// accounts without Gmail are skipped. No match, a ref naming only a
// Gmail-disabled account, or a ref naming two mailboxes (the error lists
// their qualified refs, which always resolve) is a model-facing
// *ValidationError.
func resolveEmailAccount(d *db.DB, ref string) (emailAccountRef, error) {
	ref = strings.TrimSpace(ref)
	if ref == "" {
		return emailAccountRef{}, &ValidationError{Msg: "account is required: a mailbox label or email address"}
	}
	boxes, err := listEmailMailboxes(d)
	if err != nil {
		return emailAccountRef{}, err
	}
	var found []emailMailbox
	gmailOff := false
	for _, b := range boxes {
		switch {
		case !b.matches(ref):
		case b.gmailOff:
			gmailOff = true
		default:
			found = append(found, b)
		}
	}
	switch {
	case len(found) == 1:
		return found[0].emailAccountRef, nil
	case len(found) > 1:
		refs := make([]string, 0, len(found))
		for _, b := range found {
			refs = append(refs, b.describe())
		}
		return emailAccountRef{}, &ValidationError{Msg: fmt.Sprintf("ambiguous account %s: it names %d mailboxes; use one of %s",
			strconv.Quote(ref), len(found), strings.Join(refs, ", "))}
	case gmailOff:
		return emailAccountRef{}, &ValidationError{Msg: "gmail is not enabled for this account " + strconv.Quote(ref) + ": it has no synced mail"}
	}
	return emailAccountRef{}, &ValidationError{Msg: "unknown account " + strconv.Quote(ref) +
		": use a connected mailbox's label or email address, or gmail:<id> / imap:<id>"}
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
