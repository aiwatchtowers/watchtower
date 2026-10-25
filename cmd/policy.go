package cmd

import (
	"encoding/json"
	"fmt"
	"io"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/policy"
)

var policyCmd = &cobra.Command{
	Use:   "policy",
	Short: "Show the settings your organization forces through its MDM",
	// Opens no workspace or database: the policy comes from managed preferences.
	PersistentPreRunE: func(*cobra.Command, []string) error { return nil },
}

var policyShowFlagJSON bool

var policyShowCmd = &cobra.Command{
	Use:   "show [--json]",
	Short: "Print the effective organization policy",
	Long: "Prints the policy forced by a configuration profile for the preference domain " + policy.Domain + ":\n" +
		"one line per key (\"not set\" = no restriction), the reserved keys not enforced in this version,\n" +
		"and any problems with the profile. Only forced (managed) values count; a value written with\n" +
		"`defaults write` is ignored. --json prints one JSON document as the last stdout line with the keys\n" +
		"managed, domain, keys, reserved_not_enforced, errors.",
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, _ []string) error {
		p := policy.Current()
		if policyShowFlagJSON {
			b, err := json.Marshal(p)
			if err != nil {
				return err
			}
			_, err = fmt.Fprintln(cmd.OutOrStdout(), string(b))
			return err
		}
		return printPolicy(cmd.OutOrStdout(), p)
	},
}

func init() {
	policyShowCmd.Flags().BoolVar(&policyShowFlagJSON, "json", false, "print JSON")
	policyCmd.AddCommand(policyShowCmd)
	rootCmd.AddCommand(policyCmd)
}

func printPolicy(w io.Writer, p policy.Policy) error {
	var b strings.Builder
	managed := "no"
	if p.Managed {
		managed = "yes"
	}
	fmt.Fprintf(&b, "Managed by your organization: %s (domain %s)\n", managed, p.Domain)
	k := p.Keys
	lines := []struct {
		key   string
		value string
	}{
		{policy.KeyAllowedSources, plainList(k.AllowedSources)},
		{policy.KeyMobileSync, plainString(k.MobileSync)},
		{policy.KeyAllowedQuickConnections, plainList(k.AllowedQuickConnections)},
		{policy.KeyAllowAutomationShell, plainAllowed(k.AllowAutomationShell)},
		{policy.KeyAllowedAIProviders, plainList(k.AllowedAIProviders)},
		{policy.KeyAllowClaudeAITools, plainAllowed(k.AllowClaudeAITools)},
		{policy.KeyPurgeRevokedData, plainOnOff(k.PurgeRevokedData)},
	}
	for _, l := range lines {
		fmt.Fprintf(&b, "%s: %s\n", l.key, l.value)
	}
	if len(p.ReservedNotEnforced) > 0 {
		fmt.Fprintf(&b, "Not enforced in this version: %s\n", strings.Join(p.ReservedNotEnforced, ", "))
	}
	if len(p.Errors) > 0 {
		problems := make([]string, 0, len(p.Errors))
		for _, e := range p.Errors {
			problems = append(problems, fmt.Sprintf("%s (%s)", e.Key, e.Problem))
		}
		fmt.Fprintf(&b, "Profile problems: %s\n", strings.Join(problems, ", "))
	}
	_, err := io.WriteString(w, b.String())
	return err
}

const policyNotSet = "not set"

func plainList(v []string) string {
	switch {
	case v == nil:
		return policyNotSet
	case len(v) == 0:
		return "none"
	}
	return strings.Join(v, ", ")
}

func plainString(v *string) string {
	if v == nil {
		return policyNotSet
	}
	return *v
}

func plainAllowed(v *bool) string {
	switch {
	case v == nil:
		return policyNotSet
	case *v:
		return "allowed"
	}
	return "not allowed"
}

func plainOnOff(v *bool) string {
	switch {
	case v == nil:
		return policyNotSet
	case *v:
		return "on"
	}
	return "off"
}
