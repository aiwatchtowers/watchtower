package auditlog

import "testing"

// The real unified-log sink returns; what it wrote is not asserted (the
// unified log is not reliably readable from a test).
func TestOSLog_WritesWithoutPanic(t *testing.T) {
	osLog(`{"v":1,"proc":"test","tool":"auditlog_test","result":"ok"}`)
}
