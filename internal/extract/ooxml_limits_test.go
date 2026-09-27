package extract

import (
	"archive/zip"
	"bytes"
	"context"
	"io"
	"runtime"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// zipOf builds an in-memory archive holding parts (name → content).
func zipOf(t testing.TB, parts map[string]func(io.Writer) error) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for name, write := range parts {
		w, err := zw.Create(name)
		require.NoError(t, err)
		require.NoError(t, write(w))
	}
	require.NoError(t, zw.Close())
	return buf.Bytes()
}

// nested writes head, n × "<a>", text, n × "</a>", tail — a document n
// elements deeper than its own wrapper.
func nested(head, tail string, n int) func(io.Writer) error {
	return func(w io.Writer) error {
		if _, err := io.WriteString(w, head); err != nil {
			return err
		}
		if _, err := w.Write(bytes.Repeat([]byte("<a>"), n)); err != nil {
			return err
		}
		if _, err := io.WriteString(w, "deep"); err != nil {
			return err
		}
		if _, err := w.Write(bytes.Repeat([]byte("</a>"), n)); err != nil {
			return err
		}
		_, err := io.WriteString(w, tail)
		return err
	}
}

func literal(s string) func(io.Writer) error {
	return func(w io.Writer) error { _, err := io.WriteString(w, s); return err }
}

const (
	docxOpen  = `<w:document xmlns:w="w"><w:body><w:p><w:r><w:t>`
	docxClose = `</w:t></w:r></w:p></w:body></w:document>`
)

// extractAllocs runs one Extract and returns its result plus the bytes the
// process allocated meanwhile (TotalAlloc delta — monotonic, GC-proof).
func extractAllocs(t *testing.T, mediaType, name string, data []byte) (string, uint64) {
	t.Helper()
	x := newExtractor(t, nil)
	runtime.GC()
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	secs, status, err := x.Extract(context.Background(), mediaType, name, bytes.NewReader(data))
	runtime.ReadMemStats(&after)
	require.NoError(t, err)
	if status != StatusOK {
		assert.Nil(t, secs)
	}
	assertTempDirEmpty(t, x.TempDir)
	return status, after.TotalAlloc - before.TotalAlloc
}

// allocCeiling is a generous bound on what rejecting a hostile part may
// allocate. Before the depth/tag caps the documents below allocated
// hundreds of MiB (the finding measured 3.6 GB for 20M levels); rejected
// at the cap they allocate well under 1 MiB, so 32 MiB leaves ample room
// for runtime noise without letting the regression back in.
const allocCeiling = 32 << 20

// A deeply nested part in any of the three formats is a permanent failed,
// rejected at maxXMLDepth instead of growing encoding/xml's element stack
// one entry per level. 2M levels compress to a few KiB and stay far under
// the zip byte budget, so the byte cap alone never catches them.
func TestOOXMLDeepNestingIsBoundedFailure(t *testing.T) {
	const levels = 2_000_000
	cases := []struct {
		name, mediaType, file string
		parts                 map[string]func(io.Writer) error
	}{
		{"docx", mtDocx, "deep.docx", map[string]func(io.Writer) error{
			"word/document.xml": nested(docxOpen, docxClose, levels),
		}},
		{"xlsx shared strings", mtXlsx, "deep.xlsx", map[string]func(io.Writer) error{
			"xl/sharedStrings.xml":     nested(`<sst><si><t>`, `</t></si></sst>`, levels),
			"xl/worksheets/sheet1.xml": literal(`<worksheet><sheetData/></worksheet>`),
		}},
		{"xlsx sheet", mtXlsx, "deep.xlsx", map[string]func(io.Writer) error{
			"xl/worksheets/sheet1.xml": nested(`<worksheet><sheetData><row><c t="inlineStr"><is><t>`, `</t></is></c></row></sheetData></worksheet>`, levels),
		}},
		{"pptx", mtPptx, "deep.pptx", map[string]func(io.Writer) error{
			"ppt/slides/slide1.xml": nested(`<p:sld xmlns:p="p" xmlns:a="a"><a:p><a:t>`, `</a:t></a:p></p:sld>`, levels),
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			status, alloc := extractAllocs(t, tc.mediaType, tc.file, zipOf(t, tc.parts))
			assert.Equal(t, StatusFailed, status)
			assert.Less(t, alloc, uint64(allocCeiling), "allocated %d MiB", alloc>>20)
		})
	}
}

// One start tag carrying millions of attributes makes encoding/xml build
// the whole attribute slice inside a single Token call (~12× the input
// bytes) before any depth check could see it; the per-token byte cap stops
// the read instead, recording the file too_large.
func TestOOXMLHugeTagIsBounded(t *testing.T) {
	attrs := func(w io.Writer) error {
		if _, err := io.WriteString(w, `<w:document xmlns:w="w"><w:body a=""`); err != nil {
			return err
		}
		if _, err := w.Write(bytes.Repeat([]byte(` b=""`), 3_000_000)); err != nil {
			return err
		}
		_, err := io.WriteString(w, `><w:p><w:r><w:t>x</w:t></w:r></w:p></w:body></w:document>`)
		return err
	}
	data := zipOf(t, map[string]func(io.Writer) error{"word/document.xml": attrs})
	status, alloc := extractAllocs(t, mtDocx, "attrs.docx", data)
	assert.Equal(t, StatusTooLarge, status)
	assert.Less(t, alloc, uint64(allocCeiling), "allocated %d MiB", alloc>>20)
}

// A document nested exactly to the cap still extracts: the limits reject
// only what no real Office file produces (a docx nests about 10 levels).
func TestOOXMLNestingAtTheCapExtracts(t *testing.T) {
	// docxOpen already opens 4 levels (document, body, p, r) plus w:t.
	data := zipOf(t, map[string]func(io.Writer) error{
		"word/document.xml": nested(docxOpen, docxClose, maxXMLDepth-5),
	})
	x := newExtractor(t, nil)
	secs, status, err := x.Extract(context.Background(), mtDocx, "ok.docx", bytes.NewReader(data))
	require.NoError(t, err)
	require.Equal(t, StatusOK, status)
	require.Len(t, secs, 1)
	assert.Equal(t, "deep", secs[0].Text)

	over := zipOf(t, map[string]func(io.Writer) error{
		"word/document.xml": nested(docxOpen, docxClose, maxXMLDepth-4),
	})
	_, status, err = x.Extract(context.Background(), mtDocx, "over.docx", bytes.NewReader(over))
	require.NoError(t, err)
	assert.Equal(t, StatusFailed, status)
}

// A large text run is one CharData token; the per-token cap must leave
// room for any real one (a cell caps at 32767 chars, a Word run far below
// the cap).
func TestOOXMLLongTextRunExtracts(t *testing.T) {
	text := strings.Repeat("word ", 30_000) // 150 KB in one w:t, under MaxTextRunes
	data := zipOf(t, map[string]func(io.Writer) error{
		"word/document.xml": literal(docxOpen + text + docxClose),
	})
	x := newExtractor(t, nil)
	secs, status, err := x.Extract(context.Background(), mtDocx, "long.docx", bytes.NewReader(data))
	require.NoError(t, err)
	require.Equal(t, StatusOK, status)
	require.Len(t, secs, 1)
	assert.Equal(t, strings.TrimSpace(text), secs[0].Text)
}
