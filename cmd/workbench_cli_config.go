package cmd

import "watchtower/internal/config"

// loadWorkbenchCLIConfig loads the config for the active workspace (or
// --workspace) and validates it, opening nothing: the workbench hooks and
// Desktop-run verbs that open the database their own way (the Stop ask
// guard, escalate-question) start here.
func loadWorkbenchCLIConfig() (*config.Config, error) {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return nil, err
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	if err := cfg.ValidateWorkspace(); err != nil {
		return nil, err
	}
	return cfg, nil
}
