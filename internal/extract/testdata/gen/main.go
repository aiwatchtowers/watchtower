//go:build ignore

// Command gen writes the extract test fixtures into internal/extract/testdata.
// Run from the repo root:
//
//	go run internal/extract/testdata/gen/main.go
//
// The Office files are minimal OOXML packages built with archive/zip; the
// PDFs are hand-written with computed xref offsets.
package main

import (
	"archive/zip"
	"bytes"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"log"
	"os"
	"path/filepath"
)

const dir = "internal/extract/testdata"

func main() {
	write("sample.csv", []byte("name,qty\napple,3\npear,5\n"))
	write("sample.html", []byte(`<!DOCTYPE html><html><head><title>T</title><style>p{color:red}</style>
<script>var x = 1;</script></head><body><h1>Release notes</h1><p>First   paragraph
with <b>bold</b> text.</p><ul><li>one</li><li>two</li></ul><div>Tail&amp;end</div></body></html>`))
	write("sample.docx", docx())
	write("sample.xlsx", xlsx())
	write("sample.pptx", pptx())
	write("sample.pdf", pdf([]pdfPage{{text: "Quarterly report: revenue grew twelve percent"}}))
	write("scanned.pdf", pdf([]pdfPage{{image: true}}))
	write("mixed.pdf", pdf([]pdfPage{{text: "Cover page with enough text to count"}, {image: true}}))
	write("sample.png", pngBytes())
	write("short.pdf", pdf([]pdfPage{{text: "A long enough page of real text here"}, {text: "Hi"}}))
	write("blank.pdf", pdf([]pdfPage{{text: "A long enough page of real text here"}, {blank: true}}))
	// Malformed: a page tree whose /Kids points back at itself (the
	// library's Reader.Page spins on it forever).
	write("kidsloop.pdf", rawPDF([]string{
		"<< /Type /Catalog /Pages 2 0 R >>",
		"<< /Type /Pages /Kids [2 0 R] /Count 1 >>",
	}, false, 0))
	// Malformed: the trailer's /Prev points at its own xref section (the
	// library's NewReader loops on it forever).
	write("prevloop.pdf", rawPDF([]string{
		"<< /Type /Catalog /Pages 2 0 R >>",
		"<< /Type /Pages /Kids [] /Count 0 >>",
	}, true, 0))
	// Page 2's /Resources points at object 8, whose xref entry lands on
	// object 1: resolving it panics inside the library. Page 1 must survive.
	good := "BT /F1 12 Tf 72 720 Td (The first page reads fine and keeps its text) Tj ET"
	bad := "BT /F1 12 Tf 72 720 Td (x) Tj ET"
	write("badpage.pdf", rawPDF([]string{
		"<< /Type /Catalog /Pages 2 0 R >>",
		"<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>",
		"<< /Type /Page /Parent 2 0 R /Resources << /Font << /F1 7 0 R >> >> /Contents 4 0 R >>",
		fmt.Sprintf("<< /Length %d >>\nstream\n%s\nendstream", len(good), good),
		"<< /Type /Page /Parent 2 0 R /Resources 8 0 R /Contents 6 0 R >>",
		fmt.Sprintf("<< /Length %d >>\nstream\n%s\nendstream", len(bad), bad),
		"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
	}, false, 1))
}

// rawPDF writes objs as objects 1..n with a correct xref; selfPrev adds a
// trailer /Prev pointing at that same xref section; bogus adds that many
// extra object numbers whose xref entries point at object 1.
func rawPDF(objs []string, selfPrev bool, bogus int) []byte {
	var buf bytes.Buffer
	buf.WriteString("%PDF-1.4\n")
	offsets := make([]int, len(objs))
	for i, o := range objs {
		offsets[i] = buf.Len()
		fmt.Fprintf(&buf, "%d 0 obj\n%s\nendobj\n", i+1, o)
	}
	xref := buf.Len()
	for range bogus {
		offsets = append(offsets, offsets[0])
	}
	fmt.Fprintf(&buf, "xref\n0 %d\n0000000000 65535 f \n", len(offsets)+1)
	for _, off := range offsets {
		fmt.Fprintf(&buf, "%010d 00000 n \n", off)
	}
	prev := ""
	if selfPrev {
		prev = fmt.Sprintf(" /Prev %d", xref)
	}
	fmt.Fprintf(&buf, "trailer\n<< /Size %d /Root 1 0 R%s >>\nstartxref\n%d\n%%%%EOF\n", len(offsets)+1, prev, xref)
	return buf.Bytes()
}

func write(name string, b []byte) {
	if err := os.WriteFile(filepath.Join(dir, name), b, 0o644); err != nil {
		log.Fatal(err)
	}
}

func zipOf(files [][2]string) []byte {
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for _, f := range files {
		w, err := zw.Create(f[0])
		if err != nil {
			log.Fatal(err)
		}
		if _, err := w.Write([]byte(f[1])); err != nil {
			log.Fatal(err)
		}
	}
	if err := zw.Close(); err != nil {
		log.Fatal(err)
	}
	return buf.Bytes()
}

const wNS = `xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"`

