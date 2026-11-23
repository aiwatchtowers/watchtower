package cmd

import (
	"encoding/json"
	"fmt"
	"io"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/companybundle"
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
		"managed, domain, keys, reserved_not_enforced, errors. keys.CompanyBundle is the forced company's\n" +
		"name, never the bundle (it carries client secrets).",
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, _ []string) error {
		p := policy.Current()
		if policyShowFlagJSON {
			if p.Keys.CompanyBundle != nil {
				name := plainCompanyBundle(p.Keys.CompanyBundle)
				p.Keys.CompanyBundle = &name
			}
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

var policyKeysFlagJSON bool

var policyKeysCmd = &cobra.Command{
	Use:   "keys [--json]",
	Short: "List every key an organization can force, with its type, default and effect",
	Long: "Lists every key Watchtower reads from " + policy.Domain + ", the enforced ones first, then the\n" +
		"reserved ones. --json prints one JSON array of {key, type, default, effect}; docs/mdm/keys.json\n" +
		"holds the same output for the IT page (" + policy.ITGuideURL + ").",
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, _ []string) error {
		docs := policy.KeyDocs()
		if policyKeysFlagJSON {
			b, err := json.MarshalIndent(docs, "", "  ")
			if err != nil {
				return err
			}
			_, err = fmt.Fprintln(cmd.OutOrStdout(), string(b))
			return err
		}
		var b strings.Builder
		for _, d := range docs {
			fmt.Fprintf(&b, "%s (%s, default %s): %s\n", d.Key, d.Type, d.Default, d.Effect)
		}
		fmt.Fprintf(&b, "What each key does: %s\n", policy.ITGuideURL)
		_, err := io.WriteString(cmd.OutOrStdout(), b.String())
		return err
	},
}

func init() {
	policyShowCmd.Flags().BoolVar(&policyShowFlagJSON, "json", false, "print JSON")
	policyKeysCmd.Flags().BoolVar(&policyKeysFlagJSON, "json", false, "print JSON")
	policyCmd.AddCommand(policyShowCmd, policyKeysCmd)
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
		{policy.KeyPurgeGraceHours, plainHours(k.PurgeGraceHours)},
		{policy.KeyAllowBackgroundAI, plainAllowed(k.AllowBackgroundAI)},
		{policy.KeySlackApps, plainSlackApps(k.SlackApps)},
		{policy.KeyCompanyBundle, plainCompanyBundle(k.CompanyBundle)},
		{policy.KeyAllowAtlassianAPIToken, plainAllowed(k.AllowAtlassianAPIToken)},
		{policy.KeyAllowOwnGoogleProject, plainAllowed(k.AllowOwnGoogleProject)},
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
	fmt.Fprintf(&b, "What each key does: %s\n", policy.ITGuideURL)
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

func plainSlackApps(v []policy.SlackApp) string {
	switch {
	case v == nil:
		return policyNotSet
	case len(v) == 0:
		return "none"
	}
	parts := make([]string, 0, len(v))
	for _, a := range v {
		parts = append(parts, a.TeamID+" ("+a.ClientID+")")
	}
	return strings.Join(parts, ", ")
}

func plainHours(v *int) string {
	if v == nil {
		return policyNotSet
	}
	return fmt.Sprintf("%d hours", *v)
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

// plainCompanyBundle names the forced company; the bundle itself (its
// client secrets included) is never printed in the text form.
func plainCompanyBundle(v *string) string {
	if v == nil {
		return policyNotSet
	}
	b, err := companybundle.Parse(*v, companybundle.OriginMDM)
	if err != nil { // Normalize kept only a bundle Parse accepts
		return "set"
	}
	return b.Company
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
