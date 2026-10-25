package jira

import (
	"context"
	"log"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/require"

	"watchtower/internal/logcanary"
)

// TestFILES01_JiraBodyStaysOnTheError: a Jira error body is kept whole on the
// returned error (it is stored) and reaches the log only as a scrubbed
// excerpt, through the syncer's own logging and a caller's.
func TestFILES01_JiraBodyStaysOnTheError(t *testing.T) {
	canary := logcanary.Text("jira.body")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"errorMessages":["` + canary + `"]}`))
	}))
	t.Cleanup(srv.Close)
	sink := logcanary.Capture(t)

	_, err := makeTestClient(t, srv.URL).GetMyself(context.Background())
	require.ErrorContains(t, err, canary, "the stored error keeps the whole body")
	log.Printf("jira: %v", err)

	s := quietSyncer(t, syncerDBWithBoard(t, "PROJ"), srv.URL)
	s.SetLogger(sink.Logger())
	_, err = s.Sync(context.Background())
	log.Printf("jira sync: %v", err)

	require.Contains(t, sink.String(), "status 500", "the failure must still be logged")
	sink.AssertClean(t)
}
