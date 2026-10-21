// Copyright (C) 2019 Yasuhiro Matsumoto <mattn.jp@gmail.com>. leak-check:allow
// Copyright (C) 2018 G.J.R. Timmer <gjr.timmer@gmail.com>. leak-check:allow

// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file.

//go:build sqlite_introspect

package sqlcipher

/*
#cgo CFLAGS: -DSQLITE_INTROSPECTION_PRAGMAS
#cgo LDFLAGS: -lm
*/
import "C"
