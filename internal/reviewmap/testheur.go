package reviewmap

import "strings"

// IsTest reports whether path looks like a test file: a Tests, tests or
// __tests__ directory, a base name (extension dropped) ending _test, Tests,
// Test, .test or .spec, or starting test_. A port of the Desktop's
// ReviewChapters.isTest, kept in step with its test table.
func IsTest(path string) bool {
	parts := strings.FieldsFunc(path, func(r rune) bool { return r == '/' })
	if len(parts) == 0 {
		return false
	}
	for _, dir := range parts[:len(parts)-1] {
		if dir == "Tests" || dir == "tests" || dir == "__tests__" {
			return true
		}
	}
	base := dropExtension(parts[len(parts)-1])
	for _, suffix := range []string{"_test", "Tests", "Test", ".test", ".spec"} {
		if strings.HasSuffix(base, suffix) {
			return true
		}
	}
	return strings.HasPrefix(base, "test_")
}

// dropExtension removes the last ".ext" the way NSString's
// deletingPathExtension does: a leading dot (".gitignore") or a trailing one
// ("foo.") is not an extension.
func dropExtension(name string) string {
	i := strings.LastIndexByte(name, '.')
	if i <= 0 || i == len(name)-1 {
		return name
	}
	return name[:i]
}
