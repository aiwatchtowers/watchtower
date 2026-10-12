package sessioncleanup

// Kind is an item's kind.
type Kind string

const (
	KindWorktree Kind = "worktree"
	KindBranch   Kind = "branch"
	KindProcess  Kind = "process"
	KindLsreg    Kind = "lsreg"
)

// Item actions.
const (
	ActionRemove = "remove"
	ActionKeep   = "keep"
)

// Item is one thing the plan would remove or keeps, with why (spec §4.1).
type Item struct {
	Key        string     `json:"key"`
	Kind       Kind       `json:"kind"`
	Name       string     `json:"name"`
	Branch     string     `json:"branch"`
	Bytes      int64      `json:"bytes"`
	BytesKnown bool       `json:"bytes_known"`
	Action     string     `json:"action"`
	Reason     string     `json:"reason"`
	Detail     string     `json:"detail"`
	Done       bool       `json:"done"`
	Error      string     `json:"error"`
	Owner      *OwnerHint `json:"owner,omitempty"` // sweep only
}

// OwnerHint is the sweep's guess at whose an item is: the session that
// recorded it, or Unknown (a pre-feature or deleted session).
type OwnerHint struct {
	SessionID  int64  `json:"session_id,omitempty"`
	Title      string `json:"title,omitempty"`
	LastActive string `json:"last_active,omitempty"` // RFC 3339
	Unknown    bool   `json:"unknown,omitempty"`
}

// Plan is what an evaluation found. Items is never nil.
type Plan struct {
	Items         []Item `json:"items"`
	DefaultBranch string `json:"default_branch"`
}
