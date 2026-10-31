package secure

// Buckets are the padded frame sizes below 64 KiB (Padding.buckets).
var Buckets = []int{256, 1024, 4096, 16384, 65536}

const paddingStep = 65536

// PaddedLength is the next bucket, then 64 KiB multiples, clipped to limit
// (D12); false when n > limit.
func PaddedLength(n, limit int) (int, bool) {
	if n > limit {
		return 0, false
	}
	n = max(n, 0)
	target := (n + paddingStep - 1) / paddingStep * paddingStep
	for _, b := range Buckets {
		if b >= n {
			target = b
			break
		}
	}
	return min(target, limit), true
}
