// Package caldav provides multi-account open-protocol calendar sources for
// Watchtower — CalDAV servers (username/password basic auth: iCloud,
// Fastmail, Yandex, Nextcloud, corporate) and secret ICS feed URLs (Google
// Calendar's "Secret address in iCal format", Outlook published calendars).
// Both speak iCalendar and differ only in transport, mirroring how
// internal/imap covers password and XOAUTH2 mailboxes with one package.
package caldav

import "time"

// Event is a parsed iCalendar event ready for conversion to a
// db.CalendarEvent row. Recurring events are expanded into one Event per
// window-relevant occurrence (see expandEvents).
type Event struct {
	UID         string // account-unique instance id (occurrence start appended for recurring instances)
	Title       string
	Description string
	Location    string
	Start       time.Time // UTC
	End         time.Time // UTC
	IsAllDay    bool
	Organizer   string // email
	Attendees   []Attendee
	Status      string // "confirmed" | "tentative" | "cancelled"
	Recurring   bool
	UpdatedAt   string // ISO8601 from LAST-MODIFIED/DTSTAMP, may be empty
}

// Attendee mirrors internal/calendar.Attendee's JSON shape exactly so the
// attendees column stays byte-compatible with Google-synced events and the
// downstream consumers (inbox calendar detector, meeting prep, Desktop)
// decode both identically.
type Attendee struct {
	Email          string `json:"email"`
	DisplayName    string `json:"display_name"`
	ResponseStatus string `json:"response_status"` // accepted/declined/tentative/needsAction
	SlackUserID    string `json:"slack_user_id"`   // resolved via email→users.email lookup
}
