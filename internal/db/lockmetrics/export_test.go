package lockmetrics

import "sync"

// resetForTest drops every piece of process state so a test starts from a
// fresh process: env re-read, no sink, default role, warning not yet spent.
func resetForTest() {
	settingsOnce = sync.Once{}
	settings = config{}
	sinkPath.Store(nil)
	role.Store(nil)
	warnOnce = sync.Once{}
	writeMu.Lock()
	closeHeld()
	maxFileBytes = MaxFileBytes
	writeMu.Unlock()
}

// setMaxFileBytesForTest lowers the rotation cap so a test reaches it with a
// handful of lines.
func setMaxFileBytesForTest(n int64) {
	writeMu.Lock()
	defer writeMu.Unlock()
	maxFileBytes = n
}
