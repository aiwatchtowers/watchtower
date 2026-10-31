package secure

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"

	"golang.org/x/crypto/chacha20poly1305"
)

// ChunkSize is the production asset chunk: 1 MiB.
const ChunkSize uint32 = 1 << 20

const (
	assetHeaderLen = 37
	// AssetDescriptorLen is the encoded descriptor: key 32 ‖ header 37 ‖ digest 32.
	AssetDescriptorLen = 101
	assetVersion       = 1
	assetSuite1        = 1
	// maxAssetTotal keeps every length computation far from overflow (1 TiB).
	maxAssetTotal uint64 = 1 << 40
)

var assetMagic = [3]byte{'W', 'T', 'A'}

// AssetHeader is 37 bytes on the wire: "WTA" | ver u8 (1) | suite u8 (1) |
// asset_id 16 | chunk_size u32 | total_len u64 | chunk_count u32. Suite 1 only.
type AssetHeader struct {
	AssetID     ID
	ChunkSize   uint32
	TotalLength uint64
	ChunkCount  uint32
}

// newAssetHeader refuses a zero chunk size, a total above 1 TiB and a chunk
// count beyond u32.
func newAssetHeader(id ID, chunkSize uint32, total uint64) (AssetHeader, error) {
	if chunkSize == 0 || total > maxAssetTotal {
		return AssetHeader{}, ErrAssetBadHeader
	}
	chunks := max(1, (total+uint64(chunkSize)-1)/uint64(chunkSize))
	if chunks > math.MaxUint32 {
		return AssetHeader{}, ErrAssetBadHeader
	}
	return AssetHeader{AssetID: id, ChunkSize: chunkSize, TotalLength: total, ChunkCount: uint32(chunks)}, nil
}

func (h AssetHeader) encode() []byte {
	out := make([]byte, 0, assetHeaderLen)
	out = append(out, assetMagic[:]...)
	out = append(out, assetVersion, assetSuite1)
	out = append(out, h.AssetID[:]...)
	out = binary.BigEndian.AppendUint32(out, h.ChunkSize)
	out = binary.BigEndian.AppendUint64(out, h.TotalLength)
	return binary.BigEndian.AppendUint32(out, h.ChunkCount)
}

func parseAssetHeader(b []byte) (AssetHeader, error) {
	if len(b) != assetHeaderLen || [3]byte(b[:3]) != assetMagic || b[3] != assetVersion || b[4] != assetSuite1 {
		return AssetHeader{}, ErrAssetBadHeader
	}
	h, err := newAssetHeader(ID(b[5:21]), binary.BigEndian.Uint32(b[21:25]), binary.BigEndian.Uint64(b[25:33]))
	if err != nil {
		return AssetHeader{}, err
	}
	if h.ChunkCount != binary.BigEndian.Uint32(b[33:37]) {
		return AssetHeader{}, ErrAssetBadHeader
	}
	return h, nil
}

// AssetDescriptor is what the owning record's inner frame carries.
type AssetDescriptor struct {
	Key             [32]byte
	Header          AssetHeader
	PlaintextDigest [32]byte
}

// Encode is key 32 ‖ header 37 ‖ SHA-256(plaintext) 32.
func (d AssetDescriptor) Encode() []byte {
	out := make([]byte, 0, AssetDescriptorLen)
	out = append(out, d.Key[:]...)
	out = append(out, d.Header.encode()...)
	return append(out, d.PlaintextDigest[:]...)
}

// ParseAssetDescriptor reads the 101-byte descriptor; its header must be valid.
func ParseAssetDescriptor(b []byte) (AssetDescriptor, error) {
	if len(b) != AssetDescriptorLen {
		return AssetDescriptor{}, ErrAssetBadHeader
	}
	h, err := parseAssetHeader(b[32:69])
	if err != nil {
		return AssetDescriptor{}, err
	}
	return AssetDescriptor{Key: [32]byte(b[:32]), Header: h, PlaintextDigest: [32]byte(b[69:])}, nil
}

func chunkNonce(c uint32) []byte {
	return binary.BigEndian.AppendUint64(make([]byte, 4, nonceLen), uint64(c))
}

