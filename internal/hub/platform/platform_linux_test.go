package platform

import "testing"

func TestAwayLinuxIsAlways(t *testing.T) {
	away, err := NewAway().Away()
	if err != nil || !away {
		t.Fatalf("Away() = %v, %v; want always away", away, err)
	}
}

func TestAwakeLinuxIsNoop(t *testing.T) {
	release, err := NewAwake().Hold(AwakeReason)
	if err != nil || release == nil {
		t.Fatalf("Hold() = %v", err)
	}
	release()
	release()
}
