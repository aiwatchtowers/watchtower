package tools

import "testing"

func TestTaskBranch(t *testing.T) {
	for _, c := range []struct {
		chain        []string
		branch, base string
	}{
		{nil, "", ""},
		{[]string{"", ""}, "", ""},
		{[]string{"task"}, "task", ""},
		{[]string{"", "feature"}, "feature", ""},
		{[]string{"task", "feature"}, "task", "feature"},
		{[]string{"", "task", "", "feature", "epic"}, "task", "feature"},
		// An ancestor on the same branch is skipped: the base is the next one that differs.
		{[]string{"feature", "feature", "epic"}, "feature", "epic"},
	} {
		branch, base := TaskBranch(c.chain)
		if branch != c.branch || base != c.base {
			t.Errorf("TaskBranch(%q) = %q, %q; want %q, %q", c.chain, branch, base, c.branch, c.base)
		}
	}
}
