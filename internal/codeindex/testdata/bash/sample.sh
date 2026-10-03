#!/usr/bin/env bash
# Builds and ships the sample.
set -euo pipefail

# The largest size a store holds.
# shellcheck disable=SC2034
readonly MAX_SIZE=64
declare -r GREETING="hi"
export LOG_LEVEL="info"
counter=0
declare -a STORES=()

# Prints a message to stderr.
log() {
  local level="$1"
  echo "[$level] $*" >&2
}

## Doubles a number.
function double {
  local n=$1
  echo $((n * 2))
}

function cleanup() {
  inner() { :; }
  inner
}

usage()
{
  echo "usage: sample.sh"
}

if [[ -n "${DEBUG:-}" ]]; then
  debug() { echo "$@"; }
fi

trap cleanup EXIT
log info "start"
