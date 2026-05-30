#!/usr/bin/env bash
# harness-crop-flow.sh — Layer C flow for the crop tool.
#
# Boots the app in harness mode, imports fixture photos, navigates to
# Develop on the first asset, fires setCrop with a 3:2 centre crop via
# the harness CLI, verifies getEdit reflects the crop on the asset,
# and screenshots the Develop view with the crop applied.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/harness-launch.sh
. "$REPO_ROOT/bin/lib/harness-launch.sh"
ARTIFACT_DIR="$REPO_ROOT/.artifacts/harness-crop"
# Honour SCREENSHOT_DIR when the capture-screenshots skill sets it so each
# flow's output lands under .artifacts/issue-<N>/<flow>/; otherwise fall
# back to the legacy per-flow artifact directory.
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$ARTIFACT_DIR}"
CATALOG_COPY="$ARTIFACT_DIR/catalog.sqlite"
ORIGINALS_DIR="$ARTIFACT_DIR/originals"
IMPORT_SOURCE="$REPO_ROOT/fixtures/import"
SOCKET="/tmp/dimroom-harness-crop-$$.sock"
APP_PID=""

cleanup() {
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
    fi
    rm -f "$SOCKET"
}
trap cleanup EXIT

assert_json_field() {
    local label="$1" json="$2" field="$3" expected="$4"
    local actual
    actual=$(printf '%s' "$json" | "$REPO_ROOT/bin/harness-json-extract" "$field")
    if [ "$actual" != "$expected" ]; then
        echo "ERROR: $label — expected $field == $expected, got $actual"
        echo "Response: $json"
        exit 1
    fi
    echo "  OK: $label — $field == $expected"
}

assert_json_field_present() {
    local label="$1" json="$2" field="$3"
    local present
    present=$(printf '%s' "$json" | "$REPO_ROOT/bin/harness-json-extract" "$field" --absent)
    if [ "$present" != "present" ]; then
        echo "ERROR: $label — expected $field to be present"
        echo "Response: $json"
        exit 1
    fi
    echo "  OK: $label — $field present"
}

echo "=== Building App ==="
swift build --package-path "$REPO_ROOT/App" 2>&1

echo "=== Building CLI ==="
swift build --package-path "$REPO_ROOT/Packages/Harness" --product dimroom-cli 2>&1

APP_BIN="$REPO_ROOT/App/.build/debug/Dimroom"
CLI_BIN="$REPO_ROOT/Packages/Harness/.build/debug/dimroom-cli"

if [ ! -x "$APP_BIN" ]; then
    echo "ERROR: App binary not found at $APP_BIN"
    exit 1
fi
if [ ! -x "$CLI_BIN" ]; then
    echo "ERROR: CLI binary not found at $CLI_BIN"
    exit 1
fi

echo "=== Preparing working catalog and originals dir ==="
rm -rf "$ARTIFACT_DIR"
mkdir -p "$ARTIFACT_DIR" "$ORIGINALS_DIR"
rm -f "$CATALOG_COPY"

echo "=== Launching app in harness mode ==="
FIXTURE_CATALOG="$CATALOG_COPY"
HARNESS_WORK_DIR="$ARTIFACT_DIR"
HARNESS_ENV=(DIMROOM_HARNESS_DISABLE_DRIVE=1 DIMROOM_HARNESS_AUTO_CONFIRM_RESTORE=0)
harness_launch_app

echo "=== Import fixtures ==="
IMPORT_OUT=$("$CLI_BIN" import-folder "$IMPORT_SOURCE" --socket "$SOCKET")
echo "$IMPORT_OUT"
assert_json_field "import status" "$IMPORT_OUT" "status" "ok"

