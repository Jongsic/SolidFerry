#!/bin/bash
# Pause and resume in the middle of a job, through the app (docs/DEVICE_TESTS.md):
#
#   scripts/pause-test.sh SERIAL[:adb|mtp] [SECONDS…]
#
# Jobs that replace files: a copy on the phone onto files that are there, and an upload onto
# them. Each is paused SECONDS after it starts running (default: 0.3 1 2) and resumed once it
# has stopped (-dev.pauseAfter). Afterwards every file must be the source's, whole, and no
# temporary or moved-aside file left.
#
# Safety: only /sdcard/Download/xfer-pausetest-<time> on the phone, with generated files, and
# a temporary folder on the Mac; all deleted at the end. No window captures.
set -u

BUNDLE=$(ls -d "$(cd "$(dirname "$0")/.." && pwd)"/build/Build/Products/Debug/*.app 2>/dev/null | head -1)
NAME=$(basename "$BUNDLE" .app)
APP="$BUNDLE/Contents/MacOS/$NAME"
[ $# -ge 1 ] || { echo "usage: $0 SERIAL[:adb|mtp] [SECONDS…]"; exit 2; }
S=${1%%:*}; T=${1#*:}; [ "$T" = "$1" ] && T=adb
shift
DELAYS=${*:-0.3 1 2}
[ -x "$APP" ] || { echo "build the app first (make build)"; exit 2; }
pgrep -x "$NAME" >/dev/null && { echo "quit $NAME first"; exit 2; }

TAG=xfer # WorkNames.tag
DIR=/sdcard/Download/$TAG-pausetest-$(date +%s)
TMP=$(mktemp -d -t $TAG-pausetest)
FAILED=0
trap 'adb -s "$S" shell "rm -rf '"'$DIR'"'"; rm -rf "$TMP"; echo "removed $DIR and $TMP"' EXIT
pass() { echo "  ✔︎ $1"; }
fail() { echo "  ✘ $1"; FAILED=$((FAILED + 1)); }

run_app() { # args… → "copied skipped failed state paused"
    local result="$TMP/result.json"; rm -f "$result"
    perl -e 'alarm 600; exec @ARGV' "$APP" -transport."$S" "$T" -dev.policy overwrite \
        -dev.quitWhenDone "$result" "$@" >/dev/null 2>&1
    [ -f "$result" ] || { echo "- - - timed-out -"; return; }
    python3 -c '
import json, sys
for j in json.load(open(sys.argv[1])):
    print(j["copied"], j["skipped"], j["failed"], j["state"].replace(" ", "_"), j["paused"])
    for f in j["failures"][:3]: print("     ", f, file=sys.stderr)
' "$result"
}
md5s() { adb -s "$S" shell "cd '$1' && find . -type f | sort | xargs md5sum" | awk '{print $2, $1}'; }
leftovers() { adb -s "$S" shell "find '$DIR' -name '.*$TAG-*'" | wc -l | tr -d ' '; }

# Files the jobs replace: one big (so the pause lands in it) and some small ones.
make_files() { # folder on the phone, big size in MB
    adb -s "$S" shell "mkdir -p '$1' && cd '$1' && head -c $(($2 << 20)) /dev/urandom > big.bin &&
        for i in \$(seq 1 20); do head -c \$(( (RANDOM % 50 + 1) * 1000 )) /dev/urandom > s\$i.bin; done"
}

echo "$S ($T), working in $DIR"
make_files "$DIR/src" 300
mkdir -p "$TMP/up/src"
adb -s "$S" pull "$DIR/src" "$TMP/up/" >/dev/null
SRC=$(md5s "$DIR/src")
COUNT=$(echo "$SRC" | wc -l | tr -d ' ')

for delay in $DELAYS; do
    echo "copy on the phone onto existing files, paused after ${delay}s"
    adb -s "$S" shell "rm -rf '$DIR/copy'"
    make_files "$DIR/copy/src" 20
    got=$(run_app -dev.pauseAfter "$delay" -dev.deviceCopy "$S|$DIR/src|$DIR/copy|copy")
    set -- $got
    [ "$1 $2 $3 $4" = "$COUNT 0 0 completed" ] && pass "job: $got" || fail "job: $got"
    [ "${5:-}" = True ] || echo "    (finished before the pause)"
    [ "$(md5s "$DIR/copy/src")" = "$SRC" ] && pass "every file is the source's" || fail "files differ from the source"
    n=$(leftovers); [ "$n" = 0 ] && pass "nothing left behind" || fail "$n temporary files left"

    echo "upload onto existing files, paused after ${delay}s"
    adb -s "$S" shell "rm -rf '$DIR/up'"
    make_files "$DIR/up/src" 20
    got=$(run_app -dev.pauseAfter "$delay" -dev.upload "$S|$DIR/up|$TMP/up/src")
    set -- $got
    [ "$1 $2 $3 $4" = "$COUNT 0 0 completed" ] && pass "job: $got" || fail "job: $got"
    [ "${5:-}" = True ] || echo "    (finished before the pause)"
    [ "$(md5s "$DIR/up/src")" = "$SRC" ] && pass "every file is the source's" || fail "files differ from the source"
    n=$(leftovers); [ "$n" = 0 ] && pass "nothing left behind" || fail "$n temporary files left"
done
[ $FAILED -eq 0 ] && echo "all passed" || echo "$FAILED failed"
