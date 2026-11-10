package reviewmap

import (
	"testing"

	"watchtower/internal/reviewdiff"
)

func TestIsNoise(t *testing.T) {
	p := ParsePatterns("## Can skip\n- docs/generated/**\n- *.lock.json\n## Breaking\n- api/**\n")
	cases := []struct {
		name string
		f    reviewdiff.File
		want bool
	}{
		{"lockfile", reviewdiff.File{Path: "go.sum"}, true},
		{"nested lockfile", reviewdiff.File{Path: "web/package-lock.json"}, true},
		{"generated pb", reviewdiff.File{Path: "internal/x/a.pb.go"}, true},
		{"golden suffix", reviewdiff.File{Path: "internal/x/out.golden"}, true},
		{"testdata segment", reviewdiff.File{Path: "internal/x/testdata/in.json"}, true},
		{"Fixtures segment", reviewdiff.File{Path: "Tests/Fixtures/a.json"}, true},
		{"fixtures segment", reviewdiff.File{Path: "spec/fixtures/a.yml"}, true},
		{"snapshots segment", reviewdiff.File{Path: "web/__snapshots__/a.js"}, true},
		{"golden segment", reviewdiff.File{Path: "internal/golden/a.txt"}, true},
		{"snap suffix", reviewdiff.File{Path: "web/a.test.js.snap"}, true},
		{"pbxproj", reviewdiff.File{Path: "App/App.pbxproj"}, true},
		{"inside xcodeproj", reviewdiff.File{Path: "App/App.xcodeproj/xcshareddata/x.xcscheme"}, true},
		{"binary", reviewdiff.File{Path: "assets/logo.png", Binary: true}, true},
		{"repo can skip glob", reviewdiff.File{Path: "docs/generated/a/b.md"}, true},
		{"repo can skip top-level only", reviewdiff.File{Path: "x.lock.json"}, true},
		{"repo can skip is per segment", reviewdiff.File{Path: "web/x.lock.json"}, false},
		{"ordinary source", reviewdiff.File{Path: "internal/x/a.go"}, false},
		{"too large is not noise", reviewdiff.File{Path: "internal/x/big.go", CollapsedReason: "too_large"}, false},
		{"breaking pattern is not noise", reviewdiff.File{Path: "api/a.go"}, false},
		{"name containing testdata", reviewdiff.File{Path: "internal/mytestdata/a.go"}, false},
	}
	for _, c := range cases {
		if got := IsNoise(c.f, p); got != c.want {
			t.Errorf("%s: IsNoise(%q) = %v, want %v", c.name, c.f.Path, got, c.want)
		}
	}
}
