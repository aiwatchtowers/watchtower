package reviewmap

import (
	"path"
	"regexp"
	"slices"
	"strings"

	"watchtower/internal/reviewdiff"
)

// Level is how dangerous a change is; higher is more dangerous.
type Level int

const (
	Normal Level = iota
	Significant
	Breaking
)

func (l Level) String() string {
	switch l {
	case Breaking:
		return "breaking"
	case Significant:
		return "significant"
	case Normal:
		return "normal"
	}
	return "normal"
}

// Signal ids, in the order Signals reports them.
const (
	sigMigrationEdited = "migration_edited"
	sigAPIRemoved      = "api_removed"
	sigTestDeleted     = "test_deleted"
	sigMigrationAdded  = "migration_added"
	sigDependency      = "dependency"
	sigCI              = "ci"
	sigSecurityPath    = "security_path"
	sigFileDeleted     = "file_deleted"
	repoSignalPrefix   = "repo:"
)

var signalLevels = map[string]Level{
	sigMigrationEdited:                      Breaking,
	sigAPIRemoved:                           Breaking,
	sigTestDeleted:                          Breaking,
	sigMigrationAdded:                       Significant,
	sigDependency:                           Significant,
	sigCI:                                   Significant,
	sigSecurityPath:                         Significant,
	sigFileDeleted:                          Significant,
	repoSignalPrefix + Breaking.String():    Breaking,
	repoSignalPrefix + Significant.String(): Significant,
}

var dependencyFiles = []string{"go.mod", "package.json", "Package.swift", "composer.json", "Cargo.toml",
	"pyproject.toml", "Gemfile", "pom.xml"}

var dependencyGlobs = []string{"requirements*.txt", "build.gradle*"}

var securityWords = []string{"auth", "token", "secret", "credential", "permission", "policy", "crypto",
	"keychain", "oauth"}

var (
	// An exported Go func/method/type/const/var declared on a diff line.
	goDecl = regexp.MustCompile(`^[-+]\s*(?:func(?: \([^)]*\))? |type |(?:const|var) )([A-Z]\w*)`)
	// A Swift public/package/open declaration on a diff line: attributes and
	// other modifiers may come before or after the access keyword.
	swiftDecl = regexp.MustCompile(`^[-+]\s*(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:[\w()]+\s+)*?(?:public|package|open)\s+` +
		`(?:[\w()]+\s+)*?(?:(?:func|var|let|class|struct|enum|protocol|typealias|actor|associatedtype)\s+` +
		"`?" + `(\w+)|(init|subscript)\b)`)
)

// Signals lists f's danger signal ids, in a fixed order, from its path,
// status and diff lines only.
func Signals(f reviewdiff.File, p Patterns) []string {
	var out []string
	migration := inMigrations(f.Path) || (f.Status == "renamed" && inMigrations(f.OldPath))
	// A file moved into migrations/ from elsewhere is a new migration; a
	// rename within or out of migrations/ edits an applied one.
	migrationAdded := migration && (f.Status == "added" || (f.Status == "renamed" && !inMigrations(f.OldPath)))
	deleted := f.Status == "deleted"
	if migration && !migrationAdded {
		out = append(out, sigMigrationEdited)
	}
	if apiRemoved(f) {
		out = append(out, sigAPIRemoved)
	}
	testDeleted := deleted && IsTest(f.Path)
	if testDeleted {
		out = append(out, sigTestDeleted)
	}
	if migrationAdded {
		out = append(out, sigMigrationAdded)
	}
	base := path.Base(f.Path)
	if isDependencyFile(base) {
		out = append(out, sigDependency)
	}
	if isCI(f.Path, base) {
		out = append(out, sigCI)
	}
	if isSecurityPath(f.Path) {
		out = append(out, sigSecurityPath)
	}
	if deleted && !testDeleted && !migration && !IsNoise(f, p) {
		out = append(out, sigFileDeleted)
	}
	if level, skip, ok := p.Match(f.Path); ok && !skip {
		out = append(out, repoSignalPrefix+level.String())
	}
	return out
}

// LevelOf is the highest level among signals (Normal for none).
func LevelOf(signals []string) Level {
	level := Normal
	for _, s := range signals {
		level = max(level, signalLevels[s])
	}
	return level
}

func dirSegments(p string) []string {
	segs := strings.Split(p, "/")
	return segs[:len(segs)-1]
}

func inMigrations(p string) bool {
	return p != "" && slices.Contains(dirSegments(p), "migrations")
}

func isDependencyFile(base string) bool {
	if slices.Contains(dependencyFiles, base) {
		return true
	}
	for _, g := range dependencyGlobs {
		if ok, _ := path.Match(g, base); ok {
			return true
		}
	}
	return false
}

func isCI(p, base string) bool {
	if strings.HasPrefix(p, ".github/workflows/") || base == ".gitlab-ci.yml" || base == "Jenkinsfile" ||
		strings.HasPrefix(base, "Dockerfile") {
		return true
	}
	for _, d := range dirSegments(p) {
		if d == ".circleci" || d == "helm" || d == "charts" {
			return true
		}
	}
	return false
}

func isSecurityPath(p string) bool {
	for _, seg := range strings.Split(strings.ToLower(p), "/") {
		for _, w := range securityWords {
			if strings.Contains(seg, w) {
				return true
			}
		}
	}
	return false
}

// apiRemoved: a removed line declares an exported Go name (.go files) or a
// Swift public/package/open name (.swift files) that no added line of the
// same file declares again.
func apiRemoved(f reviewdiff.File) bool {
	var decl *regexp.Regexp
	switch path.Ext(f.Path) {
	case ".go":
		decl = goDecl
	case ".swift":
		decl = swiftDecl
	default:
		return false
	}
	removed := map[string]bool{}
	added := map[string]bool{}
	for _, h := range f.Hunks {
		for _, line := range h.Lines {
			if line == "" || (line[0] != '-' && line[0] != '+') {
				continue
			}
			m := decl.FindStringSubmatch(line)
			if m == nil {
				continue
			}
			name := m[1]
			if len(m) > 2 && name == "" {
				name = m[2]
			}
			if line[0] == '-' {
				removed[name] = true
			} else {
				added[name] = true
			}
		}
	}
	for name := range removed {
		if !added[name] {
			return true
		}
	}
	return false
}
