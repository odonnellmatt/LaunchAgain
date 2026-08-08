#!/bin/bash
#
# End-to-end test of the LaunchAgain engine against a synthetic application, in a scratch
# store. It never touches your real instances, never launches anything, and cleans up
# after itself.
#
#   ./Scripts/integration-test.sh
#
# What it proves, in order: an app can be inspected; instances can be created and
# numbered; an existing number never moves and a freed one is reused; a rebuild preserves the
# profile; the source application is byte-for-byte unchanged; a delete leaves no orphans;
# and command-line executables are rejected so every created instance is a GUI app.
#
# The launch-and-sign-in half of the matrix needs real apps and a human, and lives in
# docs/manual-checklist.md.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/launchagain-integration.XXXXXX")"
STORE="$SCRATCH/store"
SRC="$SCRATCH/source"
MAL="$ROOT/.build/debug/launchagain"
FAILURES=0

cleanup() {
  # Unregister anything we registered, then delete the scratch tree.
  # Every scratch store this script builds into, not just the main one: the
  # cross-process create race registers eight launchers of its own.
  for bundles in "$SCRATCH"/*/bundles; do
    [ -d "$bundles" ] || continue
    for app in "$bundles"/*.app; do
      [ -d "$app" ] || continue
      /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
        -u "$app" >/dev/null 2>&1 || true
    done
  done
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
check() { if [ "$1" = "0" ]; then pass "$2"; else fail "$2"; fi; }

echo ""
echo "Integration test — scratch store at $STORE"
echo ""

# ---------------------------------------------------------------- build the engine
if [ ! -x "$MAL" ]; then
  echo "==> Building"
  swift build >/dev/null
fi

# ---------------------------------------------------------------- synthetic app
mkdir -p "$SRC/Fake App.app/Contents/MacOS" "$SRC/Fake App.app/Contents/Resources"
cp /bin/echo "$SRC/Fake App.app/Contents/MacOS/Fake App"
printf 'not really an asar' > "$SRC/Fake App.app/Contents/Resources/app.asar"
cat > "$SRC/Fake App.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.example.fakeapp</string>
  <key>CFBundleName</key><string>Fake App</string>
  <key>CFBundleExecutable</key><string>Fake App</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
</dict>
</plist>
PLIST

APP="$SRC/Fake App.app"
SOURCE_HASH_BEFORE="$(find "$APP" -type f -exec shasum {} \; | shasum | awk '{print $1}')"

# ---------------------------------------------------------------- inspect
echo "Inspect"
"$MAL" --root "$STORE" inspect "$APP" > "$SCRATCH/inspect.txt" 2>&1
check $? "inspect runs"
grep -q "supported" "$SCRATCH/inspect.txt"; check $? "the synthetic app is reported as supported"
grep -q "Keychain" "$SCRATCH/inspect.txt"; check $? "the Keychain limitation is stated up front"

# ---------------------------------------------------------------- create
echo ""
echo "Create"
"$MAL" --root "$STORE" create "$APP" --count 3 --names "Personal,Work,Research" > "$SCRATCH/create.txt" 2>&1
check $? "creating three instances succeeds"

COUNT="$(ls -d "$STORE/bundles/"*.app 2>/dev/null | wc -l | tr -d ' ')"
[ "$COUNT" = "3" ]; check $? "three launcher bundles exist (found $COUNT)"

[ -d "$STORE/bundles/Fake App 2 – Work.app" ]; check $? "bundles are named after their number and label"

for n in 1 2 3; do
  ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
        "$STORE/bundles/Fake App $n – "*.app/Contents/Info.plist 2>/dev/null | head -1)
  case "$ID" in
    com.example.fakeapp.mal$n-*) : ;;
    *) fail "instance $n has an unexpected bundle identifier: $ID"; continue ;;
  esac
done
pass "each instance has its own bundle identifier"

UNIQUE=$(for n in 1 2 3; do
    /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
      "$STORE/bundles/Fake App $n – "*.app/Contents/Info.plist 2>/dev/null | head -1
  done | sort -u | wc -l | tr -d ' ')
[ "$UNIQUE" = "3" ]; check $? "the three identifiers are distinct"

# ---------------------------------------------------------------- signatures
echo ""
echo "Signatures"
for n in 1 2 3; do
  codesign --verify --deep --strict "$STORE/bundles/Fake App $n – "*.app >/dev/null 2>&1 \
    || { fail "instance $n does not verify"; continue; }
done
pass "every generated bundle passes codesign --verify --deep --strict"

# ---------------------------------------------------------------- the source is untouched
echo ""
echo "Safety"
SOURCE_HASH_AFTER="$(find "$APP" -type f -exec shasum {} \; | shasum | awk '{print $1}')"
[ "$SOURCE_HASH_BEFORE" = "$SOURCE_HASH_AFTER" ]
check $? "the source application is byte-for-byte unchanged"

# ---------------------------------------------------------------- numbering
echo ""
echo "Numbering"
"$MAL" --root "$STORE" list --json > "$SCRATCH/pre-delete.json" 2>&1
DATA_TWO=$(python3 -c "
import json
rows=json.load(open('$SCRATCH/pre-delete.json'))
print([r for r in rows if r['number']==2][0]['data'])")
INSTANCE_TWO="$(dirname "$DATA_TWO")"
ID_TWO="$(basename "$INSTANCE_TWO")"
printf 'delete\n' | "$MAL" --root "$STORE" delete "Fake App#2" >/dev/null 2>&1
check $? "deleting #2 succeeds"
[ ! -e "$INSTANCE_TWO" ]; check $? "deleting #2 removes its complete instance directory"
[ ! -e "$STORE/support/removed-instances/$ID_TWO.removed" ]
check $? "a completed uninstall leaves no per-instance recovery marker"

"$MAL" --root "$STORE" list --json > "$SCRATCH/list.json" 2>&1
python3 - "$SCRATCH/list.json" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))
numbers = sorted(r["number"] for r in rows)
assert numbers == [1, 3], f"expected [1, 3] after deleting #2, got {numbers}"
PY
check $? "#3 is still #3 after #2 is deleted"

"$MAL" --root "$STORE" create "$APP" --count 1 --names "Fourth" >/dev/null 2>&1
"$MAL" --root "$STORE" list --json > "$SCRATCH/list2.json" 2>&1
python3 - "$SCRATCH/list2.json" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))
numbers = sorted(r["number"] for r in rows)
assert numbers == [1, 2, 3], f"expected [1, 2, 3] - the freed number should be reused - got {numbers}"
PY
check $? "the next instance fills the freed gap at #2"

# ---------------------------------------------------------------- rebuild keeps data
echo ""
echo "Rebuild"
DATA=$(python3 -c "
import json,sys
rows=json.load(open('$SCRATCH/list2.json'))
print([r for r in rows if r['number']==3][0]['data'])")
printf 'signed in' > "$DATA/session.txt"
"$MAL" --root "$STORE" rebuild "Fake App#3" >/dev/null 2>&1
check $? "rebuild succeeds"
[ "$(cat "$DATA/session.txt" 2>/dev/null)" = "signed in" ]
check $? "the profile survived the rebuild untouched"

# ---------------------------------------------------------------- doctor
echo ""
echo "Housekeeping"
mkdir -p "$STORE/bundles/Stray.app"
cp -R "$STORE/bundles/Fake App 1 – Personal.app" \
      "$STORE/bundles/Verified Interrupted Copy.app"
"$MAL" --root "$STORE" doctor > "$SCRATCH/doctor.txt" 2>&1
grep -q "Stray.app" "$SCRATCH/doctor.txt"; check $? "the orphan sweep finds a stray bundle"
"$MAL" --root "$STORE" doctor --clean >/dev/null 2>&1
[ -d "$STORE/bundles/Stray.app" ]
check $? "--clean preserves an app whose LaunchAgain ownership cannot be proved"
[ ! -d "$STORE/bundles/Verified Interrupted Copy.app" ]
check $? "--clean removes a verified generated launcher copy"

"$MAL" --root "$STORE" diagnostics "$SCRATCH/diag.md" >/dev/null 2>&1
check $? "diagnostics export succeeds"
grep -q "no instance data" "$SCRATCH/diag.md"; check $? "the diagnostics file says what it excludes"

# ---------------------------------------------------------------- delete with data
echo ""
echo "Deletion"
DATA_ONE=$(python3 -c "
import json
rows=json.load(open('$SCRATCH/list2.json'))
print([r for r in rows if r['number']==1][0]['data'])")
INSTANCE_ONE="$(dirname "$DATA_ONE")"
BUNDLE_ONE="$STORE/bundles/Fake App 1 – Personal.app"
ID_ONE="$(basename "$INSTANCE_ONE")"
CLONE_ID_ONE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
  "$BUNDLE_ONE/Contents/Info.plist")
printf 'delete\n' | "$MAL" --root "$STORE" delete "Fake App#1" >/dev/null 2>&1
[ ! -d "$BUNDLE_ONE" ]; check $? "the launcher is removed"
[ ! -e "$INSTANCE_ONE" ]; check $? "its profile, logs and lock directory are removed together"
REMAINING_MANAGED=$(find "$STORE/bundles" -maxdepth 1 -type d \
  -name 'Fake App *.app' | wc -l | tr -d ' ')
if [ "$REMAINING_MANAGED" = "2" ]; then
  pass "only the two expected managed launchers remain"
else
  fail "expected two managed launchers after deletion (found $REMAINING_MANAGED)"
fi
if [ -d "$STORE/bundles/Stray.app" ]; then
  pass "the unrelated unproven app remains untouched after selected-instance deletion"
else
  fail "selected-instance deletion removed the unrelated unproven app"
fi

SHARED_LOG="$STORE/support/logs/launchagain.log"
LOG_IDENTITY_FOUND=0
for token in "$ID_ONE" "$CLONE_ID_ONE" "$BUNDLE_ONE" "$DATA_ONE"; do
  if grep -Fq "$token" "$SHARED_LOG" 2>/dev/null; then
    LOG_IDENTITY_FOUND=1
  fi
done
if [ "$LOG_IDENTITY_FOUND" = "0" ]; then
  pass "the deleted instance identity is absent from LaunchAgain's shared log"
else
  fail "the deleted instance identity remains in LaunchAgain's shared log"
fi
# `grep -v` exits non-zero when it filters everything out, which under `set -o pipefail`
# would end the script at the point it is proving that nothing was left behind.
STAGING=$( { ls -A "$STORE/bundles/.staging" 2>/dev/null | grep -cv metadata_never_index || true; } | tr -d ' ')
[ "$STAGING" = "0" ]; check $? "nothing is left in staging"

# ---------------------------------------------------------------- GUI-only boundary
echo ""
echo "GUI-only boundary"
if "$MAL" --root "$STORE" inspect /usr/bin/env > "$SCRATCH/non-gui.txt" 2>&1; then
  fail "a command-line executable was accepted as an application"
else
  pass "command-line executables are rejected"
fi
grep -q "GUI application instances only" "$SCRATCH/non-gui.txt"
check $? "the rejection explains that only macOS GUI apps can be cloned"

# A recorded GUI launcher that has disappeared must also produce a real process
# failure. Earlier builds printed an error but returned status 0, which made
# automation report a successful launch even though no application had opened.
MISSING_BUNDLE="$STORE/bundles/Fake App 2 – Fourth.app"
HELD_BUNDLE="$SCRATCH/held-fake-app-2"
mv "$MISSING_BUNDLE" "$HELD_BUNDLE"
if "$MAL" --root "$STORE" launch "Fake App#2" > "$SCRATCH/missing-launch.txt" 2>&1; then
  fail "a failed GUI launch returned status zero"
else
  pass "a failed GUI launch returns a non-zero process status"
fi
mv "$HELD_BUNDLE" "$MISSING_BUNDLE"
grep -Eq "not found|does not exist|missing" "$SCRATCH/missing-launch.txt"
check $? "the failed launch explains that the recorded GUI app is missing"

# ---------------------------------------------------------------- total failure exits non-zero
echo ""
echo "Failure reporting"
# A create where every instance failed used to print ✗ for each one and exit 0, so a
# script could not tell it from a success. An unwritable install root fails every
# instance in the batch without needing an unusual application.
FAIL_ROOT="$SCRATCH/failing-store"
mkdir -p "$FAIL_ROOT"
"$MAL" --root "$FAIL_ROOT" create "$APP" --count 1 > /dev/null 2>&1
check $? "a create into a writable scratch root succeeds (control)"

chmod 500 "$FAIL_ROOT/bundles"
set +e
"$MAL" --root "$FAIL_ROOT" create "$APP" --count 2 > "$SCRATCH/create-fail.txt" 2>&1
CREATE_FAIL_STATUS=$?
set -e
chmod 700 "$FAIL_ROOT/bundles"

[ "$CREATE_FAIL_STATUS" != "0" ]
check $? "a create where every instance failed exits non-zero (got $CREATE_FAIL_STATUS)"

FAIL_BUNDLES=$(ls -d "$FAIL_ROOT/bundles/"*.app 2>/dev/null | wc -l | tr -d ' ')
[ "$FAIL_BUNDLES" = "1" ]
check $? "nothing was created by the failed batch (bundles=$FAIL_BUNDLES, expected the 1 from the control)"

grep -q "✗" "$SCRATCH/create-fail.txt"
check $? "each failed instance is reported"

# ---------------------------------------------------------------- the permission message
echo ""
echo "Unwritable install root"
# B2. The exists-but-read-only branch — the likelier real failure for
# /Applications/LaunchAgain — suggests `sudo chown …`. That is a command printed for the
# user to run themselves, and the message says so. The product never escalates: it runs
# a fixed list of Apple tools by absolute path and sudo is not one of them.
grep -q "exists but LaunchAgain cannot write to it" "$SCRATCH/create-fail.txt"
check $? "a read-only install root is described as read-only, not as missing"

grep -q 'sudo chown -R \$(whoami)' "$SCRATCH/create-fail.txt"
check $? "the message suggests the command that actually fixes it"

grep -q "does not run any command for you" "$SCRATCH/create-fail.txt"
check $? "the message says LaunchAgain will not run that command itself"

grep -q "Ask one to create" "$SCRATCH/create-fail.txt" && \
  fail "a directory that exists is described as one to create" || \
  pass "the not-exists advice is not given for a directory that exists"

# ---------------------------------------------------------------- cross-process log startup
echo ""
echo "Cross-process logging"
LOG_RACE_ROOT="$SCRATCH/log-race"
LOG_RACE_PIDS=()
for i in {1..12}; do
  "$MAL" --root "$LOG_RACE_ROOT" doctor \
    > "$SCRATCH/log-race-$i.txt" 2>&1 &
  LOG_RACE_PIDS+=("$!")
done
LOG_RACE_EXIT_FAILURE=0
for pid in "${LOG_RACE_PIDS[@]}"; do
  if ! wait "$pid"; then
    LOG_RACE_EXIT_FAILURE=1
  fi
done
[ "$LOG_RACE_EXIT_FAILURE" = "0" ]
check $? "twelve concurrent CLI processes initialize the same store successfully"
LOG_RACE_RECORDS=$(grep -c "orphan sweep:" \
  "$LOG_RACE_ROOT/support/logs/launchagain.log" 2>/dev/null || true)
[ "$LOG_RACE_RECORDS" = "12" ]
check $? "cross-process log initialization preserves every record (found $LOG_RACE_RECORDS)"

# ---------------------------------------------------------------- cross-process create
#
# The check above races twelve processes over *log* initialization, which is not the
# shape of the bug that was blocking. That one was the registry: `create` drew a number,
# spent seconds cloning, then committed, and nothing ordered one process's read-modify-
# write against another's. Eight concurrent creates all reported success, all took the
# same number, seven lost the commit, and seven signed and registered launchers were
# left with profiles nothing could ever reattach.
#
# So race real `create` processes and assert the three counts agree. Anything less —
# rows, bundles or profiles disagreeing, or a repeated number — is that bug.
echo ""
echo "Cross-process create"
RACE_ROOT="$SCRATCH/create-race"
RACE_WRITERS=8
RACE_GO="$SCRATCH/create-race.go"

# A synthetic app clones in milliseconds, so processes started in a plain loop tend to
# serialise on fork order alone and never overlap. Each writer therefore spins on a
# barrier file and starts within the same instant of the others, which is what puts
# them inside each other's allocate-then-commit window.
RACE_PIDS=()
for i in $(seq 1 "$RACE_WRITERS"); do
  (
    while [ ! -f "$RACE_GO" ]; do :; done
    exec "$MAL" --root "$RACE_ROOT" create "$APP" --count 1 --names "Racer$i"
  ) > "$SCRATCH/create-race-$i.txt" 2>&1 &
  RACE_PIDS+=("$!")
done
sleep 1
touch "$RACE_GO"

RACE_REPORTED_OK=0
for pid in "${RACE_PIDS[@]}"; do
  if wait "$pid"; then RACE_REPORTED_OK=$((RACE_REPORTED_OK + 1)); fi
done

RACE_ROWS=$("$MAL" --root "$RACE_ROOT" list --json 2>/dev/null \
  | grep -c '"number"' || true)
RACE_BUNDLES=$(ls -d "$RACE_ROOT/bundles/"*.app 2>/dev/null | wc -l | tr -d ' ')
RACE_PROFILES=$(ls -d "$RACE_ROOT/support/instances/"*/ 2>/dev/null | wc -l | tr -d ' ')
RACE_NUMBERS=$("$MAL" --root "$RACE_ROOT" list --json 2>/dev/null \
  | sed -n 's/.*"number" *: *\([0-9][0-9]*\).*/\1/p' | sort -n)
