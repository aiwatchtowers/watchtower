// Copyright (C) 2019 Yasuhiro Matsumoto <mattn.jp@gmail.com>. leak-check:allow
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file.

//go:build windows

package sqlcipher

/*
#cgo CFLAGS: -I.
#cgo CFLAGS: -fno-stack-check
#cgo CFLAGS: -fno-stack-protector
#cgo CFLAGS: -mno-stack-arg-probe
#cgo windows,386 CFLAGS: -D_USE_32BIT_TIME_T
*/
import "C"
