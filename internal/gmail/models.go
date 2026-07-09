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
}
