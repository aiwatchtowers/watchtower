package jira

import "watchtower/internal/jirakey"

// KeyRegexp matches Jira issue keys like "PROJ-123". Exported so other
// packages that need the bare pattern without the known-prefix filtering the
// issue-key detector (internal/issuekey) applies (e.g. internal/confluence's
// storage-format converter) can reuse it directly instead of duplicating the
// regex. It is the dependency-free internal/jirakey pattern, re-exported here.
var KeyRegexp = jirakey.KeyRegexp
