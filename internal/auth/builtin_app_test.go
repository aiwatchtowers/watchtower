package auth

import "testing"

func TestBuiltinApp(t *testing.T) {
	cases := []struct {
		name                 string
		envID, envSecret     string
		bakedID, bakedSecret string
		wantID, wantSecret   string
		wantOK               bool
	}{
		{name: "nothing set"},
		{name: "baked only", bakedID: "1.2", bakedSecret: "s", wantID: "1.2", wantSecret: "s", wantOK: true},
		{name: "env wins over baked", envID: "3.4", envSecret: "e", bakedID: "1.2", bakedSecret: "s", wantID: "3.4", wantSecret: "e", wantOK: true},
		{name: "env id with baked secret", envID: "3.4", bakedSecret: "s", wantID: "3.4", wantSecret: "s", wantOK: true},
		{name: "id without secret", bakedID: "1.2", wantID: "1.2"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("WATCHTOWER_OAUTH_CLIENT_ID", tc.envID)
			t.Setenv("WATCHTOWER_OAUTH_CLIENT_SECRET", tc.envSecret)
			oldID, oldSecret := DefaultClientID, DefaultClientSecret
			t.Cleanup(func() { DefaultClientID, DefaultClientSecret = oldID, oldSecret })
			DefaultClientID, DefaultClientSecret = tc.bakedID, tc.bakedSecret

			cfg, ok := BuiltinApp()
			if cfg.ClientID != tc.wantID || cfg.ClientSecret != tc.wantSecret || ok != tc.wantOK {
				t.Fatalf("BuiltinApp() = (%q, %q, %v), want (%q, %q, %v)",
					cfg.ClientID, cfg.ClientSecret, ok, tc.wantID, tc.wantSecret, tc.wantOK)
			}
		})
	}
}
