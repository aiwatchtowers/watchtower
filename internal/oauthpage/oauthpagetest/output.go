// Package oauthpagetest holds test helpers for the loopback OAuth logins.
package oauthpagetest

import (
	"bytes"
	"strings"
	"sync"
)

// Output is a goroutine-safe io.Writer a test hands to a Login as its
// output. WaitFor and WaitURL block until Login has printed what they look
// for — no polling and no deadline: a Login that never prints is caught by
// the package's go test timeout.
type Output struct {
	mu   sync.Mutex
	buf  bytes.Buffer
	cond *sync.Cond // made lazily under mu; broadcast on every write
}

func (o *Output) Write(p []byte) (int, error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	n, err := o.buf.Write(p)
	if o.cond != nil {
		o.cond.Broadcast()
	}
	return n, err
}

// String returns everything written so far.
func (o *Output) String() string {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.buf.String()
}

// WaitFor blocks until the output contains text and returns the output at
// that moment.
func (o *Output) WaitFor(text string) string {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.cond == nil {
		o.cond = sync.NewCond(&o.mu)
	}
	for !strings.Contains(o.buf.String(), text) {
		o.cond.Wait()
	}
	return o.buf.String()
}

// WaitURL blocks until the output holds a complete URL starting with prefix
// (one followed by a newline or a space) and returns that URL.
func (o *Output) WaitURL(prefix string) string {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.cond == nil {
		o.cond = sync.NewCond(&o.mu)
	}
	for {
		s := o.buf.String()
		if idx := strings.Index(s, prefix); idx != -1 {
			if end := strings.IndexAny(s[idx:], "\n "); end != -1 {
				return s[idx : idx+end]
			}
		}
		o.cond.Wait()
	}
}
