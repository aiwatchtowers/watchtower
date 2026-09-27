package confluence

import (
	"runtime"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
)

// A storage body nested a million elements deep cannot blow the daemon's
// memory: golang.org/x/net/html caps its open-element stack at 512 (the
// parse fails there), and every pass before it (CDATA escaping, the
// self-closing rewrite) is a linear scan, so the cost stays proportional
// to the body's size — measured ~10x its bytes — never to its depth. What
// such a body indexes as (today: nothing) is a separate finding; this pins
// only the resource bound. Layout wrappers are included because
// flattenTransparent recurses into them.
func TestStorageDeepNestingIsBounded(t *testing.T) {
	const levels = 1_000_000
	for _, tag := range []string{"div", "ac:layout", "b", "ul"} {
		t.Run(tag, func(t *testing.T) {
			body := strings.Repeat("<"+tag+">", levels) + "deep"
			runtime.GC()
			var before, after runtime.MemStats
			runtime.ReadMemStats(&before)
			assert.NotPanics(t, func() { StorageToSections(body, maxBodyRunes) })
			runtime.ReadMemStats(&after)
			alloc := after.TotalAlloc - before.TotalAlloc
			assert.Less(t, alloc, uint64(40*len(body)), "allocated %d MiB for a %d MiB body", alloc>>20, len(body)>>20)
		})
	}
}
