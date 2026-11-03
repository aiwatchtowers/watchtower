package cmd

import (
	"encoding/json"
	"errors"
	"os"
	"watchtower/internal/daemon"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/digest"
	"watchtower/internal/providerhealth"
	"watchtower/internal/providerrouting"
	"watchtower/internal/providers"
)

type routingStatusOutput struct {
	ApplicationError  string                   `json:"application_error,omitempty"`
	SavedVersion      string                   `json:"saved_version,omitempty"`
	Application       *routingApplication      `json:"application,omitempty"`
	Revision          string                   `json:"revision"`
	PreferredProvider string                   `json:"preferred_provider"`
	Enabled           bool                     `json:"enabled"`
	Providers         []providerrouting.Status `json:"providers"`
}

// Tests replace only the acknowledgement reader; production retains strict
// kernel-start-qualified process identity validation.
var routingStatusApplication = readRoutingApplication

func init() {
	aiCmd.AddCommand(&cobra.Command{Use: "routing-status", Short: "Read local provider quota metadata without inference", Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			cfg, err := config.Load(flagConfig)
			if err != nil {
				return errors.New("could not read provider configuration")
			}
			if flagWorkspace != "" {
				cfg.ActiveWorkspace = flagWorkspace
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
			application, applicationErr := routingStatusApplication(cfg)
			out := routingStatusOutput{SavedVersion: routingSavedVersion(flagConfig), Revision: providers.RoutingRevision(cfg), PreferredProvider: cfg.AI.ConfiguredProviderID(), Enabled: cfg.AI.Fallback.Enabled,
				Providers: []providerrouting.Status{}, Application: application}
			if applicationErr != nil {
				out.ApplicationError = routingApplicationError(applicationErr)
			}
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

// Keep local paths and raw file contents out of the metadata boundary.
func routingApplicationError(err error) string {
	var syntax *json.SyntaxError
	switch {
	case errors.Is(err, os.ErrPermission):
		return "The background configuration acknowledgement cannot be read: permission denied"
	case errors.As(err, &syntax):
		return "The background configuration acknowledgement is corrupt"
	case errors.Is(err, daemon.ErrIdentityUnconfirmed):
		return "The background process identity cannot be confirmed"
	default:
		return "The background configuration acknowledgement could not be read"
	}
}
