package jira

import (
	"bytes"
	"context"
	"log"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/assert"

	"watchtower/internal/db"
)

// The daemon routes every Jira sub-component's output into its own rotated
// watchtower.log through these setters; a default that still wins after
// SetLogger would land the line in daemon.log, which cannot be rotated while
// the daemon runs.

func TestKeyDetector_SetLoggerReceivesOutput(t *testing.T) {
	database := openTestDB(t)
	d := NewKeyDetector(database)
	var buf bytes.Buffer
	d.SetLogger(log.New(&buf, "", 0))

	// A closed database makes the known-key load fail, which the detector logs.
	_ = database.Close()
	assert.Empty(t, d.DetectKeys("see PROJ-1"))
	assert.Contains(t, buf.String(), "failed to load known project keys")
}

func TestBoardAnalyzer_SetLoggerReceivesOutput(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "boom", http.StatusNotFound)
	}))
	defer srv.Close()

	database := openTestDB(t)
	a := NewBoardAnalyzer(makeTestClient(t, srv.URL), database, nil, 1)
	var buf bytes.Buffer
	a.SetLogger(log.New(&buf, "", 0))

	_, _ = a.FetchBoardRawData(context.Background(), db.JiraBoard{ID: 7, ProjectKey: "PROJ"})
	assert.Contains(t, buf.String(), "could not fetch board config for 7")
}
