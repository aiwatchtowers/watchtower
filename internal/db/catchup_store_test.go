package db

import (
	"testing"
)

func TestCatchupStore_SessionAndThemeRoundTrip(t *testing.T) {
	database, err := Open(":memory:")
	if err != nil {
		t.Fatalf("opening db: %v", err)
	}
	defer database.Close()

	// Create a session — starts in 'building'.
	sessionID, err := database.CreateCatchupSession()
	if err != nil {
		t.Fatalf("CreateCatchupSession: %v", err)
	}
	if sessionID == 0 {
		t.Fatal("expected non-zero session id")
	}

	// Insert a skeleton theme.
	themeID, err := database.InsertCatchupTheme(CatchupTheme{
		SessionID: sessionID,
		OrderIdx:  0,
		Title:     "Release coordination",
		Priority:  "high",
		RefsJSON:  `[{"area":"digest","id":7,"label":"eng digest"}]`,
		GenState:  "skeleton",
	})
	if err != nil {
		t.Fatalf("InsertCatchupTheme: %v", err)
	}
	if themeID == 0 {
		t.Fatal("expected non-zero theme id")
	}

	// Update its expansion.
	if err := database.UpdateCatchupThemeExpansion(themeID, "The team aligned on the cut.", "high", true, "Confirm the date", "ready"); err != nil {
		t.Fatalf("UpdateCatchupThemeExpansion: %v", err)
	}

	// Set session totals.
	if err := database.SetCatchupSessionTotals(sessionID, 1); err != nil {
		t.Fatalf("SetCatchupSessionTotals: %v", err)
	}

	// GetCatchupTheme round-trips the fields.
	theme, err := database.GetCatchupTheme(themeID)
	if err != nil {
		t.Fatalf("GetCatchupTheme: %v", err)
	}
	if theme.Title != "Release coordination" {
		t.Errorf("title = %q, want %q", theme.Title, "Release coordination")
	}
	if theme.Narrative != "The team aligned on the cut." {
		t.Errorf("narrative = %q, want expansion narrative", theme.Narrative)
	}
	if theme.Priority != "high" {
		t.Errorf("priority = %q, want high", theme.Priority)
	}
	if !theme.NeedsYou {
		t.Error("needs_you = false, want true")
	}
	if theme.SuggestedAction != "Confirm the date" {
		t.Errorf("suggested_action = %q, want %q", theme.SuggestedAction, "Confirm the date")
	}
	if theme.GenState != "ready" {
		t.Errorf("gen_state = %q, want ready", theme.GenState)
	}
	if theme.ReviewState != "pending" {
		t.Errorf("review_state = %q, want pending", theme.ReviewState)
	}
	if theme.RefsJSON != `[{"area":"digest","id":7,"label":"eng digest"}]` {
		t.Errorf("refs = %q, want round-tripped JSON", theme.RefsJSON)
	}

	// ListCatchupThemes returns it.
	themes, err := database.ListCatchupThemes(sessionID)
	if err != nil {
		t.Fatalf("ListCatchupThemes: %v", err)
	}
	if len(themes) != 1 {
		t.Fatalf("ListCatchupThemes returned %d themes, want 1", len(themes))
	}
	if themes[0].ID != themeID {
		t.Errorf("listed theme id = %d, want %d", themes[0].ID, themeID)
	}

	// SetCatchupThemeReview + SetCatchupThemeTask persist.
	if err := database.SetCatchupThemeReview(themeID, "reviewed", ""); err != nil {
		t.Fatalf("SetCatchupThemeReview: %v", err)
	}
	if err := database.SetCatchupThemeTask(themeID, 42); err != nil {
		t.Fatalf("SetCatchupThemeTask: %v", err)
	}
	theme, err = database.GetCatchupTheme(themeID)
	if err != nil {
		t.Fatalf("GetCatchupTheme after updates: %v", err)
	}
	if theme.ReviewState != "reviewed" {
		t.Errorf("review_state = %q, want reviewed", theme.ReviewState)
	}
	if theme.TaskID != 42 {
		t.Errorf("task_id = %d, want 42", theme.TaskID)
	}

	// IncrementReviewed bumps the session counter.
	if err := database.IncrementReviewed(sessionID); err != nil {
		t.Fatalf("IncrementReviewed: %v", err)
	}
}

func TestCatchupStore_ActiveSessionLifecycle(t *testing.T) {
	database, err := Open(":memory:")
	if err != nil {
		t.Fatalf("opening db: %v", err)
	}
	defer database.Close()

	// No sessions yet → nil.
	got, err := database.GetActiveCatchupSession()
	if err != nil {
		t.Fatalf("GetActiveCatchupSession (empty): %v", err)
	}
	if got != nil {
		t.Fatalf("expected nil active session, got %+v", got)
	}

	sessionID, err := database.CreateCatchupSession()
	if err != nil {
		t.Fatalf("CreateCatchupSession: %v", err)
	}

	// 'building' counts as active (non-done/non-failed).
	got, err = database.GetActiveCatchupSession()
	if err != nil {
		t.Fatalf("GetActiveCatchupSession (building): %v", err)
	}
	if got == nil || got.ID != sessionID {
		t.Fatalf("expected active session %d, got %+v", sessionID, got)
	}
	if got.Status != "building" {
		t.Errorf("status = %q, want building", got.Status)
	}

	// Flip to active via SetCatchupSessionStatus — still active.
	if err := database.SetCatchupSessionStatus(sessionID, "active"); err != nil {
		t.Fatalf("SetCatchupSessionStatus: %v", err)
	}
	got, err = database.GetActiveCatchupSession()
	if err != nil {
		t.Fatalf("GetActiveCatchupSession (active): %v", err)
	}
	if got == nil || got.Status != "active" {
		t.Fatalf("expected active status, got %+v", got)
	}

	// CloseOpenCatchupSessions marks it done.
	if err := database.CloseOpenCatchupSessions(); err != nil {
		t.Fatalf("CloseOpenCatchupSessions: %v", err)
	}
	got, err = database.GetActiveCatchupSession()
	if err != nil {
		t.Fatalf("GetActiveCatchupSession (after close): %v", err)
	}
	if got != nil {
		t.Fatalf("expected nil active session after close, got %+v", got)
	}
}
