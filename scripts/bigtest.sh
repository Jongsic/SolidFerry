#!/bin/bash
# Many files through the app's queue on one phone (docs/DEVICE_TESTS.md):
#
#   scripts/bigtest.sh SERIAL adb|mtp DIR
#
# DIR (/sdcard/Download/xfer-bigtest-…) holds the test files in DIR/src: Camera/ with 8,000
# files and Docs/sub01…sub20 with 100 each (see the setup line in DEVICE_TESTS.md). Downloads
# them to a temporary folder on this Mac (deleted at the end), downloads again (skip, by size
# and date, by contents over ADB), uploads them to DIR/up-<transport>, then copies, merges and
# moves within the phone into DIR/copy-, DIR/moved-<transport>. Those results of an earlier run
# are cleared first; DIR/src stays for the next run. Quit the app first.
set -u
S=$1; T=$2; D=$3
BUNDLE=$(ls -d "$(cd "$(dirname "$0")/.." && pwd)"/build/DerivedData.noindex/Build/Products/Debug/*.app 2>/dev/null | head -1)
APP="$BUNDLE/Contents/MacOS/$(basename "$BUNDLE" .app)"
[ -x "$APP" ] || { echo "build the app first (make build)"; exit 2; }
pgrep -x "$(basename "$BUNDLE" .app)" >/dev/null && { echo "quit the app first"; exit 2; }
case "$D" in /sdcard/Download/xfer-bigtest-*) ;; *) echo "DIR must be /sdcard/Download/xfer-bigtest-…"; exit 2;; esac
SRC=$D/src # the test files; results go next to it
NAME=src
L=$(mktemp -d -t xfer-bigtest)
FAILED=0
trap 'rm -rf "$L"; echo "removed $L"' EXIT

pass() { echo "  ✔︎ $1"; }
fail() { echo "  ✘ $1"; FAILED=$((FAILED + 1)); }

run_app() { # args… → "copied skipped failed state", and the time taken
    local result="$L/result.json"; rm -f "$result"
    local start=$(date +%s)
    perl -e 'alarm 1800; exec @ARGV' "$APP" -transport."$S" "$T" -dev.quitWhenDone "$result" "$@" >/dev/null 2>&1
    local took=$(( $(date +%s) - start ))
    if [ ! -f "$result" ]; then echo "- - - timed-out ${took}s"; return; fi
    python3 -c '
import json, sys
j = json.load(open(sys.argv[1]))[0]
print(j["copied"], j["skipped"], j["failed"], j["state"].replace(" ", "_"), sys.argv[2] + "s")
for f in j["failures"][:5]: print("     ", f, file=sys.stderr)
' "$result" "$took"
}

expect() { # name expected actual(with time)
    local got=${3% *}
    if [ "$got" = "$2" ]; then pass "$1 ($3)"; else fail "$1: got '$3', expected '$2'"; fi
}

phone_md5() { adb -s "$S" shell "cd '$1' && find Camera Docs -type f | sort | xargs md5sum" | awk '{print $2, $1}'; }
local_md5() { (cd "$1" && find Camera Docs -type f | sort | xargs md5 -r | awk '{print $2, $1}'); }
same() { if [ "$2" = "$3" ] && [ -n "$2" ]; then pass "$1"; else fail "$1"; diff <(echo "$2") <(echo "$3") | head -5; fi; }
count() { adb -s "$S" shell "find '$1' -type f | wc -l" | tr -d ' \r'; }

echo "== $T: $S, $D"
adb -s "$S" shell "rm -rf '$D/up-$T' '$D/copy-$T' '$D/moved-$T'"
SOURCE=$(phone_md5 "$SRC")
echo "source: $(echo "$SOURCE" | wc -l | tr -d ' ') files"

echo "download → Mac"
expect "job" "10000 0 0 completed" "$(run_app -dev.download "$S|$SRC|$L/dl")"
same "same files on the Mac" "$SOURCE" "$(local_md5 "$L/dl/$NAME")"

echo "download again, skipping what's there"
expect "job" "0 10000 0 completed" "$(run_app -dev.policy skip -dev.download "$S|$SRC|$L/dl")"

echo "download again, by size and date"
expect "job" "0 10000 0 completed" "$(run_app -dev.policy ifSizeOrDateDiffers -dev.download "$S|$SRC|$L/dl")"

if [ "$T" = adb ]; then
    echo "download again, comparing contents; 5 files changed on the Mac (same size)"
    for i in 1 2 3 4 5; do
        f="$L/dl/$NAME/Docs/sub02/doc$i.txt"
        size=$(stat -f %z "$f"); head -c "$size" /dev/urandom > "$f"
    done
    expect "job" "5 9995 0 completed" "$(run_app -dev.policy ifHashDiffers -dev.download "$S|$SRC|$L/dl")"
    same "same files on the Mac" "$SOURCE" "$(local_md5 "$L/dl/$NAME")"
fi

echo "upload Mac → phone"
adb -s "$S" shell "mkdir -p '$D/up-$T' '$D/copy-$T' '$D/moved-$T'"
expect "job" "10000 0 0 completed" "$(run_app -dev.upload "$S|$D/up-$T|$L/dl/$NAME")"
same "same files on the phone" "$SOURCE" "$(phone_md5 "$D/up-$T/$NAME")"

echo "upload again, by size and date (dates the phone dropped don't count)"
expect "job" "0 10000 0 completed" "$(run_app -dev.policy ifSizeOrDateDiffers -dev.upload "$S|$D/up-$T|$L/dl/$NAME")"

echo "copy within the phone: a folder whose name is free goes whole"
expect "job" "1 0 0 completed" "$(run_app -dev.deviceCopy "$S|$SRC/Camera|$D/copy-$T|copy")"
c=$(count "$D/copy-$T/Camera"); [ "$c" = 8000 ] && pass "8000 files copied" || fail "copied: $c files"

echo "copy within the phone into a folder of the same name: merged file by file"
expect "job" "0 2000 0 completed" "$(run_app -dev.policy skip -dev.deviceCopy "$S|$SRC/Docs|$D/up-$T/$NAME|copy")"

echo "move within the phone: whole"
expect "job" "1 0 0 completed" "$(run_app -dev.deviceCopy "$S|$D/copy-$T/Camera|$D/moved-$T|move")"
c=$(count "$D/moved-$T/Camera"); [ "$c" = 8000 ] && pass "8000 files moved" || fail "moved: $c files"
left=$(adb -s "$S" shell "ls '$D/copy-$T'" | tr -d '\r'); [ -z "$left" ] && pass "source gone" || fail "left at source: $left"

LEFT=$(adb -s "$S" shell "find '$D' -name '.*xfer-*'" | wc -l | tr -d ' ')
[ "$LEFT" = 0 ] && pass "no temporary files on the phone" || fail "$LEFT temporary files on the phone"

[ $FAILED -eq 0 ] && echo "all passed" || echo "$FAILED failed"
