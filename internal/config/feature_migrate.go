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
// switch, and stamps the features.migrated marker that makes that migration
// one-time. It is called on daemon start and before every `features`
// subcommand, and behaves as follows:
//
//   - The file is absent: nothing to migrate, nothing written, (false, nil).
//   - features.migrated is already set: (false, nil), and nothing is
//     written — the file stays byte-identical from here on, forever.
//   - digest.enabled is explicitly false and there is no marker: a real
//     legacy install. Every key in legacyDigestOffFeatureKeys is written
//     false alongside the marker, atomically; returns (true, nil).
//   - digest.enabled is true or absent and there is no marker: first
//     contact with a non-legacy install. The marker is written ALONE — no
//     feature key is touched — and it returns (false, nil).
//
// That last case is why the marker is stamped on first contact rather than
// only alongside a real migration. digest.enabled=false is the legacy
// signature, but it is ALSO exactly what `features disable slack-digests`
// writes; without a marker already on the file the two are
// indistinguishable, so the owner's ordinary one-key disable read back as a
// legacy install and the next call — a read-only `features list`, or the
// daemon restarting right after the Desktop applied the change — cascaded
// nine features off. Stamping on first contact closes that window: by the
// time any product write can flip digest.enabled, the marker is already
// there.
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

	if v.IsSet("features.migrated") {
		return false, nil
	}

	legacy := v.IsSet("digest.enabled") && !v.GetBool("digest.enabled")
	if legacy {
		for _, key := range legacyDigestOffFeatureKeys {
			v.Set(key, false)
		}
	}
	v.Set("features.migrated", 1)

	if err := writeFeatureMigrationConfig(v, configPath); err != nil {
		return false, err
	}
	return legacy, nil
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
