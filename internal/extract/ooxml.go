package extract

import (
	"archive/zip"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"path"
	"sort"
	"strconv"
	"strings"

	"watchtower/internal/extsync"
)

// Zip-bomb guards: the total uncompressed bytes read from one archive and
// the number of entries opened. Variables so tests can lower them.
var (
	maxZipBytes   int64 = 100 << 20
	maxZipEntries       = 1000
)

// errZipBudget: the archive needs more than the zip budget to extract.
var errZipBudget = errors.New("extract: archive exceeds the extraction budget")

// errMissingPart: a required OOXML part is absent (not a valid document).
var errMissingPart = errors.New("extract: missing OOXML part")

// ooxmlText extracts a docx/xlsx/pptx spooled at path. A corrupt archive
// is StatusFailed; one that exceeds the zip budget is StatusTooLarge.
func ooxmlText(k kind, path string, logf logFunc) ([]extsync.Section, string, error) {
	zr, err := zip.OpenReader(path)
	if err != nil {
		logf("extract: opening the OOXML archive: %v; recording it failed", err)
		return nil, StatusFailed, nil
	}
	defer func() { _ = zr.Close() }()
	pkg := &ooxmlPackage{files: map[string]*zip.File{}, bytesLeft: maxZipBytes, entriesLeft: maxZipEntries}
	for _, f := range zr.File {
		pkg.files[f.Name] = f
	}
	var secs []extsync.Section
	switch k {
	case kindDocx:
		secs, err = docxText(pkg)
	case kindXlsx:
		secs, err = xlsxText(pkg)
	default:
		secs, err = pptxText(pkg)
	}
	switch {
	case errors.Is(err, errZipBudget):
		logf("extract: OOXML archive over the extraction budget: %v", err)
		return nil, StatusTooLarge, nil
	case err != nil:
		logf("extract: reading the OOXML archive: %v; recording it failed", err)
		return nil, StatusFailed, nil
	}
	return secs, StatusOK, nil
}

// ooxmlPackage is an opened archive plus its remaining extraction budget.
type ooxmlPackage struct {
	files       map[string]*zip.File
	bytesLeft   int64
	entriesLeft int
}

// walk streams the XML tokens of part name to fn, charging the budget.
// A missing part is errMissingPart.
func (p *ooxmlPackage) walk(name string, fn func(xml.Token)) error {
	f, ok := p.files[name]
	if !ok {
		return fmt.Errorf("%w: %s", errMissingPart, name)
	}
	if p.entriesLeft--; p.entriesLeft < 0 {
		return errZipBudget
	}
	rc, err := f.Open()
	if err != nil {
		return fmt.Errorf("extract: opening %s: %w", name, err)
	}
	defer rc.Close()
	d := xml.NewDecoder(&budgetReader{r: rc, p: p})
	for {
		tok, err := d.Token()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("extract: parsing %s: %w", name, err)
		}
		fn(tok)
	}
}

// budgetReader charges every byte read to its package's budget.
type budgetReader struct {
	r io.Reader
	p *ooxmlPackage
}

func (b *budgetReader) Read(buf []byte) (int, error) {
	n, err := b.r.Read(buf)
	b.p.bytesLeft -= int64(n)
	if b.p.bytesLeft < 0 {
		return n, errZipBudget
	}
	return n, err
}

// numbered returns the part names prefix<N>.xml sorted by N (so slide10
// follows slide2).
func (p *ooxmlPackage) numbered(prefix string) []string {
	type part struct {
		name string
		n    int
	}
	var parts []part
	for name := range p.files {
		num, ok := strings.CutPrefix(name, prefix)
		if !ok {
			continue
		}
		num, ok = strings.CutSuffix(num, ".xml")
		if n, err := strconv.Atoi(num); ok && err == nil {
			parts = append(parts, part{name, n})
		}
	}
	sort.Slice(parts, func(i, j int) bool { return parts[i].n < parts[j].n })
	out := make([]string, len(parts))
	for i, pt := range parts {
		out[i] = pt.name
	}
	return out
}

// attr returns the value of the attribute with local name local.
func attr(e xml.StartElement, local string) string {
	for _, a := range e.Attr {
		if a.Name.Local == local {
			return a.Value
		}
	}
	return ""
}

// --- docx ---

