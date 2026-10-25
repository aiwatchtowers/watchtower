package jira

import (
	"context"
	"log"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/require"

	"watchtower/internal/logcanary"
	"watchtower/internal/logredact"
)

// TestFILES01_JiraBodyStaysOnTheError: a Jira error body is kept whole in
// logredact.Full of the returned error (what is stored) and reaches the log
// only as a fingerprint, through the syncer's own logging and a caller's,
// with %v and %q alike.
func TestFILES01_JiraBodyStaysOnTheError(t *testing.T) {
	canary := logcanary.Text("jira.body")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		// A short unquoted body: a scrub of quoted strings alone would keep it.
		_, _ = w.Write([]byte("Issue PROJ-1 " + canary + " fix not found"))
	}))
	t.Cleanup(srv.Close)
	sink := logcanary.Capture(t)

	_, err := makeTestClient(t, srv.URL).GetMyself(context.Background())
	require.Contains(t, logredact.Full(err), canary, "the stored error keeps the whole body")
	log.Printf("jira: %v", err)
	log.Printf("jira quoted: %q", err)

	s := quietSyncer(t, syncerDBWithBoard(t, "PROJ"), srv.URL)
	s.SetLogger(sink.Logger())
	_, err = s.Sync(context.Background())
	log.Printf("jira sync: %v", err)

	require.Contains(t, sink.String(), "status 500", "the failure must still be logged")
	sink.AssertClean(t)
}
