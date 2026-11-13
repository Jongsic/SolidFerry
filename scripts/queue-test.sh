#!/bin/bash
# The transfer queue end to end, through the app (docs/DEVICE_TESTS.md):
#
#   scripts/queue-test.sh SERIAL_A[:adb|mtp] SERIAL_B[:adb|mtp]
#   APP_ARGS="-writeNewFilesDirectly YES -writeReplacedFilesDirectly YES" scripts/queue-test.sh …
#                                  (settings for this run only, e.g. writing straight to the phone)
#   SNAPSHOTS=0 scripts/queue-test.sh …
#                                  (no window captures of a stuck step: for personal phones,
#                                   whose folders would show in them)
#
# Runs a Debug build of the app once per step with -dev.download/-dev.upload/
# -dev.deviceCopy and -dev.quitWhenDone, then checks the job results and the files
# (md5) on the Mac and on the phones. The connection the app uses is chosen per phone
# (default adb); setting up and checking always go through adb, so both phones need USB
# debugging on.
#
# Safety: only /sdcard/Download/xfer-queuetest-<time> on each phone and a temporary
# folder on the Mac, with generated files; all deleted at the end.
set -u

BUNDLE=$(ls -d "$(cd "$(dirname "$0")/.." && pwd)"/build/Build/Products/Debug/*.app 2>/dev/null | head -1)
NAME=$(basename "$BUNDLE" .app)
APP="$BUNDLE/Contents/MacOS/$NAME"
[ $# -eq 2 ] || { echo "usage: $0 SERIAL_A[:adb|mtp] SERIAL_B[:adb|mtp]"; exit 2; }
A=${1%%:*}; TA=${1#*:}; [ "$TA" = "$1" ] && TA=adb
B=${2%%:*}; TB=${2#*:}; [ "$TB" = "$2" ] && TB=adb
[ -x "$APP" ] || { echo "build the app first (make build)"; exit 2; }
[ "$A" != "$B" ] || { echo "two different phones, please"; exit 2; }
pgrep -x "$NAME" >/dev/null && { echo "quit $NAME first"; exit 2; }

TAG=xfer # WorkNames.tag: what the app's own files and folders carry
DIR=/sdcard/Download/$TAG-queuetest-$(date +%s)
TMP=$(mktemp -d -t $TAG-queuetest)
SMALL=30
FILES=$((SMALL + 3))
FAILED=0

cleanup() {
    adb -s "$A" shell "rm -rf $DIR" >/dev/null 2>&1
    adb -s "$B" shell "rm -rf $DIR" >/dev/null 2>&1
    rm -rf "$TMP"
    echo "removed $DIR on both phones and $TMP"
}
trap cleanup EXIT

pass() { echo "  ✔︎ $1"; }
fail() { echo "  ✘ $1"; FAILED=$((FAILED + 1)); }

# Runs the app with one job; prints the result line "copied skipped failed state".
run_app() {
    local result="$TMP/result.json"
    rm -f "$result"
    rm -rf "$TMP/snap"
    # Windows are captured just before the time limit, to see what a stuck run was doing.
    local snap=(-dev.snapshot "$TMP/snap" -dev.snapshotDelay 110)
    [ "${SNAPSHOTS:-1}" = 0 ] && snap=()
    perl -e 'alarm 120; exec @ARGV' "$APP" -transport."$A" "$TA" -transport."$B" "$TB" \
        -dev.quitWhenDone "$result" ${snap[@]+"${snap[@]}"} ${APP_ARGS:-} "$@" >/dev/null 2>&1
    if [ ! -f "$result" ]; then
        local kept="${TMPDIR:-/tmp}/$TAG-queuetest-stuck-$(date +%s)"
        cp -R "$TMP/snap" "$kept" 2>/dev/null && echo "      (windows at the time limit: $kept)" >&2
        echo "- - - timed-out"
        return
    fi
    python3 -c '
import json, sys
jobs = json.load(open(sys.argv[1]))
j = jobs[0]
print(j["copied"], j["skipped"], j["failed"], j["state"].replace(" ", "_"))
for f in j["failures"][:5]: print("     ", f, file=sys.stderr)
' "$result"
}

# "path md5" lines for every file below a folder, sorted.
device_md5() { adb -s "$1" shell "cd '$2' && find . -type f | sort | while read f; do md5sum \"\$f\"; done" | awk '{print $2, $1}'; }
local_md5() { (cd "$1" && find . -type f | sort | while read -r f; do echo "$f $(md5 -q "$f")"; done); }

expect() { # name "copied skipped failed state" actual
    if [ "$3" = "$2" ]; then pass "$1 ($3)"; else fail "$1: got '$3', expected '$2'"; fi
}

same_files() { # name listA listB
    if [ "$2" = "$3" ] && [ -n "$2" ]; then pass "$1"; else fail "$1"; diff <(echo "$2") <(echo "$3") | head -5; fi
}

echo "A: $A ($TA), B: $B ($TB), working in $DIR on each"

# Test files on A: small ones, one of 5 MB, one in a subfolder, one dated 2024.
adb -s "$A" shell "mkdir -p $DIR/src/sub && cd $DIR/src && i=1; while [ \$i -le $SMALL ]; do echo small \$i > s\$i.txt; i=\$((i+1)); done; head -c 5000000 /dev/urandom > big.bin; echo deep > sub/deep.txt; echo dated > old.txt; touch -d '2024-01-02 03:04:05' old.txt" || exit 1
adb -s "$B" shell "mkdir -p $DIR/copied $DIR/uploaded" || exit 1
SOURCE=$(device_md5 "$A" "$DIR/src")

echo "download A → Mac"
mkdir -p "$TMP/dl"
expect "job" "$FILES 0 0 completed" "$(run_app -dev.download "$A|$DIR/src|$TMP/dl")"
same_files "same files on the Mac" "$SOURCE" "$(local_md5 "$TMP/dl/src")"
OLD=$(stat -f %m "$TMP/dl/src/old.txt" 2>/dev/null)
if [ "$OLD" = "$(date -j -f '%Y-%m-%d %H:%M:%S' '2024-01-02 03:04:05' +%s)" ]; then pass "date kept"; else fail "date of old.txt: $OLD"; fi

echo "download again, skipping what's there"
expect "job" "0 $FILES 0 completed" "$(run_app -dev.policy skip -dev.download "$A|$DIR/src|$TMP/dl")"

echo "download again, comparing contents: same files are skipped"
if [ "$TA" = adb ]; then
    expect "job" "0 $FILES 0 completed" "$(run_app -dev.policy ifHashDiffers -dev.download "$A|$DIR/src|$TMP/dl")"
else
    echo "  (contents are compared over ADB only)"
fi

echo "upload Mac → B"
expect "job" "$FILES 0 0 completed" "$(run_app -dev.upload "$B|$DIR/uploaded|$TMP/dl/src")"
same_files "same files on B" "$SOURCE" "$(device_md5 "$B" "$DIR/uploaded/src")"

echo "copy A → B"
expect "job" "$FILES 0 0 completed" "$(run_app -dev.deviceCopy "$A>$B|$DIR/src|$DIR/copied|copy")"
same_files "same files on B" "$SOURCE" "$(device_md5 "$B" "$DIR/copied/src")"

echo "copy again: same files are skipped, a changed one is replaced, a leftover partial is cleared"
adb -s "$B" shell "echo changed on B, longer than before > $DIR/copied/src/s2.txt"
# As an interrupted upload leaves it (MTP keeps it; adbd removes its own).
adb -s "$B" shell "echo half > $DIR/copied/src/.$TAG-part-0000TEST"
# An original moved aside whose replacement made it: it was to be overwritten, so it goes.
adb -s "$B" shell "echo old > $DIR/copied/src/.s3.txt.$TAG-old-0000TEST"
expect "job" "1 $((FILES - 1)) 0 completed" "$(run_app -dev.policy ifSizeOrDateDiffers -dev.deviceCopy "$A>$B|$DIR/src|$DIR/copied|copy")"
same_files "same files on B" "$SOURCE" "$(device_md5 "$B" "$DIR/copied/src")"

LEFT=$(adb -s "$B" shell "find $DIR -name '.*' -name '*.$TAG-*'" | wc -l | tr -d ' ')
if [ "$LEFT" = 0 ]; then pass "no temporary files on B"; else fail "$LEFT temporary files on B"; fi

[ $FAILED -eq 0 ] && echo "all passed" || echo "$FAILED failed"
exit $((FAILED > 0))