// docxText reads word/document.xml: each w:p is a line (w:tab → tab,
// w:br → newline); a paragraph styled Heading1..3 starts a new section.
//
// Accepted v1 limits: heading detection matches only the English built-in
// style ids ("Heading1".."Heading3"); a document authored in a localized
// Word whose heading styles carry other ids is one untitled section. And
// mc:AlternateContent is not resolved — text present in both its Choice and
// Fallback branches (e.g. a text box) is extracted twice.
func docxText(p *ooxmlPackage) ([]extsync.Section, error) {
	w := &docxWalker{}
	if err := p.walk("word/document.xml", w.token); err != nil {
		return nil, err
	}
	return w.done(), nil
}

// sectionBuilder accumulates headed sections of lines.
type sectionBuilder struct {
	secs  []extsync.Section
	lines []string
	open  bool
}

func (s *sectionBuilder) heading(h string) {
	s.close()
	s.secs = append(s.secs, extsync.Section{Heading: h})
	s.open = true
}

func (s *sectionBuilder) line(l string) {
	if !s.open {
		s.secs = append(s.secs, extsync.Section{})
		s.open = true
	}
	s.lines = append(s.lines, l)
}

func (s *sectionBuilder) close() {
	if s.open {
		s.secs[len(s.secs)-1].Text = strings.Join(s.lines, "\n")
	}
	s.lines, s.open = nil, false
}

func (s *sectionBuilder) done() []extsync.Section {
	s.close()
	return s.secs
}

type docxWalker struct {
	sectionBuilder
	para   strings.Builder
	styled bool // the open paragraph is styled Heading1..3
	inRun  int
	inText bool
}

func (w *docxWalker) token(tok xml.Token) {
	switch t := tok.(type) {
	case xml.StartElement:
		w.start(t)
	case xml.EndElement:
		w.end(t.Name.Local)
	case xml.CharData:
		if w.inText {
			w.para.Write(t)
		}
	}
}

func (w *docxWalker) start(e xml.StartElement) {
	switch e.Name.Local {
	case "p":
		w.endPara() // a nested paragraph (text box) ends the outer one's text so far
	case "pStyle":
		w.styled = isHeadingStyle(attr(e, "val"))
	case "r":
		w.inRun++
	case "t":
		w.inText = w.inRun > 0
	case "tab":
		w.runChar("\t")
	case "br", "cr":
		w.runChar("\n")
	}
}

// runChar appends s for a run-level element (w:tab inside w:pPr/w:tabs is
// a tab stop definition, not text).
func (w *docxWalker) runChar(s string) {
	if w.inRun > 0 {
		w.para.WriteString(s)
	}
}

func (w *docxWalker) end(local string) {
	switch local {
	case "t":
		w.inText = false
	case "r":
		w.inRun = max(w.inRun-1, 0)
	case "p":
		w.endPara()
	}
}

func (w *docxWalker) endPara() {
	text := strings.TrimSpace(w.para.String())
	w.para.Reset()
	isHeading := w.styled
	w.styled = false
	switch {
	case text == "":
	case isHeading:
		w.sectionBuilder.heading(text)
	default:
		w.line(text)
	}
}

func isHeadingStyle(v string) bool {
	switch strings.ToLower(v) {
	case "heading1", "heading2", "heading3":
		return true
	}
	return false
}

// --- xlsx ---

// xlsxText is one section per worksheet (numeric file order), headed by
// the sheet's name; each non-empty row is a line of cells joined " | ".
func xlsxText(p *ooxmlPackage) ([]extsync.Section, error) {
	shared, err := sharedStrings(p)
	if err != nil {
		return nil, err
	}
	names := sheetNames(p)
	var secs []extsync.Section
	for i, part := range p.numbered("xl/worksheets/sheet") {
		w := &sheetWalker{shared: shared}
		if err := p.walk(part, w.token); err != nil {
			return nil, err
		}
		if len(w.lines) == 0 {
			continue
		}
		name := names[part]
		if name == "" {
			name = fmt.Sprintf("Sheet %d", i+1)
		}
		secs = append(secs, extsync.Section{Heading: name, Text: strings.Join(w.lines, "\n")})
	}
	return secs, nil
}

// sharedStrings reads xl/sharedStrings.xml (absent = none): each <si> is
// the concatenation of its <t> texts, phonetic runs excluded.
func sharedStrings(p *ooxmlPackage) ([]string, error) {
	var out []string
	var cur strings.Builder
	inT, inPhonetic := false, 0
	err := p.walk("xl/sharedStrings.xml", func(tok xml.Token) {
		switch t := tok.(type) {
		case xml.StartElement:
			switch t.Name.Local {
			case "si":
				cur.Reset()
			case "rPh":
				inPhonetic++
			case "t":
				inT = inPhonetic == 0
			}
		case xml.EndElement:
			switch t.Name.Local {
			case "si":
				out = append(out, cur.String())
			case "rPh":
				inPhonetic--
			case "t":
				inT = false
			}
		case xml.CharData:
			if inT {
				cur.Write(t)
			}
		}
	})
	if errors.Is(err, errMissingPart) {
		return nil, nil
	}
	return out, err
}