// chunkAAD is header ‖ u64 c ‖ u8 last.
func chunkAAD(header []byte, h AssetHeader, c uint32) []byte {
	out := binary.BigEndian.AppendUint64(append([]byte(nil), header...), uint64(c))
	if c == h.ChunkCount-1 {
		return append(out, 1)
	}
	return append(out, 0)
}

// assetSealer seals chunk after chunk into one reused buffer.
type assetSealer struct {
	header  AssetHeader
	encoded []byte
	buf     []byte
	aead    interface {
		Seal(dst, nonce, plaintext, additionalData []byte) []byte
	}
}

func newAssetSealer(h AssetHeader, key []byte) (*assetSealer, error) {
	aead, err := chacha20poly1305.New(key)
	if err != nil {
		return nil, fmt.Errorf("secure: asset key: %w", err)
	}
	return &assetSealer{header: h, encoded: h.encode(), buf: make([]byte, h.ChunkSize, int(h.ChunkSize)+tagLen), aead: aead}, nil
}

// seal zero-pads plain (≤ chunk size) to the chunk size and returns
// ciphertext ‖ tag, valid until the next call.
func (s *assetSealer) seal(plain []byte, c uint32) []byte {
	buf := s.buf[:s.header.ChunkSize]
	clear(buf[copy(buf, plain):])
	return s.aead.Seal(buf[:0], chunkNonce(c), buf, chunkAAD(s.encoded, s.header, c))
}

func (s *assetSealer) wipe() { clear(s.buf[:cap(s.buf)]) }

// EncryptAsset seals plain in chunks of chunkSize. File layout: chunk_0 …
// chunk_{n-1} and nothing else; each chunk is chunkSize plaintext bytes (the
// last zero-padded) sealed with nonce u32 0 ‖ u64 c and AAD header ‖ u64 c ‖
// u8 last, plus a 16-byte tag. key MUST be fresh per asset: the nonce sequence
// is fixed, so a reused key repeats (key, nonce) pairs.
func EncryptAsset(plain []byte, assetID ID, key []byte, chunkSize uint32) ([]byte, AssetDescriptor, error) {
	if len(key) != chacha20poly1305.KeySize {
		return nil, AssetDescriptor{}, fmt.Errorf("secure: asset key length %d", len(key))
	}
	h, err := newAssetHeader(assetID, chunkSize, uint64(len(plain)))
	if err != nil {
		return nil, AssetDescriptor{}, err
	}
	s, err := newAssetSealer(h, key)
	if err != nil {
		return nil, AssetDescriptor{}, err
	}
	defer s.wipe()
	out := make([]byte, 0, int(h.ChunkCount)*(int(chunkSize)+tagLen))
	size := int(chunkSize)
	for c := range h.ChunkCount {
		start := min(int(c)*size, len(plain))
		out = append(out, s.seal(plain[start:min(start+size, len(plain))], c)...)
	}
	return out, AssetDescriptor{Key: [32]byte(key), Header: h, PlaintextDigest: sha256.Sum256(plain)}, nil
}

// DecryptAsset checks the sealed length against the descriptor's header
// (ErrAssetTruncated, ErrOversized), opens every chunk in order (a chunk that
// does not open is ErrAuthenticationFailed), trims to the total length and
// checks the plaintext digest.
func DecryptAsset(sealed []byte, d AssetDescriptor) ([]byte, error) {
	h := d.Header
	if want, err := newAssetHeader(h.AssetID, h.ChunkSize, h.TotalLength); err != nil || want != h {
		return nil, ErrAssetBadHeader
	}
	chunkLen := uint64(h.ChunkSize) + tagLen
	expected := uint64(h.ChunkCount) * chunkLen
	if uint64(len(sealed)) < expected {
		return nil, ErrAssetTruncated
	}
	if uint64(len(sealed)) > expected {
		return nil, ErrOversized
	}
	aead, err := chacha20poly1305.New(d.Key[:])
	if err != nil {
		return nil, ErrAuthenticationFailed
	}
	encoded := h.encode()
	out := make([]byte, 0, h.TotalLength)
	remaining := h.TotalLength
	opened := make([]byte, 0, h.ChunkSize)
	defer clear(opened[:cap(opened)])
	for c := range h.ChunkCount {
		start := uint64(c) * chunkLen
		opened, err = aead.Open(opened[:0], chunkNonce(c), sealed[start:start+chunkLen], chunkAAD(encoded, h, c))
		if err != nil {
			clear(out)
			return nil, fmt.Errorf("asset chunk %d: %w", c, ErrAuthenticationFailed)
		}
		keep := min(remaining, uint64(h.ChunkSize))
		out = append(out, opened[:keep]...)
		remaining -= keep
	}
	if digest := sha256.Sum256(out); subtle.ConstantTimeCompare(digest[:], d.PlaintextDigest[:]) != 1 {
		clear(out)
		return nil, ErrAssetDigestMismatch
	}
	return out, nil
}