RACE_DISTINCT=$(printf '%s\n' "$RACE_NUMBERS" | sort -u | grep -c . || true)

[ "$RACE_REPORTED_OK" = "$RACE_WRITERS" ]
check $? "every concurrent create process reports success ($RACE_REPORTED_OK/$RACE_WRITERS)"

[ "$RACE_ROWS" = "$RACE_WRITERS" ] && [ "$RACE_BUNDLES" = "$RACE_WRITERS" ] \
  && [ "$RACE_PROFILES" = "$RACE_WRITERS" ]
check $? "registry rows, launcher bundles and profiles all agree \
(rows=$RACE_ROWS bundles=$RACE_BUNDLES profiles=$RACE_PROFILES, expected $RACE_WRITERS)"

[ "$RACE_DISTINCT" = "$RACE_WRITERS" ]
check $? "every concurrently created instance has a distinct number \
(distinct=$RACE_DISTINCT of $RACE_WRITERS: $(printf '%s' "$RACE_NUMBERS" | tr '\n' ' '))"

[ -z "$(ls -A "$RACE_ROOT/support/number-reservations" 2>/dev/null)" ]
check $? "no number reservation is left held after the race"

# ---------------------------------------------------------------- result
echo ""
if [ "$FAILURES" = "0" ]; then
  printf '\033[32mAll integration checks passed.\033[0m\n\n'
  exit 0
else
  printf '\033[31m%s check(s) failed.\033[0m\n\n' "$FAILURES"
  exit 1
fi
