package secure

import (
	"encoding/hex"
	"fmt"
	"strings"
)

// ID is a hub or device id: the 16 UUID bytes as they go on the wire.
type ID [16]byte

// ParseID reads the canonical 8-4-4-4-12 form in either case (Swift
// UUID(uuidString:)).
func ParseID(s string) (ID, error) {
	var id ID
	if len(s) != 36 {
		return id, fmt.Errorf("secure: bad id %q", s)
	}
	digits := make([]byte, 0, 32)
	for i := 0; i < len(s); i++ {
		c := s[i]
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if c != '-' {
				return ID{}, fmt.Errorf("secure: bad id %q", s)
			}
			continue
		}
		digits = append(digits, c)
	}
	if n, err := hex.Decode(id[:], digits); err != nil || n != len(id) {
		return ID{}, fmt.Errorf("secure: bad id %q", s)
	}
	return id, nil
}

// String is Swift's uuidString: uppercase canonical.
func (id ID) String() string {
	h := strings.ToUpper(hex.EncodeToString(id[:]))
	return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:32]
}
