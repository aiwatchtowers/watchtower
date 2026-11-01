package cloudkit

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"

	"watchtower/internal/hub/transport"
)

// GenerationFile is where the client keeps, in the hub dir, the bridge
// generation the hub's stored cursors and tags belong to (0600).
const GenerationFile = "bridge.generation"

// ErrStaleTag is a conditional write on a tag_seq of an older bridge
// generation: refused per item, never compared. It wraps
// transport.ErrTokenExpired — read the zone again from 0.
var ErrStaleTag = fmt.Errorf("cloudkit: tag of an older bridge generation: %w", transport.ErrTokenExpired)

// generations tracks the bridge's generation (bridge.proto). The cursors and
// tags the hub stores came from the generation in GenerationFile; when the
// bridge answers with another one (its bridge.db was lost or recreated),
// every zone's stored cursor is stale until the zone is read again from 0,
// and an ExpectSeq is sent only with a tag this client was handed in the new
// generation.
type generations struct {
	path string

	mu       sync.Mutex
	gen      string
	rebased  bool              // the generation changed under the stored state
	cursorOK map[string]bool   // ck zone → read from 0 since the change
	fresh    map[string]uint64 // ck zone + "\x00" + name → tag handed out since the change
}

func newGenerations(dir string) *generations {
	return &generations{path: filepath.Join(dir, GenerationFile)}
}

// current is the generation the client speaks ("" before the first Hello).
func (g *generations) current() string {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.gen
}

// adopt takes the bridge's generation; it reports whether it differs from
// the one the stored state belongs to.
func (g *generations) adopt(gen string) (changed bool, err error) {
	if gen == "" {
		return false, errors.New("cloudkit: the bridge sent no generation")
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	if gen == g.gen {
		return false, nil
	}
	if g.gen == "" {
		prev, err := os.ReadFile(g.path)
		switch {
		case err == nil && string(prev) == gen:
			g.gen = gen
			return false, nil
		case errors.Is(err, os.ErrNotExist):
			// No stored state of any generation yet.
			g.gen = gen
			return false, g.write(gen)
		case err != nil:
			return false, fmt.Errorf("cloudkit: reading the bridge generation: %w", err)
		}
	}
	g.gen, g.rebased = gen, true
	g.cursorOK, g.fresh = map[string]bool{}, map[string]uint64{}
	return true, g.write(gen)
}

func (g *generations) write(gen string) error {
	if err := os.WriteFile(g.path, []byte(gen), 0o600); err != nil {
		return fmt.Errorf("cloudkit: storing the bridge generation: %w", err)
	}
	return nil
}

// sinceOK: a since ≠ 0 is read only in a zone that was read from 0 under
// the current generation (or when it never changed).
func (g *generations) sinceOK(ck string, since uint64) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	return since == 0 || !g.rebased || g.cursorOK[ck]
}

// readFromZero marks ck read from 0 under the current generation.
func (g *generations) readFromZero(ck string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.rebased {
		g.cursorOK[ck] = true
	}
}

// tagOK: an ExpectSeq tag may be sent (it is this generation's).
func (g *generations) tagOK(ck, name string, tag uint64) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if !g.rebased {
		return true
	}
	t, ok := g.fresh[ck+"\x00"+name]
	return ok && t == tag
}

// note records the tag a record has now (0 = deleted).
func (g *generations) note(ck, name string, tag uint64) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if !g.rebased {
		return
	}
	if tag == 0 {
		delete(g.fresh, ck+"\x00"+name)
		return
	}
	g.fresh[ck+"\x00"+name] = tag
}
