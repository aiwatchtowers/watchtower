//go:build darwin && keychain

// Run by hand on a Mac with an unlocked login keychain:
//
//	go test -tags keychain ./internal/hub/identity -run Keychain
//
// Every test uses its own throwaway service (never KeychainService) and
// deletes its items in t.Cleanup.
package identity

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"testing"

	"watchtower/internal/logcanary"
)

func testKeychain(t *testing.T) KeychainStore {
	t.Helper()
	var b [6]byte
	if _, err := rand.Read(b[:]); err != nil {
		t.Fatal(err)
	}
	s := KeychainStore{Service: "watchtower-hub-keychain-test-" + hex.EncodeToString(b[:])}
	t.Cleanup(func() {
		if err := s.Delete(); err != nil {
			t.Errorf("cleanup Delete: %v", err)
		}
		if err := s.DeleteStaged(); err != nil {
			t.Errorf("cleanup DeleteStaged: %v", err)
		}
	})
	return s
}

func sameIdentity(a, b Identity) bool {
	return a.Signing.Equal(b.Signing) && a.RelayAuth.Equal(b.RelayAuth) && a.Wrap == b.Wrap &&
		bytes.Equal(a.Agreement.Bytes(), b.Agreement.Bytes())
}

func TestKeychainRoundTripThisDeviceOnly(t *testing.T) {
	s := testKeychain(t)
	if _, err := s.Load(); !errors.Is(err, ErrNoIdentity) {
		t.Fatalf("Load before Save = %v, want ErrNoIdentity", err)
	}
	id, err := New()
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Save(id); err != nil {
		t.Fatalf("Save: %v", err)
	}
	got, err := s.Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if !sameIdentity(got, id) {
		t.Fatal("loaded identity differs from the saved one")
	}
	for _, acct := range keychainAccounts {
		res, err := keychainAccessible(s.Service, acct)
		if err != nil {
			t.Fatalf("%s attributes: %v", acct, err)
		}
		switch res {
		case 1:
		case -1:
			// The file-based login keychain (the only one a binary without a
			// keychain-access-groups entitlement reaches) keeps no
			// accessibility attribute; the item is device-local there.
			t.Logf("%s: kSecAttrAccessible not reported (file-based login keychain)", acct)
		default:
			t.Fatalf("%s: kSecAttrAccessible is not AfterFirstUnlockThisDeviceOnly", acct)
		}
	}

	// Save over an existing identity replaces every item.
	other, err := New()
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Save(other); err != nil {
		t.Fatalf("Save over: %v", err)
	}
	if got, err := s.Load(); err != nil || !sameIdentity(got, other) {
		t.Fatalf("Load after Save over = %v; want the second identity", err)
	}

	if err := s.Delete(); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if _, err := s.Load(); !errors.Is(err, ErrNoIdentity) {
		t.Fatalf("Load after Delete = %v, want ErrNoIdentity", err)
	}
	if err := s.Delete(); err != nil {
		t.Fatalf("Delete twice: %v", err)
	}
}

func TestKeychainPartialItemsAreRefused(t *testing.T) {
	s := testKeychain(t)
	id, err := New()
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Save(id); err != nil {
		t.Fatal(err)
	}
	if err := keychainDelete(s.Service, "wrap"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Load(); !errors.Is(err, errPartialKeychain) {
		t.Fatalf("Load with a missing item = %v, want errPartialKeychain", err)
	}
	if err := keychainPut(s.Service, "wrap", []byte("short")); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Load(); !errors.Is(err, errMalformedKeychain) {
		t.Fatalf("Load with a short item = %v, want errMalformedKeychain", err)
	}
}

func TestKeychainStagedPromoteAndDelete(t *testing.T) {
	s := testKeychain(t)
	if _, ok, err := s.Staged(); ok || err != nil {
		t.Fatalf("Staged before SaveStaged = %v, %v; want none", ok, err)
	}
	if err := s.PromoteStaged(); !errors.Is(err, ErrNoIdentity) {
		t.Fatalf("PromoteStaged with nothing staged = %v, want ErrNoIdentity", err)
	}
	live, err := New()
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Save(live); err != nil {
		t.Fatal(err)
	}
	staged, err := New()
	if err != nil {
		t.Fatal(err)
	}
	if err := s.SaveStaged(staged); err != nil {
		t.Fatalf("SaveStaged: %v", err)
	}
	if got, err := s.Load(); err != nil || !sameIdentity(got, live) {
		t.Fatalf("staging touched the live identity: %v", err)
	}
	got, ok, err := s.Staged()
	if err != nil || !ok || !sameIdentity(got, staged) {
		t.Fatalf("Staged = %v, %v; want the staged identity", ok, err)
	}
	if err := s.PromoteStaged(); err != nil {
		t.Fatalf("PromoteStaged: %v", err)
	}
	if got, err := s.Load(); err != nil || !sameIdentity(got, staged) {
		t.Fatalf("Load after promote = %v; want the staged identity", err)
	}
	if _, ok, err := s.Staged(); ok || err != nil {
		t.Fatalf("Staged after promote = %v, %v; want none", ok, err)
	}

	if err := s.SaveStaged(live); err != nil {
		t.Fatal(err)
	}
	if err := s.DeleteStaged(); err != nil {
		t.Fatalf("DeleteStaged: %v", err)
	}
	if _, ok, _ := s.Staged(); ok {
		t.Fatal("staged items left after DeleteStaged")
	}
	if got, err := s.Load(); err != nil || !sameIdentity(got, staged) {
		t.Fatalf("DeleteStaged touched the live identity: %v", err)
	}
}

func TestKeychainNeverLogsKeys(t *testing.T) {
	sink := logcanary.Capture(t)
	s := testKeychain(t)
	id, err := New()
	if err != nil {
		t.Fatal(err)
	}
	var errs []error
	errs = append(errs, s.Save(id), s.SaveStaged(id), s.PromoteStaged())
	_, err = s.Load()
	errs = append(errs, err)
	errs = append(errs, keychainPut(s.Service, "wrap", []byte("short")))
	_, err = s.Load()
	errs = append(errs, err, s.Delete())
	for _, err := range errs {
		if err != nil {
			log.Printf("hub identity: %v", err)
		}
	}
	log.Printf("hub identity: %v", &KeychainError{Op: "load", Status: -25293})
	out := sink.String()
	kx := id.Agreement.Bytes()
	for name, key := range map[string][]byte{
		"hub_sig": id.Signing.Seed(), "hub_kx": kx, "wrap": id.Wrap[:], "relay_auth": id.RelayAuth.Seed(),
	} {
		for _, form := range []string{hex.EncodeToString(key), base64.StdEncoding.EncodeToString(key),
			base64.RawURLEncoding.EncodeToString(key), fmt.Sprint(key)} {
			if bytes.Contains([]byte(out), []byte(form)) {
				t.Fatalf("FILES-01: %s reached the log", name)
			}
		}
	}
	sink.AssertClean(t)
}
