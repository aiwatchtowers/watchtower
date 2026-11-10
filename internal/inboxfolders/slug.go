package inboxfolders

import "strconv"

// fallbackSlug is the slug of a title with no ASCII letter or digit.
const fallbackSlug = "folder"

// baseSlug derives a folder's slug from its title: ASCII letters (lowered)
// and digits kept, every run of anything else one "-", none at the ends.
func baseSlug(title string) string {
	out := make([]byte, 0, len(title))
	dash := false
	for _, r := range title {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			out = append(out, byte(r))
			dash = false
		case r >= 'A' && r <= 'Z':
			out = append(out, byte(r-'A'+'a'))
			dash = false
		default:
			if !dash && len(out) > 0 {
				out = append(out, '-')
			}
			dash = true
		}
	}
	for len(out) > 0 && out[len(out)-1] == '-' {
		out = out[:len(out)-1]
	}
	if len(out) == 0 {
		return fallbackSlug
	}
	return string(out)
}

// uniqueSlug is baseSlug with "-2", "-3"… appended while taken says the
// slug is in use. A slug is derived once, at creation, and never changes.
func uniqueSlug(title string, taken func(string) bool) string {
	base := baseSlug(title)
	slug := base
	for n := 2; taken(slug); n++ {
		slug = base + "-" + strconv.Itoa(n)
	}
	return slug
}
