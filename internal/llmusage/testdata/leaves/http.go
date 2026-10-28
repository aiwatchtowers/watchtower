package leaves

import (
	"bytes"
	"context"
	"net/http"
)

// postChat posts to a chat-completions endpoint and records nothing:
// reported (both the request and the send).
func postChat(ctx context.Context, base string, body []byte) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+"/v1/chat/completions", bytes.NewReader(body))
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	return resp.Body.Close()
}
