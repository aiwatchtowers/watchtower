package inboxfolders

import (
	"errors"
	"fmt"

	"watchtower/internal/db"
)

// The refusals of a folder write. Each write returns one of them (wrapped,
// errors.Is works) with the owner-facing text the CLI prints as is; nothing
// is written when one is returned.
var (
	// ErrRevisionConflict: the tree changed since the caller read it. The
	// returned error is a *ConflictError; the caller re-reads, never retries.
	ErrRevisionConflict = errors.New("the Inbox menu changed")
	// ErrRevisionRequired: a write without an expected revision, refused
	// before anything is read.
	ErrRevisionRequired = errors.New("--expect-revision is required")
	ErrRootFixed        = errors.New("the Inbox folder can't be changed")
	ErrApprovalsFixed   = errors.New("Needs approval can't be moved, renamed, hidden or deleted") //nolint:staticcheck // ST1005: the folder's name, shown to the owner as is
	// ErrApprovalsRouteFixed: the needs-approval built-in routed anywhere
	// but Needs approval.
	ErrApprovalsRouteFixed = errors.New("Needs approval's automation stays in Needs approval") //nolint:staticcheck // ST1005: the folder's name, shown to the owner as is
	// ErrApprovalsHoldsNothingElse: a folder created or moved into Needs
	// approval, or another automation routed there.
	ErrApprovalsHoldsNothingElse = errors.New("Needs approval holds only its own approvals") //nolint:staticcheck // ST1005: the folder's name, shown to the owner as is
	ErrDuplicateTitle            = errors.New("a folder with this name already exists here")
	ErrTooDeep                   = fmt.Errorf("folders nest at most %d deep", MaxDepth)
	ErrTooMany                   = fmt.Errorf("the Inbox holds at most %d folders", MaxOwnerFolders)
	ErrUnknownIcon               = errors.New("unknown icon")
	ErrNoFolder                  = errors.New("no such folder")
	ErrNoAutomation              = errors.New("no such automation")
	ErrCycle                     = errors.New("a folder can't move into itself or a folder inside it")
	ErrBadTitle                  = fmt.Errorf("a folder title is 1 to %d characters on one line", MaxTitleRunes)
	ErrBadPosition               = errors.New("a position can't be negative")
	// ErrRouteTarget: a route names both an existing folder and a new one,
	// or neither.
	ErrRouteTarget = errors.New("a route names either an existing folder or a new title")
)

// ConflictError is the revision refusal: Now is the tree's revision, Given
// the caller's. It is ErrRevisionConflict and unwraps to the db refusal.
type ConflictError struct {
	db *db.ErrInboxRevisionConflict
}

func (e *ConflictError) Error() string {
	return fmt.Sprintf("the Inbox menu changed — reload it and try again (revision %d, you had %d)", e.db.Now, e.db.Given)
}

func (e *ConflictError) Is(target error) bool { return target == ErrRevisionConflict }

func (e *ConflictError) Unwrap() error { return e.db }

// refusal is a sentinel with an owner-facing text naming the value at fault
// (`a folder named "Release" already exists here`, `no folder 7`).
type refusal struct {
	msg  string
	kind error
}

func (r *refusal) Error() string { return r.msg }

func (r *refusal) Unwrap() error { return r.kind }

func refuse(kind error, format string, args ...any) error {
	return &refusal{msg: fmt.Sprintf(format, args...), kind: kind}
}

func noFolder(id int64) error { return refuse(ErrNoFolder, "no folder %d", id) }

func duplicateTitle(title string) error {
	return refuse(ErrDuplicateTitle, "a folder named %q already exists here", title)
}
