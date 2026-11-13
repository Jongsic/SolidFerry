#!/bin/bash
# Two jobs at once through the app's queue, on two phones (docs/DEVICE_TESTS.md):
#
#   scripts/two-jobs-test.sh SERIAL_A[:adb|mtp] SERIAL_B[:adb|mtp]
#
# 1. A → B and B → A copies running together (each job uses both phones).
# 2. A and B downloading into the same Mac folder together: files of the same names, different
#    contents. Each file must arrive whole from exactly one phone; the other job finds it there
#    ("already exists"), and nothing half-written is left.
#
# Safety: only /sdcard/Download/xfer-twojobs-<time> on each phone, with generated files, and a
# temporary folder on the Mac; all deleted at the end. No window captures.
set -u

BUNDLE=$(ls -d "$(cd "$(dirname "$0")/.." && pwd)"/build/Build/Products/Debug/*.app 2>/dev/null | head -1)
NAME=$(basename "$BUNDLE" .app)
APP="$BUNDLE/Contents/MacOS/$NAME"
[ $# -eq 2 ] || { echo "usage: $0 SERIAL_A[:adb|mtp] SERIAL_B[:adb|mtp]"; exit 2; }
A=${1%%:*}; TA=${1#*:}; [ "$TA" = "$1" ] && TA=adb
B=${2%%:*}; TB=${2#*:}; [ "$TB" = "$2" ] && TB=adb
[ -x "$APP" ] || { echo "build the app first (make build)"; exit 2; }
pgrep -x "$NAME" >/dev/null && { echo "quit $NAME first"; exit 2; }

TAG=xfer # WorkNames.tag
DIR=/sdcard/Download/$TAG-twojobs-$(date +%s)
TMP=$(mktemp -d -t $TAG-twojobs)
COUNT=200
FAILED=0
cleanup() {
    adb -s "$A" shell "rm -rf '$DIR'"; adb -s "$B" shell "rm -rf '$DIR'"; rm -rf "$TMP"
    echo "removed $DIR on both phones and $TMP"
}
trap cleanup EXIT
pass() { echo "  ✔︎ $1"; }
fail() { echo "  ✘ $1"; FAILED=$((FAILED + 1)); }

run_app() { # args… → one line per job: "copied skipped failed state"
    local result="$TMP/result.json"; rm -f "$result"
    perl -e 'alarm 900; exec @ARGV' "$APP" -transport."$A" "$TA" -transport."$B" "$TB" -dev.policy skip \
        -dev.quitWhenDone "$result" "$@" >/dev/null 2>&1
    [ -f "$result" ] || { echo "- - - timed-out"; return; }
    python3 -c '
import json, sys
for j in json.load(open(sys.argv[1])):
    print(j["copied"], j["skipped"], j["failed"], j["state"].replace(" ", "_"))
    for f in j["failures"][:3]: print("     ", f, file=sys.stderr)
' "$result"
}
md5s() { adb -s "$1" shell "cd '$2' && find . -type f | sort | xargs md5sum" | awk '{print $2, $1}'; }

echo "A: $A ($TA), B: $B ($TB), working in $DIR on each"
for S in "$A" "$B"; do
    # Same names on both phones, different contents and sizes.
    adb -s "$S" shell "mkdir -p '$DIR/src/sub' '$DIR/fromA' '$DIR/fromB' && cd '$DIR/src' &&
        for i in \$(seq 1 $COUNT); do f=f\$i.bin; [ \$((i % 4)) = 0 ] && f=sub/f\$i.bin;
            head -c \$(( (RANDOM % 60 + 1) * 1000 )) /dev/urandom > \$f; done"
done
SA=$(md5s "$A" "$DIR/src"); SB=$(md5s "$B" "$DIR/src")
[ "$(echo "$SA" | wc -l | tr -d ' ')" = $COUNT ] && [ "$SA" != "$SB" ] && pass "setup: $COUNT files on each, different" || fail "setup"

echo "copies A → B and B → A at the same time"
got=$(run_app -dev.deviceCopy "$A>$B|$DIR/src|$DIR/fromA|copy;$B>$A|$DIR/src|$DIR/fromB|copy")
[ "$got" = "$(printf '%s 0 0 completed\n%s 0 0 completed' $COUNT $COUNT)" ] && pass "both jobs: $(echo $got)" || fail "jobs: $(echo $got)"
[ "$(md5s "$B" "$DIR/fromA/src")" = "$SA" ] && pass "A's files on B" || fail "A's files on B differ"
[ "$(md5s "$A" "$DIR/fromB/src")" = "$SB" ] && pass "B's files on A" || fail "B's files on A differ"

echo "A and B download into the same Mac folder at the same time"
got=$(run_app -dev.download "$A|$DIR/src|$TMP/dl;$B|$DIR/src|$TMP/dl")
copied=$(echo "$got" | awk '{s += $1} END {print s}')
others=$(echo "$got" | awk '{s += $2 + $3} END {print s}')
states=$(echo "$got" | awk '{print $4}' | sort -u)
[ "$copied" = $COUNT ] && [ "$others" = $COUNT ] && [ "$states" = completed ] \
    && pass "each file copied once: $(echo $got)" || fail "jobs: $(echo $got)"
LOCAL=$(cd "$TMP/dl/src" && find . -type f ! -name '.*' | sort | xargs md5 -r | awk '{print $2, $1}')
whole=$(python3 -c '
import sys
a = dict(l.split() for l in open(sys.argv[1]).read().splitlines())
b = dict(l.split() for l in open(sys.argv[2]).read().splitlines())
m = dict(l.split() for l in open(sys.argv[3]).read().splitlines())
bad = [p for p in a if m.get(p) not in (a[p], b[p])]
print(len(m), len(bad))
' <(echo "$SA") <(echo "$SB") <(echo "$LOCAL"))
[ "$whole" = "$COUNT 0" ] && pass "every file whole, from one phone or the other" || fail "files on the Mac: $whole (count, not matching either phone)"
left=$(find "$TMP/dl" -name '.*' | wc -l | tr -d ' ')
[ "$left" = 0 ] && pass "nothing half-written on the Mac" || fail "$left hidden files left on the Mac"

for S in "$A" "$B"; do
    n=$(adb -s "$S" shell "find '$DIR' -name '.*$TAG-*'" | wc -l | tr -d ' ')
    [ "$n" = 0 ] && pass "no temporary files on $S" || fail "$n temporary files on $S"
done
[ $FAILED -eq 0 ] && echo "all passed" || echo "$FAILED failed"
