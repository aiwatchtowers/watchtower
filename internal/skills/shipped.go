package skills

import (
	"embed"
	"io/fs"
	"path"
	"sort"
	"strings"
)

//go:embed shipped/*.md
var shippedFS embed.FS

// ShippedSkill is one skill embedded in the binary: its identity, its exact
// file bytes, and the digest Deploy compares against to tell "we changed it"
// from "the owner edited it".
type ShippedSkill struct {
	Name    string
	Content string
	SHA256  string
}

// Shipped returns the embedded pack, sorted by name. The result is stable
// across calls — Deploy's drift detection depends on it.
func Shipped() []ShippedSkill {
	entries, err := fs.ReadDir(shippedFS, "shipped")
	if err != nil {
		// An embed failure is a build-time defect, not a runtime condition.
		panic("skills: reading embedded pack: " + err.Error())
	}
	out := make([]ShippedSkill, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), fileExt) {
			continue
		}
		b, err := shippedFS.ReadFile(path.Join("shipped", e.Name()))
		if err != nil {
			panic("skills: reading embedded " + e.Name() + ": " + err.Error())
		}
		out = append(out, ShippedSkill{
			Name:    strings.TrimSuffix(e.Name(), fileExt),
			Content: string(b),
			SHA256:  digestOf(string(b)),
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}
