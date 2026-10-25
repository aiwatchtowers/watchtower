// Package gmail provides Gmail integration for Watchtower.
package gmail

// Message is a parsed Gmail message ready for storage.
type Message struct {
	ID           string
	ThreadID     string
	FromEmail    string
	FromName     string
	To           []string
	Cc           []string
	Subject      string
	Snippet      string
	BodyText     string
	InternalDate string // ISO8601
	Labels       []string
	IsUnread     bool
	Permalink    string
	Images       []ImagePart // every leaf image/* part, in walk order
}

// ImagePart is one leaf image/* part of a message. ContentID is the
// Content-ID without its angle brackets (an inline image's reference).
type ImagePart struct {
	PartID, Filename, MediaType, ContentID string
	Size                                   int64
}
