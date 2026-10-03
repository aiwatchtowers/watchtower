package cmd

import (
	"context"
	"errors"
	"fmt"
	"os"
	"testing"

	"watchtower/internal/db"
	"watchtower/internal/externalmcp"
	"watchtower/internal/extract"
)

// TestMain installs the db schema template cache before running tests and
// points HOME at an empty directory for the whole package.
//
// The cmd package makes heavy use of db.Open(":memory:") — without the
// template cache every call runs goose migrations (~1 s each under -race),
// which exceeds Go's 10-minute test timeout on slow CI runners.
//
// HOME isolation: config.Load resolves an empty active_workspace from
// ~/.local/share/watchtower when exactly one workspace holds a database.
// Two dozen tests point flagConfig at a nonexistent file and expect a
// "config required" error; against the developer's real HOME they would
// instead resolve the real workspace and run the command for real (an AI
// query, a Slack sync). Tests that need their own HOME still t.Setenv it.
//
// GO_WANT_HELPER_PROCESS(_DELAYED) short-circuit: several tests
// (cmd/shutdown_test.go, cmd/sync_stop_test.go, cmd/ideas_test.go) re-exec
// the test binary into a specific helper test via the standard
// os/exec.Command(os.Args[0], ...) re-exec pattern — GO_WANT_HELPER_PROCESS
// for the swallows-SIGTERM-forever helper, GO_WANT_HELPER_PROCESS_DELAYED
// for the exits-shortly-after-SIGTERM one. That helper still runs through
// THIS package's TestMain first — it inherits it, there is no way to opt
// out per-test — so without this short-circuit every helper process pays
// the full db.InitTestTemplate cost (goose migrations against an in-memory
// db, ~8s under -race) before it ever reaches its own test body and prints
// "ready", which blows through the 5s readiness deadlines those tests use,
// and leaks a watchtower-cmd-tests-home-* temp dir per spawn (the helper
// exits via os.Exit/SIGKILL, so TestMain's own RemoveAll never runs for
// it). None of the fixture setup below (db template, isolated HOME) is
// relevant to a helper process — it doesn't touch the database or read
// config — so it must run before any of it, not just before the DB call
// specifically.
//
// extract-pdf-text short-circuit: the attachment extractor parses PDFs by
// re-executing os.Executable() with the hidden `extract-pdf-text <path>`
// command (pdfHelperArgv). Under `go test` that executable is this test
// binary, which would ignore the unknown arguments and run the whole suite
// again — so a cmd test that syncs a PDF must be served the parse here.
func TestMain(m *testing.M) {
	if len(os.Args) == 3 && os.Args[1] == extractPDFTextCmd.Name() {
		if err := extract.ServePDFHelper(os.Stdout, os.Stderr, os.Args[2]); err != nil {
			os.Exit(1)
		}
		os.Exit(0)
	}
	// The test binary as the real CLI (os.Args[1:] are its arguments), for
	// tests that need a process: signals, stdin EOF, exit codes.
	if os.Getenv(runCLIEnv) == "1" {
		os.Exit(Execute())
	}
	if os.Getenv("GO_WANT_HELPER_PROCESS") == "1" || os.Getenv("GO_WANT_HELPER_PROCESS_DELAYED") == "1" {
		os.Exit(m.Run())
	}
	// No cmd test may start a real Quick Connection server or dial its URL
	// to list tools (QC-02); tests that need a listing stub it themselves.
	listServerTools = func(context.Context, externalmcp.ServerSpec) ([]db.ExternalTool, error) {
		return nil, errors.New("tools/list is stubbed out in cmd tests")
	}
	if err := db.InitTestTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	home, err := os.MkdirTemp("", "watchtower-cmd-tests-home-")
	if err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	if err := os.Setenv("HOME", home); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	code := m.Run()
	_ = os.RemoveAll(home)
	os.Exit(code)
}
