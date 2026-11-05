// Package rollout opens Codex rollout files, plain or zstd-compressed. Codex
// may store an older rollout as one zstd frame under the same .jsonl name;
// Open tells the two apart by the magic bytes and decompresses in memory
// only, so a reader never writes the transcript or a sibling file (FEED-01).
package rollout

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/klauspost/compress/zstd"
)

// MaxDecompressed caps the bytes one compressed rollout may expand to. Past
// it a read fails with ErrTooLarge instead of growing without bound.
const MaxDecompressed int64 = 256 << 20

// ErrTooLarge means a compressed rollout expands past MaxDecompressed.
var ErrTooLarge = errors.New("rollout: decompressed size over the cap")

// Magic opens a zstd frame.
var Magic = []byte{0x28, 0xb5, 0x2f, 0xfd}

// IsCompressed reports whether head, the first bytes of a file, opens a zstd
// frame.
func IsCompressed(head []byte) bool { return bytes.HasPrefix(head, Magic) }

// Open opens the rollout at path for reading. A plain file comes back as the
// *os.File itself at offset 0 (so it can still seek and ReadAt) and
// compressed is false. A zstd file comes back as a decoder over it that
// yields the decompressed text and fails with ErrTooLarge past
// MaxDecompressed; a frame that does not decode fails on Read. Close releases
// the decoder and the file.
func Open(path string) (rc io.ReadCloser, compressed bool, err error) {
	return open(path, MaxDecompressed)
}

func open(path string, limit int64) (io.ReadCloser, bool, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, false, err
	}
	head := make([]byte, len(Magic))
	n, err := f.ReadAt(head, 0)
	if err != nil && !errors.Is(err, io.EOF) {
		_ = f.Close()
		return nil, false, err
	}
	if !IsCompressed(head[:n]) {
		return f, false, nil
	}
	dec, err := zstd.NewReader(f,
		zstd.WithDecoderConcurrency(1),
		zstd.WithDecoderLowmem(true),
		zstd.WithDecoderMaxMemory(uint64(MaxDecompressed)))
	if err != nil {
		_ = f.Close()
		return nil, true, fmt.Errorf("rollout: zstd decoder: %w", err)
	}
	return &decoded{dec: dec, f: f, left: limit}, true, nil
}

// decoded reads a zstd stream with a cap on its decompressed size.
type decoded struct {
	dec  *zstd.Decoder
	f    *os.File
	left int64
}

func (d *decoded) Read(p []byte) (int, error) {
	if d.left < 0 {
		return 0, ErrTooLarge
	}
	// Read at most one byte past the cap: that byte proves the overflow
	// and is never handed out.
	if int64(len(p)) > d.left+1 {
		p = p[:d.left+1]
	}
	n, err := d.dec.Read(p)
	d.left -= int64(n)
	if d.left < 0 {
		return n + int(d.left), ErrTooLarge
	}
	if errors.Is(err, zstd.ErrDecoderSizeExceeded) {
		// A frame that declares a size past the cap fails before any byte.
		d.left = -1
		return n, ErrTooLarge
	}
	return n, err
}

func (d *decoded) Close() error {
	d.dec.Close()
	return d.f.Close()
}
