package sessioncleanup

import "sync"

// Observer hears a plan or an apply as it goes (spec §6): the CLI's
// --stream writes one JSON line per call. It only reports: no catch, order
// or re-check depends on it (PROJ-18). Calls never overlap.
type Observer interface {
	// Listed: the candidates from the git listing, before any catch
	// (Action ""). A branch checked out in a listed worktree arrives with
	// it through Checked instead.
	Listed(items []Item)
	// Checked: an item with its action and reason; a worktree's bundles
	// and orphans right after it.
	Checked(item Item)
	// Sized: a worktree to remove, measured.
	Sized(key string, bytes int64, known bool)
	// Removing: apply only, before the item is acted on.
	Removing(key string)
	// Removed: apply only, the item as it ended (done, kept or error).
	Removed(item Item)
}

// reporter serialises the calls to an Observer; a nil one reports nothing.
type reporter struct {
	mu  sync.Mutex
	obs Observer
}

func (r *reporter) call(f func(Observer)) {
	if r == nil || r.obs == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	f(r.obs)
}

func (r *reporter) listed(items []Item) { r.call(func(o Observer) { o.Listed(items) }) }

func (r *reporter) checked(items ...Item) {
	r.call(func(o Observer) {
		for _, it := range items {
			o.Checked(it)
		}
	})
}

func (r *reporter) sized(key string, bytes int64, known bool) {
	r.call(func(o Observer) { o.Sized(key, bytes, known) })
}

func (r *reporter) removing(key string) { r.call(func(o Observer) { o.Removing(key) }) }

func (r *reporter) removed(it Item) { r.call(func(o Observer) { o.Removed(it) }) }
