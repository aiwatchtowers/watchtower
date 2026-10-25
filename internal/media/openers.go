package media

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"watchtower/internal/db"
)

// Opener reads one item's bytes for the pass. limit is the download cap: an
// opener that knows the size refuses more with ErrTooLarge (the pass caps
// the read itself as well). The media type is the declared one, never
// trusted for what is sent. ErrGone ends the item unreachable; any other
// error is a failed attempt.
type Opener interface {
	Open(ctx context.Context, it db.MediaItem, limit int64) (io.ReadCloser, string, error)
}

// Resolver turns an item that only refers to another item (a Confluence
// inline image naming its page's attachment) into that item. A nil target
// and nil error: the item is no reference, the pass opens it as usual. A
// target that is ok is copied, one still pending or unavailable is waited
// for (the row stays as it is), any other target status ends the item
// unreachable, and so does ErrGone; another error is a failed attempt.
type Resolver interface {
	Resolve(ctx context.Context, it db.MediaItem) (target *db.MediaItem, err error)
}

// LocalOpener opens the owner's own uploads (chat attachments, workbench
// target images): an absolute locator whose resolved path lies under one of
// Roots (<workspace>/chat_files, <workspace>/project_files), opened once
// with O_NOFOLLOW and read only through that descriptor, which must be a
// regular file. Anything else is ErrGone.
type LocalOpener struct {
	Roots []string
}

// beforeLocalOpen runs between the root check and the open (a test seam for
// a path swapped in that window); nil in production.
var beforeLocalOpen func(path string)

func (o LocalOpener) Open(_ context.Context, it db.MediaItem, limit int64) (io.ReadCloser, string, error) {
	if !filepath.IsAbs(it.Locator) {
		return nil, "", ErrGone
	}
	resolved, err := filepath.EvalSymlinks(it.Locator)
	if err != nil || !o.underRoot(resolved) {
		return nil, "", ErrGone
	}
	if beforeLocalOpen != nil {
		beforeLocalOpen(resolved)
	}
	// O_NONBLOCK: a FIFO swapped in must not block the open; it is refused
	// below as not regular.
	f, err := os.OpenFile(resolved, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, "", ErrGone
	}
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() {
		_ = f.Close()
		return nil, "", ErrGone
	}
	if info.Size() > limit {
		_ = f.Close()
		return nil, "", ErrTooLarge
	}
	return f, it.MediaType, nil
}

// underRoot reports a resolved path strictly inside one of the resolved roots.
func (o LocalOpener) underRoot(path string) bool {
	for _, root := range o.Roots {
		r, err := filepath.EvalSymlinks(root)
		if err != nil {
			continue
		}
		rel, err := filepath.Rel(r, path)
		if err == nil && rel != "." && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) && !filepath.IsAbs(rel) {
			return true
		}
	}
	return false
}
