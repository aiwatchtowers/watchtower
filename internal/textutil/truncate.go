// Package textutil holds small text helpers shared by the prompt builders.
package textutil

// Truncate cuts s to at most n runes and appends suffix when it cut anything;
// a string that already fits is returned unchanged. Counting runes rather than
// bytes keeps a cut from splitting a multi-byte character (Cyrillic is two
// bytes a letter) and gives non-Latin text the same budget as Latin text.
func Truncate(s string, n int, suffix string) string {
	if len(s) <= n {
		return s // n bytes hold at most n runes
	}
	i := 0
	for pos := range s {
		if i == n {
			return s[:pos] + suffix
		}
		i++
	}
	return s
}
