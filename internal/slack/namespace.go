package slack

import (
	"encoding/json"
	"strconv"
	"strings"
)

func Namespace(accountID int64, rawID string) string {
	if rawID == "" {
		return ""
	}
	return strconv.FormatInt(accountID, 10) + ":" + rawID
}

func SplitAccountID(id string) (accountID int64, rawID string, ok bool) {
	idx := strings.IndexByte(id, ':')
	if idx <= 0 {
		return 0, id, false
	}
	n, err := strconv.ParseInt(id[:idx], 10, 64)
	if err != nil {
		return 0, id, false
	}
	return n, id[idx+1:], true
}

// RawIDsJSON takes a JSON array of Slack ids as stored (e.g. `["1:U456"]`) and
// returns the same array with every element reduced to its raw form (e.g.
// `["U456"]`). It is for rendering an id blob into AI prompt text that must be
// matched against model-authored content, which carries raw ids regardless of
// how the blob itself is namespaced — the input-side counterpart of matching
// a namespaced id against raw text via SplitAccountID.
//
// Anything that isn't a JSON array of strings — empty string, empty array,
// malformed JSON, non-array JSON — is returned unchanged. These are prompt
// strings: a parse failure must never panic or blank the block, only skip
// the rewrite. A non-namespaced element passes through unchanged too, since
// SplitAccountID already returns it as its own raw form.
func RawIDsJSON(blob string) string {
	if blob == "" || blob == "[]" {
		return blob
	}
	var ids []string
	if err := json.Unmarshal([]byte(blob), &ids); err != nil {
		return blob
	}
	raw := make([]string, len(ids))
	for i, id := range ids {
		_, rawID, _ := SplitAccountID(id)
		raw[i] = rawID
	}
	out, err := json.Marshal(raw)
	if err != nil {
		return blob
	}
	return string(out)
}
