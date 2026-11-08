package ai

import (
	"context"
	"errors"
	"os/exec"
	"testing"

	"watchtower/internal/providers"
)

func TestClientTypedQuotaRetainsExitCause(t *testing.T) {
	bin := writeMockClaude(t, `cat >/dev/null
printf '%s\n' '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Claude AI usage limit reached|1760000000"}'
exit 1
`)
	client := NewClient("m", "", bin)
	check := func(err error) {
		t.Helper()
		var failure *providers.Failure
		var exit *exec.ExitError
		if !errors.As(err, &failure) || failure.Category != providers.Quota || !errors.As(err, &exit) {
			t.Fatalf("lost typed CLI causes: %v %+v", err, failure)
		}
	}
	_, _, err := client.QuerySync(context.Background(), "", "prompt", "")
	check(err)
	text, errs, _ := client.Query(context.Background(), "", "prompt", "")
	for range text {
	}
	check(<-errs)
	if client.InvocationProfile() != providers.ToolPreflight {
		t.Fatal("ordinary tool runtime became batch")
	}
	client.SetReadFolder(t.TempDir())
	if client.InvocationProfile() != providers.ReviewReadonly {
		t.Fatal("review profile not excluded")
	}
}
