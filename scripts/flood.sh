#!/bin/sh
# Floods the unified log for throughput checks (Task 11).
#   scripts/flood.sh [rate=25000] [seconds=60] [threads=4] [level=debug|info|default]
# Compiles scripts/flood.swift once (optimised) into $TMPDIR, then runs it in the foreground.
# Messages use subsystem app.betterconsole.flood, so they can be filtered out afterwards.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
bin="${TMPDIR:-/tmp}/betterconsole-flood"
if [ ! -x "$bin" ] || [ "$here/flood.swift" -nt "$bin" ]; then
  xcrun swiftc -O -swift-version 6 "$here/flood.swift" -o "$bin"
fi
exec "$bin" "$@"
