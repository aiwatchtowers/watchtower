// Package backupexclude keeps Watchtower's data folders out of Time Machine
// (BACKUP-01). It writes the sticky item exclusion — the extended attribute
// Attr holding the binary plist `tmutil addexclusion` writes — on each folder.
// On a folder the exclusion covers everything inside it, including files
// created later; it is lost when the folder is deleted and recreated, so the
// callers re-apply it on every start. The real implementation is darwin-only;
// every other OS gets a no-op.
package backupexclude

// Attr is the extended attribute Time Machine reads to skip an item.
const Attr = "com.apple.metadata:com_apple_backup_excludeItem"
