package db

import (
	"encoding/json"
	"os"
	"testing"
)

// actorsFixture is testdata/actors.json: the status actors as the Desktop
// reads them (WatchtowerDesktop/Tests/Core/WorkbenchOwnerNoticePolicyTests.swift
// pins WorkbenchOwnerNoticePolicy.ownerActor to the "owner" entry). Rewritten
// by `go test ./internal/db -run TestActorsFixture -update`.
const actorsFixture = "testdata/actors.json"

func TestActorsFixture(t *testing.T) {
	want := map[string]string{"agent": ActorAgent, "owner": ActorOwner, "system": ActorSystem}
	if *updateGolden {
		data, err := json.MarshalIndent(want, "", "  ")
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(actorsFixture, append(data, '\n'), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	data, err := os.ReadFile(actorsFixture)
	if err != nil {
		t.Fatalf("read %s (regenerate with -update): %v", actorsFixture, err)
	}
	var got map[string]string
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatalf("decode %s: %v", actorsFixture, err)
	}
	if len(got) != len(want) {
		t.Fatalf("%s = %v, want %v (regenerate with -update)", actorsFixture, got, want)
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s[%q] = %q, want %q (regenerate with -update)", actorsFixture, k, got[k], v)
		}
	}
}
