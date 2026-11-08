package providers

import (
	"strings"
	"testing"

	"watchtower/internal/config"

	"github.com/spf13/viper"
)

func TestFallbackModelBuckets(t *testing.T) {
	for _, preferred := range []string{"claude", "codex", "ollama"} {
		t.Run(preferred, func(t *testing.T) {
			v := viper.New()
			v.SetConfigType("yaml")
			if err := v.ReadConfig(strings.NewReader("ai:\n  provider: " + preferred + "\n  model: custom-model\n  unrelated: keep\n")); err != nil {
				t.Fatal(err)
			}
			var before config.Config
			if err := v.Unmarshal(&before); err != nil {
				t.Fatal(err)
			}
			revision := RoutingRevision(&before)
			if err := MigrateModelBuckets(v); err != nil {
				t.Fatal(err)
			}
			var after config.Config
			if err := v.Unmarshal(&after); err != nil {
				t.Fatal(err)
			}
			if revision != RoutingRevision(&after) {
				t.Fatal("migration changed routing revision")
			}
			if len(after.AI.Providers) != 1 || after.AI.Providers[preferred].Models.Strong != "custom-model" {
				t.Fatalf("wrong migration: %+v", after.AI)
			}
			for _, other := range []string{"claude", "codex", "ollama"} {
				_, strong := ResolveModelsFor(&after, other)
				if other != preferred && strong == "custom-model" {
					t.Fatal("model leaked")
				}
			}
			if err := MigrateModelBuckets(v); err != nil {
				t.Fatal(err)
			}
			if v.GetString("ai.unrelated") != "keep" || v.GetString("ai.model") != "custom-model" {
				t.Fatal("lost legacy/unknown field")
			}
		})
	}
}

func TestExplicitEmptyBucketWinsLegacy(t *testing.T) {
	for _, bucket := range []string{"{}", "{models: {light: '', strong: ''}}"} {
		v := viper.New()
		v.SetConfigType("yaml")
		if err := v.ReadConfig(strings.NewReader("ai:\n  provider: claude\n  model: sonnet\n  providers:\n    claude: " + bucket + "\n")); err != nil {
			t.Fatal(err)
		}
		if err := MigrateModelBuckets(v); err != nil {
			t.Fatal(err)
		}
		var cfg config.Config
		if err := v.Unmarshal(&cfg); err != nil {
			t.Fatal(err)
		}
		l, s := ResolveModelsFor(&cfg, "claude")
		if l != ByID("claude").DefaultLight || s != ByID("claude").DefaultStrong {
			t.Fatalf("empty bucket inherited legacy: %q %q", l, s)
		}
	}
}

func TestFallbackValidation(t *testing.T) {
	for _, tc := range []struct {
		preferred, reserve string
		enabled, valid     bool
	}{
		{"claude", "codex", true, true}, {"codex", "claude", true, true}, {"ollama", "", false, true},
		{"ollama", "claude", true, false}, {"claude", "claude", false, false}, {"claude", "unknown", false, false},
		{"unknown", "", false, false}, {"codex", "", true, false}, {"claude", "ollama", true, false},
	} {
		a := config.AIConfig{Provider: tc.preferred, Fallback: config.AIFallbackConfig{Provider: tc.reserve, Enabled: tc.enabled}}
		if (a.Validate() == nil) != tc.valid {
			t.Errorf("unexpected validation: %+v", tc)
		}
	}
	if Allowed("unknown") == nil {
		t.Fatal("unknown provider silently accepted")
	}
}

func TestRoutingRevisionTracksInputs(t *testing.T) {
	cfg := config.Config{AI: config.AIConfig{Provider: "claude"}}
	before := RoutingRevision(&cfg)
	cfg.AI.Fallback = config.AIFallbackConfig{Provider: "codex", Enabled: true}
	enabled := RoutingRevision(&cfg)
	if before == enabled {
		t.Fatal("reserve enable omitted from revision")
	}
	cfg.AI.Providers = map[string]config.AIProviderConfig{"codex": {Models: config.AIModels{Strong: "custom-model"}}}
	if RoutingRevision(&cfg) == enabled {
		t.Fatal("reserve model omitted from revision")
	}
}
