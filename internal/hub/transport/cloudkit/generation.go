package cloudkit

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sync"

	"watchtower/internal/hub/transport"
)

// GenerationFile is where the client keeps, in the hub dir, the bridge
// generation and the zones still pending a rebase onto it (0600, JSON).
const GenerationFile = "bridge.generation"

// ErrStaleTag is a conditional write on a tag_seq that may be of an older
// bridge generation: refused per item, never compared. It wraps
// transport.ErrTokenExpired — read the zone again from 0.
var ErrStaleTag = fmt.Errorf("cloudkit: tag of an older bridge generation: %w", transport.ErrTokenExpired)

// generationState is GenerationFile's content.
type generationState struct {
	Generation string   `json:"generation"`
	Pending    []string `json:"pending,omitempty"` // CloudKit zones not rebased yet
}

// generations tracks the bridge's generation (bridge.proto) against the
// cursors and tags the hub stores. A zone is pending a rebase when the
// bridge's generation changed under it — or when nothing says which
// generation the stored state is of (no GenerationFile: a first start, an
// upgrade, a deleted file). In a pending zone a cursor other than 0 is
// refused (ErrTokenExpired) unless this client handed it out in the current
// generation, and an ExpectSeq only goes out with a tag this client handed
// out in it. The zone stops pending — persisted — only once the consumer
// came back with a cursor of the new generation, which shows it dropped its
// old state; a crash before that leaves the zone pending, so after a
// restart the old cursors and tags are still refused.
type generations struct {
	path  string
	zones []string // the hub's CloudKit zones

	mu     sync.Mutex
	loaded bool
	st     generationState
	issued map[string]map[uint64]bool // ck zone → cursors handed out in this generation
	fresh  map[string]uint64          // ck zone + "\x00" + name → tag handed out in this generation
}

func newGenerations(dir string, zones ...string) *generations {
	return &generations{
		path: filepath.Join(dir, GenerationFile), zones: zones,
		issued: map[string]map[uint64]bool{}, fresh: map[string]uint64{},
	}
}

// current is the generation the client speaks ("" before the first Hello).
func (g *generations) current() string {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.st.Generation
}

// load reads GenerationFile once; g.mu is held. A missing file is every
// zone pending (the stored state's generation is unknown).
func (g *generations) load() error {
	if g.loaded {
		return nil
	}
	b, err := os.ReadFile(g.path)
	switch {
	case errors.Is(err, os.ErrNotExist):
		g.st = generationState{Pending: slices.Clone(g.zones)}
	case err != nil:
		return fmt.Errorf("cloudkit: reading the bridge generation: %w", err)
	default:
		if err := json.Unmarshal(b, &g.st); err != nil {
			// Unreadable: as unknown as a missing file.
			g.st = generationState{Pending: slices.Clone(g.zones)}
		}
		if err := os.Chmod(g.path, 0o600); err != nil {
			return fmt.Errorf("cloudkit: bridge generation mode: %w", err)
		}
	}
	g.loaded = true
	return nil
}

// adopt takes the bridge's generation; it reports whether it differs from
// the one the stored state belongs to. A change makes every zone pending,
// persisted before the call returns.
func (g *generations) adopt(gen string) (changed bool, err error) {
	if gen == "" {
		return false, errors.New("cloudkit: the bridge sent no generation")
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	if err := g.load(); err != nil {
		return false, err
	}
	if gen == g.st.Generation {
		return false, nil
	}
	changed = g.st.Generation != ""
	g.st = generationState{Generation: gen, Pending: slices.Clone(g.zones)}
	g.issued, g.fresh = map[string]map[uint64]bool{}, map[string]uint64{}
	return changed, g.save()
}

// save writes the state through a 0600 temp file beside it, synced, then
// renamed into place; g.mu is held.
func (g *generations) save() error {
	b, err := json.Marshal(g.st)
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(g.path), "."+GenerationFile+"-*")
	if err != nil {
		return fmt.Errorf("cloudkit: storing the bridge generation: %w", err)
	}
	defer func() { _ = os.Remove(tmp.Name()) }()
	if err := tmp.Chmod(0o600); err == nil {
		_, err = tmp.Write(b)
		if err == nil {
			err = tmp.Sync()
		}
		if cerr := tmp.Close(); err == nil {
			err = cerr
		}
		if err == nil {
			err = os.Rename(tmp.Name(), g.path)
		}
		if err != nil {
			return fmt.Errorf("cloudkit: storing the bridge generation: %w", err)
		}
	} else {
		_ = tmp.Close()
		return fmt.Errorf("cloudkit: storing the bridge generation: %w", err)
	}
	return nil
}

func (g *generations) pending(ck string) bool { return slices.Contains(g.st.Pending, ck) }

// sinceOK: a cursor other than 0 may be sent. In a pending zone only one
// this client handed out in the current generation may; that use is the
// consumer's commit to the new generation, so the zone stops pending.
func (g *generations) sinceOK(ck string, since uint64) (bool, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if err := g.load(); err != nil {
		return false, err
	}
	if since == 0 || !g.pending(ck) {
		return true, nil
	}
	if !g.issued[ck][since] {
		return false, nil
	}
	g.st.Pending = slices.DeleteFunc(g.st.Pending, func(z string) bool { return z == ck })
	return true, g.save()
}

// handedOut records a cursor given to the consumer in this generation.
func (g *generations) handedOut(ck string, cursor uint64) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if !g.pending(ck) {
		return
	}
	if g.issued[ck] == nil {
		g.issued[ck] = map[uint64]bool{}
	}
	g.issued[ck][cursor] = true
}

// tagOK: an ExpectSeq tag may be sent — any tag outside a pending zone, in
// one only a tag this client handed out in the current generation.
func (g *generations) tagOK(ck, name string, tag uint64) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if !g.pending(ck) {
		return true
	}
	t, ok := g.fresh[ck+"\x00"+name]
	return ok && t == tag
}

// note records the tag a record has now (0 = deleted).
func (g *generations) note(ck, name string, tag uint64) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if !g.pending(ck) {
		return
	}
	if tag == 0 {
		delete(g.fresh, ck+"\x00"+name)
		return
	}
	g.fresh[ck+"\x00"+name] = tag
}
