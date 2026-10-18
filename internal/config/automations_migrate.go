package config

import (
	"errors"
	"fmt"
	"os"

	"github.com/spf13/viper"
)

// LegacyAutomationsKey is the config key of the retired automations feature
// switch (board #671, ask #372). Nothing reads it as a switch any more: an
// explicit false is the signal for the daemon's one-time upgrade step, which
// pauses the recipes that switch kept from running and then removes the key
// (RemoveLegacyAutomationsKey).
const LegacyAutomationsKey = "automations.enabled"

// LegacyAutomationsOff reports whether configPath sets LegacyAutomationsKey
// explicitly to false — an install whose automations were turned off before
// the switch was removed. An absent file or key, or true, is not off.
func LegacyAutomationsOff(configPath string) (bool, error) {
	v, err := readConfigFile(configPath)
	if err != nil || v == nil {
		return false, err
	}
	return v.IsSet(LegacyAutomationsKey) && !v.GetBool(LegacyAutomationsKey), nil
}

// RemoveLegacyAutomationsKey removes LegacyAutomationsKey from configPath with
// a YAML node edit (patchConfigYAML), so comments, key order and casing
// elsewhere survive; the automations block goes with it when the key was its
// only entry. An absent file or key writes nothing.
func RemoveLegacyAutomationsKey(configPath string) error {
	v, err := readConfigFile(configPath)
	if err != nil || v == nil || !v.IsSet(LegacyAutomationsKey) {
		return err
	}
	del := LegacyAutomationsKey
	if block := v.GetStringMap("automations"); len(block) == 1 {
		del = "automations"
	}
	return patchConfigYAML(configPath, nil, []string{del})
}

// readConfigFile reads configPath with a fresh viper and no defaults, so
// IsSet sees only what the file says. A missing file is (nil, nil).
func readConfigFile(configPath string) (*viper.Viper, error) {
	v := viper.New()
	v.SetConfigFile(configPath)
	if err := v.ReadInConfig(); err != nil {
		var notFound viper.ConfigFileNotFoundError
		if errors.As(err, &notFound) || os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("reading config: %w", err)
	}
	return v, nil
}
