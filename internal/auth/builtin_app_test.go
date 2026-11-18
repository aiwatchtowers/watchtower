package auth

import "testing"

func TestBuiltinApp_EnvOverridesBakedAndBothAreNeeded(t *testing.T) {
	origID, origSecret := DefaultClientID, DefaultClientSecret
	t.Cleanup(func() { DefaultClientID, DefaultClientSecret = origID, origSecret })

	DefaultClientID, DefaultClientSecret = "baked-id", "baked-secret"
	t.Setenv("WATCHTOWER_OAUTH_CLIENT_ID", "")
	t.Setenv("WATCHTOWER_OAUTH_CLIENT_SECRET", "")
	if cfg, ok := BuiltinApp(); !ok || cfg.ClientID != "baked-id" || cfg.ClientSecret != "baked-secret" {
		t.Fatalf("baked: got %+v ok=%v", cfg, ok)
	}

	t.Setenv("WATCHTOWER_OAUTH_CLIENT_ID", "env-id")
	if cfg, ok := BuiltinApp(); !ok || cfg.ClientID != "env-id" || cfg.ClientSecret != "baked-secret" {
		t.Fatalf("env id: got %+v ok=%v", cfg, ok)
	}

	DefaultClientSecret = ""
	if cfg, ok := BuiltinApp(); ok || cfg.ClientID != "env-id" {
		t.Fatalf("no secret: got %+v ok=%v, want ok=false with the id kept", cfg, ok)
	}
}
