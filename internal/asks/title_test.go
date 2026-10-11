package asks

import "testing"

func TestNormalizeTitle(t *testing.T) {
	for in, want := range map[string]string{
		"Pick the DB":         "pick the db",
		"  Pick   the\tDB?! ": "pick the db",
		"Pick the DB .":       "pick the db",
		"v1.2 rollout":        "v1.2 rollout",
		"Выбрать БД?":         "выбрать бд",
		"":                    "",
		"?!":                  "",
	} {
		if got := NormalizeTitle(in); got != want {
			t.Errorf("NormalizeTitle(%q) = %q, want %q", in, got, want)
		}
	}
}
