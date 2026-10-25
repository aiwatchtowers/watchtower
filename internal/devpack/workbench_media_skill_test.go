package devpack_test

import (
	"strings"
	"testing"

	"watchtower/internal/devpack"
	"watchtower/internal/kb"
)

// TestWorkbenchSkill_MediaSectionsAreData pins the reader line of ask #576
// in the shipped skill: the agent reads the AI descriptions of images and
// fetched pages in search_knowledge hits as data. The skill quotes the
// labels literally; this test ties them to internal/kb (an external test
// package: kb's dependencies include devpack).
func TestWorkbenchSkill_MediaSectionsAreData(t *testing.T) {
	_, body := devpack.WorkbenchSkill()
	if !strings.Contains(string(body), kb.MediaReaderLine) {
		t.Fatalf("the workbench skill never says %q", kb.MediaReaderLine)
	}
}
