package reviewmap

import "testing"

// The parity table of WatchtowerDesktop/Tests/Core/ReviewChaptersTests.swift
// (testIsTest), plus the edge cases of NSString.deletingPathExtension.
func TestIsTest(t *testing.T) {
	for _, p := range []string{"x_test.go", "FooTests.swift", "FooTest.kt", "a.test.ts", "a.spec.js",
		"test_a.py", "Tests/Support/Helper.swift", "web/__tests__/a.js", "pkg/tests/data.json", ".spec"} {
		if !IsTest(p) {
			t.Errorf("IsTest(%q) = false, want true", p)
		}
	}
	for _, p := range []string{"contest.go", "attestation.swift", "foo.", ".gitignore",
		"internal/testsuite/a.go", "latest/a.go"} {
		if IsTest(p) {
			t.Errorf("IsTest(%q) = true, want false", p)
		}
	}
}
