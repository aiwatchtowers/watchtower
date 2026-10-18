package instructions

import (
	"errors"
	"strings"
	"testing"
	"unicode/utf8"

	"watchtower/internal/db"
)

func TestValidate_CountsRunesNotBytes(t *testing.T) {
	if err := Validate(strings.Repeat("ж", MaxRunes)); err != nil {
		t.Fatalf("1000 runes: %v", err)
	}
	if err := Validate(strings.Repeat("ж", MaxRunes+1)); !errors.Is(err, ErrTooLong) {
		t.Fatalf("1001 runes: got %v, want ErrTooLong", err)
	}
	if err := Validate("  " + strings.Repeat("a", MaxRunes) + "  "); err != nil {
		t.Fatalf("surrounding space must not count: %v", err)
	}
}

func TestBriefSlot_Shapes(t *testing.T) {
	const head = "Owner's instructions (follow in every turn):"
	const ptr = "Target procedure: update_target returns it when a target goes in_progress."
	tests := []struct {
		name string
		in   Texts
		want string
	}{
		{"all empty", Texts{}, ""},
		{"global only", Texts{Global: db.OwnerInstructions{Session: "A"}}, head + "\nA"},
		{"workbench only", Texts{Workbench: db.OwnerInstructions{Session: "B"}}, head + "\nFor this workbench:\nB"},
		{"both", Texts{Global: db.OwnerInstructions{Session: "A"}, Workbench: db.OwnerInstructions{Session: "B"}},
			head + "\nA\nFor this workbench:\nB"},
		{"procedure only", Texts{Global: db.OwnerInstructions{Procedure: "P"}}, ptr},
		{"session and procedure", Texts{Workbench: db.OwnerInstructions{Session: "B", Procedure: "P"}},
			head + "\nFor this workbench:\nB\n" + ptr},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := BriefSlot(tc.in); got != tc.want {
				t.Fatalf("got %q, want %q", got, tc.want)
			}
		})
	}
}

func TestBriefSlot_MaxFitsSlotMaxRunes(t *testing.T) {
	long := strings.Repeat("ж", MaxRunes)
	full := db.OwnerInstructions{Session: long, Procedure: long}
	got := BriefSlot(Texts{Global: full, Workbench: full})
	if n := utf8.RuneCountInString(got); n > SlotMaxRunes || n < SlotMaxRunes-5 {
		t.Fatalf("full slot is %d runes, SlotMaxRunes %d", n, SlotMaxRunes)
	}
}

func TestProcedure_FirstLineAndWorkbenchPart(t *testing.T) {
	if got := Procedure(Texts{Global: db.OwnerInstructions{Session: "x"}}, 7); got != "" {
		t.Fatalf("no procedure: got %q", got)
	}
	g := Texts{Global: db.OwnerInstructions{Procedure: "G"}}
	if got, want := Procedure(g, 7), "Owner's target procedure — follow it for #7:\nG"; got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
	both := Texts{Global: db.OwnerInstructions{Procedure: "G"}, Workbench: db.OwnerInstructions{Procedure: "W"}}
	if got, want := Procedure(both, 7), "Owner's target procedure — follow it for #7:\nG\nFor this workbench:\nW"; got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
	wb := Texts{Workbench: db.OwnerInstructions{Procedure: "W"}}
	if got, want := Procedure(wb, 7), "Owner's target procedure — follow it for #7:\nFor this workbench:\nW"; got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestAppendLine_RefusesOverLimit(t *testing.T) {
	if got, err := AppendLine("", "a"); err != nil || got != "a" {
		t.Fatalf("empty: %q %v", got, err)
	}
	if got, err := AppendLine("a", "b"); err != nil || got != "a\nb" {
		t.Fatalf("append: %q %v", got, err)
	}
	if _, err := AppendLine(strings.Repeat("a", MaxRunes-1), "b"); !errors.Is(err, ErrTooLong) {
		t.Fatalf("got %v, want ErrTooLong", err)
	}
}

func TestFingerprint_IgnoresCaseAndPunctuation(t *testing.T) {
	a := Fingerprint("Never build in the background!")
	b := Fingerprint("never build, in the background")
	if a != b || a != "never build in the background" {
		t.Fatalf("%q vs %q", a, b)
	}
}
