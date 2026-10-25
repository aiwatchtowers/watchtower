package tools

import "maps"

// UnmarkedReadToolsForTest is a copy of unmarkedReadTools for the external
// guard test's stale-entry check.
func UnmarkedReadToolsForTest() map[string]string { return maps.Clone(unmarkedReadTools) }
