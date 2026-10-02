package codesearch

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"unicode/utf8"

	"watchtower/internal/codewalk"
)

func write(t *testing.T, root, rel, data string) {
	t.Helper()
	p := filepath.Join(root, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}
}

// search runs opt over root and returns every match plus the summary.
func search(t *testing.T, root string, opt Options) ([]Match, Summary) {
	t.Helper()
	if opt.Max == 0 {
		opt.Max = 2000
	}
	var got []Match
	sum, err := Run(context.Background(), root, opt, func(m Match) error {
		got = append(got, m)
		return nil
	})
	if err != nil {
		t.Fatalf("Run(%+v): %v", opt, err)
	}
	slices.SortFunc(got, func(a, b Match) int {
		if c := strings.Compare(a.Path, b.Path); c != 0 {
			return c
		}
		if a.Line != b.Line {
			return a.Line - b.Line
		}
		return a.Col - b.Col
	})
	return got, sum
}

// positions renders matches as path:line:col for compact comparisons.
func positions(ms []Match) []string {
	out := []string{}
	for _, m := range ms {
		out = append(out, fmt.Sprintf("%s:%d:%d", m.Path, m.Line, m.Col))
	}
	return out
}

func TestRun_SmartCase(t *testing.T) {
	root := t.TempDir()
	write(t, root, "a.go", "func saveNow() {}\n")
	write(t, root, "b.go", "var savenow = 1\n")

	cases := []struct {
		name string
		opt  Options
		want []string
	}{
		{"lower query is insensitive", Options{Query: "savenow"}, []string{"a.go:1:6", "b.go:1:5"}},
		{"an upper-case letter makes it sensitive", Options{Query: "SaveNow"}, []string{}},
		{"exact case still matches", Options{Query: "saveNow"}, []string{"a.go:1:6"}},
		{"--case forces sensitive", Options{Query: "savenow", Case: true}, []string{"b.go:1:5"}},
		{"regex smart case", Options{Query: "save.ow", Regex: true}, []string{"a.go:1:6", "b.go:1:5"}},
		{"regex with an upper literal", Options{Query: "save[N]ow", Regex: true}, []string{"a.go:1:6"}},
		{"regex escape is not upper case", Options{Query: `save\Sow`, Regex: true}, []string{"a.go:1:6", "b.go:1:5"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, _ := search(t, root, tc.opt)
			if p := positions(got); !slices.Equal(p, tc.want) {
				t.Fatalf("matches = %v, want %v", p, tc.want)
			}
		})
	}
}

func TestRun_NonASCIIInsensitive(t *testing.T) {
	root := t.TempDir()
	write(t, root, "ru.txt", "Привет мир\n")
	got, _ := search(t, root, Options{Query: "привет"})
	if p := positions(got); !slices.Equal(p, []string{"ru.txt:1:1"}) {
		t.Fatalf("matches = %v", p)
	}
}

func TestRun_Word(t *testing.T) {
	root := t.TempDir()
	write(t, root, "a.go", "id := idx + user_id\nreturn id\n")
	write(t, root, "a.php", "<?php\n$x = 1;\n$xy = 2;\necho $x;\n")

	got, _ := search(t, root, Options{Query: "id", Word: true})
	if p := positions(got); !slices.Equal(p, []string{"a.go:1:1", "a.go:2:8"}) {
		t.Errorf("--word id = %v", p)
	}
	got, _ = search(t, root, Options{Query: "$x", Word: true})
	if p := positions(got); !slices.Equal(p, []string{"a.php:2:1", "a.php:4:6"}) {
		t.Errorf("--word $x = %v", p)
	}
	// Without --word both are substrings.
	got, _ = search(t, root, Options{Query: "$x"})
	if len(got) != 3 {
		t.Errorf("$x without --word = %v, want 3", positions(got))
	}
	// `$` is an identifier character: `x` alone is not a word inside `$x`.
	got, _ = search(t, root, Options{Query: "x", Word: true})
	if len(got) != 0 {
		t.Errorf("--word x = %v, want none", positions(got))
	}
	// A rejected candidate does not hide an overlapping one after it.
	write(t, root, "b.txt", "xa-a-a\n")
	got, _ = search(t, root, Options{Query: "a-a", Word: true})
	if p := positions(got); !slices.Equal(p, []string{"b.txt:1:4"}) {
		t.Errorf("--word a-a = %v, want [b.txt:1:4]", p)
	}
}