func docx() []byte {
	body := `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document ` + wNS + `><w:body>
<w:p><w:r><w:t>Intro line</w:t></w:r></w:p>
<w:p><w:pPr><w:pStyle w:val="Heading1"/><w:tabs><w:tab w:val="left" w:pos="720"/></w:tabs></w:pPr><w:r><w:t>Goals</w:t></w:r></w:p>
<w:p><w:r><w:t>Ship</w:t></w:r><w:r><w:tab/><w:t xml:space="preserve">the </w:t></w:r><w:r><w:t>thing</w:t></w:r></w:p>
<w:p/>
<w:p><w:r><w:t>Second line</w:t></w:r></w:p>
<w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t>Risks</w:t></w:r></w:p>
<w:tbl><w:tr><w:tc><w:p><w:r><w:t>Cell text</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
</w:body></w:document>`
	return zipOf([][2]string{
		{"[Content_Types].xml", `<?xml version="1.0"?><Types/>`},
		{"word/document.xml", body},
	})
}

const ssNS = `xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"`
const relNS = `xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"`

func xlsx() []byte {
	return zipOf([][2]string{
		{"[Content_Types].xml", `<?xml version="1.0"?><Types/>`},
		{"xl/workbook.xml", `<?xml version="1.0"?><workbook ` + ssNS + ` ` + relNS + `><sheets>
<sheet name="Budget" sheetId="1" r:id="rId1"/><sheet name="Team" sheetId="2" r:id="rId2"/></sheets></workbook>`},
		{"xl/_rels/workbook.xml.rels", `<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Target="/xl/worksheets/sheet2.xml"/></Relationships>`},
		{"xl/sharedStrings.xml", `<?xml version="1.0"?><sst ` + ssNS + `><si><t>Item</t></si><si><t>Cost</t></si>
<si><r><t>Ser</t></r><r><t>vers</t></r></si><si><t>Alice</t></si></sst>`},
		{"xl/worksheets/sheet1.xml", `<?xml version="1.0"?><worksheet ` + ssNS + `><sheetData>
<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
<row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><f>SUM(1,2)</f><v>1200</v></c></row>
<row r="3"></row>
<row r="4"><c r="A4" t="inlineStr"><is><t>Total</t></is></c><c r="B4" t="b"><v>1</v></c></row>
</sheetData></worksheet>`},
		{"xl/worksheets/sheet2.xml", `<?xml version="1.0"?><worksheet ` + ssNS + `><sheetData>
<row r="1"><c r="A1" t="s"><v>3</v></c></row></sheetData></worksheet>`},
	})
}

const aNS = `xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"`

func slide(paras ...string) string {
	s := `<?xml version="1.0"?><p:sld ` + aNS + `><p:cSld><p:spTree><p:sp><p:txBody>`
	for _, p := range paras {
		s += `<a:p><a:r><a:t>` + p + `</a:t></a:r></a:p>`
	}
	return s + `</p:txBody></p:sp></p:spTree></p:cSld></p:sld>`
}

func pptx() []byte {
	return zipOf([][2]string{
		{"[Content_Types].xml", `<?xml version="1.0"?><Types/>`},
		{"ppt/slides/slide1.xml", slide("Kickoff", "Agenda")},
		{"ppt/slides/slide2.xml", slide("Timeline")},
		{"ppt/slides/slide10.xml", slide("Questions")},
	})
}

type pdfPage struct {
	text  string
	image bool
	blank bool // no content, no XObject resources
}

// pdf writes a minimal PDF: one Helvetica font, one 2x2 grayscale image
// XObject, one content stream per page.
func pdf(pages []pdfPage) []byte {
	// Object numbers: 1 catalog, 2 pages, 3 font, 4 image, then per page
	// (page, contents).
	var objs []string
	kids := ""
	for i := range pages {
		kids += fmt.Sprintf("%d 0 R ", 5+2*i)
	}
	objs = append(objs,
		"<< /Type /Catalog /Pages 2 0 R >>",
		fmt.Sprintf("<< /Type /Pages /Kids [%s] /Count %d >>", kids, len(pages)),
		"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
		"<< /Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8 /Length 4 >>\nstream\n\x00\xff\xff\x00\nendstream",
	)
	for i, p := range pages {
		content := "q 200 0 0 200 100 400 cm /Im0 Do Q"
		resources := "<< /Font << /F1 3 0 R >> /XObject << /Im0 4 0 R >> >>"
		switch {
		case p.blank:
			content, resources = "", "<< >>"
		case !p.image:
			content = fmt.Sprintf("BT /F1 12 Tf 72 720 Td (%s) Tj ET", p.text)
		}
		objs = append(objs,
			fmt.Sprintf("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources %s /Contents %d 0 R >>", resources, 6+2*i),
			fmt.Sprintf("<< /Length %d >>\nstream\n%s\nendstream", len(content), content),
		)
	}
	var buf bytes.Buffer
	buf.WriteString("%PDF-1.4\n")
	offsets := make([]int, len(objs))
	for i, o := range objs {
		offsets[i] = buf.Len()
		fmt.Fprintf(&buf, "%d 0 obj\n%s\nendobj\n", i+1, o)
	}
	xref := buf.Len()
	fmt.Fprintf(&buf, "xref\n0 %d\n0000000000 65535 f \n", len(objs)+1)
	for _, off := range offsets {
		fmt.Fprintf(&buf, "%010d 00000 n \n", off)
	}
	fmt.Fprintf(&buf, "trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n", len(objs)+1, xref)
	return buf.Bytes()
}

func pngBytes() []byte {
	img := image.NewGray(image.Rect(0, 0, 2, 2))
	img.Set(0, 0, color.White)
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		log.Fatal(err)
	}
	return buf.Bytes()
}
