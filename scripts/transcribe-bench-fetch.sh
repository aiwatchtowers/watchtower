#!/bin/bash
# Fetches the open speech the transcription hallucination bench decodes
# (TranscriptionHallucinationBenchTests, board #554): a few utterances each of
# English, Russian and Ukrainian from the Google FLEURS test split, with their
# reference transcripts.
#
# Licence: FLEURS is released by Google under CC BY 4.0
# (https://huggingface.co/datasets/google/fleurs). The audio stays in the
# user cache, never in the repo — the repo holds no recordings.
#
# Output (override the root with WATCHTOWER_BENCH_CACHE):
#   ~/Library/Caches/watchtower-bench/fleurs/<lang>/<id>.wav   16 kHz mono PCM
#   ~/Library/Caches/watchtower-bench/fleurs/references.tsv    lang \t file \t transcript
#
# Idempotent: a language whose directory already holds the requested number of
# clips is skipped. Only the head of each test tarball is streamed — the
# download stops once enough distinct sentences are collected.
#
# Usage: scripts/transcribe-bench-fetch.sh [count-per-language]   (default 10)
set -euo pipefail

COUNT="${1:-10}"
ROOT="${WATCHTOWER_BENCH_CACHE:-$HOME/Library/Caches/watchtower-bench}/fleurs"
BASE="https://huggingface.co/datasets/google/fleurs/resolve/main/data"

echo "FLEURS (google/fleurs, test split) - licence CC BY 4.0, https://creativecommons.org/licenses/by/4.0/"
echo "Source: https://huggingface.co/datasets/google/fleurs (Conneau et al., 2022)"
echo "Cache:  $ROOT"
mkdir -p "$ROOT"

# Streams one language's test tarball and keeps the first COUNT clips with
# distinct sentence ids (FLEURS reads each sentence by several speakers).
# Writes the wavs plus a per-language refs file; prints the kept count.
FETCH_PY='
import csv, io, os, sys, tarfile, urllib.request
base, config, out_dir, count = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
with urllib.request.urlopen(f"{base}/{config}/test.tsv", timeout=60) as resp:
    rows = list(csv.reader(io.TextIOWrapper(resp, encoding="utf-8"), delimiter="\t", quoting=csv.QUOTE_NONE))
# Columns: sentence id, file name, raw transcription, normalised transcription, ...
by_file = {row[1]: (row[0], row[2]) for row in rows if len(row) > 2}
seen, kept = set(), []
with urllib.request.urlopen(f"{base}/{config}/audio/test.tar.gz", timeout=60) as resp:
    with tarfile.open(fileobj=resp, mode="r|gz") as tar:
        for member in tar:
            name = os.path.basename(member.name)
            if not member.isfile() or name not in by_file:
                continue
            sentence, text = by_file[name]
            if sentence in seen:
                continue
            data = tar.extractfile(member).read()
            with open(os.path.join(out_dir, name), "wb") as f:
                f.write(data)
            seen.add(sentence)
            kept.append((name, text))
            if len(kept) >= count:
                break
with open(os.path.join(out_dir, "refs.tsv.part"), "w", encoding="utf-8") as f:
    for name, text in kept:
        f.write(f"{name}\t{text}\n")
print(len(kept))
'

for pair in en:en_us ru:ru_ru uk:uk_ua; do
    lang="${pair%%:*}"
    config="${pair##*:}"
    dir="$ROOT/$lang"
    if [ -f "$dir/refs.tsv" ] && [ "$(wc -l < "$dir/refs.tsv" | tr -d ' ')" -ge "$COUNT" ]; then
        echo "$lang: cached ($(wc -l < "$dir/refs.tsv" | tr -d ' ') clips)"
        continue
    fi
    rm -rf "$dir"
    mkdir -p "$dir"
    kept=$(python3 -I -c "$FETCH_PY" "$BASE" "$config" "$dir" "$COUNT")
    # The bench reads 16 kHz mono Float-compatible PCM; convert anything else.
    for wav in "$dir"/*.wav; do
        info=$(afinfo "$wav")
        if ! grep -Eq "1 ch, +16000 Hz" <<<"$info"; then
            afconvert -f WAVE -d LEI16@16000 -c 1 "$wav" "$wav.tmp"
            mv "$wav.tmp" "$wav"
        fi
    done
    # Written last: a language counts as cached only once every clip is in place.
    mv "$dir/refs.tsv.part" "$dir/refs.tsv"
    echo "$lang: fetched $kept clips"
done

# One references file for the bench: lang \t file \t transcript.
refs="$ROOT/references.tsv"
: > "$refs.tmp"
for lang in en ru uk; do
    awk -v lang="$lang" -F '\t' '{ print lang "\t" $1 "\t" $2 }' "$ROOT/$lang/refs.tsv" >> "$refs.tmp"
done
mv "$refs.tmp" "$refs"
echo "References: $refs ($(wc -l < "$refs" | tr -d ' ') clips)"
