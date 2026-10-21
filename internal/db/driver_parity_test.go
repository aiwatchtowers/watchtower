package db

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestDriverValueParity pins what a Go argument turns into on disk, and what
// a column scans back into, through the package's normal Open. The expected
// strings are what modernc.org/sqlite wrote before the SQLCipher engine swap
// (#603); they are what the Desktop's GRDB readers see, so the engine swap
// must keep every one of them. A time.Time argument lands as its String()
// text (modernc's legacy layout). No production call binds a raw time.Time
// (audited 2026-10-21: every one is formatted first, as nullAutomationTime
// does), so those rows guard code written later.
func TestDriverValueParity(t *testing.T) {
	d, err := Open(filepath.Join(t.TempDir(), "parity.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = d.Close() })
	if _, err := d.Exec(`CREATE TABLE parity (
		name TEXT PRIMARY KEY,
		c_none, c_text TEXT, c_int INTEGER, c_real REAL, c_blob BLOB)`); err != nil {
		t.Fatal(err)
	}

	utc := time.Date(2026, 10, 21, 9, 30, 15, 0, time.UTC)
	fixed := time.Date(2026, 10, 21, 12, 30, 15, 0, time.FixedZone("EEST", 3*3600))
	nanos := time.Date(2026, 10, 21, 9, 30, 15, 123456789, time.UTC)
	ptr := utc
	var nilPtr *time.Time

	cases := []struct {
		name string
		arg  any
		// disk is typeof(c)|quote(c) for c_none, c_text, c_int, c_real, c_blob.
		disk string
		// scan is the value read back from c_none as any, string, []byte,
		// time.Time and sql.NullTime ("ERR" where Scan refuses).
		scan string
	}{
		{"time_utc", utc,
			"text|'2026-10-21 09:30:15 +0000 UTC' ; text|'2026-10-21 09:30:15 +0000 UTC' ; text|'2026-10-21 09:30:15 +0000 UTC' ; text|'2026-10-21 09:30:15 +0000 UTC' ; text|'2026-10-21 09:30:15 +0000 UTC'",
			"any:string(2026-10-21 09:30:15 +0000 UTC) ; string:\"2026-10-21 09:30:15 +0000 UTC\" ; bytes:323032362d31302d32312030393a33303a3135202b3030303020555443(nil=false) ; time:ERR ; nulltime:ERR"},
		{"time_fixed_zone", fixed,
			"text|'2026-10-21 12:30:15 +0300 EEST' ; text|'2026-10-21 12:30:15 +0300 EEST' ; text|'2026-10-21 12:30:15 +0300 EEST' ; text|'2026-10-21 12:30:15 +0300 EEST' ; text|'2026-10-21 12:30:15 +0300 EEST'",
			"any:string(2026-10-21 12:30:15 +0300 EEST) ; string:\"2026-10-21 12:30:15 +0300 EEST\" ; bytes:323032362d31302d32312031323a33303a3135202b303330302045455354(nil=false) ; time:ERR ; nulltime:ERR"},
		{"time_nanos", nanos,
			"text|'2026-10-21 09:30:15.123456789 +0000 UTC' ; text|'2026-10-21 09:30:15.123456789 +0000 UTC' ; text|'2026-10-21 09:30:15.123456789 +0000 UTC' ; text|'2026-10-21 09:30:15.123456789 +0000 UTC' ; text|'2026-10-21 09:30:15.123456789 +0000 UTC'",
			"any:string(2026-10-21 09:30:15.123456789 +0000 UTC) ; string:\"2026-10-21 09:30:15.123456789 +0000 UTC\" ; bytes:323032362d31302d32312030393a33303a31352e313233343536373839202b3030303020555443(nil=false) ; time:ERR ; nulltime:ERR"},
		{"time_zero", time.Time{},
			"text|'0001-01-01 00:00:00 +0000 UTC' ; text|'0001-01-01 00:00:00 +0000 UTC' ; text|'0001-01-01 00:00:00 +0000 UTC' ; text|'0001-01-01 00:00:00 +0000 UTC' ; text|'0001-01-01 00:00:00 +0000 UTC'",
			"any:string(0001-01-01 00:00:00 +0000 UTC) ; string:\"0001-01-01 00:00:00 +0000 UTC\" ; bytes:303030312d30312d30312030303a30303a3030202b3030303020555443(nil=false) ; time:ERR ; nulltime:ERR"},
		{"time_ptr", &ptr,
			"text|'2026-10-21 09:30:15 +0000 UTC' ; text|'2026-10-21 09:30:15 +0000 UTC' ; text|'2026-10-21 09:30:15 +0000 UTC' ; text|'2026-10-21 09:30:15 +0000 UTC' ; text|'2026-10-21 09:30:15 +0000 UTC'",
			"any:string(2026-10-21 09:30:15 +0000 UTC) ; string:\"2026-10-21 09:30:15 +0000 UTC\" ; bytes:323032362d31302d32312030393a33303a3135202b3030303020555443(nil=false) ; time:ERR ; nulltime:ERR"},
		{"time_ptr_nil", nilPtr,
			"null|NULL ; null|NULL ; null|NULL ; null|NULL ; null|NULL",
			"any:<nil>(<nil>) ; string:ERR ; bytes:(nil=true) ; time:ERR ; nulltime:false/0001-01-01T00:00:00Z"},
		{"string_ascii", "hello",
			"text|'hello' ; text|'hello' ; text|'hello' ; text|'hello' ; text|'hello'",
			"any:string(hello) ; string:\"hello\" ; bytes:68656c6c6f(nil=false) ; time:ERR ; nulltime:ERR"},
		{"string_emoji", "héllo 👋",
			"text|'héllo 👋' ; text|'héllo 👋' ; text|'héllo 👋' ; text|'héllo 👋' ; text|'héllo 👋'",
			"any:string(héllo 👋) ; string:\"héllo 👋\" ; bytes:68c3a96c6c6f20f09f918b(nil=false) ; time:ERR ; nulltime:ERR"},
		{"string_empty", "",
			"text|'' ; text|'' ; text|'' ; text|'' ; text|''",
			"any:string() ; string:\"\" ; bytes:(nil=false) ; time:ERR ; nulltime:ERR"},
		{"string_number", "42",
			"text|'42' ; text|'42' ; integer|42 ; real|42.0 ; text|'42'",
			"any:string(42) ; string:\"42\" ; bytes:3432(nil=false) ; time:ERR ; nulltime:ERR"},
		{"bytes", []byte{0x00, 0x01, 0xff},
			"blob|X'0001FF' ; blob|X'0001FF' ; blob|X'0001FF' ; blob|X'0001FF' ; blob|X'0001FF'",
			"any:[]uint8([0 1 255]) ; string:\"\\x00\\x01\\xff\" ; bytes:0001ff(nil=false) ; time:ERR ; nulltime:ERR"},
		{"bytes_empty", []byte{},
			"blob|X'' ; blob|X'' ; blob|X'' ; blob|X'' ; blob|X''",
			"any:[]uint8([]) ; string:\"\" ; bytes:(nil=true) ; time:ERR ; nulltime:ERR"},
		{"json_raw", json.RawMessage(`{"a":1}`),
			"blob|X'7B2261223A317D' ; blob|X'7B2261223A317D' ; blob|X'7B2261223A317D' ; blob|X'7B2261223A317D' ; blob|X'7B2261223A317D'",
			"any:[]uint8([123 34 97 34 58 49 125]) ; string:\"{\\\"a\\\":1}\" ; bytes:7b2261223a317d(nil=false) ; time:ERR ; nulltime:ERR"},
		{"bool_true", true,
			"integer|1 ; text|'1' ; integer|1 ; real|1.0 ; integer|1",
			"any:int64(1) ; string:\"1\" ; bytes:31(nil=false) ; time:ERR ; nulltime:ERR"},
		{"bool_false", false,
			"integer|0 ; text|'0' ; integer|0 ; real|0.0 ; integer|0",
			"any:int64(0) ; string:\"0\" ; bytes:30(nil=false) ; time:ERR ; nulltime:ERR"},
		{"nil", nil,
			"null|NULL ; null|NULL ; null|NULL ; null|NULL ; null|NULL",
			"any:<nil>(<nil>) ; string:ERR ; bytes:(nil=true) ; time:ERR ; nulltime:false/0001-01-01T00:00:00Z"},
		{"int64", int64(-7),
			"integer|-7 ; text|'-7' ; integer|-7 ; real|-7.0 ; integer|-7",
			"any:int64(-7) ; string:\"-7\" ; bytes:2d37(nil=false) ; time:ERR ; nulltime:ERR"},
		{"int64_max", int64(9223372036854775807),
			"integer|9223372036854775807 ; text|'9223372036854775807' ; integer|9223372036854775807 ; real|9.2233720368547758e+18 ; integer|9223372036854775807",
			"any:int64(9223372036854775807) ; string:\"9223372036854775807\" ; bytes:39323233333732303336383534373735383037(nil=false) ; time:ERR ; nulltime:ERR"},
		{"float64", 1.5,
			"real|1.5 ; text|'1.5' ; real|1.5 ; real|1.5 ; real|1.5",
			"any:float64(1.5) ; string:\"1.5\" ; bytes:312e35(nil=false) ; time:ERR ; nulltime:ERR"},
		{"float64_whole", 2.0,
			"real|2.0 ; text|'2.0' ; integer|2 ; real|2.0 ; real|2.0",
			"any:float64(2) ; string:\"2\" ; bytes:32(nil=false) ; time:ERR ; nulltime:ERR"},
		{"null_string_valid", sql.NullString{String: "x", Valid: true},
			"text|'x' ; text|'x' ; text|'x' ; text|'x' ; text|'x'",
			"any:string(x) ; string:\"x\" ; bytes:78(nil=false) ; time:ERR ; nulltime:ERR"},
		{"null_string_invalid", sql.NullString{},
			"null|NULL ; null|NULL ; null|NULL ; null|NULL ; null|NULL",
			"any:<nil>(<nil>) ; string:ERR ; bytes:(nil=true) ; time:ERR ; nulltime:false/0001-01-01T00:00:00Z"},
		{"null_int64_valid", sql.NullInt64{Int64: 3, Valid: true},
			"integer|3 ; text|'3' ; integer|3 ; real|3.0 ; integer|3",
			"any:int64(3) ; string:\"3\" ; bytes:33(nil=false) ; time:ERR ; nulltime:ERR"},
		{"null_int64_invalid", sql.NullInt64{},
			"null|NULL ; null|NULL ; null|NULL ; null|NULL ; null|NULL",
			"any:<nil>(<nil>) ; string:ERR ; bytes:(nil=true) ; time:ERR ; nulltime:false/0001-01-01T00:00:00Z"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := d.Exec(`INSERT INTO parity (name, c_none, c_text, c_int, c_real, c_blob) VALUES (?, ?, ?, ?, ?, ?)`,
				tc.name, tc.arg, tc.arg, tc.arg, tc.arg, tc.arg); err != nil {
				t.Fatalf("insert: %v", err)
			}
			var parts [5]string
			if err := d.QueryRow(`SELECT
				typeof(c_none) || '|' || quote(c_none),
				typeof(c_text) || '|' || quote(c_text),
				typeof(c_int) || '|' || quote(c_int),
				typeof(c_real) || '|' || quote(c_real),
				typeof(c_blob) || '|' || quote(c_blob)
				FROM parity WHERE name = ?`, tc.name).Scan(&parts[0], &parts[1], &parts[2], &parts[3], &parts[4]); err != nil {
				t.Fatalf("read back: %v", err)
			}
			if got := strings.Join(parts[:], " ; "); got != tc.disk {
				t.Errorf("on disk:\n got %q\nwant %q", got, tc.disk)
			}
			if got := scanForms(t, d, tc.name); got != tc.scan {
				t.Errorf("scanned:\n got %q\nwant %q", got, tc.scan)
			}
		})
	}
}

// scanForms scans c_none of row name into each destination type and
// describes what came back.
func scanForms(t *testing.T, d *DB, name string) string {
	t.Helper()
	row := func(dest any) error {
		return d.QueryRow(`SELECT c_none FROM parity WHERE name = ?`, name).Scan(dest)
	}
	var out []string
	var a any
	if err := row(&a); err != nil {
		out = append(out, "any:ERR")
	} else {
		out = append(out, fmt.Sprintf("any:%T(%v)", a, a))
	}
	var s string
	if err := row(&s); err != nil {
		out = append(out, "string:ERR")
	} else {
		out = append(out, fmt.Sprintf("string:%q", s))
	}
	var b []byte
	if err := row(&b); err != nil {
		out = append(out, "bytes:ERR")
	} else {
		out = append(out, fmt.Sprintf("bytes:%x(nil=%t)", b, b == nil))
	}
	var tm time.Time
	if err := row(&tm); err != nil {
		out = append(out, "time:ERR")
	} else {
		out = append(out, "time:"+tm.Format(time.RFC3339Nano))
	}
	var nt sql.NullTime
	if err := row(&nt); err != nil {
		out = append(out, "nulltime:ERR")
	} else {
		out = append(out, fmt.Sprintf("nulltime:%t/%s", nt.Valid, nt.Time.Format(time.RFC3339Nano)))
	}
	return strings.Join(out, " ; ")
}
