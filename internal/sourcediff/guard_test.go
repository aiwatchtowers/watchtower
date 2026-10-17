package sourcediff

import "testing"

func TestCheck(t *testing.T) {
	tests := []struct {
		name                    string
		stored, listed, missing int
		f                       Floors
		wantOK                  bool
		wantReason              bool
	}{
		{"nothing missing", 0, 0, 0, SlackFloors, false, false},
		{"slack empty at floor", 5, 0, 5, SlackFloors, false, true},
		{"slack empty below floor", 4, 0, 4, SlackFloors, true, false},
		{"slack over half at floor", 10, 4, 6, SlackFloors, false, true},
		{"slack over half below floor", 9, 3, 6, SlackFloors, true, false},
		{"slack exactly half", 10, 5, 5, SlackFloors, true, false},
		{"mail empty", 1, 0, 1, MailFloors, false, true},
		{"mail over half", 3, 1, 2, MailFloors, false, true},
		{"mail exactly half", 4, 2, 2, MailFloors, true, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ok, reason := Check(tt.stored, tt.listed, tt.missing, tt.f)
			if ok != tt.wantOK || (reason != "") != tt.wantReason {
				t.Fatalf("Check(%d,%d,%d) = %v, %q", tt.stored, tt.listed, tt.missing, ok, reason)
			}
		})
	}
}
