package rollout

import (
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"testing"

	"github.com/klauspost/compress/zstd"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const sample = `{"type":"event_msg","payload":{"type":"user_message","message":"example"}}` + "\n"

func writeFile(t *testing.T, content []byte) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "rollout-x.jsonl")
	require.NoError(t, os.WriteFile(path, content, 0o600))
	return path
}

func compress(t *testing.T, plain []byte) []byte {
	t.Helper()
	enc, err := zstd.NewWriter(nil)
	require.NoError(t, err)
	defer func() { _ = enc.Close() }()
	return enc.EncodeAll(plain, nil)
}

func readAll(t *testing.T, path string, limit int64) ([]byte, bool, error) {
	t.Helper()
	rc, compressed, err := open(path, limit)
	require.NoError(t, err)
	defer rc.Close()
	b, err := io.ReadAll(rc)
	return b, compressed, err
}

func TestRolloutOpen_PlainFileIsTheFileItself(t *testing.T) {
	path := writeFile(t, []byte(sample))
	rc, compressed, err := Open(path)
	require.NoError(t, err)
	defer rc.Close()
	assert.False(t, compressed)
	_, isFile := rc.(*os.File)
	assert.True(t, isFile, "a plain rollout keeps seeking and ReadAt")
	b, err := io.ReadAll(rc)
	require.NoError(t, err)
	assert.Equal(t, sample, string(b))
}

func TestRolloutOpen_ShortAndEmptyFilesArePlain(t *testing.T) {
	for _, content := range []string{"", "{", "\x28\xb5\x2f"} {
		got, compressed, err := readAll(t, writeFile(t, []byte(content)), MaxDecompressed)
		require.NoError(t, err)
		assert.False(t, compressed)
		assert.Equal(t, content, string(got))
	}
}

func TestRolloutOpen_CompressedDecodesInMemory(t *testing.T) {
	plain := bytes.Repeat([]byte(sample), 100)
	path := writeFile(t, compress(t, plain))
	got, compressed, err := readAll(t, path, MaxDecompressed)
	require.NoError(t, err)
	assert.True(t, compressed)
	assert.Equal(t, plain, got)
	entries, err := os.ReadDir(filepath.Dir(path))
	require.NoError(t, err)
	assert.Len(t, entries, 1, "decoding writes no sibling file")
}

func TestRolloutOpen_CorruptFrameIsAnError(t *testing.T) {
	_, compressed, err := readAll(t, writeFile(t, []byte("\x28\xb5\x2f\xfdnot a frame")), MaxDecompressed)
	assert.True(t, compressed)
	require.Error(t, err)
	assert.False(t, errors.Is(err, ErrTooLarge))
}

func TestRolloutOpen_MissingFile(t *testing.T) {
	_, _, err := Open(filepath.Join(t.TempDir(), "absent.jsonl"))
	assert.ErrorIs(t, err, os.ErrNotExist)
}

func TestRolloutOpen_DecompressedSizeCap(t *testing.T) {
	plain := bytes.Repeat([]byte(sample), 10)
	path := writeFile(t, compress(t, plain))

	got, _, err := readAll(t, path, int64(len(plain)))
	require.NoError(t, err, "exactly at the cap is fine")
	assert.Equal(t, plain, got)

	got, _, err = readAll(t, path, int64(len(plain))-1)
	require.ErrorIs(t, err, ErrTooLarge)
	assert.Len(t, got, len(plain)-1, "nothing past the cap is returned")

	// The shipped cap: one byte over 256 MiB of zeros fails.
	assert.EqualValues(t, 256<<20, MaxDecompressed)
	var buf bytes.Buffer
	enc, err := zstd.NewWriter(&buf)
	require.NoError(t, err)
	_, err = io.CopyN(enc, zeros{}, MaxDecompressed+1)
	require.NoError(t, err)
	require.NoError(t, enc.Close())
	rc, compressed, err := Open(writeFile(t, buf.Bytes()))
	require.NoError(t, err)
	defer rc.Close()
	assert.True(t, compressed)
	n, err := io.Copy(io.Discard, rc)
	require.ErrorIs(t, err, ErrTooLarge)
	assert.EqualValues(t, MaxDecompressed, n)
}

type zeros struct{}

func (zeros) Read(p []byte) (int, error) {
	clear(p)
	return len(p), nil
}
