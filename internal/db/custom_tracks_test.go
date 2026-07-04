package db

import (
	"strings"
	"testing"
)

func TestCreateCustomTrackAndFetch(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	id, err := d.CreateCustomTrack(Track{
		AssigneeUserID: "U1", Text: "Watch HashBank refund",
		Context:     "the refund decision and who owns it",
		Instruction: "surface anything about the HashBank refund decision",
		Fingerprint: `["hashbank"]`,
	})
	if err != nil {
		t.Fatalf("CreateCustomTrack: %v", err)
	}
	got, err := d.GetTrackByID(int(id))
	if err != nil {
		t.Fatalf("GetTrackByID: %v", err)
	}
	if got.Origin != "custom" || !got.Enabled || got.Instruction == "" {
		t.Fatalf("unexpected custom track: origin=%q enabled=%v instr=%q", got.Origin, got.Enabled, got.Instruction)
	}

	enabled, err := d.GetEnabledCustomTracks()
	if err != nil || len(enabled) != 1 {
		t.Fatalf("GetEnabledCustomTracks: n=%d err=%v", len(enabled), err)
	}

	if err := d.SetTrackLastRun(int(id), "2026-07-04T00:00:00Z"); err != nil {
		t.Fatalf("SetTrackLastRun: %v", err)
	}
	if err := d.SetTrackEnabled(int(id), false); err != nil {
		t.Fatalf("SetTrackEnabled: %v", err)
	}
	enabled, _ = d.GetEnabledCustomTracks()
	if len(enabled) != 0 {
		t.Fatalf("disabled track still enabled: %d", len(enabled))
	}
}

func TestFoldSourceRefsPreservesNarrative(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()
	id, _ := d.CreateCustomTrack(Track{
		AssigneeUserID: "U1", Text: "Watch refund", Context: "orig narrative",
		Instruction: "watch", SourceRefs: `[{"ts":"1","author":"a","text":"x"}]`,
		ChannelIDs: `["C1"]`, RelatedDigestIDs: `[1]`,
	})
	if err := d.FoldSourceRefsIntoTrack(int(id),
		`[{"ts":"2","author":"b","text":"y"}]`, `["C2"]`, `[2]`); err != nil {
		t.Fatalf("Fold: %v", err)
	}
	got, _ := d.GetTrackByID(int(id))
	if got.Text != "Watch refund" || got.Context != "orig narrative" || got.Instruction != "watch" {
		t.Fatalf("fold overwrote narrative: %+v", got)
	}
	if !got.HasUpdates {
		t.Fatal("fold should set has_updates")
	}
	// channel/digest ids merged.
	if !strings.Contains(got.ChannelIDs, "C1") || !strings.Contains(got.ChannelIDs, "C2") {
		t.Fatalf("channel ids not merged: %s", got.ChannelIDs)
	}
}
