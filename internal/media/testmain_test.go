package media

import (
	"fmt"
	"os"
	"testing"

	"watchtower/internal/db"
)

// TestMain migrates one template database so each test's OpenTestDB copies
// it instead of running every migration again.
func TestMain(m *testing.M) {
	if err := db.InitTestFileTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}
