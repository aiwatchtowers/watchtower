package inboxfolders

import (
	_ "embed"
	"encoding/json"
)

// iconsJSON is the allowlist of SF Symbol names a folder may carry. The
// Desktop reads the same file (one list, no dual path).
//
//go:embed testdata/icons.json
var iconsJSON []byte

var allowedIcons = mustLoadIcons(iconsJSON)

func mustLoadIcons(raw []byte) map[string]bool {
	var names []string
	if err := json.Unmarshal(raw, &names); err != nil {
		panic("inboxfolders: testdata/icons.json: " + err.Error())
	}
	set := make(map[string]bool, len(names))
	for _, n := range names {
		set[n] = true
	}
	return set
}
