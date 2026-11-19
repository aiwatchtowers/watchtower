package sources

import (
	"os"
	"strconv"
	"strings"
	"testing"
)

// TestPermissionMaxSummaryMatchesTheDesktopCap pins the dual path of the
// phone's summary cap (PROJ-21): the Workchat's Allow on the Mac
// (SessionControl.phoneSummaryCap) refuses a summary the phone saw shortened,
// so it must be this slice's PermissionMaxSummary.
func TestPermissionMaxSummaryMatchesTheDesktopCap(t *testing.T) {
	src, err := os.ReadFile("../../../../WatchtowerDesktop/Sources/Services/SessionControl.swift")
	if err != nil {
		t.Fatal(err)
	}
	want := "nonisolated static let phoneSummaryCap = " + strconv.Itoa(PermissionMaxSummary)
	if !strings.Contains(string(src), want) {
		t.Errorf("SessionControl.swift has no %q", want)
	}
}
