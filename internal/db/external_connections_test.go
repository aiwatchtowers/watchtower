package db

import "testing"

func TestExternalConnections_CRUD(t *testing.T) {
	d := openTestDB(t)
	id, err := d.InsertExternalConnection(ExternalConnection{
		Name: "trello", Kind: "stdio", Command: "npx", Args: []string{"-y", "trello-mcp"}, Enabled: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	_, err = d.InsertExternalConnection(ExternalConnection{Name: "trello", Kind: "http", URL: "https://x"})
	if err == nil {
		t.Fatal("expected UNIQUE(name) violation")
	}
	en, err := d.ListEnabledExternalConnections()
	if err != nil {
		t.Fatal(err)
	}
	if len(en) != 1 || en[0].Name != "trello" || len(en[0].Args) != 2 {
		t.Fatalf("enabled = %+v", en)
	}
	if err := d.SetExternalConnectionEnabled(id, false); err != nil {
		t.Fatal(err)
	}
	en, _ = d.ListEnabledExternalConnections()
	if len(en) != 0 {
		t.Fatalf("still enabled: %+v", en)
	}
	if err := d.RemoveExternalConnection(id); err != nil {
		t.Fatal(err)
	}
	all, _ := d.ListExternalConnections()
	if len(all) != 0 {
		t.Fatalf("not removed: %+v", all)
	}
}
