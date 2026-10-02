package codeindex

import (
	"bytes"
	"strings"
	"testing"
)

// sameShape fails unless masked keeps src's length and every newline.
func sameShape(t *testing.T, src, masked []byte) {
	t.Helper()
	if len(masked) != len(src) {
		t.Fatalf("masked length %d, want %d", len(masked), len(src))
	}
	for i := range src {
		if (src[i] == '\n') != (masked[i] == '\n') {
			t.Fatalf("newline moved at byte %d:\n%s", i, masked)
		}
	}
}

func TestMaskSQLiteTriggers(t *testing.T) {
	src := []byte(`-- +goose StatementBegin
CREATE TRIGGER IF NOT EXISTS entries_ai AFTER INSERT ON entries
WHEN NEW.value != ''
BEGIN
    UPDATE stores SET touched = 1 WHERE id = NEW.store_id;
END;
-- +goose StatementEnd
CREATE TABLE after_it (id INTEGER);
`)
	got := maskSQLiteTriggers(src)
	sameShape(t, src, got)
	s := string(got)
	if !strings.Contains(s, "CREATE TRIGGER IF NOT EXISTS entries_ai ") {
		t.Errorf("the trigger's head changed:\n%s", s)
	}
	for _, gone := range []string{"BEGIN", "UPDATE", "WHEN"} {
		if strings.Contains(s, gone) {
			t.Errorf("%s survived the mask:\n%s", gone, s)
		}
	}
	// The filler ends where END ended, so the statement keeps its last line.
	if !strings.Contains(s, "\nf();\n-- +goose StatementEnd") {
		t.Errorf("the filler is not right-aligned to END:\n%s", s)
	}
	if !strings.HasSuffix(s, "CREATE TABLE after_it (id INTEGER);\n") {
		t.Errorf("the statement after the trigger changed:\n%s", s)
	}
}

// What the mask must leave alone: a PostgreSQL trigger, a trigger named
// in a comment, a body with no END, and a body too short for the filler.
func TestMaskSQLiteTriggers_LeavesOtherTextAlone(t *testing.T) {
	for _, src := range []string{
		"CREATE TRIGGER t AFTER INSERT ON x FOR EACH ROW EXECUTE FUNCTION f();\nSELECT 1; BEGIN; END;\n",
		"-- see CREATE TRIGGER t ... BEGIN ... END;\nSELECT 1;\n",
		"CREATE TRIGGER t AFTER INSERT ON x BEGIN SELECT 1;\n",
		"CREATE TRIGGER t BEGIN END;",
		"",
	} {
		if got := maskSQLiteTriggers([]byte(src)); !bytes.Equal(got, []byte(src)) {
			t.Errorf("mask changed %q to %q", src, got)
		}
	}
}

func TestMaskGroovy(t *testing.T) {
	src := []byte("@CompileStatic\nclass Store extends Base implements Storable,\n    Closeable {\n}\n  trait Named {\n}\ndef implements = 1\n")
	got := maskGroovy(src)
	sameShape(t, src, got)
	want := "@CompileStatic\nclass Store extends Base                     \n              {\n}\n  class Named {\n}\ndef implements = 1\n"
	if string(got) != want {
		t.Errorf("maskGroovy =\n%q\nwant\n%q", got, want)
	}
	if plain := []byte("class Store {\n}\n"); !bytes.Equal(maskGroovy(plain), plain) {
		t.Error("a file with nothing to mask changed")
	}
}

// Prose that reads like a header — in a GroovyDoc, a line comment or a
// string — is left alone, so the comment keeps its terminator and the
// class after it keeps its header.
func TestMaskGroovy_LeavesCommentsAndStringsAlone(t *testing.T) {
	for _, src := range []string{
		"/** A class that implements caching. */\nclass Cache {\n}\n",
		"/**\n * class Foo implements Bar\n */\nclass Cache {\n}\n",
		"// this class Foo implements Bar\ndef x = 1\nclass Real {\n}\n",
		"def s = \"class X implements Y\"\nclass Z {\n}\n",
	} {
		if got := maskGroovy([]byte(src)); string(got) != src {
			t.Errorf("maskGroovy changed %q to %q", src, got)
		}
	}
}

func TestMaskObjC(t *testing.T) {
	src := []byte("typedef NS_ENUM(NSInteger, Shape) {\n    ShapeCircle,\n};\ntypedef NS_OPTIONS( NSUInteger , Opts ) {};\n")
	got := maskObjC(src)
	sameShape(t, src, got)
	want := "typedef enum               Shape  {\n    ShapeCircle,\n};\ntypedef enum                     Opts   {};\n"
	if string(got) != want {
		t.Errorf("maskObjC =\n%q\nwant\n%q", got, want)
	}
	if i := strings.Index(string(src), "Shape)"); string(got[i:i+5]) != "Shape" {
		t.Error("the enum's name moved")
	}
}
