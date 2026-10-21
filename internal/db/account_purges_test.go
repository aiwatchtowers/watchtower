package db

import "testing"

func TestListPurgeAccounts_EveryStatusAndLabel(t *testing.T) {
	d := OpenTestDB(t)
	for _, q := range []string{
		`INSERT INTO slack_accounts (id, team_id, team_name, status) VALUES (1, 'T1', 'Acme', 'removed')`,
		`INSERT INTO google_accounts (id, email, calendar_enabled) VALUES (1, 'a@example.com', 1)`,
		`INSERT INTO jira_accounts (id, cloud_id, label, site_name, enabled) VALUES (1, 'c1', 'Work', 'acme', 0)`,
		`INSERT INTO linear_accounts (id, org_id, url_key, status) VALUES (1, 'o1', 'acme', 'purged')`,
	} {
		if _, err := d.Exec(q); err != nil {
			t.Fatal(err)
		}
	}
	got, err := d.ListPurgeAccounts()
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]PurgeAccount{
		"slack":  {Source: "slack", ID: 1, Label: "Acme", Status: "removed", Enabled: true},
		"google": {Source: "google", ID: 1, Label: "a@example.com", Status: "ok", Enabled: true},
		"jira":   {Source: "jira", ID: 1, Label: "Work", Status: "ok", Enabled: false},
		"linear": {Source: "linear", ID: 1, Label: "acme", Status: "purged", Enabled: true},
	}
	if len(got) != len(want) {
		t.Fatalf("got %d accounts, want %d: %+v", len(got), len(want), got)
	}
	for _, a := range got {
		if w := want[a.Source]; a != w {
			t.Errorf("%s: got %+v, want %+v", a.Source, a, w)
		}
	}
}

func TestScheduleAccountPurge_OneOpenRow(t *testing.T) {
	d := OpenTestDB(t)
	ok, err := d.ScheduleAccountPurge("slack", 1, "revoked", "2026-10-24T12:00:00Z")
	if err != nil || !ok {
		t.Fatalf("first schedule: %v %v", ok, err)
	}
	ok, err = d.ScheduleAccountPurge("slack", 1, "lease", "2026-10-25T12:00:00Z")
	if err != nil || ok {
		t.Fatalf("a second open row must be a no-op: %v %v", ok, err)
	}
	if _, err := d.ScheduleAccountPurge("slack", 2, "bogus", "x"); err == nil {
		t.Fatal("an invalid reason must error (CHECK), not be ignored")
	}
	rows, err := d.ListAccountPurges(true)
	if err != nil || len(rows) != 1 {
		t.Fatalf("open rows = %+v, %v", rows, err)
	}
	if ok, err := d.CancelAccountPurge(rows[0].ID); err != nil || !ok {
		t.Fatalf("cancel: %v %v", ok, err)
	}
	if ok, err := d.CancelAccountPurge(rows[0].ID); err != nil || ok {
		t.Fatalf("a second cancel is a no-op: %v %v", ok, err)
	}
	all, err := d.ListAccountPurges(false)
	if err != nil || len(all) != 1 || all[0].State != "cancelled" || all[0].FinishedAt == "" {
		t.Fatalf("all rows = %+v, %v", all, err)
	}
}
