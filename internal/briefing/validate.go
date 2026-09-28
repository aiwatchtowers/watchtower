package briefing

import (
	"strconv"
	"strings"

	watchtowerslack "watchtower/internal/slack"
)

// shownIDs records the ids a briefing prompt actually showed the model, so
// the ids the model echoes back — which the Desktop turns into navigation
// links — can be checked against them (the day plan's validateSource and
// Catch-Up's CATCHUP-04 precedent). Its methods are nil-safe: a gather
// function called outside RunForDate (tests) records nothing.
type shownIDs struct {
	targets map[int]bool
	tracks  map[int]bool
	digests map[int]bool
	inbox   map[int]bool
	people  map[string]bool
}

func newShownIDs() *shownIDs {
	return &shownIDs{
		targets: map[int]bool{},
		tracks:  map[int]bool{},
		digests: map[int]bool{},
		inbox:   map[int]bool{},
		people:  map[string]bool{},
	}
}

func (s *shownIDs) addTarget(id int) {
	if s != nil {
		s.targets[id] = true
	}
}

func (s *shownIDs) addTrack(id int) {
	if s != nil {
		s.tracks[id] = true
	}
}

func (s *shownIDs) addDigest(id int) {
	if s != nil {
		s.digests[id] = true
	}
}

func (s *shownIDs) addInbox(id int) {
	if s != nil {
		s.inbox[id] = true
	}
}

func (s *shownIDs) addPerson(userID string) {
	if s != nil {
		s.people[userID] = true
	}
}

// resolvePerson maps a model-emitted user id to the stored (namespaced) id of
// a person the prompt showed: an exact match, or a raw id exactly one shown
// person carries. ok=false for anything else, including a raw id two
// accounts share.
func (s *shownIDs) resolvePerson(id string) (string, bool) {
	id = strings.TrimPrefix(strings.TrimSpace(id), "@")
	if s.people[id] {
		return id, true
	}
	match := ""
	for shown := range s.people {
		if _, raw, _ := watchtowerslack.SplitAccountID(shown); raw == id {
			if match != "" {
				return "", false
			}
			match = shown
		}
	}
	return match, match != ""
}

// validateIDs blanks every id in result the prompt never showed and returns
// how many it blanked. The item itself is kept — its text is still useful —
// it just loses the link (digest's blankInventedMessageRefs disposition).
func (s *shownIDs) validateIDs(result *BriefingResult) int {
	blanked := 0
	for i := range result.YourDay {
		item := &result.YourDay[i]
		if item.TrackID != 0 && !s.tracks[item.TrackID] {
			item.TrackID = 0
			blanked++
		}
		if item.TargetID != 0 && !s.targets[item.TargetID] {
			item.TargetID = 0
			blanked++
		}
	}
	for i := range result.WhatHappened {
		item := &result.WhatHappened[i]
		if item.DigestID != 0 && !s.digests[item.DigestID] {
			item.DigestID = 0
			blanked++
		}
	}
	for i := range result.Attention {
		item := &result.Attention[i]
		if item.SourceID == "" {
			continue
		}
		if resolved, ok := s.resolveAttentionSource(item.SourceType, item.SourceID); ok {
			item.SourceID = resolved
		} else {
			item.SourceID = ""
			blanked++
		}
	}
	return blanked
}

// resolveAttentionSource validates an attention item's source_id for its
// source_type. A source type the prompt does not define ids for is left as
// the model wrote it: nothing navigates on it.
func (s *shownIDs) resolveAttentionSource(sourceType, sourceID string) (string, bool) {
	var set map[int]bool
	switch sourceType {
	case "track":
		set = s.tracks
	case "target":
		set = s.targets
	case "digest":
		set = s.digests
	case "inbox":
		set = s.inbox
	case "people":
		return s.resolvePerson(sourceID)
	default:
		return sourceID, true
	}
	id, err := strconv.Atoi(strings.TrimSpace(sourceID))
	if err != nil || !set[id] {
		return "", false
	}
	return strconv.Itoa(id), true
}
