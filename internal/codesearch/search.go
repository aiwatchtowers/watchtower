// Package codesearch is the text search of a workbench folder (`watchtower
// code search`): a literal or regexp query over the files internal/codewalk
// lists, no external tool. Matches stream per file as they are found so the
// first result shows before the whole folder is read.
package codesearch

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"regexp/syntax"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"unicode"
	"unicode/utf8"

	"watchtower/internal/codewalk"
)

// maxTextChars caps a match's Text (and each context line) in characters.
const maxTextChars = 400

// ErrInvalidQuery marks options Run refuses before reading anything: an
// empty or multi-line query, a regexp that does not compile, Max < 1 or a
// negative Context.
var ErrInvalidQuery = errors.New("invalid query")

// Options is one search.
type Options struct {
	Query string
	// Word keeps only matches that are whole identifiers ([A-Za-z0-9_$]).
	Word bool
	// Case forces a case-sensitive search; otherwise the search is
	// case-insensitive unless Query has an upper-case letter (smart case).
	Case bool
	// Regex reads Query as a Go regexp, matched within each line.
	Regex bool
	// Max is the most matches emitted; one more found sets Truncated.
	Max int
	// Context is how many lines before and after each match to include.
	Context int
}

// Match is one occurrence. Line and Col are 1-based, Col in UTF-16 units
// of the full line (what Monaco and NSString use). Text is the line, cut
// to maxTextChars around the match when longer; Before and After hold up
// to Options.Context neighbouring lines, each cut to maxTextChars.
// TextCol is the match's 1-based UTF-16 column inside Text (equal to Col
// when the line was not cut), for highlighting it. A byte that is not
// valid UTF-8 counts one UTF-16 unit in both (it reads as one U+FFFD, as
// the JSON text carries it).
type Match struct {
	Path    string   `json:"path"`
	Line    int      `json:"line"`
	Col     int      `json:"col"`
	Text    string   `json:"text"`
	TextCol int      `json:"text_col"`
	Before  []string `json:"before"`
	After   []string `json:"after"`
}

// Summary counts a run: Files read and searched (a file the walk or the
// size cap skips is not counted; a run stopped by Max still counts the
// files its workers had searched by then), the Matches emitted, and
// Truncated when Max stopped it.
type Summary struct {
	Files     int
	Matches   int
	Truncated bool
}

// Run searches the folder at root and calls emit for every match, from one
// goroutine; all of a file's matches are emitted together, files in
// completion order. It stops after opt.Max matches. Invalid options return
// an error wrapping ErrInvalidQuery; an emit error stops the run and is
// returned; a cancelled ctx stops it with ctx's error.
func Run(ctx context.Context, root string, opt Options, emit func(Match) error) (Summary, error) {
	m, err := compile(opt)
	if err != nil {
		return Summary{}, err
	}
	parent := ctx
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	jobs := make(chan string)
	results := make(chan []Match)
	walkErr := make(chan error, 1)
	go func() {
		defer close(jobs)
		walkErr <- feed(ctx, root, jobs)
	}()

	var scanned atomic.Int64
	var wg sync.WaitGroup
	for range runtime.GOMAXPROCS(0) {
		wg.Go(func() {
			s := scanner{m: m, opt: opt, limit: opt.Max + 1}
			for rel := range jobs {
				ms, ok := s.file(root, rel)
				if ok {
					scanned.Add(1)
				}
				if len(ms) == 0 {
					continue
				}
				select {
				case results <- ms:
				case <-ctx.Done():
					return
				}
			}
		})
	}
	go func() {
		wg.Wait()
		close(results)
	}()

	var sum Summary
	var emitErr error
	stopped := false
	for ms := range results {
		if stopped {
			continue // drain until the workers stop
		}
		for _, match := range ms {
			if sum.Matches == opt.Max {
				sum.Truncated = true
				break
			}
			if emitErr = emit(match); emitErr != nil {
				break
			}
			sum.Matches++
		}
		if emitErr != nil || sum.Truncated {
			stopped = true
			cancel()
		}
	}
	// results closes only after every worker stopped: scanned is final.
	sum.Files = int(scanned.Load())
	switch {
	case emitErr != nil:
		return sum, emitErr
	case parent.Err() != nil:
		return sum, parent.Err()
	case sum.Truncated:
		return sum, nil
	}
	return sum, <-walkErr
}

