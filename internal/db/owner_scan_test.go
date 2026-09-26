package db

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"testing"
)

// ownerScanMinFiles is the coverage floor: a scan pointed at the wrong root
// walks nothing and passes for the wrong reason.
const ownerScanMinFiles = 300

// accountOneOwnerRead is the SQL shape of a direct owner read — a Slack
// account's current_user_id selected on its own instead of through the
// resolver. Whitespace- and case-tolerant, so a reflowed query still matches.
// Per-account reads (internal/inbox, internal/db/slack_accounts.go) select
// current_user_id through slackAccountColumns and never match. Out of the
// scan's reach: a typed read such as GetSlackAccount(1).CurrentUserID.
var accountOneOwnerRead = regexp.MustCompile(`(?i)current_user_id\s+FROM\s+slack_accounts\b`)

// TestOwner01_NoOwnerReadsOutsideResolver pins OWNER-01's Go half
// (docs/superpowers/specs/2026-09-25-no-slack-owner-identity-design.md §8):
// every owner-identity read goes through ResolveOwner. It walks every
// non-test .go file under internal/ and cmd/ (except internal/db/owner.go,
// the resolver itself) and fails on the retired GetCurrentUserID identifier
// or a string literal carrying a direct current_user_id query — the
// two ways a Slack-only owner read can come back. Outside internal/db it also
// fails on GetUserProfile: an exact-key profile read skips GetOwnerProfile's
// fallback to a profile parked under an earlier owner key. Comments are not
// scanned.
func TestOwner01_NoOwnerReadsOutsideResolver(t *testing.T) {
	root := repoRootForOwnerScan(t)
	resolver := filepath.Join("internal", "db", "owner.go")

	var failures []string
	walked := 0
	for _, dir := range []string{"internal", "cmd"} {
		err := filepath.Walk(filepath.Join(root, dir), func(path string, info os.FileInfo, err error) error {
			if err != nil {
				return err
			}
			if info.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
				return nil
			}
			rel, err := filepath.Rel(root, path)
			if err != nil {
				return err
			}
			walked++
			if rel == resolver {
				return nil
			}
			failures = append(failures, scanFileForOwnerReads(t, path, rel)...)
			return nil
		})
		if err != nil {
			t.Fatalf("walking %s: %v", dir, err)
		}
	}

	if walked < ownerScanMinFiles {
		t.Fatalf("walked only %d non-test .go files under internal/ and cmd/, want at least %d — wrong root %q?", walked, ownerScanMinFiles, root)
	}
	for _, f := range failures {
		t.Error(f)
	}
}

// scanFileForOwnerReads reports each GetCurrentUserID identifier, each
// GetUserProfile identifier outside internal/db, and each string literal
// matching accountOneOwnerRead in one file.
func scanFileForOwnerReads(t *testing.T, path, rel string) []string {
	t.Helper()
	inDB := strings.HasPrefix(rel, filepath.Join("internal", "db")+string(filepath.Separator))
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, path, nil, 0)
	if err != nil {
		t.Fatalf("parsing %s: %v", path, err)
	}
	var out []string
	ast.Inspect(f, func(n ast.Node) bool {
		switch x := n.(type) {
		case *ast.Ident:
			if x.Name == "GetCurrentUserID" {
				out = append(out, rel+":"+strconv.Itoa(fset.Position(x.Pos()).Line)+": GetCurrentUserID — resolve the owner with db.ResolveOwner (OWNER-01)")
			}
			if x.Name == "GetUserProfile" && !inDB {
				out = append(out, rel+":"+strconv.Itoa(fset.Position(x.Pos()).Line)+": GetUserProfile — read the owner's profile with db.GetOwnerProfile (OWNER-01)")
			}
		case *ast.BasicLit:
			if x.Kind != token.STRING {
				return true
			}
			s, err := strconv.Unquote(x.Value)
			if err != nil {
				s = x.Value
			}
			if accountOneOwnerRead.MatchString(s) {
				out = append(out, rel+":"+strconv.Itoa(fset.Position(x.Pos()).Line)+": reads a slack account's current_user_id directly — resolve the owner with db.ResolveOwner (OWNER-01)")
			}
		}
		return true
	})
	return out
}

// repoRootForOwnerScan resolves the repository root from this file's path,
// so the scan does not depend on the working directory.
func repoRootForOwnerScan(t *testing.T) string {
	t.Helper()
	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed resolving this test file's path")
	}
	// internal/db/owner_scan_test.go -> repo root is two directories up.
	root := filepath.Join(filepath.Dir(thisFile), "..", "..")
	if _, err := os.Stat(filepath.Join(root, "go.mod")); err != nil {
		t.Fatalf("resolved repo root %q does not contain go.mod: %v", root, err)
	}
	return root
}
