// Package guide embeds the user guide so the binary can answer questions from it.
package guide

import "embed"

// FS holds every guide page and the README catalogue.
//
//go:embed README.md start concepts features troubleshooting reference
var FS embed.FS
