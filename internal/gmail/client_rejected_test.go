package gmail

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	"watchtower/internal/oauthclient"
)

// A pass whose client check fails (the company changed its app) reaches no
// Gmail endpoint and leaves Re-login needed on the row — a pass on the old
// pair never writes "ok" over it.
func TestGmailSync_ClientCheckStopsPass(t *testing.T) {
	calls := 0
	mux := http.NewServeMux()
	mux.HandleFunc("/users/me/messages", func(w http.ResponseWriter, _ *http.Request) {
		calls++
		fmt.Fprint(w, `{"messages":[]}`)
	})
	s, database, accountID := newTestSyncerForMux(t, mux)
	if err := database.SetAccountCompany("google", accountID, "acme"); err != nil {
		t.Fatal(err)
	}
	s.SetClientCheck(func() error { return fmt.Errorf("changed: %w", oauthclient.ErrClientRejected) })

	if _, err := s.Sync(context.Background()); !errors.Is(err, oauthclient.ErrClientRejected) {
		t.Fatalf("err = %v, want ErrClientRejected", err)
	}
	if calls != 0 {
		t.Fatalf("%d Gmail calls, want none", calls)
	}
	acc, err := database.GetGoogleAccount(accountID)
	if err != nil {
		t.Fatal(err)
	}
	if acc.Status != "error" || acc.Error != oauthclient.CodeInvalidClient {
		t.Fatalf("account = %s/%q, want error/invalid_client", acc.Status, acc.Error)
	}
}

// TestGoogleRefresh_InvalidClientIsError (#1887 P5): a refresh Google refuses
// for the client is oauthclient.ErrClientRejected, and the account becomes
// 'error' with its code — unknown_client untied, invalid_client tied to a
// company — never 'revoked', so no purge is scheduled (PURGE-01).
func TestGoogleRefresh_InvalidClientIsError(t *testing.T) {
	for _, tc := range []struct{ slug, body, want string }{
		{"", `{"error":"unauthorized_client","error_description":"Unauthorized"}`, oauthclient.CodeUnknownClient},
		{"acme", `{"error":"invalid_client","error_description":"The OAuth client was not found."}`, oauthclient.CodeInvalidClient},
		{"acme", `{"error":"deleted_client"}`, oauthclient.CodeInvalidClient},
	} {
		mux := http.NewServeMux()
		mux.HandleFunc("/users/me/messages", func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusUnauthorized)
		})
		s, database, accountID := newTestSyncerForMux(t, mux)
		if tc.slug != "" {
			if err := database.SetAccountCompany("google", accountID, tc.slug); err != nil {
				t.Fatal(err)
			}
		}
		tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusUnauthorized)
			fmt.Fprint(w, tc.body)
		}))
		t.Cleanup(tokenSrv.Close)
		googleTokenEndpoint = tokenSrv.URL // newTestSyncerForMux's cleanup restores it

		_, err := s.Sync(context.Background())
		if !errors.Is(err, oauthclient.ErrClientRejected) {
			t.Fatalf("%s: err = %v, want ErrClientRejected", tc.body, err)
		}
		if errors.Is(err, ErrAuthRevoked) {
			t.Fatalf("%s: a rejected client is not a revoked grant", tc.body)
		}
		acc, err := database.GetGoogleAccount(accountID)
		if err != nil {
			t.Fatal(err)
		}
		if acc.Status != "error" || acc.Error != tc.want {
			t.Fatalf("%s: account = %s/%q, want error/%q", tc.body, acc.Status, acc.Error, tc.want)
		}
	}
}
