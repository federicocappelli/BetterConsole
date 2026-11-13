#!/bin/sh
# Test fixture for ProcessLogTransportTests.
# Prints the `log stream` header line, then $1 copies of an NDJSON entry whose
# processID is this script's pid (so tests can find the child). Then, by $2:
#   hang        sleep until killed
#   ignoreterm  ignore SIGTERM (also in the sleep child), then sleep until killed
#   orphan      start a sleep in its own process group that keeps stdout open,
#               print an entry "orphan <pid>", and exit 0
entry() {
  echo "{\"eventMessage\":\"$1\",\"messageType\":\"Default\",\"eventType\":\"logEvent\",\"processID\":$$,\"processImagePath\":\"/bin/sh\",\"timestamp\":\"2026-11-13 16:39:02.431868+0000\"}"
}
echo 'Filtering the log data using "subsystem == \"com.example.bcfixture\""'
n=${1:-0}
i=0
while [ "$i" -lt "$n" ]; do
  entry "line $i"
  i=$((i + 1))
done
case "$2" in
  hang)
    while :; do sleep 86400; done ;;
  ignoreterm)
    trap '' TERM
    while :; do sleep 86400; done ;;
  orphan)
    set -m
    sleep 86399 &
    entry "orphan $!" ;;
esac
