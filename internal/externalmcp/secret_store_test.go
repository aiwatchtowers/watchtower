package externalmcp

import (
	"os"
	"testing"
)

func TestSecretStore_RoundTrip(t *testing.T) {
	dir := t.TempDir()
	st := NewSecretStore(dir, 7)
	if got, err := st.Load(); err != nil || got != nil {
		t.Fatalf("empty load = %v, %v", got, err)
	}
	want := &Secret{Env: map[string]string{"TRELLO_TOKEN": "abc"}}
	if err := st.Save(want); err != nil {
		t.Fatal(err)
	}
	fi, _ := os.Stat(st.Path())
	if fi.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %v", fi.Mode().Perm())
	}
	got, err := st.Load()
	if err != nil || got.Env["TRELLO_TOKEN"] != "abc" {
		t.Fatalf("load = %v, %v", got, err)
	}
}
