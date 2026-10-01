package extract

import (
	"context"
	"os/exec"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// backgroundPri is the scheduling priority `ps -o pri` shows for a process
// in the Darwin background band (a default process shows 31).
const backgroundPri = "4"

// selfPriScript prints the shell's own scheduling priority once the parent
// has had time to lower it.
const selfPriScript = `sleep 0.5; p=$(ps -o pri= -p $$ | tr -d ' ')`

func requireDarwin(t *testing.T) {
	t.Helper()
	if runtime.GOOS != "darwin" {
		t.Skip("the background priority band is macOS-only")
	}
	if _, err := exec.LookPath("ps"); err != nil {
		t.Skip("ps not available")
	}
}

// The OCR helper runs in the background priority band.
func TestHelperOCRRunsAtBackgroundPriority(t *testing.T) {
	requireDarwin(t)
	helper, _ := fakeHelper(t, selfPriScript+`; echo "{\"pages\":[{\"index\":0,\"text\":\"$p\"}]}"`)
	got, err := NewHelperOCR(helper, 10*time.Second).Recognize(context.Background(), "/tmp/x.png", nil)
	require.NoError(t, err)
	assert.Equal(t, backgroundPri, got[0])
}

// The PDF helper runs in the background priority band.
func TestPDFHelperRunsAtBackgroundPriority(t *testing.T) {
	requireDarwin(t)
	x := &Extractor{PDFHelper: []string{"/bin/sh", "-c", selfPriScript + `; echo "{\"ok\":true,\"pages\":[{\"index\":0,\"text\":\"$p\"}]}"`, "sh"}}
	pages, ok, err := x.parsePDF(context.Background(), "/tmp/x.pdf")
	require.NoError(t, err)
	require.True(t, ok)
	require.Len(t, pages, 1)
	assert.Equal(t, backgroundPri, strings.TrimSpace(pages[0].Text))
}
