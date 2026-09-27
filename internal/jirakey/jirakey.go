// Package jirakey holds the Jira issue-key pattern as a dependency-free
// leaf, so packages that only need to spot keys in text (internal/doclinks)
// do not pull internal/jira and, through it, the AI stack. internal/jira
// re-exports it as jira.KeyRegexp.
package jirakey

import "regexp"

// KeyRegexp matches Jira issue keys like "PROJ-123". It is the bare shape,
// without the known-project filter jira.KeyDetector applies.
var KeyRegexp = regexp.MustCompile(`\b([A-Z][A-Z0-9_]+-\d+)\b`)
