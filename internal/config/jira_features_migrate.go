package config

import (
	"errors"
	"fmt"
	"os"

	"github.com/spf13/viper"
)

// JiraFeaturesMigratedKey marks the jira.features key repair as done. It is
// a SIBLING of jira.features on purpose: everything under that node is
// enumerated as a feature toggle, so a marker inside it would read back as
// a twelfth flag.
const JiraFeaturesMigratedKey = "jira.features_migrated"

// squashedJiraFeatureKeys maps the key a pre-repair `jira features` write
// left under jira.features to the key config.Load actually reads. The
// squashed spelling is yaml.v3's fallback for a struct field with no yaml
// tag — the lowercased Go field name — and matches no mapstructure tag, so
// viper never saw it. The long spelling is the mapstructure tag.
//
// TestSquashedJiraFeatureKeys_MatchStruct derives both halves from
// JiraFeatureToggles by reflection, so a renamed field cannot drift.
var squashedJiraFeatureKeys = map[string]string{
	"myissuesinbriefing":   "my_issues_in_briefing",
	"awaitingmyinput":      "awaiting_my_input",
	"whoping":              "who_ping",
	"trackjiralinking":     "track_jira_linking",
	"teamworkload":         "team_workload",
	"blockermap":           "blocker_map",
	"iterationprogress":    "iteration_progress",
	"epicprogress":         "epic_progress",
	"writebacksuggestions": "write_back_suggestions",
	"releasedashboard":     "release_dashboard",
	"withoutjiradetection": "without_jira_detection",
}

// MigrateJiraFeatureKeys performs the one-time repair of configs written by
// the pre-fix `jira features` writer, and stamps the marker that makes it
// one-time. It is called on daemon start and before every `jira features`
// subcommand — ALWAYS before that subcommand reads or writes, since a write
// landing first would be followed by a migration reading a file it no longer
// describes.
//
// It is value-preserving, not a delete. A `teamworkload: true` on disk is
// an enable the owner performed and the repaired reader cannot see; the
// migration carries that value over to `team_workload` before removing the
// dead key. A long key already present wins — it is an explicit value the
// owner or the repaired writer set, and must never be overwritten by a
// stale squashed one.
//
// Behaviour, mirroring MigrateFeatureGates:
//
//   - The file is absent: nothing to migrate, nothing written, (false, nil).
//   - The marker is already set: (false, nil), and the file stays
//     byte-identical from here on, forever.
//   - No squashed key is present: the marker is written ALONE. This is the
//     common case (a fresh install, or one that never touched a toggle) and
//     it costs exactly one write, ever.
//   - Squashed keys are present: their values move to the long spelling
//     where no long key already exists, the squashed keys are removed, and
//     the marker is stamped — all in one atomic write.
//
// The returned bool is repaired: at least one squashed key was carried over
// and removed. A read or write failure returns (false, err) — nothing was
// repaired, and the next call retries from the unstamped file. (A read
// failure also means config.Load would have failed on the same file anyway.)
func MigrateJiraFeatureKeys(configPath string) (bool, error) {
	v := viper.New()
	v.SetConfigFile(configPath)

	if err := v.ReadInConfig(); err != nil {
		var configNotFound viper.ConfigFileNotFoundError
		if errors.As(err, &configNotFound) || os.IsNotExist(err) {
			return false, nil
		}
		return false, fmt.Errorf("reading config: %w", err)
	}

	if v.IsSet(JiraFeaturesMigratedKey) {
		return false, nil
	}

	sets := map[string]bool{JiraFeaturesMigratedKey: true}
	var deletes []string
	for squashed, long := range squashedJiraFeatureKeys {
		squashedKey := "jira.features." + squashed
		if !v.IsSet(squashedKey) {
			continue
		}
		deletes = append(deletes, squashedKey)
		longKey := "jira.features." + long
		if !v.IsSet(longKey) {
			sets[longKey] = v.GetBool(squashedKey)
		}
	}

	if err := patchConfigYAML(configPath, sets, deletes); err != nil {
		return false, err
	}
	return len(deletes) > 0, nil
}
