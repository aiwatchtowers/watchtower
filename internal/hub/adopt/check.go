package adopt

import "fmt"

// foldedIn are the columns the Swift hub adds by ALTER TABLE and 00001
// folds into its CREATE statements: 00001 is IF NOT EXISTS over the Swift
// tables, so a file without one of them would never get it.
var foldedIn = [][2]string{
	{"devices", "signing_key"},
	{"devices", "agreement_key"},
	{"devices", "link_nonce"},
	{"devices", "last_seq"},
	{"link_refusals", "agreement_key"},
	{"link_codes", "confirm_nonces_drawn"},
	{"slice_state", "wire_name"},
}

// CheckSwiftFile checks, read-only through pragma_table_info, that every
// column 00001 folds in is present in the Swift file at path; one missing
// is ErrSwiftSchema.
func CheckSwiftFile(path string) error {
	db, err := rawOpen(path, true)
	if err != nil {
		return err
	}
	defer func() { _ = db.Close() }()
	for _, tc := range foldedIn {
		var n int
		if err := db.QueryRow(`SELECT count(*) FROM pragma_table_info(?) WHERE name = ?`, tc[0], tc[1]).Scan(&n); err != nil {
			return fmt.Errorf("%w: %w", ErrSwiftCorrupt, err)
		}
		if n != 1 {
			return fmt.Errorf("%w: %s.%s", ErrSwiftSchema, tc[0], tc[1])
		}
	}
	return nil
}