echo "=== List assets to get UUID ==="
LIST_OUT=$("$CLI_BIN" list-assets --socket "$SOCKET")
echo "$LIST_OUT"
ASSET=$(printf '%s' "$LIST_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data[0].id')
ASSET_B=$(printf '%s' "$LIST_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data[1].id')
echo "  Asset A: $ASSET"
echo "  Asset B: $ASSET_B"

echo "=== Select asset and navigate to Develop ==="
"$CLI_BIN" select-asset "$ASSET" --socket "$SOCKET" >/dev/null
"$CLI_BIN" navigate develop --socket "$SOCKET" >/dev/null
# Let DevelopViewModel.activate finish loading the preview.
sleep 1

echo "=== setCrop — 3:2 centre crop, no straighten ==="
SET_OUT=$("$CLI_BIN" set-crop "$ASSET" \
    --x 0.125 --y 0.0 --width 0.75 --height 1.0 --angle 0 \
    --socket "$SOCKET")
echo "$SET_OUT"
assert_json_field "setCrop status" "$SET_OUT" "status" "ok"
# Wait for debounced render + auto-save.
sleep 1

echo "=== getEdit — verify cropRect present, cropAngle absent/null (angle=0 stored as nil) ==="
GET_OUT=$("$CLI_BIN" get-edit "$ASSET" --socket "$SOCKET")
echo "$GET_OUT"
assert_json_field "getEdit status" "$GET_OUT" "status" "ok"
assert_json_field_present "getEdit cropRect" "$GET_OUT" "data.cropRect"

echo "=== setCrop — with +10° straighten ==="
SET_OUT2=$("$CLI_BIN" set-crop "$ASSET" \
    --x 0.1 --y 0.1 --width 0.8 --height 0.8 --angle 10 \
    --socket "$SOCKET")
echo "$SET_OUT2"
assert_json_field "setCrop#2 status" "$SET_OUT2" "status" "ok"
sleep 1

echo "=== getEdit — verify cropAngle == 10 ==="
GET_OUT2=$("$CLI_BIN" get-edit "$ASSET" --socket "$SOCKET")
echo "$GET_OUT2"
assert_json_field_present "getEdit cropRect" "$GET_OUT2" "data.cropRect"
CROP_ANGLE=$(printf '%s' "$GET_OUT2" | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
print(float(doc['data']['cropAngle']))
")
if [ "$CROP_ANGLE" != "10.0" ]; then
    echo "ERROR: expected cropAngle == 10.0, got '$CROP_ANGLE'"
    exit 1
fi
echo "  OK: cropAngle == $CROP_ANGLE"

echo "=== setCrop — top-left display quadrant (Bug 1 regression test) ==="
# Select the top-left quadrant in *display* space. A broken renderer
# that doesn't flip Y would crop the bottom-left quadrant instead —
# bug 1 from #156.
SET_OUT3=$("$CLI_BIN" set-crop "$ASSET" \
    --x 0.0 --y 0.0 --width 0.5 --height 0.5 --angle 0 \
    --socket "$SOCKET")
echo "$SET_OUT3"
assert_json_field "setCrop top-left status" "$SET_OUT3" "status" "ok"
sleep 1

echo "=== Screenshot (crop applied, top-left quadrant) ==="
mkdir -p "$SCREENSHOT_DIR"
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/crop-topleft-result.png" --socket "$SOCKET" || true

echo "=== enter-crop again (Bug 2 regression test — re-enter crop mode) ==="
"$CLI_BIN" enter-crop "$ASSET" --socket "$SOCKET" >/dev/null
# Let render reschedule.
sleep 1

echo "=== Screenshot (re-entered crop — full frame + overlay) ==="
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/crop-reentered-overlay.png" --socket "$SOCKET" || true

echo "=== set-crop-preset oneToOne → commit-crop → get-edit ==="
"$CLI_BIN" set-crop-preset --preset oneToOne --socket "$SOCKET" >/dev/null
"$CLI_BIN" commit-crop --socket "$SOCKET" >/dev/null
sleep 1

GET_OUT3=$("$CLI_BIN" get-edit "$ASSET" --socket "$SOCKET")
echo "$GET_OUT3"
assert_json_field "getEdit after oneToOne" "$GET_OUT3" "status" "ok"
# The stored cropRect is in CI pixel space. A 1:1 square is cropWidth
# == cropHeight; verify via Python rather than substring match.
SQUARE_CHECK=$(printf '%s' "$GET_OUT3" | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
r = doc['data'].get('cropRect')
if not r:
    print('no-crop')
else:
    # CGRect's default Codable encodes as a 2-element array
    # [[x, y], [w, h]]; tolerate dictionary forms too just in case.
    if isinstance(r, list):
        w = r[1][0]
        h = r[1][1]
    elif 'width' in r and 'height' in r:
        w, h = r['width'], r['height']
    else:
        w = r['size']['width']
        h = r['size']['height']
    print('square' if abs(w - h) < 0.5 else f'non-square w={w} h={h}')
")
if [ "$SQUARE_CHECK" != "square" ]; then
    echo "ERROR: oneToOne preset did not produce a square crop — $SQUARE_CHECK"
    exit 1
fi
echo "  OK: oneToOne preset produced a square crop"

echo "=== enter-crop → reset-crop → commit-crop → get-edit (identity) ==="
"$CLI_BIN" enter-crop "$ASSET" --socket "$SOCKET" >/dev/null
sleep 1
"$CLI_BIN" reset-crop --socket "$SOCKET" >/dev/null
"$CLI_BIN" commit-crop --socket "$SOCKET" >/dev/null
sleep 1

GET_OUT4=$("$CLI_BIN" get-edit "$ASSET" --socket "$SOCKET")
echo "$GET_OUT4"
# Identity crop is canonicalised to nil by commitCrop, so cropRect
# should be absent or null in the stored state.
IDENTITY_CHECK=$(printf '%s' "$GET_OUT4" | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
r = doc['data'].get('cropRect')
print('absent' if r is None else f'present:{r}')
")
if [ "$IDENTITY_CHECK" != "absent" ]; then
    echo "ERROR: reset-crop + commit-crop did not collapse to identity — $IDENTITY_CHECK"
    exit 1
fi
echo "  OK: reset-crop collapsed cropRect to identity (null)"

echo "=== Final screenshot ==="
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/crop-result.png" --socket "$SOCKET" || true

# ---------------------------------------------------------------------
# Issue #323: drag-to-rotate handles. Enter crop mode (asset A is at
# identity after the reset-crop+commit above), drive two rotate-handle
# drags about the crop centre and confirm the deltas accumulate onto
# cropAngle, then commit and read it back. The CLI command lands on the
# same setCropAngleLive path the on-screen handle drag uses.
# ---------------------------------------------------------------------
echo "=== drag-to-rotate — enter crop on A ==="
"$CLI_BIN" enter-crop "$ASSET" --socket "$SOCKET" >/dev/null
sleep 1

echo "=== drag-rotate-handle topLeft +10° ==="
ROT_OUT=$("$CLI_BIN" drag-rotate-handle --corner topLeft --angle-delta 10 --socket "$SOCKET")
echo "$ROT_OUT"
assert_json_field "drag-rotate-handle status" "$ROT_OUT" "status" "ok"
sleep 1

echo "=== drag-rotate-handle topRight +5° (accumulates to 15°) ==="
ROT_OUT2=$("$CLI_BIN" drag-rotate-handle --corner topRight --angle-delta 5 --socket "$SOCKET")
echo "$ROT_OUT2"
assert_json_field "drag-rotate-handle#2 status" "$ROT_OUT2" "status" "ok"
sleep 1

echo "=== Screenshot — crop overlay rotated via handle ==="
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/rotate-handle-result.png" --socket "$SOCKET" || true

echo "=== commit-crop → get-edit — cropAngle accumulated to 15 ==="
"$CLI_BIN" commit-crop --socket "$SOCKET" >/dev/null
sleep 1
GET_ROT=$("$CLI_BIN" get-edit "$ASSET" --socket "$SOCKET")
echo "$GET_ROT"
ROT_ANGLE=$(printf '%s' "$GET_ROT" | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
print(float(doc['data']['cropAngle']))
")
if [ "$ROT_ANGLE" != "15.0" ]; then
    echo "ERROR: expected cropAngle == 15.0 after two rotate-handle drags, got '$ROT_ANGLE'"
    exit 1
fi
echo "  OK: rotate handles accumulated cropAngle == $ROT_ANGLE"

echo "=== drag-rotate-handle rejects out-of-crop-mode use ==="
# Already committed, so crop mode is inactive — the command must error.
INACTIVE_OUT=$("$CLI_BIN" drag-rotate-handle --corner topLeft --angle-delta 5 --socket "$SOCKET" || true)
echo "$INACTIVE_OUT"
assert_json_field "drag-rotate-handle inactive status" "$INACTIVE_OUT" "status" "error"

# ---------------------------------------------------------------------
# Issue #239 bug 2 regression: cross-asset crop state isolation. After
# cropping asset A above, navigating to a never-cropped asset B and
# entering crop mode must show the full frame — not asset A's leftover
# cropRect.
# ---------------------------------------------------------------------
if [ -n "$ASSET_B" ] && [ "$ASSET_B" != "null" ]; then
    echo "=== Cross-asset state isolation — set crop on A ==="
    "$CLI_BIN" set-crop "$ASSET" \
        --x 0.1 --y 0.1 --width 0.6 --height 0.6 --angle 0 \
        --socket "$SOCKET" >/dev/null
    sleep 1

    echo "=== Select asset B (never cropped) ==="
    "$CLI_BIN" select-asset "$ASSET_B" --socket "$SOCKET" >/dev/null
    # DevelopViewModel.activate resets cropViewModel before loading.
    sleep 1

    echo "=== Enter crop mode on B ==="
    "$CLI_BIN" enter-crop "$ASSET_B" --socket "$SOCKET" >/dev/null
    sleep 1

    echo "=== Screenshot — full-frame overlay on B ==="
    "$CLI_BIN" screenshot "$SCREENSHOT_DIR/crop-fresh-asset.png" --socket "$SOCKET" || true

    echo "=== getEdit on B — must have no cropRect ==="
    GET_OUT_B=$("$CLI_BIN" get-edit "$ASSET_B" --socket "$SOCKET")
    echo "$GET_OUT_B"
    B_CROP_CHECK=$(printf '%s' "$GET_OUT_B" | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
r = doc['data'].get('cropRect')
print('absent' if r is None else f'present:{r}')
")
    if [ "$B_CROP_CHECK" != "absent" ]; then
        echo "ERROR: never-cropped asset B has a cropRect after switching from A — $B_CROP_CHECK"
        exit 1
    fi
    echo "  OK: asset B has no stored cropRect after switching from cropped A"

    # Commit-crop on B without modifying anything — the stored state must
    # remain identity even though the user briefly entered crop mode.
    "$CLI_BIN" commit-crop --socket "$SOCKET" >/dev/null
    sleep 1
    GET_OUT_B2=$("$CLI_BIN" get-edit "$ASSET_B" --socket "$SOCKET")
    B_CROP_CHECK2=$(printf '%s' "$GET_OUT_B2" | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
r = doc['data'].get('cropRect')
print('absent' if r is None else f'present:{r}')
")
    if [ "$B_CROP_CHECK2" != "absent" ]; then
        echo "ERROR: identity commit on B wrote a non-identity cropRect — $B_CROP_CHECK2"
        exit 1
    fi
    echo "  OK: identity commit on B preserved no-crop state"
fi

echo "=== Quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness crop flow PASSED ==="
