package sessionfeed

// readSet collects, in first-read order and without repeats, the files and
// directories a read touched: every transcript, rollout, sidecar meta file
// and subagents directory whose content went into the output. A watcher of
// the list sees every change the next read would reflect. A nil set ignores
// adds.
type readSet struct {
	list []string
	seen map[string]bool
}

func (s *readSet) add(paths ...string) {
	if s == nil {
		return
	}
	if s.seen == nil {
		s.seen = map[string]bool{}
	}
	for _, p := range paths {
		if p != "" && !s.seen[p] {
			s.seen[p] = true
			s.list = append(s.list, p)
		}
	}
}
