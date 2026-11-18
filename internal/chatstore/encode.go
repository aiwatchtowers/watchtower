package chatstore

import (
	"bytes"
	"encoding/json"

	"github.com/rivo/uniseg"

	"watchtower/internal/chat"
)

// compactJSON marshals v without HTML escaping and without the encoder's
// trailing newline.
func compactJSON(v any) (string, error) {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return "", err
	}
	return string(bytes.TrimRight(b.Bytes(), "\n")), nil
}

// argsJSON is a tool_start's args as the Swift decoder stores them: the
// object (or array) re-serialized with sorted keys, "{}" for anything else.
func argsJSON(raw json.RawMessage) string {
	if len(raw) == 0 {
		return "{}"
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return "{}"
	}
	switch v.(type) {
	case map[string]any, []any:
	default:
		return "{}"
	}
	s, err := compactJSON(v)
	if err != nil {
		return "{}"
	}
	return s
}

// sourcesJSON is ChatSource.encodeList: "[]" for none.
func sourcesJSON(sources []chat.Source) string {
	if len(sources) == 0 {
		return "[]"
	}
	s, err := compactJSON(sources)
	if err != nil {
		return "[]"
	}
	return s
}

// metaJSON is ChatArtifactQueries.encodeMeta: sorted keys, "{}" for none.
func metaJSON(meta map[string]string) (string, error) {
	if len(meta) == 0 {
		return "{}", nil
	}
	return compactJSON(meta)
}

// prefixGraphemes is Swift's String.prefix(n): the first n grapheme clusters.
func prefixGraphemes(s string, n int) string {
	g := uniseg.NewGraphemes(s)
	end := 0
	for i := 0; i < n && g.Next(); i++ {
		_, end = g.Positions()
	}
	return s[:end]
}
