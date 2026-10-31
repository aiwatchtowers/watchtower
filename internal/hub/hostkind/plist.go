package hostkind

import (
	"bytes"
	"encoding/xml"
	"errors"
	"unicode/utf16"
)

// errPlist: an Info.plist that does not parse, or names no bundle id.
var errPlist = errors.New("hostkind: unreadable Info.plist")

const bundleIDKey = "CFBundleIdentifier"

// plistBundleID is an Info.plist's top-level CFBundleIdentifier, from an XML
// plist (what scripts/build-app.sh writes) or a binary one (bplist00, what
// Xcode and plutil may write). An empty one is errPlist too.
func plistBundleID(raw []byte) (string, error) {
	read := xmlBundleID
	if bytes.HasPrefix(raw, []byte("bplist00")) {
		read = binaryBundleID
	}
	id, err := read(raw)
	if err == nil && id == "" {
		return "", errPlist
	}
	return id, err
}

// xmlBundleID reads <plist><dict>…<key>CFBundleIdentifier</key><string>id…
func xmlBundleID(raw []byte) (string, error) {
	d := xml.NewDecoder(bytes.NewReader(raw))
	depth, wantID := 0, false
	for {
		tok, err := d.Token()
		if err != nil { // io.EOF included: no bundle id
			return "", errPlist
		}
		switch t := tok.(type) {
		case xml.EndElement:
			depth--
		case xml.StartElement:
			depth++
			if depth == 1 && t.Name.Local != "plist" || depth == 2 && t.Name.Local != "dict" {
				return "", errPlist
			}
			if depth != 3 {
				continue
			}
			// A child of the top dict: read it whole (its end is consumed).
			depth--
			switch {
			case wantID && t.Name.Local == "string":
				var id string
				if err := d.DecodeElement(&id, &t); err != nil {
					return "", errPlist
				}
				return id, nil
			case wantID:
				return "", errPlist
			case t.Name.Local == "key":
				var key string
				if err := d.DecodeElement(&key, &t); err != nil {
					return "", errPlist
				}
				wantID = key == bundleIDKey
			default:
				if err := d.Skip(); err != nil {
					return "", errPlist
				}
			}
		}
	}
}

// binaryBundleID reads a bplist00: the trailer, the offset table and the
// top dict's string keys and values (ASCII 0x5_ or UTF-16BE 0x6_ strings,
// short or with an int length).
func binaryBundleID(raw []byte) (string, error) {
	if len(raw) < 8+32 {
		return "", errPlist
	}
	tr := raw[len(raw)-32:]
	offSize, refSize := int(tr[6]), int(tr[7])
	numObjects, top, tableOff := beUint(tr[8:16]), beUint(tr[16:24]), beUint(tr[24:32])
	if offSize < 1 || offSize > 8 || refSize < 1 || refSize > 8 || top >= numObjects ||
		tableOff >= uint64(len(raw)) || numObjects > (uint64(len(raw))-tableOff)/uint64(offSize) {
		return "", errPlist
	}
	object := func(ref uint64) (uint64, bool) {
		if ref >= numObjects {
			return 0, false
		}
		at := tableOff + ref*uint64(offSize)
		off := beUint(raw[at : at+uint64(offSize)])
		return off, off < tableOff
	}
	// length is an object's count and where its content starts.
	length := func(off uint64) (n, start uint64, ok bool) {
		if lo := uint64(raw[off] & 0x0F); lo != 0x0F {
			return lo, off + 1, true
		}
		if off+2 > tableOff || raw[off+1]>>4 != 0x1 {
			return 0, 0, false
		}
		size := uint64(1) << (raw[off+1] & 0x0F)
		if size > 8 || off+2+size > tableOff {
			return 0, 0, false
		}
		return beUint(raw[off+2 : off+2+size]), off + 2 + size, true
	}
	// strAt is a string object's content in place, and whether it is UTF-16
	// (count = len(content)/2) rather than ASCII; nothing is copied.
	strAt := func(ref uint64) (content []byte, wide, ok bool) {
		off, ok := object(ref)
		if !ok {
			return nil, false, false
		}
		n, start, ok := length(off)
		if !ok {
			return nil, false, false
		}
		switch raw[off] >> 4 {
		case 0x5:
			if n <= tableOff-start {
				return raw[start : start+n], false, true
			}
		case 0x6:
			if n <= (tableOff-start)/2 {
				return raw[start : start+2*n], true, true
			}
		}
		return nil, false, false
	}
	// isKey compares a string object with bundleIDKey without decoding it.
	isKey := func(ref uint64) bool {
		content, wide, ok := strAt(ref)
		if !ok {
			return false
		}
		if !wide {
			return string(content) == bundleIDKey // no allocation: compared in place
		}
		if len(content) != 2*len(bundleIDKey) {
			return false
		}
		for i := 0; i < len(bundleIDKey); i++ {
			if content[2*i] != 0 || content[2*i+1] != bundleIDKey[i] {
				return false
			}
		}
		return true
	}
	str := func(ref uint64) (string, bool) {
		content, wide, ok := strAt(ref)
		if !ok || !wide {
			return string(content), ok
		}
		units := make([]uint16, len(content)/2)
		for i := range units {
			units[i] = uint16(content[2*i])<<8 | uint16(content[2*i+1])
		}
		return string(utf16.Decode(units)), true
	}

	off, ok := object(top)
	if !ok || raw[off]>>4 != 0xD {
		return "", errPlist
	}
	n, start, ok := length(off)
	if !ok || n > (tableOff-start)/uint64(2*refSize) {
		return "", errPlist
	}
	ref := func(i uint64) uint64 {
		at := start + i*uint64(refSize)
		return beUint(raw[at : at+uint64(refSize)])
	}
	for i := uint64(0); i < n; i++ {
		if isKey(ref(i)) {
			if id, ok := str(ref(n + i)); ok {
				return id, nil
			}
			return "", errPlist
		}
	}
	return "", errPlist
}

// beUint reads a big-endian unsigned integer of 1–8 bytes.
func beUint(b []byte) uint64 {
	var v uint64
	for _, c := range b {
		v = v<<8 | uint64(c)
	}
	return v
}
