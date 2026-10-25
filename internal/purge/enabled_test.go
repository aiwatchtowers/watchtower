package purge

import (
	"testing"

	"watchtower/internal/config"
	"watchtower/internal/policy/policytest"
)

func boolPtr(b bool) *bool { return &b }

// TestPurge01_EnabledOrder pins the order policy > setting > build > default.
func TestPurge01_EnabledOrder(t *testing.T) {
	cases := []struct {
		name       string
		policyOn   bool
		policySet  bool
		setting    *bool
		build      string
		wantOn     bool
		wantOrigin Origin
	}{
		{"nothing set", false, false, nil, "", false, OriginDefault},
		{"build on", false, false, nil, "on", true, OriginBuild},
		{"build other value is off", false, false, nil, "yes", false, OriginDefault},
		{"setting true", false, false, boolPtr(true), "", true, OriginSetting},
		{"setting false beats build on", false, false, boolPtr(false), "on", false, OriginSetting},
		{"policy off beats setting true", false, true, boolPtr(true), "on", false, OriginPolicy},
		{"policy on beats setting false", true, true, boolPtr(false), "", true, OriginPolicy},
	}
	oldPolicy, oldBuild := policySwitch, BuildDefault
	t.Cleanup(func() { policySwitch, BuildDefault = oldPolicy, oldBuild })
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			policySwitch = func() (bool, bool) { return c.policyOn, c.policySet }
			BuildDefault = c.build
			cfg := &config.Config{}
			cfg.Privacy.PurgeRevokedData = c.setting
			on, origin := Enabled(cfg)
			if on != c.wantOn || origin != c.wantOrigin {
				t.Fatalf("Enabled = (%v, %s), want (%v, %s)", on, origin, c.wantOn, c.wantOrigin)
			}
		})
	}
}

// TestPurge01_PolicyOriginFromManagedPreference pins that a forced
// PurgeRevokedData (#608) decides the switch over the owner's setting, and
// that without the key the setting decides.
func TestPurge01_PolicyOriginFromManagedPreference(t *testing.T) {
	cfg := &config.Config{}
	cfg.Privacy.PurgeRevokedData = boolPtr(true)

	policytest.Set(t, map[string]any{"PurgeRevokedData": false})
	on, origin := Enabled(cfg)
	if on || origin != OriginPolicy {
		t.Fatalf("forced false: Enabled = (%v, %s), want (false, policy)", on, origin)
	}

	policytest.Set(t, map[string]any{"PurgeRevokedData": "yes"})
	on, origin = Enabled(&config.Config{})
	if !on || origin != OriginPolicy {
		t.Fatalf("wrong type fails closed: Enabled = (%v, %s), want (true, policy)", on, origin)
	}

	policytest.Set(t, nil)
	on, origin = Enabled(cfg)
	if !on || origin != OriginSetting {
		t.Fatalf("no key: Enabled = (%v, %s), want (true, setting)", on, origin)
	}
}
