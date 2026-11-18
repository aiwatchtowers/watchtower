package cmd

import (
	"encoding/json"
	"errors"
	"os"
	"watchtower/internal/daemon"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/providerhealth"
	"watchtower/internal/providerrouting"
)

// routingStatusOutput is providerrouting.Output after the command's own
// application fields (the embedded struct's keys follow them, so the bytes
// are as before).
type routingStatusOutput struct {
	ApplicationError string              `json:"application_error,omitempty"`
	SavedVersion     string              `json:"saved_version,omitempty"`
	Application      *routingApplication `json:"application,omitempty"`
	providerrouting.Output
}

// Tests replace only the acknowledgement reader; production retains strict
// kernel-start-qualified process identity validation.
var routingStatusApplication = readRoutingApplication

func init() {
	var checkAgain bool
	command := &cobra.Command{PersistentPreRunE: func(*cobra.Command, []string) error { return nil }, Use: "routing-status", Short: "Read local provider quota metadata without inference", Args: cobra.NoArgs,
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
			application, applicationErr := routingStatusApplication(cfg)
			status, err := providerrouting.ReadStatus(cmd.Context(), cfg, router, checkAgain)
			if err != nil {
				return err
			}
			out := routingStatusOutput{SavedVersion: routingSavedVersion(flagConfig), Application: application, Output: status}
			if applicationErr != nil {
				out.ApplicationError = routingApplicationError(applicationErr)
			}
			return json.NewEncoder(cmd.OutOrStdout()).Encode(out)
		}}
	command.Flags().BoolVar(&checkAgain, "check-again", false, "reserve a metadata-only limits check (at most once per minute)")
	aiCmd.AddCommand(command)
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