// EncryptAssetFile streams src into dst with one chunk resident, under a fresh
// key, through a 0600 temp file beside dst that is renamed into place only
// when every chunk is written. A source that shrinks or grows while it is
// sealed fails (ErrAssetTruncated, ErrAssetSourceChanged).
func EncryptAssetFile(src, dst string, assetID ID) (AssetDescriptor, error) {
	in, err := os.Open(src)
	if err != nil {
		return AssetDescriptor{}, fmt.Errorf("secure: open asset source: %w", err)
	}
	defer func() { _ = in.Close() }()
	info, err := in.Stat()
	if err != nil {
		return AssetDescriptor{}, fmt.Errorf("secure: stat asset source: %w", err)
	}
	if info.Size() < 0 {
		return AssetDescriptor{}, ErrAssetSourceChanged
	}
	return encryptAssetStream(in, uint64(info.Size()), dst, assetID)
}

// encryptAssetStream is EncryptAssetFile's body over a reader that must hold
// exactly length bytes (the seam for read-failure tests).
func encryptAssetStream(in io.Reader, length uint64, dst string, assetID ID) (d AssetDescriptor, err error) {
	h, err := newAssetHeader(assetID, ChunkSize, length)
	if err != nil {
		return AssetDescriptor{}, err
	}
	key := make([]byte, chacha20poly1305.KeySize)
	defer clear(key)
	if _, err := rand.Read(key); err != nil {
		return AssetDescriptor{}, fmt.Errorf("secure: asset key: %w", err)
	}
	s, err := newAssetSealer(h, key)
	if err != nil {
		return AssetDescriptor{}, err
	}
	defer s.wipe()

	tmp, err := os.CreateTemp(filepath.Dir(dst), ".asset-*.tmp")
	if err != nil {
		return AssetDescriptor{}, fmt.Errorf("secure: create asset temp: %w", err)
	}
	defer func() {
		if err != nil {
			_ = tmp.Close()
			_ = os.Remove(tmp.Name())
		}
	}()
	if err := tmp.Chmod(0o600); err != nil {
		return AssetDescriptor{}, fmt.Errorf("secure: chmod asset temp: %w", err)
	}

	hasher := sha256.New()
	chunk := make([]byte, ChunkSize)
	defer clear(chunk)
	remaining := h.TotalLength
	for c := range h.ChunkCount {
		want := chunk[:min(remaining, uint64(ChunkSize))]
		if _, err := io.ReadFull(in, want); err != nil {
			if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
				return AssetDescriptor{}, ErrAssetTruncated
			}
			return AssetDescriptor{}, fmt.Errorf("secure: read asset source: %w", err)
		}
		hasher.Write(want)
		remaining -= uint64(len(want))
		if _, err := tmp.Write(s.seal(want, c)); err != nil {
			return AssetDescriptor{}, fmt.Errorf("secure: write asset: %w", err)
		}
	}
	n, err := io.ReadFull(in, chunk[:1])
	switch {
	case n != 0:
		return AssetDescriptor{}, ErrAssetSourceChanged
	case !errors.Is(err, io.EOF):
		return AssetDescriptor{}, fmt.Errorf("secure: read asset source: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		return AssetDescriptor{}, fmt.Errorf("secure: sync asset: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return AssetDescriptor{}, fmt.Errorf("secure: close asset: %w", err)
	}
	if err := os.Rename(tmp.Name(), dst); err != nil {
		return AssetDescriptor{}, fmt.Errorf("secure: place asset: %w", err)
	}
	d = AssetDescriptor{Key: [32]byte(key), Header: h}
	copy(d.PlaintextDigest[:], hasher.Sum(nil))
	return d, nil
}
