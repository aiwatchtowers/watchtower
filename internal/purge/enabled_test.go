package purge

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/policy/policytest"
)

func boolPtr(b bool) *bool { return &b }

// TestPurge01_EnabledOrder pins the order policy > setting > build > default,
// and that the default is off (owner decision 2026-11-23).
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
		{"nothing set: off by default", false, false, nil, "", false, OriginDefault},
		{"build on", false, false, nil, "on", true, OriginBuild},
		{"build other value falls back to the default", false, false, nil, "yes", false, OriginDefault},
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

// defaultCase is one case of testdata/default_cases.json, the fixture the
// Swift AccountPurgeDefaultFixtureTests run too (#1769): policy, setting,
// build default and the CLI's status → the shown value and its origin.
type defaultCase struct {
	Name            string `json:"name"`
	Policy          *bool  `json:"policy"`
	Setting         *bool  `json:"setting"`
	Build           string `json:"build"`
	StatusEnabled   *bool  `json:"status_enabled"`
	StatusEnabledBy string `json:"status_enabled_by"`
	Shown           bool   `json:"shown"`
	Origin          Origin `json:"origin"`
}

// TestPurge01_DefaultSharedFixture runs the shared default fixture against
// Enabled: Go and the Desktop show the same switch. Cases with a CLI status
// are the Desktop's alone (Go is the CLI).
func TestPurge01_DefaultSharedFixture(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("testdata", "default_cases.json"))
	if err != nil {
		t.Fatal(err)
	}
	var cases []defaultCase
	if err := json.Unmarshal(b, &cases); err != nil {
		t.Fatal(err)
	}
	if len(cases) == 0 {
		t.Fatal("no cases")
	}
	oldPolicy, oldBuild := policySwitch, BuildDefault
	t.Cleanup(func() { policySwitch, BuildDefault = oldPolicy, oldBuild })
	ran := 0
	for _, c := range cases {
		if c.StatusEnabled != nil {
			continue
		}
		ran++
		t.Run(c.Name, func(t *testing.T) {
			policySwitch = func() (bool, bool) { return c.Policy != nil && *c.Policy, c.Policy != nil }
			BuildDefault = c.Build
			cfg := &config.Config{}
			cfg.Privacy.PurgeRevokedData = c.Setting
			on, origin := Enabled(cfg)
			if on != c.Shown || origin != c.Origin {
				t.Fatalf("Enabled = (%v, %s), want (%v, %s)", on, origin, c.Shown, c.Origin)
			}
		})
	}
	if ran == 0 {
		t.Fatal("no Go case in the fixture")
	}
}

// TestPurgeRules_Table pins every row of spec §2 "Per-account rules" (#1769,
// A21; origin default is off since the owner's 2026-11-23 decision), and the
// lease deadline each rule gives.
func TestPurgeRules_Table(t *testing.T) {
	allowAll := func(string) bool { return true }
	noJira := func(s string) bool { return s != "jira" }
	liveSlack := acct("slack", 1, "ok", t0.Add(-40*24*time.Hour))
	removedSlack := acct("slack", 2, "removed", t0.Add(-time.Hour))
	revokedSlack := acct("slack", 3, "revoked", t0.Add(-40*24*time.Hour))
	liveGoogle := acct("google", 1, "ok", t0.Add(-40*24*time.Hour))
	removedGoogle := acct("google", 2, "removed", t0.Add(-40*24*time.Hour))
	liveJira := acct("jira", 1, "ok", t0.Add(-40*24*time.Hour))
	removedJira := acct("jira", 2, "removed", t0.Add(-40*24*time.Hour))
	revokedJira := acct("jira", 3, "revoked", t0.Add(-40*24*time.Hour))
	all := []db.PurgeAccount{liveSlack, removedSlack, revokedSlack, liveGoogle, removedGoogle, liveJira, removedJira, revokedJira}

	type want struct {
		rule     Rule
		deadline time.Time // zero: none
	}
	none := time.Time{}
	cases := []struct {
		name  string
		rules func(db.PurgeAccount) Rule
		want  map[accountKey]want
	}{
		{"off", Rules(false, allowAll), map[accountKey]want{
			{"slack", 1}: {RuleNone, none}, {"slack", 2}: {RuleNone, none}, {"slack", 3}: {RuleNone, none},
			{"google", 1}: {RuleNone, none}, {"google", 2}: {RuleNone, none},
			{"jira", 1}: {RuleNone, none}, {"jira", 2}: {RuleNone, none}, {"jira", 3}: {RuleNone, none},
		}},
		{"on", Rules(true, allowAll), map[accountKey]want{
			{"slack", 1}:  {RuleFull, t0.Add(-40 * 24 * time.Hour).Add(Lease)},
			{"slack", 2}:  {RuleFull, t0.Add(-time.Hour)},                      // zero lease
			{"slack", 3}:  {RuleFull, t0.Add(-40 * 24 * time.Hour).Add(Lease)}, // a revoked account is live
			{"google", 1}: {RuleFull, t0.Add(-40 * 24 * time.Hour).Add(Lease)},
			{"google", 2}: {RuleFull, t0.Add(-40 * 24 * time.Hour).Add(Lease)},
			{"jira", 1}:   {RuleFull, t0.Add(-40 * 24 * time.Hour).Add(Lease)},
			{"jira", 2}:   {RuleFull, t0.Add(-40 * 24 * time.Hour).Add(Lease)},
			{"jira", 3}:   {RuleFull, t0.Add(-40 * 24 * time.Hour).Add(Lease)},
		}},
		{"jira forbidden by policy", Rules(true, noJira), map[accountKey]want{
			// The source's leases are held; its revoked rule still runs.
			{"jira", 1}: {RuleRevokedAndRemoved, none},
			{"jira", 2}: {RuleNone, none},
			{"jira", 3}: {RuleRevokedAndRemoved, none},
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			deadlines := leaseDeadlines(all, c.rules)
			for _, a := range all {
				k := accountKey{a.Source, a.ID}
				w, ok := c.want[k]
				if !ok {
					continue
				}
				if got := c.rules(a); got != w.rule {
					t.Errorf("%s %d (%s): rule %d, want %d", a.Source, a.ID, a.Status, got, w.rule)
				}
				d, has := deadlines[k]
				switch {
				case w.deadline.IsZero() && has:
					t.Errorf("%s %d (%s): lease deadline %s, want none", a.Source, a.ID, a.Status, d)
				case !w.deadline.IsZero() && (!has || !d.Equal(w.deadline)):
					t.Errorf("%s %d (%s): lease deadline %s (%v), want %s", a.Source, a.ID, a.Status, d, has, w.deadline)
				}
			}
		})
	}

	// Cutoff: a removed Slack account under a scheduling rule starts only
	// while still removed, with nothing newer than now; everything else
	// keeps today's now − Lease.
	if c, req := Cutoff(removedSlack, RuleRevokedAndRemoved, t0); !c.Equal(t0) || !req {
		t.Fatalf("removed slack cutoff = %s %v, want now, true", c, req)
	}
	for _, a := range []db.PurgeAccount{liveSlack, removedGoogle, removedJira} {
		if c, req := Cutoff(a, RuleFull, t0); !c.Equal(t0.Add(-Lease)) || req {
			t.Fatalf("%s %d cutoff = %s %v, want now − Lease, false", a.Source, a.ID, c, req)
		}
	}
}
