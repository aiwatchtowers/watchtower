package cmd

import (
	"encoding/json"
	"io"
	"sync"

	"watchtower/internal/sessioncleanup"
)

// streamObserver writes a cleanup's progress as JSON lines (spec §6): one
// object per event, then a done line carrying the --json result. Each line
// is one Encode under the mutex, so lines never interleave.
type streamObserver struct {
	mu  sync.Mutex
	enc *json.Encoder
	err error // first write error; later writes are skipped
}

func newStreamObserver(w io.Writer) *streamObserver {
	return &streamObserver{enc: json.NewEncoder(w)}
}

func (s *streamObserver) write(v any) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.err == nil {
		s.err = s.enc.Encode(v)
	}
	return s.err
}

type streamItems struct {
	Event string                `json:"event"`
	Items []sessioncleanup.Item `json:"items"`
}

type streamItem struct {
	Event string              `json:"event"`
	Item  sessioncleanup.Item `json:"item"`
}

type streamSized struct {
	Event      string `json:"event"`
	Key        string `json:"key"`
	Bytes      int64  `json:"bytes"`
	BytesKnown bool   `json:"bytes_known"`
}

type streamKey struct {
	Event string `json:"event"`
	Key   string `json:"key"`
}

type streamDone struct {
	Event string                `json:"event"`
	Plan  sessioncleanup.Result `json:"plan"`
}

func (s *streamObserver) Listed(items []sessioncleanup.Item) {
	if items == nil {
		items = []sessioncleanup.Item{}
	}
	_ = s.write(streamItems{"listed", items})
}

func (s *streamObserver) Checked(it sessioncleanup.Item) { _ = s.write(streamItem{"checked", it}) }

func (s *streamObserver) Sized(key string, bytes int64, known bool) {
	_ = s.write(streamSized{"sized", key, bytes, known})
}

func (s *streamObserver) Removing(key string) { _ = s.write(streamKey{"removing", key}) }

func (s *streamObserver) Removed(it sessioncleanup.Item) { _ = s.write(streamItem{"removed", it}) }

// done writes the last line; a broken stdout surfaces here as the error.
func (s *streamObserver) done(res sessioncleanup.Result) error {
	return s.write(streamDone{"done", res})
}
