package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadAIBucketsReadOnly(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.yaml")
	body := []byte("ai:\n  provider: claude\n  model: sonnet\n  providers: {claude: {}}\n")
	if err := os.WriteFile(path, body, 0600); err != nil {
		t.Fatal(err)
	}
	cfg, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := cfg.AI.Providers["claude"]; !ok {
		t.Fatal("explicit empty bucket disappeared")
	}
	got, _ := os.ReadFile(path)
	if string(got) != string(body) {
		t.Fatal("Load wrote config")
	}
	if err := os.WriteFile(path, []byte("ai:\n  providers: {unknown: {}}\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(path); err == nil {
		t.Fatal("unknown empty bucket accepted")
	}
}
