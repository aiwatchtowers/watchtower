package planusage

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"testing"

	"github.com/stretchr/testify/require"
)

// The Desktop decoder rejects an unknown error code, so the Swift list must
// equal the Go public set exactly.
func TestPlanUsageCodes_SwiftPublicSetMatches(t *testing.T) {
	path := filepath.Join(moduleRoot(t), "WatchtowerDesktop", "Sources", "WatchtowerCore", "Models", "PlansUsage.swift")
	src, err := os.ReadFile(path)
	require.NoError(t, err)
	decl := regexp.MustCompile(`(?s)struct PlansOperationError\b.*?static let codes = \[(.*?)\]`).FindSubmatch(src)
	require.NotNil(t, decl, "PlansOperationError.codes not found")
	var swift []string
	for _, m := range regexp.MustCompile(`"([^"]*)"`).FindAllSubmatch(decl[1], -1) {
		swift = append(swift, string(m[1]))
	}
	var goCodes []string
	for c := range publicCodes {
		goCodes = append(goCodes, c)
	}
	sort.Strings(swift)
	sort.Strings(goCodes)
	require.Equal(t, goCodes, swift)
}
