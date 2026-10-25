package media

import (
	"bytes"
	"encoding/binary"
	"errors"
	"image"
	_ "image/gif"  // DecodeConfig: headers only
	_ "image/jpeg" // DecodeConfig: headers only
	_ "image/png"  // DecodeConfig: headers only
	"io"
	"net/http"
	"os"
)

// Image caps (Global Constraints): what is downloaded, what is sent to the
// model, and the junk filter.
const (
	maxMediaDownload   = 25 << 20
	maxModelImageBytes = 5 << 20
	maxModelImageSide  = 8000
	downscaleSide      = 2048
	minImageBytes      = 2 << 10
	maxJunkSide        = 16
	// maxConvertPixels bounds what sips is asked to decode: a header that
	// declares more is refused too_large without any decode.
	maxConvertPixels = 100_000_000
)

// The media types sent to the model as they are, and those sips converts.
const (
	typePNG  = "image/png"
	typeJPEG = "image/jpeg"
	typeGIF  = "image/gif"
	typeWebP = "image/webp"
	typeHEIC = "image/heic"
	typeTIFF = "image/tiff"
)

// sniffType names an image type from the file's first bytes ("" for
// anything else, SVG included); the declared type is never trusted.
func sniffType(head []byte) string {
	switch ct := http.DetectContentType(head); ct {
	case typePNG, typeJPEG, typeGIF, typeWebP:
		return ct
	}
	if len(head) >= 12 && string(head[4:8]) == "ftyp" {
		switch string(head[8:12]) {
		case "heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1":
			return typeHEIC
		}
	}
	if bytes.HasPrefix(head, []byte("II*\x00")) || bytes.HasPrefix(head, []byte("MM\x00*")) {
		return typeTIFF
	}
	return ""
}

// errBadHeader marks an image whose header cannot be read.
var errBadHeader = errors.New("media: unreadable image header")

// sniffImage reads only the header of the file at path: its sniffed type
// and declared size (0×0 for HEIC/TIFF, which sips converts first). Nothing
// is decoded beyond the header.
func sniffImage(path string) (mediaType string, w, h int, err error) {
	f, err := os.Open(path)
	if err != nil {
		return "", 0, 0, openError{err}
	}
	defer f.Close()
	head := make([]byte, 512)
	n, err := io.ReadFull(f, head)
	if err != nil && !errors.Is(err, io.ErrUnexpectedEOF) && !errors.Is(err, io.EOF) {
		return "", 0, 0, openError{err}
	}
	head = head[:n]
	mediaType = sniffType(head)
	switch mediaType {
	case typePNG, typeJPEG, typeGIF:
		if _, err := f.Seek(0, io.SeekStart); err != nil {
			return "", 0, 0, openError{err}
		}
		cfg, _, err := image.DecodeConfig(f)
		if err != nil {
			return mediaType, 0, 0, errBadHeader
		}
		return mediaType, cfg.Width, cfg.Height, nil
	case typeWebP:
		w, h, ok := webpSize(head)
		if !ok {
			return mediaType, 0, 0, errBadHeader
		}
		return mediaType, w, h, nil
	}
	return mediaType, 0, 0, nil
}

// webpSize reads a WebP canvas size from the RIFF header (VP8X, lossy VP8
// or lossless VP8L), never decoding the image.
func webpSize(b []byte) (w, h int, ok bool) {
	if len(b) < 30 || string(b[0:4]) != "RIFF" || string(b[8:12]) != "WEBP" {
		return 0, 0, false
	}
	le24 := func(p []byte) int { return int(p[0]) | int(p[1])<<8 | int(p[2])<<16 }
	switch string(b[12:16]) {
	case "VP8X":
		return le24(b[24:27]) + 1, le24(b[27:30]) + 1, true
	case "VP8 ":
		if b[23] != 0x9d || b[24] != 0x01 || b[25] != 0x2a {
			return 0, 0, false
		}
		return int(binary.LittleEndian.Uint16(b[26:28]) & 0x3fff), int(binary.LittleEndian.Uint16(b[28:30]) & 0x3fff), true
	case "VP8L":
		if b[20] != 0x2f {
			return 0, 0, false
		}
		v := binary.LittleEndian.Uint32(b[21:25])
		return int(v&0x3fff) + 1, int((v>>14)&0x3fff) + 1, true
	}
	return 0, 0, false
}

// isJunk is the junk filter: tiny files and tracking-pixel sizes.
func isJunk(size int64, w, h int) bool {
	return size < minImageBytes || w <= maxJunkSide || h <= maxJunkSide
}

// fitsModel reports an image the model takes as it is.
func fitsModel(size int64, w, h int) bool {
	return size <= maxModelImageBytes && w <= maxModelImageSide && h <= maxModelImageSide
}

func fileSize(path string) (int64, error) {
	info, err := os.Stat(path)
	if err != nil {
		return 0, openError{err}
	}
	return info.Size(), nil
}
