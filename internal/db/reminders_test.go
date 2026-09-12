package db

import "testing"

func TestReminders_InsertListDueSnoozeDone(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	past := "2000-01-01T00:00:00Z"
	future := "2999-01-01T00:00:00Z"
	id, err := d.InsertReminder(Reminder{MessageRef: "C1@123.45", Note: "ping the vendor", RemindAt: past})
	if err != nil || id == 0 {
		t.Fatalf("insert: id=%d err=%v", id, err)
	}
	if _, err := d.InsertReminder(Reminder{MessageRef: "C2@9.9", Note: "later one", RemindAt: future}); err != nil {
		t.Fatalf("insert2: %v", err)
	}
	due, err := d.ListDueReminders("2100-01-01T00:00:00Z")
	if err != nil {
		t.Fatalf("list due: %v", err)
	}
	if len(due) != 1 || due[0].ID != id {
		t.Fatalf("want 1 due (the past one), got %d: %+v", len(due), due)
	}
	if err := d.SnoozeReminder(id, future); err != nil {
		t.Fatalf("snooze: %v", err)
	}
	if due, _ := d.ListDueReminders("2100-01-01T00:00:00Z"); len(due) != 0 {
		t.Fatalf("snoozed reminder should not be due, got %d", len(due))
	}
	if err := d.MarkReminderDone(id); err != nil {
		t.Fatalf("done: %v", err)
	}
	if due, _ := d.ListDueReminders("3000-01-01T00:00:00Z"); len(due) != 1 {
		t.Fatalf("only the future non-done one is due now, got %d", len(due))
	}
}
