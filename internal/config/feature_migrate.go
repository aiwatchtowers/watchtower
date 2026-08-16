package config

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"

	"github.com/spf13/viper"
)

// legacyDigestOffFeatureKeys lists every non-core feature key that a legacy
// digest.enabled=false install relied on to mean "all AI off". digest.enabled
// itself is already false and is not repeated here.
var legacyDigestOffFeatureKeys = []string{
	"inbox.enabled",
	"streams.enabled",
	"tracks.enabled",
	"people.enabled",
	"ideas.enabled",
	"memory.enabled",
	"briefing.enabled",
	"day_plan.enabled",
	"targets.next_step.enabled",
}

// MigrateFeatureGates performs the one-time back-compat migration for
// installs that relied on digest.enabled=false as a de-facto "all AI off"
// switch. If the yaml file at configPath explicitly sets digest.enabled to
// false and has not already been migrated (no features.migrated key), it
// writes false into every key in legacyDigestOffFeatureKeys plus
// features.migrated: 1, atomically, and returns migrated=true.
//
// In every other case — the file is absent, digest.enabled is absent or
// true, or the migrated marker is already present — MigrateFeatureGates
// writes nothing and returns migrated=false. The marker is only ever written
// together with a real migration, so a default install's config file stays
// byte-identical.
func MigrateFeatureGates(configPath string) (bool, error) {
	v := viper.New()
	v.SetConfigFile(configPath)

	if err := v.ReadInConfig(); err != nil {
		// Missing config file is not an error here — nothing to migrate.
		var configNotFound viper.ConfigFileNotFoundError
		if errors.As(err, &configNotFound) || os.IsNotExist(err) {
			return false, nil
		}
		return false, fmt.Errorf("reading config: %w", err)
	}

	if !v.IsSet("digest.enabled") || v.GetBool("digest.enabled") || v.IsSet("features.migrated") {
		return false, nil
	}

	for _, key := range legacyDigestOffFeatureKeys {
		v.Set(key, false)
	}
	v.Set("features.migrated", 1)

	if err := writeFeatureMigrationConfig(v, configPath); err != nil {
		return false, err
	}
	return true, nil
}

// writeFeatureMigrationConfig writes viper config to a temp file with 0o600
// permissions, then atomically renames it into place. Unexported copy of
// cmd/config.go's writeConfigAtomic — internal/config cannot import cmd, so
// this small helper is duplicated here rather than shared; cmd's version is
// left as-is.
func writeFeatureMigrationConfig(v *viper.Viper, configPath string) error {
	dir := filepath.Dir(configPath)

	oldMask := syscall.Umask(0o077)
	tmp, err := os.CreateTemp(dir, ".watchtower-config-*.yaml")
	syscall.Umask(oldMask)
	if err != nil {
		return fmt.Errorf("creating temp config file: %w", err)
	}
	tmpPath := tmp.Name()
	tmp.Close()

	if err := v.WriteConfigAs(tmpPath); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("writing config: %w", err)
	}

	if err := os.Chmod(tmpPath, 0o600); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("setting config file permissions: %w", err)
	}

	if err := os.Rename(tmpPath, configPath); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("renaming config file: %w", err)
	}
	return nil
}
