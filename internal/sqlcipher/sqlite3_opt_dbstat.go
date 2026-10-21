// Copyright (C) 2025 Yasuhiro Matsumoto <mattn.jp@gmail.com>. leak-check:allow
// Copyright (C) 2025 Jakob Borg <jakob@kastelo.net>. leak-check:allow
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file.

//go:build sqlite_dbstat

package sqlcipher

/*
#cgo CFLAGS: -DSQLITE_ENABLE_DBSTAT_VTAB
*/
import "C"
