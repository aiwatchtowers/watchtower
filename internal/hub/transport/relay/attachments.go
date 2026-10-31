package relay

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"syscall"

	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/relay/relayv1"
)

// maxRedirects caps the redirects an attachment PUT or GET follows.
const maxRedirects = 3

// errTooLarge: a download went past the attachment cap.
var errTooLarge = errors.New("relay: download exceeds the attachment cap")

// openNoFollow opens path read-only, refusing a symlink as the last component
// and never blocking on a FIFO.
func openNoFollow(path string) (*os.File, error) {
	return os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
}

// checkRedirect follows at most maxRedirects redirects and never one that
// leaves HTTPS once the request started on it.
func checkRedirect(req *http.Request, via []*http.Request) error {
	if len(via) >= maxRedirects {
		return errors.New("relay: too many redirects")
	}
	if via[0].URL.Scheme == "https" && req.URL.Scheme != "https" {
		return errors.New("relay: redirect leaves HTTPS")
	}
	return nil
}

// upload creates an upload slot for f's bytes in zone and PUTs the (already
// sealed) file to its URL with the slot's headers; it returns the attachment
// id. The URL is opaque: it is used as given, never parsed or logged.
func (t *Transport) upload(ctx context.Context, zone string, f *os.File) (string, error) {
	info, err := f.Stat()
	if err != nil {
		return "", err
	}
	size := info.Size()
	resp, err := t.do(ctx, &relayv1.Request{Op: &relayv1.Request_CreateUpload{CreateUpload: &relayv1.CreateUpload{
		Zone: zone, Size: uint64(size),
	}}})
	if err != nil {
		return "", fmt.Errorf("create_upload: %w", err)
	}
	up := resp.GetUpload()
	if up.GetAttachmentId() == "" || up.GetUrl() == "" {
		return "", fmt.Errorf("create_upload: no upload slot in the answer")
	}
	ctx, cancel := context.WithTimeout(ctx, transferTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, up.GetUrl(), io.NewSectionReader(f, 0, size))
	if err != nil {
		return "", fmt.Errorf("upload request: %w", errClass(err))
	}
	req.ContentLength = size
	for k, v := range up.GetHeaders() {
		req.Header.Set(k, v)
	}
	res, err := t.http.Do(req)
	if err != nil {
		return "", MapError(errClass(err))
	}
	defer func() { _ = res.Body.Close() }()
	_, _ = io.Copy(io.Discard, io.LimitReader(res.Body, 64<<10))
	if res.StatusCode/100 != 2 {
		return "", MapError(fmt.Errorf("upload answered HTTP %d", res.StatusCode))
	}
	return up.GetAttachmentId(), nil
}

// fetch GETs an opaque download URL into dst (0600), through a temporary file
// in dst's directory renamed into place only when the whole body arrived
// within the attachment cap; dst must be a hub-owned path (it is replaced).
func (t *Transport) fetch(ctx context.Context, rawURL, dst string) (err error) {
	if rawURL == "" {
		return fmt.Errorf("relay: get_download: no URL in the answer")
	}
	ctx, cancel := context.WithTimeout(ctx, transferTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return fmt.Errorf("relay: download request: %w", errClass(err))
	}
	res, err := t.http.Do(req)
	if err != nil {
		return fmt.Errorf("relay: download: %w", MapError(errClass(err)))
	}
	defer func() { _ = res.Body.Close() }()
	if res.StatusCode/100 != 2 {
		return fmt.Errorf("relay: download: %w", MapError(fmt.Errorf("HTTP %d", res.StatusCode)))
	}
	limit := t.o.MaxAttachmentBytes
	if res.ContentLength > limit {
		return fmt.Errorf("%w: %w", transport.ErrRecordTooLarge, errTooLarge)
	}
	tmp, err := os.CreateTemp(filepath.Dir(dst), ".download-*")
	if err != nil {
		return fmt.Errorf("relay: download: %w", err)
	}
	defer func() {
		if err != nil {
			_ = tmp.Close()
			_ = os.Remove(tmp.Name())
		}
	}()
	n, err := io.Copy(tmp, io.LimitReader(res.Body, limit+1))
	if err != nil {
		return fmt.Errorf("relay: download: %w", MapError(err))
	}
	if n > limit {
		err = fmt.Errorf("%w: %w", transport.ErrRecordTooLarge, errTooLarge)
		return err
	}
	if err = tmp.Close(); err != nil {
		return fmt.Errorf("relay: download: %w", err)
	}
	if err = os.Rename(tmp.Name(), dst); err != nil {
		return fmt.Errorf("relay: download: %w", err)
	}
	return nil
}

// errClass drops the URL from an HTTP error: *url.Error prints the signed
// URL, which must not reach a log (FILES-01, and the URL is a credential).
func errClass(err error) error {
	var ue *url.Error
	if errors.As(err, &ue) {
		return fmt.Errorf("%s: %w", ue.Op, ue.Err)
	}
	return err
}