// sheetNames maps a worksheet part name to its sheet name via
// xl/workbook.xml and its relationships. Best effort: any missing piece
// yields an empty map (sections fall back to "Sheet N").
func sheetNames(p *ooxmlPackage) map[string]string {
	idToName := map[string]string{}
	if err := p.walk("xl/workbook.xml", func(tok xml.Token) {
		if e, ok := tok.(xml.StartElement); ok && e.Name.Local == "sheet" {
			idToName[attr(e, "id")] = attr(e, "name")
		}
	}); err != nil {
		return map[string]string{}
	}
	out := map[string]string{}
	_ = p.walk("xl/_rels/workbook.xml.rels", func(tok xml.Token) {
		if e, ok := tok.(xml.StartElement); ok && e.Name.Local == "Relationship" {
			if name, ok := idToName[attr(e, "Id")]; ok {
				out[relTarget(attr(e, "Target"))] = name
			}
		}
	})
	return out
}

// relTarget resolves a workbook relationship target to a part name.
func relTarget(target string) string {
	if strings.HasPrefix(target, "/") {
		return strings.TrimPrefix(path.Clean(target), "/")
	}
	return path.Clean("xl/" + target)
}

type sheetWalker struct {
	shared   []string
	lines    []string
	cells    []string
	cellType string
	value    strings.Builder
	inline   strings.Builder
	inV      bool
	inT      bool
}

func (w *sheetWalker) token(tok xml.Token) {
	switch t := tok.(type) {
	case xml.StartElement:
		w.start(t)
	case xml.EndElement:
		w.end(t.Name.Local)
	case xml.CharData:
		switch {
		case w.inV:
			w.value.Write(t)
		case w.inT:
			w.inline.Write(t)
		}
	}
}

func (w *sheetWalker) start(e xml.StartElement) {
	switch e.Name.Local {
	case "row":
		w.cells = nil
	case "c":
		w.cellType = attr(e, "t")
		w.value.Reset()
		w.inline.Reset()
	case "v":
		w.inV = true
	case "t":
		w.inT = true
	}
}

func (w *sheetWalker) end(local string) {
	switch local {
	case "v":
		w.inV = false
	case "t":
		w.inT = false
	case "c":
		if v := strings.TrimSpace(w.cellValue()); v != "" {
			w.cells = append(w.cells, v)
		}
	case "row":
		if len(w.cells) > 0 {
			w.lines = append(w.lines, strings.Join(w.cells, " | "))
		}
	}
}

func (w *sheetWalker) cellValue() string {
	v := w.value.String()
	switch w.cellType {
	case "s":
		i, err := strconv.Atoi(strings.TrimSpace(v))
		if err != nil || i < 0 || i >= len(w.shared) {
			return ""
		}
		return w.shared[i]
	case "inlineStr":
		return w.inline.String()
	case "b":
		if strings.TrimSpace(v) == "1" {
			return "TRUE"
		}
		return "FALSE"
	}
	return v
}

// --- pptx ---

// pptxText is one section per slide (numeric file order), headed
// "Slide N" by position; each a:p is a line.
func pptxText(p *ooxmlPackage) ([]extsync.Section, error) {
	var secs []extsync.Section
	for i, part := range p.numbered("ppt/slides/slide") {
		w := &slideWalker{}
		if err := p.walk(part, w.token); err != nil {
			return nil, err
		}
		if len(w.lines) > 0 {
			secs = append(secs, extsync.Section{Heading: fmt.Sprintf("Slide %d", i+1), Text: strings.Join(w.lines, "\n")})
		}
	}
	return secs, nil
}

type slideWalker struct {
	lines []string
	para  strings.Builder
	inT   bool
}

func (w *slideWalker) token(tok xml.Token) {
	switch t := tok.(type) {
	case xml.StartElement:
		switch t.Name.Local {
		case "p":
			w.para.Reset()
		case "t":
			w.inT = true
		}
	case xml.EndElement:
		switch t.Name.Local {
		case "t":
			w.inT = false
		case "p":
			if line := strings.TrimSpace(w.para.String()); line != "" {
				w.lines = append(w.lines, line)
			}
		}
	case xml.CharData:
		if w.inT {
			w.para.Write(t)
		}
	}
}
