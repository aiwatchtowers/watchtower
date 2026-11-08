package planusage

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"time"
)

// A private publication-integrity receipt, not an authentication credential.
// Framing uses UTF-8 byte lengths; exact stored JSON is the publication unit.
func publicationDigest(limits, plot string) string {
	h := sha256.New()
	h.Write([]byte("watchtower.planusage.publication.v1\x00"))
	for _, text := range []string{limits, plot} {
		var size [8]byte
		binary.BigEndian.PutUint64(size[:], uint64(len(text)))
		h.Write(size[:])
		h.Write([]byte(text))
	}
	return hex.EncodeToString(h.Sum(nil))
}

// Only the Go-owned semantic plot builder mints a receipt for a publication.
// DB upserts carry it explicitly and never sign arbitrary stored candidates.
func buildPublication(fetched time.Time, limits []WindowLimit, encoded string, known bool, current map[string]bool) (string, string, error) {
	plot, err := BuildPlot(fetched, limits, known, current)
	if err != nil {
		return "", "", err
	}
	return plot, publicationDigest(encoded, plot), nil
}
