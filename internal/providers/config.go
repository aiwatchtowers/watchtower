package providers

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"

	"watchtower/internal/config"

	"github.com/spf13/viper"
)

// MigrateModelBuckets captures the original configured provider's effective
// models before a writer changes ai.provider. Existing buckets, including an
// explicitly empty bucket, win. Legacy fields remain for older readers.
func MigrateModelBuckets(v *viper.Viper) error {
	var cfg config.Config
	if err := v.Unmarshal(&cfg); err != nil {
		return err
	}
	if cfg.AI.Provider == "" {
		cfg.AI.Provider = config.DefaultAIProvider
	}
	cfg.AI.PreserveEmptyModelBuckets(v.GetStringMap("ai.providers"))
	if err := cfg.AI.Validate(); err != nil {
		return err
	}
	for id, bucket := range cfg.AI.Providers {
		v.Set("ai.providers."+id+".models.light", bucket.Models.Light)
		v.Set("ai.providers."+id+".models.strong", bucket.Models.Strong)
	}
	id := cfg.AI.Provider
	if bucket, exists := cfg.AI.Providers[id]; exists {
		v.Set("ai.providers."+id+".models.light", bucket.Models.Light)
		v.Set("ai.providers."+id+".models.strong", bucket.Models.Strong)
		return nil
	}
	light, strong := ResolveModelsFor(&cfg, id)
	// Preserve Default as an empty override instead of pinning today's defaults.
	if cfg.AI.Models.Light == "" {
		light = ""
	}
	if cfg.AI.Models.Strong == "" && (cfg.AI.Model == "" || cfg.AI.Model == config.DefaultAIModel) {
		strong = ""
	}
	v.Set("ai.providers."+id+".models.light", light)
	v.Set("ai.providers."+id+".models.strong", strong)
	return nil
}

// RoutingRevision identifies normalized routing inputs, not daemon application.
// Equivalent legacy and migrated settings produce the same revision.
func RoutingRevision(cfg *config.Config) string {
	type models struct{ Light, Strong string }
	buckets := map[string]models{}
	for _, p := range All() {
		l, s := ResolveModelsFor(cfg, p.ID)
		buckets[p.ID] = models{l, s}
	}
	preferred := cfg.AI.ConfiguredProviderID()
	if preferred == "" {
		preferred = config.DefaultAIProvider
	}
	payload := struct {
		Preferred                        string
		Fallback                         config.AIFallbackConfig
		Models                           map[string]models
		ClaudePath, CodexPath, OllamaURL string
		ContextBudget, Workers           int
	}{preferred, cfg.AI.Fallback, buckets, cfg.ClaudePath, cfg.CodexPath, cfg.AI.OllamaURL, cfg.AI.ContextBudget, cfg.AI.Workers}
	data, _ := json.Marshal(payload)
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}
