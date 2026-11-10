package reviewmap

import (
	"strings"

	"watchtower/internal/reviewdiff"
)

var noiseSegments = map[string]bool{
	"testdata": true, "Fixtures": true, "fixtures": true, "__snapshots__": true, "golden": true,
}

// IsNoise reports whether f goes to the "Can skip" chapter and is never sent
// to a model: a lockfile or generated file (reviewdiff.CollapsedReason), a
// testdata/fixtures/snapshots/golden path segment, a .snap or .pbxproj file
// or anything inside an .xcodeproj, a binary file, or a "Can skip" pattern.
func IsNoise(f reviewdiff.File, p Patterns) bool {
	if f.Binary || reviewdiff.CollapsedReason(f.Path) != "" {
		return true
	}
	segs := strings.Split(f.Path, "/")
	for i, seg := range segs {
		if noiseSegments[seg] {
			return true
		}
		if i < len(segs)-1 && strings.HasSuffix(seg, ".xcodeproj") {
			return true
		}
	}
	base := segs[len(segs)-1]
	if strings.HasSuffix(base, ".snap") || strings.HasSuffix(base, ".pbxproj") {
		return true
	}
	_, skip, _ := p.Match(f.Path)
	return skip
}
