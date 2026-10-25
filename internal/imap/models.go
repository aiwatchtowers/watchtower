// Package imap provides a multi-account IMAP integration for Watchtower —
// shared by plain username/password mailboxes and OAuth2 (XOAUTH2) providers
// such as Outlook/Office365, which speak the same IMAP wire protocol and
// differ only in how they authenticate.
package imap

// Message is a parsed IMAP message ready for storage.
type Message struct {
	UID          uint32
	FromEmail    string
	FromName     string
	To           []string
	Cc           []string
	Subject      string
	Snippet      string
	BodyText     string
	InternalDate string // ISO8601
	IsUnread     bool
	Images       []ImagePart // every leaf image/* part, in walk order
}

// ImagePart is one leaf image/* part of a message: Index is its place among
// the message's image parts in walk order (from 0). ContentID is the
// Content-ID without its angle brackets.
type ImagePart struct {
	Index                          int
	Filename, MediaType, ContentID string
	Size                           int64
}

// Security is the transport security mode for an IMAP connection.
type Security string

const (
	SecuritySSL      Security = "ssl"
	SecurityStartTLS Security = "starttls"
	SecurityNone     Security = "none"
)

// AccountConfig identifies where and how to connect to one mailbox.
type AccountConfig struct {
	Host     string
	Port     int
	Security Security
	Folder   string // mailbox to sync, e.g. "INBOX"
}
