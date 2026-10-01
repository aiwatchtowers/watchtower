//go:build !darwin

package extract

// setBackgroundPriority is a no-op off macOS: the helpers it lowers (the
// Vision OCR helper) exist only there.
func setBackgroundPriority(int) error { return nil }
