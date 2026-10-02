//go:build codegrammars && cgo

package codeindex

// The full grammar set's fixtures join the golden table.
func init() {
	goldenFixtures["rust"] = "sample.rs"
}
