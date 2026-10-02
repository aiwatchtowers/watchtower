package extract

import (
	"context"
	"os/exec"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// selfNiceScript sets p to the shell's own nice value once the parent has
// had time to lower its priority.
const selfNiceScript = `sleep 0.5; p=$(ps -o nice= -p $$ | tr -d ' ')`

func requirePS(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("ps"); err != nil {
		t.Skip("ps not available")
	}
}

// The OCR helper runs at the helpers' nice value.
func TestHelperOCRRunsNiced(t *testing.T) {
	requirePS(t)
	helper, _ := fakeHelper(t, selfNiceScript+`; echo "{\"pages\":[{\"index\":0,\"text\":\"$p\"}]}"`)
	got, err := NewHelperOCR(helper, 30*time.Second).Recognize(context.Background(), "/tmp/x.png", nil)
	require.NoError(t, err)
	assert.Equal(t, strconv.Itoa(helperNice), got[0])
}

// The PDF helper runs at the helpers' nice value.
func TestPDFHelperRunsNiced(t *testing.T) {
	requirePS(t)
	x := &Extractor{PDFHelper: []string{"/bin/sh", "-c", selfNiceScript + `; echo "{\"ok\":true,\"pages\":[{\"index\":0,\"text\":\"$p\"}]}"`, "sh"}}
	pages, ok, err := x.parsePDF(context.Background(), "/tmp/x.pdf")
	require.NoError(t, err)
	require.True(t, ok)
	require.Len(t, pages, 1)
	assert.Equal(t, strconv.Itoa(helperNice), strings.TrimSpace(pages[0].Text))
}
