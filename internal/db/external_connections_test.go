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

func TestSetExternalConnectionStatus(t *testing.T) {
	d := openTestDB(t)
	id, err := d.InsertExternalConnection(ExternalConnection{
		Name: "trello", Kind: "http", URL: "https://x", Enabled: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := d.SetExternalConnectionStatus(id, "revoked", "invalid_grant"); err != nil {
		t.Fatal(err)
	}
	c, err := d.GetExternalConnection(id)
	if err != nil {
		t.Fatal(err)
	}
	if c.Status != "revoked" || c.Error != "invalid_grant" {
		t.Fatalf("status/error = %q/%q", c.Status, c.Error)
	}
	if err := d.SetExternalConnectionStatus(id, "ok", ""); err != nil {
		t.Fatal(err)
	}
	c, err = d.GetExternalConnection(id)
	if err != nil {
		t.Fatal(err)
	}
	if c.Status != "ok" || c.Error != "" {
		t.Fatalf("status/error not cleared: %q/%q", c.Status, c.Error)
	}
	if err := d.SetExternalConnectionStatus(id+999, "ok", ""); err == nil {
		t.Fatal("expected error for unknown id")
	}
}

// TestExternalConnectionTools_CacheAndAllowList: the QC-02 tool row starts
// absent (never listed, default policy), the tool cache and the owner's allow
// list are set independently, nil clears the allow list back to NULL, and
// removing the connection removes the row.
func TestExternalConnectionTools_CacheAndAllowList(t *testing.T) {
	d := openTestDB(t)
	id, err := d.InsertExternalConnection(ExternalConnection{Name: "acme", Kind: "http", URL: "https://x", Enabled: true})
	if err != nil {
		t.Fatal(err)
	}
	get := func() ExternalConnection {
		t.Helper()
		c, err := d.GetExternalConnection(id)
		if err != nil {
			t.Fatal(err)
		}
		return c
	}

	if c := get(); c.ToolsListed || c.Tools != nil || c.AllowTools != nil {
		t.Fatalf("fresh connection: listed=%v tools=%v allow=%v, want never listed and no allow list", c.ToolsListed, c.Tools, c.AllowTools)
	}

	if err := d.SetExternalConnectionAllowTools(id, []string{"createIssue"}); err != nil {
		t.Fatal(err)
	}
	if c := get(); c.ToolsListed || len(c.AllowTools) != 1 || c.AllowTools[0] != "createIssue" {
		t.Fatalf("allow list only: listed=%v allow=%v", c.ToolsListed, c.AllowTools)
	}

	tools := []ExternalTool{{Name: "getIssue"}, {Name: "summarize", Annotated: true, ReadOnlyHint: true}}
	if err := d.SetExternalConnectionTools(id, tools, "2026-01-02T03:04:05Z"); err != nil {
		t.Fatal(err)
	}
	c := get()
	if !c.ToolsListed || c.ToolsListedAt != "2026-01-02T03:04:05Z" || len(c.Tools) != 2 || c.Tools[1] != tools[1] {
		t.Fatalf("after caching: %+v", c)
	}
	if len(c.AllowTools) != 1 {
		t.Fatalf("caching tools must keep the allow list, got %v", c.AllowTools)
	}

	if err := d.SetExternalConnectionAllowTools(id, nil); err != nil {
		t.Fatal(err)
	}
	if c := get(); c.AllowTools != nil || !c.ToolsListed {
		t.Fatalf("after clearing: allow=%v listed=%v", c.AllowTools, c.ToolsListed)
	}

	if err := d.SetExternalConnectionTools(id, nil, "2026-01-02T03:04:06Z"); err != nil {
		t.Fatal(err)
	}
	if c := get(); !c.ToolsListed || len(c.Tools) != 0 {
		t.Fatalf("an empty listing is still a listing: listed=%v tools=%v", c.ToolsListed, c.Tools)
	}

	if err := d.RemoveExternalConnection(id); err != nil {
		t.Fatal(err)
	}
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM external_connection_tools`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Fatalf("tool row must go with its connection, %d left", n)
	}
	if err := d.SetExternalConnectionTools(id, tools, "x"); err == nil {
		t.Fatal("caching tools for a removed connection must fail")
	}
}
