// Copyright (C) 2019 Yasuhiro Matsumoto <mattn.jp@gmail.com>. leak-check:allow
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file.

//go:build !windows
// +build !windows

package sqlcipher

/*
#cgo CFLAGS: -I.
#cgo linux LDFLAGS: -ldl
#cgo linux,ppc LDFLAGS: -lpthread
#cgo linux,ppc64 LDFLAGS: -lpthread
#cgo linux,ppc64le LDFLAGS: -lpthread
*/
import "C"