func TestRun_WordWithRegex(t *testing.T) {
	root := t.TempDir()
	write(t, root, "a.go", "id1 idx id2\n")
	got, _ := search(t, root, Options{Query: `id\d`, Regex: true, Word: true})
	if p := positions(got); !slices.Equal(p, []string{"a.go:1:1", "a.go:1:9"}) {
		t.Fatalf("matches = %v", p)
	}
}

func TestRun_InvalidQueries(t *testing.T) {
	root := t.TempDir()
	for name, opt := range map[string]Options{
		"bad regex":   {Query: "(", Regex: true, Max: 1},
		"empty":       {Query: "", Max: 1},
		"two lines":   {Query: "a\nb", Max: 1},
		"zero max":    {Query: "a"},
		"neg context": {Query: "a", Max: 1, Context: -1},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := Run(context.Background(), root, opt, func(Match) error { return nil })
			if !errors.Is(err, ErrInvalidQuery) {
				t.Fatalf("err = %v, want ErrInvalidQuery", err)
			}
		})
	}
}

func TestRun_UTF16Columns(t *testing.T) {
	root := t.TempDir()
	write(t, root, "e.txt", "😀 x\n")      // 😀 is 2 UTF-16 units
	write(t, root, "r.txt", "привет x\n") // 6 Cyrillic letters, 1 unit each
	write(t, root, "m.txt", "a😀b😀x\n")    // two emoji
	got, _ := search(t, root, Options{Query: "x"})
	want := []string{"e.txt:1:4", "m.txt:1:7", "r.txt:1:8"}
	if p := positions(got); !slices.Equal(p, want) {
		t.Fatalf("matches = %v, want %v", p, want)
	}
}

func TestRun_TextCapAndContext(t *testing.T) {
	root := t.TempDir()
	long := strings.Repeat("a", 5000) + "NEEDLE" + strings.Repeat("b", 5000)
	write(t, root, "long.txt", "l1\nl2\nl3\n"+long+"\nl5\nl6\nl7\n")

	got, _ := search(t, root, Options{Query: "NEEDLE", Context: 2})
	if len(got) != 1 {
		t.Fatalf("matches = %v", positions(got))
	}
	m := got[0]
	if n := utf8.RuneCountInString(m.Text); n != maxTextChars {
		t.Errorf("text has %d chars, want %d", n, maxTextChars)
	}
	if !strings.Contains(m.Text, "NEEDLE") {
		t.Errorf("capped text lost the match")
	}
	if m.Line != 4 || m.Col != 5001 {
		t.Errorf("at %d:%d, want 4:5001", m.Line, m.Col)
	}
	if !slices.Equal(m.Before, []string{"l2", "l3"}) || !slices.Equal(m.After, []string{"l5", "l6"}) {
		t.Errorf("before %v after %v", m.Before, m.After)
	}

	got, _ = search(t, root, Options{Query: "l1"})
	if m := got[0]; m.Before == nil || len(m.Before) != 0 || len(m.After) != 0 {
		t.Errorf("context 0 = before %#v after %#v, want empty non-nil", m.Before, m.After)
	}
	got, _ = search(t, root, Options{Query: "l2", Context: 3})
	if m := got[0]; !slices.Equal(m.Before, []string{"l1"}) || len(m.After) != 3 {
		t.Errorf("context at file start = before %v after %d lines", m.Before, len(m.After))
	}
	if n := utf8.RuneCountInString(got[0].After[1]); n != maxTextChars {
		t.Errorf("a long context line has %d chars, want %d", n, maxTextChars)
	}
}

func TestRun_CRLFLines(t *testing.T) {
	root := t.TempDir()
	write(t, root, "w.txt", "one\r\ntwo end\r\n")
	got, _ := search(t, root, Options{Query: "end", Context: 1})
	if len(got) != 1 || got[0].Text != "two end" || !slices.Equal(got[0].Before, []string{"one"}) {
		t.Fatalf("got %+v", got)
	}
	got, _ = search(t, root, Options{Query: `end$`, Regex: true})
	if len(got) != 1 {
		t.Fatalf("end$ matched %d, want 1", len(got))
	}
}

