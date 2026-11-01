package cmd

import (
	"errors"
	"fmt"

	"github.com/spf13/cobra"

	"watchtower/internal/hub/identity"
)

// `hub keychain-probe write|read|delete` exists only for the real-Mac
// Keychain check (Go hub phase 3, Task 1; scripts/hub-keychain-check.sh):
// one signed build writes a throwaway identity, a second signed build of
// another version reads and deletes it. Hidden, owner-only (refused under an
// agent marker), and never on the live hub's service. It prints "ok" or the
// failed call's OSStatus class, never a key byte.
const hubKeychainProbeVerb = "probe the Keychain"

// hubKeychainProbeDefaultService is the probe's throwaway service.
const hubKeychainProbeDefaultService = "watchtower-hub-keychain-probe"

func init() {
	probe := &cobra.Command{
		Use:    "keychain-probe write|read|delete",
		Short:  "Check that a newer signed build reads this build's Keychain items (manual check)",
		Hidden: true,
		Args:   cobra.ExactArgs(1),
		RunE:   runHubKeychainProbe,
	}
	probe.Flags().String("service", hubKeychainProbeDefaultService, "throwaway Keychain service (never the hub's)")
	hubCmd.AddCommand(probe)
}

func runHubKeychainProbe(cmd *cobra.Command, args []string) error {
	if err := refuseUnderAgent(hubKeychainProbeVerb); err != nil {
		return err
	}
	service, _ := cmd.Flags().GetString("service")
	if service == "" || service == identity.KeychainService {
		return fmt.Errorf("the probe never touches the hub's Keychain service %q; pass a throwaway --service", identity.KeychainService)
	}
	store := identity.KeychainStore{Service: service}
	var err error
	switch args[0] {
	case "write":
		var id identity.Identity
		if id, err = identity.New(); err == nil {
			err = store.Save(id)
			id.Zero()
		}
	case "read":
		var id identity.Identity
		if id, err = store.Load(); err == nil {
			id.Zero()
		}
	case "delete":
		err = store.Delete()
	default:
		return fmt.Errorf("unknown probe step %q (write, read or delete)", args[0])
	}
	if err != nil {
		var kerr *identity.KeychainError
		if errors.As(err, &kerr) {
			cmd.Println(fmt.Sprintf("%s: OSStatus %d (%s)", args[0], kerr.Status, identity.OSStatusClass(kerr.Status)))
		}
		return err
	}
	cmd.Println("ok")
	return nil
}
