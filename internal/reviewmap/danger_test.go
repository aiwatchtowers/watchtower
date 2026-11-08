package reviewmap

import (
	"slices"
	"testing"

	"watchtower/internal/reviewdiff"
)

func hunk(lines ...string) []reviewdiff.Hunk {
	return []reviewdiff.Hunk{{Lines: lines}}
}

func TestSignals(t *testing.T) {
	p := ParsePatterns("## Breaking\n- docs/inventory/**\n## Significant\n- internal/tools/**\n## Can skip\n- vendor/**\n")
	cases := []struct {
		name string
		f    reviewdiff.File
		want []string
	}{
		{"migration edited", reviewdiff.File{Path: "internal/db/migrations/00001_init.sql", Status: "modified"},
			[]string{"migration_edited"}},
		{"migration deleted", reviewdiff.File{Path: "internal/db/migrations/00001_init.sql", Status: "deleted"},
			[]string{"migration_edited"}},
		{"migration added", reviewdiff.File{Path: "internal/db/migrations/00174_x.sql", Status: "added"},
			[]string{"migration_added"}},
		{"migration renamed away", reviewdiff.File{Path: "internal/db/old/00001.sql", OldPath: "internal/db/migrations/00001.sql", Status: "renamed"},
			[]string{"migration_edited"}},
		{"migration renamed within", reviewdiff.File{Path: "internal/db/migrations/00175_x.sql", OldPath: "internal/db/migrations/00174_x.sql", Status: "renamed"},
			[]string{"migration_edited"}},
		{"migration moved in", reviewdiff.File{Path: "internal/db/migrations/00175_x.sql", OldPath: "drafts/00175_x.sql", Status: "renamed"},
			[]string{"migration_added"}},
		{"go func removed", reviewdiff.File{Path: "a/a.go", Status: "modified", Hunks: hunk(" x", "-func Foo(a int) {", "+// gone")},
			[]string{"api_removed"}},
		{"go method removed", reviewdiff.File{Path: "a/a.go", Status: "modified", Hunks: hunk("-func (r *Repo) Walk(ctx context.Context) error {")},
			[]string{"api_removed"}},
		{"go type removed", reviewdiff.File{Path: "a/a.go", Status: "modified", Hunks: hunk("-type Thing struct {")},
			[]string{"api_removed"}},
		{"go const removed", reviewdiff.File{Path: "a/a.go", Status: "modified", Hunks: hunk("-\tconst Max = 3")},
			[]string{"api_removed"}},
		{"go var removed", reviewdiff.File{Path: "a/a.go", Status: "modified", Hunks: hunk("-var Default = x")},
			[]string{"api_removed"}},
		{"go rename in place", reviewdiff.File{Path: "a/a.go", Status: "modified", Hunks: hunk("-func Foo(a int) {", "+func Foo(a, b int) {")},
			nil},
		{"go rename in place across hunks", reviewdiff.File{Path: "a/a.go", Status: "modified", Hunks: []reviewdiff.Hunk{
			{Lines: []string{"-func Foo() {"}}, {Lines: []string{"+func Foo() {"}}}},
			nil},
		{"go unexported removed", reviewdiff.File{Path: "a/a.go", Status: "modified", Hunks: hunk("-func foo() {", "-type bar int")},
			nil},
		{"go-looking line in markdown", reviewdiff.File{Path: "docs/a.md", Status: "modified", Hunks: hunk("-func Foo() {")},
			nil},
		{"swift public func removed", reviewdiff.File{Path: "Sources/A.swift", Status: "modified", Hunks: hunk("-    public func load(id: Int) -> Thing {")},
			[]string{"api_removed"}},
		{"swift package static func removed", reviewdiff.File{Path: "Sources/A.swift", Status: "modified", Hunks: hunk("-    package static func isTest(_ path: String) -> Bool {")},
			[]string{"api_removed"}},
		{"swift open class removed", reviewdiff.File{Path: "Sources/A.swift", Status: "modified", Hunks: hunk("-@MainActor open class Model {")},
			[]string{"api_removed"}},
		{"swift public rename in place", reviewdiff.File{Path: "Sources/A.swift", Status: "modified", Hunks: hunk("-    public var name: String", "+    public var name: String?")},
			nil},
		{"swift operator removed", reviewdiff.File{Path: "Sources/A.swift", Status: "modified", Hunks: hunk("-    public static func ==(a: A, b: A) -> Bool {")},
			[]string{"api_removed"}},
		{"swift spaced operator removed", reviewdiff.File{Path: "Sources/A.swift", Status: "modified", Hunks: hunk("-    public static func + (a: A) -> A {")},
			[]string{"api_removed"}},
		{"swift operator re-added", reviewdiff.File{Path: "Sources/A.swift", Status: "modified", Hunks: hunk("-    public static func ==(a: A, b: A) -> Bool {", "+    public static func == (a: A, b: A) -> Bool {")},
			nil},
		{"swift generic func re-added", reviewdiff.File{Path: "Sources/A.swift", Status: "modified", Hunks: hunk("-    public func load<T>(_ t: T) {", "+    public func load<U>(_ u: U) {")},
			nil},
		{"swift internal removed", reviewdiff.File{Path: "Sources/A.swift", Status: "modified", Hunks: hunk("-    func load() {", "-    private var x = 1")},
			nil},
		{"test deleted", reviewdiff.File{Path: "a/a_test.go", Status: "deleted"},
			[]string{"test_deleted"}},
		{"non-test deleted", reviewdiff.File{Path: "a/a.txt", Status: "deleted"},
			[]string{"file_deleted"}},
		{"noise deleted", reviewdiff.File{Path: "a/testdata/x.json", Status: "deleted"},
			nil},
		{"binary deleted", reviewdiff.File{Path: "assets/logo.png", Status: "deleted", Binary: true},
			nil},
		{"repo breaking deleted", reviewdiff.File{Path: "docs/inventory/old.md", Status: "deleted"},
			[]string{"file_deleted", "repo:breaking"}},
		{"test modified", reviewdiff.File{Path: "a/a_test.go", Status: "modified"},
			nil},
		{"go.mod", reviewdiff.File{Path: "go.mod", Status: "modified"}, []string{"dependency"}},
		{"nested package.json", reviewdiff.File{Path: "web/package.json", Status: "modified"}, []string{"dependency"}},
		{"Package.swift", reviewdiff.File{Path: "WatchtowerKit/Package.swift", Status: "modified"}, []string{"dependency"}},
		{"requirements-dev.txt", reviewdiff.File{Path: "requirements-dev.txt", Status: "modified"}, []string{"dependency"}},
		{"build.gradle.kts", reviewdiff.File{Path: "app/build.gradle.kts", Status: "modified"}, []string{"dependency"}},
		{"pom.xml", reviewdiff.File{Path: "pom.xml", Status: "added"}, []string{"dependency"}},
		{"workflow", reviewdiff.File{Path: ".github/workflows/ci.yml", Status: "modified"}, []string{"ci"}},
		{"gitlab", reviewdiff.File{Path: ".gitlab-ci.yml", Status: "modified"}, []string{"ci"}},
		{"circleci", reviewdiff.File{Path: ".circleci/config.yml", Status: "modified"}, []string{"ci"}},
		{"Jenkinsfile", reviewdiff.File{Path: "Jenkinsfile", Status: "modified"}, []string{"ci"}},
		{"Dockerfile variant", reviewdiff.File{Path: "deploy/Dockerfile.dev", Status: "modified"}, []string{"ci"}},
		{"helm dir", reviewdiff.File{Path: "deploy/helm/values.yaml", Status: "modified"}, []string{"ci"}},
		{"charts dir", reviewdiff.File{Path: "charts/app/values.yaml", Status: "modified"}, []string{"ci"}},
		{"security base name case-insensitive", reviewdiff.File{Path: "Sources/OAuthClient.swift", Status: "modified"}, []string{"security_path"}},
		{"security dir", reviewdiff.File{Path: "internal/policy/policy.go", Status: "modified"}, []string{"security_path"}},
		{"security keychain", reviewdiff.File{Path: "Sources/KeychainStore.swift", Status: "modified"}, []string{"security_path"}},
		{"repo breaking", reviewdiff.File{Path: "docs/inventory/review.md", Status: "modified"}, []string{"repo:breaking"}},
		{"repo significant", reviewdiff.File{Path: "internal/tools/registry.go", Status: "modified"}, []string{"repo:significant"}},
		{"repo skip gives no signal", reviewdiff.File{Path: "vendor/x/a.go", Status: "modified"}, nil},
		{"plain change", reviewdiff.File{Path: "internal/x/a.go", Status: "modified", Hunks: hunk("-a := 1", "+a := 2")}, nil},
		{"several signals in table order", reviewdiff.File{Path: "internal/auth/migrations/00002.sql", Status: "deleted"},
			[]string{"migration_edited", "security_path"}},
	}
	for _, c := range cases {
		got := Signals(c.f, p)
		if !slices.Equal(got, c.want) {
			t.Errorf("%s: Signals(%q) = %v, want %v", c.name, c.f.Path, got, c.want)
		}
	}
}

func TestLevelOf(t *testing.T) {
	cases := []struct {
		signals []string
		want    Level
	}{
		{nil, Normal},
		{[]string{"dependency"}, Significant},
		{[]string{"ci", "api_removed"}, Breaking},
		{[]string{"migration_added", "security_path", "file_deleted"}, Significant},
		{[]string{"migration_edited"}, Breaking},
		{[]string{"test_deleted"}, Breaking},
		{[]string{"repo:significant"}, Significant},
		{[]string{"repo:breaking", "dependency"}, Breaking},
		{[]string{"repo:normal"}, Normal},
		{[]string{"unknown"}, Normal},
	}
	for _, c := range cases {
		if got := LevelOf(c.signals); got != c.want {
			t.Errorf("LevelOf(%v) = %v, want %v", c.signals, got, c.want)
		}
	}
}

func TestLevelString(t *testing.T) {
	if Normal >= Significant || Significant >= Breaking {
		t.Fatal("levels must order Normal < Significant < Breaking")
	}
	for l, want := range map[Level]string{Normal: "normal", Significant: "significant", Breaking: "breaking"} {
		if l.String() != want {
			t.Errorf("%d.String() = %q, want %q", l, l.String(), want)
		}
	}
}
