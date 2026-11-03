package cmd

import (
	"encoding/json"
	"errors"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/digest"
	"watchtower/internal/providerhealth"
	"watchtower/internal/providerrouting"
	"watchtower/internal/providers"
)

type routingStatusOutput struct {
	Revision          string                   `json:"revision"`
	PreferredProvider string                   `json:"preferred_provider"`
	Enabled           bool                     `json:"enabled"`
	Providers         []providerrouting.Status `json:"providers"`
}

func init() {
	aiCmd.AddCommand(&cobra.Command{Use: "routing-status", Short: "Read local provider quota metadata without inference", Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			cfg, err := config.Load(flagConfig)
			if err != nil {
				return errors.New("could not read provider configuration")
			}
			health, err := providerhealth.Installation()
			if err != nil {
				return err
			}
			router := &providerrouting.Router{Health: health}
			req := providerrouting.Request{Tier: digest.TierStrong, Model: func(p string, _ digest.Tier) string {
				_, model := providers.ResolveModelsFor(cfg, p)
				return model
			}}
			out := routingStatusOutput{Revision: providers.RoutingRevision(cfg), PreferredProvider: cfg.AI.ConfiguredProviderID(), Enabled: cfg.AI.Fallback.Enabled,
				Providers: []providerrouting.Status{}}
			for _, p := range []string{out.PreferredProvider, cfg.AI.Fallback.Provider} {
				if p == "" {
					continue
				}
				status, err := router.Status(cmd.Context(), req, p)
				if err != nil {
					return err
				}
				out.Providers = append(out.Providers, status)
			}
			return json.NewEncoder(cmd.OutOrStdout()).Encode(out)
		}})
}
