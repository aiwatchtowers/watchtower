#!/bin/bash
# Prints the relay origin a TestFlight build carries (make mobile-testflight;
# ask #1156: every TestFlight build talks to the staging relay).
#
#   testflight-relay-origin.sh <origin file> [<dark>]
#
# The origin lives in a file OUTSIDE the repo (the repo is public; the Makefile
# default is ~/.config/watchtower/relay-testflight-origin). The file holds one
# line, https://host or https://host:port, with no path. Surrounding blank
# space and blank lines are trimmed. A missing file or any other content fails,
# so a TestFlight build never goes out dark by accident. <dark> = 1 prints
# nothing and succeeds: a deliberately dark TestFlight build.
#
# A TestFlight build carries the staging origin, so it is never the build sent
# to App Store review: that one is a separate, dark make mobile-archive.
set -euo pipefail

file="${1:?usage: testflight-relay-origin.sh <origin file> [<dark>]}"
dark="${2:-}"

if [ "$dark" = "1" ]; then
	echo "RELAY_TESTFLIGHT_DARK=1: this TestFlight build carries no relay origin (dark)." >&2
	exit 0
fi

if [ ! -f "$file" ]; then
	{
		echo "error: no relay origin for the TestFlight build: $file not found."
		echo "  Every TestFlight build talks to the staging relay (ask #1156). Create the file"
		echo "  with the staging relay's origin on one line, for example:"
		echo "    mkdir -p \"\$(dirname '$file')\" && echo 'https://relay.example.com' > '$file'"
		echo "  or point RELAY_TESTFLIGHT_ORIGIN_FILE=<path> at another file."
		echo "  To upload a dark build on purpose, pass RELAY_TESTFLIGHT_DARK=1."
	} >&2
	exit 1
fi

origin="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$file" | grep -v '^$' || true)"
lines="$(printf '%s' "$origin" | grep -c '' || true)"
host='[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?'
if [ "$lines" != "1" ] || ! printf '%s\n' "$origin" | grep -Eqx "https://${host}(:[0-9]{1,5})?"; then
	{
		echo "error: $file must hold one origin, https://host or https://host:port, with no path,"
		echo "  query or trailing slash (for example https://relay.example.com)."
	} >&2
	exit 1
fi

printf '%s\n' "$origin"
