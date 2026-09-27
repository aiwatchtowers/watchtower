package chat

import (
	"fmt"
	"io"
	"os"

	"watchtower/internal/db"
)

// ProjectAttachments turns a chat project's binary files (images, PDFs) into
// the attachments the Claude backend sends on the first turn of every fresh
// provider session (spec §6.1). Text files are not here: they ride the system
// prompt's project block.
//
// A file no longer on disk is skipped and named on warn instead of failing:
// one stale row must not break every turn of every chat in the project, and
// the project page still lists it for the owner to remove.
func ProjectAttachments(pc *db.ChatProjectContext, warn io.Writer) []Attachment {
	if pc == nil || len(pc.BinaryFiles) == 0 {
		return nil
	}
	if warn == nil {
		warn = io.Discard
	}
	out := make([]Attachment, 0, len(pc.BinaryFiles))
	for _, f := range pc.BinaryFiles {
		if _, err := os.Stat(f.Path); err != nil {
			fmt.Fprintf(warn, "chat project file %q skipped: %v\n", f.Name, err)
			continue
		}
		out = append(out, Attachment{Path: f.Path, Mime: f.Mime, Name: f.Name})
	}
	if len(out) == 0 {
		return nil
	}
	return out
}
