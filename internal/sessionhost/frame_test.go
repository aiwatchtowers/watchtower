package sessionhost

import (
	"bytes"
	"errors"
	"testing"
)

func TestFrame_RoundTrip(t *testing.T) {
	var buf bytes.Buffer
	if err := WriteFrame(&buf, Output, []byte("hi")); err != nil {
		t.Fatal(err)
	}
	if want := []byte{0x84, 0, 0, 0, 2, 'h', 'i'}; !bytes.Equal(buf.Bytes(), want) {
		t.Fatalf("bytes = %x, want %x", buf.Bytes(), want)
	}
	typ, p, err := ReadFrame(&buf)
	if err != nil || typ != Output || string(p) != "hi" {
		t.Fatalf("got %x %q %v", typ, p, err)
	}
}

func TestFrame_RejectsOversize(t *testing.T) {
	hdr := []byte{byte(Output), 0, 0x10, 0, 1}
	if _, _, err := ReadFrame(bytes.NewReader(hdr)); !errors.Is(err, ErrFrameTooLarge) {
		t.Fatalf("err = %v", err)
	}
	if err := WriteFrame(&bytes.Buffer{}, Output, make([]byte, MaxPayload+1)); !errors.Is(err, ErrFrameTooLarge) {
		t.Fatalf("write err = %v", err)
	}
}

func TestFrame_Truncated(t *testing.T) {
	if _, _, err := ReadFrame(bytes.NewReader(nil)); err == nil || err.Error() != "EOF" {
		t.Fatalf("empty err = %v", err)
	}
	if _, _, err := ReadFrame(bytes.NewReader([]byte{0x84, 0, 0, 0, 5, 'a'})); err == nil {
		t.Fatal("expected error on short payload")
	}
}
