package historybackfill

// ChunkDays is the width of one backfill chunk.
const ChunkDays = 2

// MaxChunkFailures is how many failures of one chunk skip it.
const MaxChunkFailures = 3

const daySeconds = 86400.0

// NextChunk returns the next chunk below reached, newest first:
// [max(reached − ChunkDays, floor), reached). ok is false once reached is at
// or below the floor.
func NextChunk(reached, floor float64) (from, to float64, ok bool) {
	if reached <= floor {
		return 0, 0, false
	}
	return max(reached-ChunkDays*daySeconds, floor), reached, true
}
