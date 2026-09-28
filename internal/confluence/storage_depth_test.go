package confluence

import (
	"runtime"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/extsync"
)

// A storage body nested a million elements deep cannot blow the daemon's
// memory: golang.org/x/net/html caps its open-element stack at 512 (the
// parse fails there), and every pass before it (CDATA escaping, the
// self-closing rewrite) is a linear scan, so the cost stays proportional
// to the body's size — measured ~10x its bytes — never to its depth. Past
// the cap, StorageToSections falls back to a flat, tag-blind text strip
// (fallbackText) instead of indexing the page as empty; that fallback is
// itself just one more linear tokenizer pass, so the resource bound holds
// for it too. Layout wrappers are included because flattenTransparent
// recurses into them.
func TestStorageDeepNestingIsBounded(t *testing.T) {
	const levels = 1_000_000
	for _, tag := range []string{"div", "ac:layout", "b", "ul"} {
		t.Run(tag, func(t *testing.T) {
			body := strings.Repeat("<"+tag+">", levels) + "deep"
			runtime.GC()
			var before, after runtime.MemStats
			runtime.ReadMemStats(&before)
			var sections []extsync.Section
			var parseErr error
			assert.NotPanics(t, func() { sections, _, _, parseErr = StorageToSections(body, maxBodyRunes) })
			runtime.ReadMemStats(&after)
			alloc := after.TotalAlloc - before.TotalAlloc
			assert.Less(t, alloc, uint64(40*len(body)), "allocated %d MiB for a %d MiB body", alloc>>20, len(body)>>20)
			require.Error(t, parseErr, "a body this deep must overflow the tree builder's stack")
			require.Len(t, sections, 1)
			assert.Contains(t, sections[0].Text, "deep", "the fallback strip must still surface the body's text")
		})
	}
}
