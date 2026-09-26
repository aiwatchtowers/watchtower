package mcpoauth

import (
	"encoding/json"
	"fmt"
	"io"
)

// maxResponseBodyBytes bounds every JSON body this package reads from a
// remote server: discovery documents, and registration/token/error
// responses. These are OAuth metadata/token payloads that are normally well
// under 10 KB; 1 MB is generous headroom while still refusing to let a
// hostile or misbehaving server stream an unbounded body for the life of
// the request timeout (fetchJSON/postForm/Register all decode a body
// reachable at chat launch, via EnsureFresh's pre-launch refresh).
const maxResponseBodyBytes = 1 << 20 // 1 MB

// readLimitedBody reads at most maxResponseBodyBytes+1 bytes from r and
// errors if that limit was reached, so a caller never allocates or decodes
// an unbounded body.
func readLimitedBody(r io.Reader) ([]byte, error) {
	data, err := io.ReadAll(io.LimitReader(r, maxResponseBodyBytes+1))
	if err != nil {
		return nil, fmt.Errorf("reading response body: %w", err)
	}
	if len(data) > maxResponseBodyBytes {
		return nil, fmt.Errorf("response body exceeds %d byte limit", maxResponseBodyBytes)
	}
	return data, nil
}

// decodeLimitedJSON reads r (capped at maxResponseBodyBytes) and unmarshals
// it into out.
func decodeLimitedJSON(r io.Reader, out any) error {
	data, err := readLimitedBody(r)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, out)
}
