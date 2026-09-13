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
// ONLY A `true` IS CARRIED OVER. The pre-fix writer serialized the whole
// struct, so it wrote all eleven keys on EVERY call: a `false` in that block
// records the artifact of a struct write, not a decision. Only a `true` can
// be traced to intent — an explicit `enable`, or a `reset`, which is the
// owner asking for the role defaults. A squashed `false` is therefore
// deleted and not carried, which leaves its readable key absent and lets
// Load's role default decide (see config.go). Carrying it instead would
// write eleven explicit values onto every repaired install — the common
// shape is an all-`false` block — freezing the whole Jira surface off
// forever and putting the defaults out of reach on exactly the machines
// this repair exists for.
//
// Accepted cost of that rule: an owner who deliberately disabled a flag
// that is ON in the role baseline gets it back, once. Re-disabling it now
// actually persists, which it never did before the key repair.
//
// A readable key already present always wins — it is an explicit value the
// owner or the repaired writer set, and a stale squashed key must never
// overwrite it, in either direction.
//
// Behaviour, mirroring MigrateFeatureGates:
//
//   - The file is absent: nothing to migrate, nothing written, (false, nil).
//   - The marker is already set: (false, nil), and the file stays
//     byte-identical from here on, forever.
//   - No squashed key is present: the marker is written ALONE. This is the
//     common case (a fresh install, or one that never touched a toggle) and
//     it costs exactly one write, ever.
//   - Squashed keys are present: every one of them is removed, each `true`
//     lands under the readable spelling where no readable key already
//     exists, and the marker is stamped — all in one atomic write.
//
// The returned bool is repaired: at least one squashed key was removed. A
// read or write failure returns (false, err) — nothing was repaired, and the
// next call retries from the unstamped file. (A read failure also means
// config.Load would have failed on the same file anyway.)
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
		if v.GetBool(squashedKey) && !v.IsSet(longKey) {
			sets[longKey] = true
		}
	}

	if err := patchConfigYAML(configPath, sets, deletes); err != nil {
		return false, err
	}
	return len(deletes) > 0, nil
}
