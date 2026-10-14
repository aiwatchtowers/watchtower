//go:build !darwin

package workbenchgit

func clonefileNative(string, string) error { return errCloneUnsupported }
