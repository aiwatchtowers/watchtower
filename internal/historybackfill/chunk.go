package historybackfill

// ChunkDays is the width of one backfill chunk.
const ChunkDays = 2

// MaxChunkFailures is how many failures of one chunk skip it.
const MaxChunkFailures = 3

const daySeconds = 86400.0

// NextChunk returns the next chunk below reached, newest first:
// [max(reached − ChunkDays, floor), reached). ok is false once reached is at
// or below the floor.
//
// Chunk interval convention — the one place it is stated; the fetchers and
// the AI steps refer here:
//   - Fetch loads [from, to): Slack search, Gmail and IMAP FetchRange (the
//     day-granular APIs widen it to whole days; the overlap upserts).
//   - Process reads (from, to]: the Slack digest window and the Gmail/Jira
//     stage-1 drains take items strictly after from and at or before to.
//     The Slack daily rollups cover every UTC day [from, to) touches.
//
// Chunks run newest first, so the edge instant shared by two chunks is
// fetched by the newer chunk and processed by the older one — always fetched
// first. The top edge (the first sync's start) was fetched by the forward
// sync; only the floor instant itself is never processed.
func NextChunk(reached, floor float64) (from, to float64, ok bool) {
	if reached <= floor {
		return 0, 0, false
	}
	return max(reached-ChunkDays*daySeconds, floor), reached, true
}
