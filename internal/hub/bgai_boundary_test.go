package hub

import (
	"go/parser"
	"go/token"
	"io/fs"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// bgaiModelLeaves are the packages that call a model in-process. The hub's
// own internal/hub/transport is not one of them.
var bgaiModelLeaves = map[string]bool{
	"watchtower/internal/ai":                  true,
	"watchtower/internal/digest":              true,
	"watchtower/internal/agentloop":           true,
	"watchtower/internal/providers/transport": true,
	"watchtower/internal/claude":              true,
	"watchtower/internal/codex":               true,
}

// BGAI-02, Decision 3 of #1886: the daemon hosts the hub and the chat engine
// in a background process, and no root context is marked owner. That is
// safe only while neither makes a model call in-process: every owner turn
// runs in a spawned `ai session` child with the owner's origin. An import of
// a model leaf here means an in-process call that the consent check would
// refuse while background AI is paused.
// A model call cmd hands in as a callback (the chat title hook) imports
// nothing here; TestBGAI02_HostedCallbacksNameTheirOrigin (internal/daemon)
// requires such a callback to mark its origin.
func TestBGAI02_HubAndChatEngineMakeNoInProcessModelCall(t *testing.T) {
	var offenders []string
	for _, root := range []string{".", filepath.Join("..", "chatengine")} {
		err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if d.IsDir() {
				if path != root && (d.Name() == "testdata" || strings.HasPrefix(d.Name(), ".")) {
					return filepath.SkipDir
				}
				return nil
			}
			if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
				return nil
			}
			f, err := parser.ParseFile(token.NewFileSet(), path, nil, parser.ImportsOnly)
			if err != nil {
				return err
			}
			for _, imp := range f.Imports {
				p, _ := strconv.Unquote(imp.Path.Value)
				if bgaiModelLeaves[p] {
					offenders = append(offenders, path+" imports "+p)
				}
			}
			return nil
		})
		if err != nil {
			t.Fatalf("walking %s: %v", root, err)
		}
	}
	if len(offenders) > 0 {
		t.Fatalf("the hub or the chat engine now calls a model in-process:\n  %s\n"+
			"mark the serving request aiconsent.WithOwnerStarted at its handler and update this test",
			strings.Join(offenders, "\n  "))
	}
}