func TestRun_MaxTruncates(t *testing.T) {
	root := t.TempDir()
	write(t, root, "a.txt", strings.Repeat("hit\n", 4))
	write(t, root, "b.txt", strings.Repeat("hit\n", 4))

	got, sum := search(t, root, Options{Query: "hit", Max: 5})
	if len(got) != 5 || sum.Matches != 5 || !sum.Truncated {
		t.Fatalf("%d matches, summary %+v; want 5 and truncated", len(got), sum)
	}
	got, sum = search(t, root, Options{Query: "hit", Max: 8})
	if len(got) != 8 || sum.Truncated || sum.Files != 2 {
		t.Fatalf("%d matches, summary %+v; want 8, two files, not truncated", len(got), sum)
	}
}

// Every match of one file is emitted together, not interleaved with
// another file's.
func TestRun_FileMatchesAreContiguous(t *testing.T) {
	root := t.TempDir()
	for i := range 50 {
		write(t, root, fmt.Sprintf("f%02d.txt", i), strings.Repeat("hit\n", 20))
	}
	var order []string
	_, err := Run(context.Background(), root, Options{Query: "hit", Max: 2000}, func(m Match) error {
		order = append(order, m.Path)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	for i, p := range order {
		if i > 0 && order[i-1] != p {
			if seen[p] {
				t.Fatalf("%s's matches are split", p)
			}
		}
		seen[p] = true
	}
}

func TestRun_SizeAndBinary(t *testing.T) {
	root := t.TempDir()
	write(t, root, "min.js", strings.Repeat("x", 3<<20)+"needle")
	write(t, root, "huge.js", strings.Repeat("x", codewalk.MaxSearchBytes+(1<<20))+"needle")
	write(t, root, "blob.bin", "\x00\x01needle")
	got, sum := search(t, root, Options{Query: "needle"})
	if p := positions(got); !slices.Equal(p, []string{"min.js:1:3145729"}) {
		t.Fatalf("matches = %v", p)
	}
	if sum.Files != 1 {
		t.Errorf("summary %+v", sum)
	}
}

func TestRun_EmitErrorStops(t *testing.T) {
	root := t.TempDir()
	write(t, root, "a.txt", "hit one\nhit two\n")
	boom := errors.New("boom")
	_, err := Run(context.Background(), root, Options{Query: "hit", Max: 10}, func(Match) error { return boom })
	if !errors.Is(err, boom) {
		t.Fatalf("err = %v, want boom", err)
	}
}

func TestRun_CancelledContext(t *testing.T) {
	root := t.TempDir()
	write(t, root, "a.txt", "hit\n")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	n := 0
	_, err := Run(ctx, root, Options{Query: "hit", Max: 10}, func(Match) error { n++; return nil })
	if !errors.Is(err, context.Canceled) || n != 0 {
		t.Fatalf("err = %v after %d matches, want context.Canceled and none", err, n)
	}
}

func TestRun_UnreadableRoot(t *testing.T) {
	_, err := Run(context.Background(), filepath.Join(t.TempDir(), "missing"), Options{Query: "a", Max: 1}, func(Match) error { return nil })
	if err == nil || errors.Is(err, ErrInvalidQuery) {
		t.Fatalf("err = %v, want a walk error", err)
	}
}

func TestWindow(t *testing.T) {
	line := []byte(strings.Repeat("é", 1000))
	got := window(line, 1500, 1502) // the 751st rune
	if utf8.RuneCount(got) != maxTextChars || !utf8.Valid(got) {
		t.Fatalf("window = %d runes, valid %v", utf8.RuneCount(got), utf8.Valid(got))
	}
	if short := window([]byte("abc"), 1, 2); !bytes.Equal(short, []byte("abc")) {
		t.Errorf("short line = %q", short)
	}
	// A match at the very end keeps the window inside the line.
	end := []byte(strings.Repeat("a", 1000) + "Z")
	if got := window(end, 1000, 1001); !bytes.HasSuffix(got, []byte("Z")) || utf8.RuneCount(got) != maxTextChars {
		t.Errorf("end window = %q…", got[:10])
	}
}
