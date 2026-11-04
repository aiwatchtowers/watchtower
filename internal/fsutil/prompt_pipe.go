package fsutil

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"sync"
)

// FDPayload is one payload handed to a child over an inherited pipe. Path
// is how the child names it (/dev/fd/N); the content never touches disk.
type FDPayload struct {
	Path string
	File *os.File // the read end the child inherits
}

// payloadWriters tracks the goroutines feeding payload pipes (tests wait on
// it to prove none is left blocked).
var payloadWriters sync.WaitGroup

// AttachPayloads hands each content to cmd over its own pipe: the read end
// joins cmd.ExtraFiles (fd 3 + its index there), and a goroutine writes the
// content into the write end and closes it. A content larger than the pipe
// buffer is fine: the writer blocks until the child reads, and stops with
// an error once the child exits without reading. Call cleanup after
// cmd.Start, whether it succeeded or not: it closes the parent's copies of
// the read ends. Call it before cmd is built again for a respawn: every
// spawn needs fresh pipes.
func AttachPayloads(cmd *exec.Cmd, contents ...string) ([]FDPayload, func(), error) {
	payloads := make([]FDPayload, 0, len(contents))
	cleanup := func() {
		for _, p := range payloads {
			_ = p.File.Close()
		}
	}
	for _, content := range contents {
		r, w, err := os.Pipe()
		if err != nil {
			cleanup()
			return nil, func() {}, fmt.Errorf("creating payload pipe: %w", err)
		}
		fd := 3 + len(cmd.ExtraFiles)
		cmd.ExtraFiles = append(cmd.ExtraFiles, r)
		payloads = append(payloads, FDPayload{Path: fmt.Sprintf("/dev/fd/%d", fd), File: r})
		payloadWriters.Add(1)
		go func() {
			defer payloadWriters.Done()
			_, _ = io.WriteString(w, content) // EPIPE when the child never reads: nothing to do
			_ = w.Close()
		}()
	}
	return payloads, cleanup, nil
}

// waitPayloadWriters blocks until every payload writer has returned.
func waitPayloadWriters() { payloadWriters.Wait() }

// PayloadPath is the path AttachPayloads gives the i-th payload of a cmd
// with no other ExtraFiles, for argv built before the cmd exists.
func PayloadPath(i int) string { return fmt.Sprintf("/dev/fd/%d", 3+i) }
