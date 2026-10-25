//go:build !darwin

package backupexclude

// Apply is a no-op outside macOS: there is no Time Machine to keep out.
func Apply(dirs []string) []error { return nil }