// feed sends the walk's files to the workers.
func feed(ctx context.Context, root string, jobs chan<- string) error {
	for f, err := range codewalk.Files(ctx, root) {
		if err != nil {
			return fmt.Errorf("listing %s: %w", root, err)
		}
		select {
		case jobs <- f.Rel:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	return nil
}

// matcher finds a query's occurrences in one line.
type matcher struct {
	// lit is the literal needle (lower-cased when fold); nil for re.
	lit []byte
	// fold: the haystack is ASCII-lower-cased before a literal search.
	fold bool
	re   *regexp.Regexp
	word bool
}

func compile(opt Options) (*matcher, error) {
	switch {
	case opt.Query == "":
		return nil, fmt.Errorf("%w: the query is empty", ErrInvalidQuery)
	case strings.ContainsAny(opt.Query, "\r\n"):
		return nil, fmt.Errorf("%w: the query must be one line", ErrInvalidQuery)
	case opt.Max < 1:
		return nil, fmt.Errorf("%w: max must be at least 1, got %d", ErrInvalidQuery, opt.Max)
	case opt.Context < 0:
		return nil, fmt.Errorf("%w: context must not be negative, got %d", ErrInvalidQuery, opt.Context)
	}
	m := &matcher{word: opt.Word}
	if opt.Regex {
		upper, err := regexHasUpper(opt.Query)
		if err != nil {
			return nil, fmt.Errorf("%w: %w", ErrInvalidQuery, err)
		}
		pattern := opt.Query
		if !opt.Case && !upper {
			pattern = "(?i)" + pattern
		}
		if m.re, err = regexp.Compile(pattern); err != nil {
			return nil, fmt.Errorf("%w: %w", ErrInvalidQuery, err)
		}
		return m, nil
	}
	insensitive := !opt.Case && !strings.ContainsFunc(opt.Query, unicode.IsUpper)
	switch {
	case !insensitive:
		m.lit = []byte(opt.Query)
	case isASCII(opt.Query):
		m.lit, m.fold = asciiLower(nil, []byte(opt.Query)), true
	default:
		// Unicode case folding can change byte lengths: leave it to regexp.
		m.re = regexp.MustCompile("(?i)" + regexp.QuoteMeta(opt.Query))
	}
	return m, nil
}

// regexHasUpper reports whether pattern has an upper-case literal letter
// (smart case). Escapes such as \S or \W are classes, not letters, and a
// (?i) part is insensitive already.
func regexHasUpper(pattern string) (bool, error) {
	re, err := syntax.Parse(pattern, syntax.Perl)
	if err != nil {
		return false, fmt.Errorf("parsing the regexp: %w", err)
	}
	var walk func(*syntax.Regexp) bool
	walk = func(re *syntax.Regexp) bool {
		if re.Op == syntax.OpLiteral && re.Flags&syntax.FoldCase == 0 {
			for _, r := range re.Rune {
				if unicode.IsUpper(r) {
					return true
				}
			}
		}
		for _, sub := range re.Sub {
			if walk(sub) {
				return true
			}
		}
		return false
	}
	return walk(re), nil
}

// find calls yield with each occurrence's byte range in line; hay is the
// same line as the matcher searches it (lower-cased when fold).
func (m *matcher) find(hay, line []byte, yield func(s, e int) bool) {
	if m.re != nil {
		for _, loc := range m.re.FindAllIndex(line, -1) {
			if loc[0] == loc[1] || (m.word && !wordAt(line, loc[0], loc[1])) {
				continue
			}
			if !yield(loc[0], loc[1]) {
				return
			}
		}
		return
	}
	for pos := 0; ; {
		i := bytes.Index(hay[pos:], m.lit)
		if i < 0 {
			return
		}
		s, e := pos+i, pos+i+len(m.lit)
		if m.word && !wordAt(line, s, e) {
			pos = s + 1 // a later, overlapping candidate may stand alone
			continue
		}
		if !yield(s, e) {
			return
		}
		pos = e
	}
}

// scanner is one worker's state: it searches one file at a time.
type scanner struct {
	m     *matcher
	opt   Options
	limit int
	// folded is reused across files for the lower-cased haystack.
	folded []byte
}

// file returns rel's matches, at most s.limit, and whether it was
// searched. A file that vanished or became unreadable since the walk
// listed it is skipped (not searched), as the walk skips one it cannot
// read.
func (s *scanner) file(root, rel string) ([]Match, bool) {
	buf, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
	if err != nil || len(buf) > codewalk.MaxSearchBytes {
		return nil, false
	}
	hay := buf
	if s.m.fold {
		s.folded = asciiLower(s.folded[:0], buf)
		hay = s.folded
	}
	if s.m.lit != nil && !bytes.Contains(hay, s.m.lit) {
		return nil, true
	}
	starts := lineStarts(buf)
	var out []Match
	for i := range starts {
		a, b := lineBounds(buf, starts, i)
		line := buf[a:b]
		var before, after []string
		col, colAt := 1, 0 // UTF-16 column of line[colAt], advanced per match
		s.m.find(hay[a:b], line, func(ms, me int) bool {
			if before == nil {
				before, after = s.context(buf, starts, i)
			}
			col += utf16Len(line[colAt:ms])
			colAt = ms
			ta, tb := window(line, ms, me)
			out = append(out, Match{
				Path: rel, Line: i + 1, Col: col,
				Text: string(line[ta:tb]), TextCol: utf16Len(line[ta:ms]) + 1,
				Before: before, After: after,
			})
			return len(out) < s.limit
		})
		if len(out) >= s.limit {
			break
		}
	}
	return out, true
}

// context returns the opt.Context lines around line i, never nil.
func (s *scanner) context(buf []byte, starts []int, i int) (before, after []string) {
	before, after = []string{}, []string{}
	for j := max(0, i-s.opt.Context); j < i; j++ {
		a, b := lineBounds(buf, starts, j)
		before = append(before, prefix(buf[a:b]))
	}
	for j := i + 1; j <= i+s.opt.Context && j < len(starts); j++ {
		a, b := lineBounds(buf, starts, j)
		after = append(after, prefix(buf[a:b]))
	}
	return before, after
}

// lineStarts is the byte offset of each line; a final newline does not
// start an empty last line.
func lineStarts(buf []byte) []int {
	starts := []int{0}
	for i := 0; ; {
		j := bytes.IndexByte(buf[i:], '\n')
		if j < 0 || i+j+1 == len(buf) {
			return starts
		}
		i += j + 1
		starts = append(starts, i)
	}
}

// lineBounds is line i's byte range, without its "\n" or "\r\n".
func lineBounds(buf []byte, starts []int, i int) (a, b int) {
	a, b = starts[i], len(buf)
	if i+1 < len(starts) {
		b = starts[i+1] - 1
	} else if b > a && buf[b-1] == '\n' {
		b--
	}
	if b > a && buf[b-1] == '\r' {
		b--
	}
	return a, b
}

// prefix is a context line cut to its first maxTextChars characters.
func prefix(line []byte) string {
	a, b := window(line, 0, 0)
	return string(line[a:b])
}

// window is the byte range [a, b) of line that keeps maxTextChars
// characters around line[s:e], about as many before the match as after
// it; a shorter line is kept whole. It walks only the characters it
// keeps, so a long minified line costs the same as a short one.
func window(line []byte, s, e int) (a, b int) {
	if len(line) <= maxTextChars {
		return 0, len(line) // fewer bytes than the cap: fewer characters too
	}
	n := utf8.RuneCount(line[s:e])
	if n >= maxTextChars {
		return s, advance(line, s, maxTextChars)
	}
	budget := maxTextChars - n
	a = retreat(line, s, budget/2)
	b = advance(line, e, budget-utf8.RuneCount(line[a:s]))
	if left := budget - utf8.RuneCount(line[a:s]) - utf8.RuneCount(line[e:b]); left > 0 {
		a = retreat(line, a, left)
	}
	return a, b
}

// advance is the offset n characters after i (or the line's end).
func advance(line []byte, i, n int) int {
	for ; n > 0 && i < len(line); n-- {
		_, w := utf8.DecodeRune(line[i:])
		i += w
	}
	return i
}

// retreat is the offset n characters before i (or the line's start).
func retreat(line []byte, i, n int) int {
	for ; n > 0 && i > 0; n-- {
		_, w := utf8.DecodeLastRune(line[:i])
		i -= w
	}
	return i
}

// utf16Len is b's length in UTF-16 code units; an invalid byte counts one.
func utf16Len(b []byte) int {
	n := 0
	for len(b) > 0 {
		r, w := utf8.DecodeRune(b)
		if r >= 0x10000 {
			n += 2
		} else {
			n++
		}
		b = b[w:]
	}
	return n
}

func isASCII(s string) bool {
	for i := range len(s) {
		if s[i] >= utf8.RuneSelf {
			return false
		}
	}
	return true
}

// asciiLower appends src to dst with A–Z lower-cased; byte offsets are
// unchanged, so a match in the result is a match in src.
func asciiLower(dst, src []byte) []byte {
	dst = append(dst, src...)
	for i, c := range dst {
		if 'A' <= c && c <= 'Z' {
			dst[i] = c + 'a' - 'A'
		}
	}
	return dst
}
