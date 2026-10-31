package secure

import (
	"crypto/sha256"
	"crypto/subtle"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"golang.org/x/crypto/chacha20poly1305"
)

// SealedAssetLen is the sealed length of an asset with this header: one
// ciphertext ‖ tag per chunk.
func SealedAssetLen(h AssetHeader) uint64 {
	return uint64(h.ChunkCount) * (uint64(h.ChunkSize) + tagLen)
}

// DecryptAssetFile opens the sealed asset at src chunk by chunk into dst
// (created 0600 before the first plaintext byte, renamed into place only
// after the last chunk opened and the plaintext digest matched; removed on
// every failure). Memory stays at one chunk, whatever the size. The sealed
// length must be exactly the header's (ErrAssetTruncated, ErrOversized): a
// caller with a size cap checks the header's TotalLength before it downloads.
func DecryptAssetFile(src, dst string, d AssetDescriptor) (err error) {
	h := d.Header
	if want, herr := newAssetHeader(h.AssetID, h.ChunkSize, h.TotalLength); herr != nil || want != h {
		return ErrAssetBadHeader
	}
	in, err := os.Open(src)
	if err != nil {
		return fmt.Errorf("secure: open sealed asset: %w", err)
	}
	defer func() { _ = in.Close() }()
	st, err := in.Stat()
	if err != nil {
		return fmt.Errorf("secure: stat sealed asset: %w", err)
	}
	chunkLen := uint64(h.ChunkSize) + tagLen
	switch want := SealedAssetLen(h); {
	case uint64(st.Size()) < want:
		return ErrAssetTruncated
	case uint64(st.Size()) > want:
		return ErrOversized
	}
	aead, err := chacha20poly1305.New(d.Key[:])
	if err != nil {
		return ErrAuthenticationFailed
	}
	out, err := os.CreateTemp(filepath.Dir(dst), ".asset-*")
	if err != nil {
		return fmt.Errorf("secure: create asset output: %w", err)
	}
	tmp := out.Name()
	defer func() {
		if err != nil {
			_ = out.Close()
			_ = os.Remove(tmp)
		}
	}()
	if err = out.Chmod(0o600); err != nil {
		return fmt.Errorf("secure: chmod asset output: %w", err)
	}
	if err = decryptChunks(in, out, aead, d, chunkLen); err != nil {
		return err
	}
	if err = out.Sync(); err != nil {
		return fmt.Errorf("secure: sync asset output: %w", err)
	}
	if err = out.Close(); err != nil {
		return fmt.Errorf("secure: close asset output: %w", err)
	}
	if err = os.Rename(tmp, dst); err != nil {
		return fmt.Errorf("secure: place asset output: %w", err)
	}
	return nil
}

func decryptChunks(in io.Reader, out io.Writer, aead interface {
	Open(dst, nonce, ciphertext, additionalData []byte) ([]byte, error)
}, d AssetDescriptor, chunkLen uint64) error {
	h, digest := d.Header, sha256.New()
	encoded := h.encode()
	sealed := make([]byte, chunkLen)
	opened := make([]byte, 0, h.ChunkSize)
	defer clear(opened[:cap(opened)])
	remaining := h.TotalLength
	for c := range h.ChunkCount {
		if _, err := io.ReadFull(in, sealed); err != nil {
			if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
				return ErrAssetTruncated
			}
			return fmt.Errorf("secure: read sealed asset: %w", err)
		}
		var err error
		opened, err = aead.Open(opened[:0], chunkNonce(c), sealed, chunkAAD(encoded, h, c))
		if err != nil {
			return fmt.Errorf("asset chunk %d: %w", c, ErrAuthenticationFailed)
		}
		keep := min(remaining, uint64(h.ChunkSize))
		digest.Write(opened[:keep])
		if _, err := out.Write(opened[:keep]); err != nil {
			return fmt.Errorf("secure: write asset: %w", err)
		}
		remaining -= keep
	}
	if sum := digest.Sum(nil); subtle.ConstantTimeCompare(sum, d.PlaintextDigest[:]) != 1 {
		return ErrAssetDigestMismatch
	}
	return nil
}
