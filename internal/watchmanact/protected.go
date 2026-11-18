package watchmanact

import (
	"cmp"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
)

// Behavior contracts and guard tests are the owner's (spec
// 2026-11-16-watchman-design §5, D46, WATCHMAN-01): before any twin Approve
// Go — never the model — checks whether the reviewed change or document
// touches one, and parks when it does or when that cannot be told (fail
// closed).

// ProtectedReason is the park reason when either check says protected.
const ProtectedReason = "approving a change to a behavior contract or a guard test is yours"

// inventoryPath is where the behavior inventory lives in a repository.
const inventoryPath = "docs/inventory/"

// inventoryName is that directory named anywhere in a document, with or
// without its trailing slash (fail closed).
const inventoryName = "docs/inventory"

// guardDeclRe is a guard test's declaration in Go or Swift:
// func Test<Module>NN_… or func test<Module>NN_….
var guardDeclRe = regexp.MustCompile(`\bfunc\s+[Tt]est[A-Za-z]+[0-9]{2}_`)

// ProtectedChange reports whether a diff round touches a behavior contract or
// a guard test: a path (old or new side) under docs/inventory/, or a hunk of
// diff (unified, as git prints it) whose header or lines — added, removed or
// context — declare a guard test. The string names the reason.
func ProtectedChange(paths []string, diff string) (string, bool) {
	for _, p := range paths {
		p = strings.TrimPrefix(filepath.ToSlash(p), "./")
		if strings.HasPrefix(p, inventoryPath) || p+"/" == inventoryPath {
			return "the change touches " + p, true
		}
	}
	inHunk := false
	for line := range strings.SplitSeq(diff, "\n") {
		switch {
		case strings.HasPrefix(line, "diff --git "):
			inHunk = false
			continue
		case strings.HasPrefix(line, "@@"):
			inHunk = true
		case !inHunk:
			continue
		}
		if m := guardDeclRe.FindString(line); m != "" {
			return "the change touches guard test " + strings.TrimSpace(strings.TrimPrefix(m, "func")), true
		}
	}
	return "", false
}

// guardNameRe is a guard test's name anywhere in a document.
var guardNameRe = regexp.MustCompile(`Test[A-Z][A-Za-z]*[0-9]{2}_`)

// contractHeadingRe is an inventory contract's heading: "## <ID> — <title>".
var contractHeadingRe = regexp.MustCompile(`(?m)^##\s+([A-Z][A-Z0-9]*(?:-[A-Z][A-Z0-9]*)*)-([0-9]+)\s+[—–-]\s`)

// noChangeRe is a line's explicit "this contract is not changed" marker.
var noChangeRe = regexp.MustCompile(`(?i)\b(unchanged|not changed|no change|does not change|untouched|stays as is)\b`)

// ProtectedDoc reports whether a spec or plan's whole snapshot may change a
// behavior contract (D46): anywhere in it a docs/inventory/ path or a guard
// test name; or a line (a list item, a table row, a prose line — never a
// paragraph) naming a contract id of inventoryDir's headings or a family
// wildcard of their prefixes (REVIEW-0x), matched in any case, unless that
// line names exactly one id and is one clause saying it is not changed (no
// ";", ".", ":", ",", "but" or "and" on it but a closing mark). A
// "PROJ-12/21" shorthand is two ids; a wildcard is never exactly one. An inventoryDir that exists but cannot be
// read, or holds files with no contract heading, parks ("inventory
// unreadable"); an absent one gives no ids.
func ProtectedDoc(inventoryDir, snapshot string) (string, bool) {
	if strings.Contains(snapshot, inventoryName) {
		return "the document names " + inventoryName, true
	}
	if m := guardNameRe.FindString(snapshot); m != "" {
		return "the document names guard test " + m, true
	}
	prefixes, err := contractPrefixes(inventoryDir)
	if err != nil {
		return "inventory unreadable", true
	}
	if len(prefixes) == 0 {
		return "", false
	}
	idRe, wildRe := contractRes(prefixes)
	for i, line := range strings.Split(snapshot, "\n") {
		ids := 0
		for _, m := range idRe.FindAllStringSubmatch(line, -1) {
			ids += 1 + strings.Count(m[1], "/")
		}
		wild := wildRe.MatchString(line)
		if ids == 0 && !wild {
			continue
		}
		if ids == 1 && !wild && noChangeRe.MatchString(line) && singleClause(line) {
			continue
		}
		return fmt.Sprintf("line %d names a behavior contract", i+1), true
	}
	return "", false
}

// contractPrefixes reads the contract id prefixes (PROJ, TGT-BRIEF) of the
// "## <ID> —" headings of dir's *.md files. An absent dir gives none; a dir
// that cannot be read, or whose files hold no heading, is an error.
func contractPrefixes(dir string) (map[string]bool, error) {
	if _, err := os.Stat(dir); os.IsNotExist(err) {
		return nil, nil
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	out := map[string]bool{}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".md") {
			continue
		}
		b, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			return nil, err
		}
		for _, m := range contractHeadingRe.FindAllStringSubmatch(string(b), -1) {
			out[m[1]] = true
		}
	}
	if len(out) == 0 && len(entries) > 0 {
		return nil, fmt.Errorf("%s holds no contract heading", dir)
	}
	return out, nil
}

// contractRes builds the id matcher (<PREFIX>-NN, with "/NN" shorthands as
// group 2) and the family wildcard matcher (<PREFIX>-[0-9]*x) of prefixes.
func contractRes(prefixes map[string]bool) (id, wild *regexp.Regexp) {
	alts := make([]string, 0, len(prefixes))
	for p := range prefixes {
		alts = append(alts, regexp.QuoteMeta(p))
	}
	// Longest first, so TGT-BRIEF is tried before TGT.
	slices.SortFunc(alts, func(a, b string) int { return cmp.Or(len(b)-len(a), strings.Compare(a, b)) })
	group := `(?:` + strings.Join(alts, "|") + `)`
	id = regexp.MustCompile(`(?i)\b` + group + `-[0-9]+((?:/[0-9]+)*)\b`)
	wild = regexp.MustCompile(`(?i)\b` + group + `-[0-9]*x\b`)
	return id, wild
}

// listMarkRe is a leading list or quote mark: "- ", "* ", "1. ", "> ".
var listMarkRe = regexp.MustCompile(`^\s*(?:[-*+>]|[0-9]+[.)])\s+`)

// clauseSepRe separates clauses: punctuation, "but", "and".
var clauseSepRe = regexp.MustCompile(`(?i)[;.:,]|\b(?:but|and)\b`)

// singleClause reports a line that is one clause: after its list mark and
// any closing punctuation, nothing separates it into two (table pipes and
// emphasis marks are not clauses).
func singleClause(line string) bool {
	t := strings.TrimRight(listMarkRe.ReplaceAllString(line, ""), " \t.;:,|*_`")
	n := 0
	for _, part := range clauseSepRe.Split(t, -1) {
		if strings.Trim(part, " \t|*_`#>") != "" {
			n++
		}
	}
	return n == 1
}
