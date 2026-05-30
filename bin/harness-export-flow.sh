#!/usr/bin/env bash
# harness-export-flow.sh — Layer C flow for the export pipeline.
#
# Boots the app in harness mode, imports fixture photos, then exports
# them to a temp directory as JPEG. Verifies files exist with the
# correct extension. Exports again to the same directory and verifies
# collision naming (_1 suffixes).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/harness-launch.sh
. "$REPO_ROOT/bin/lib/harness-launch.sh"
ARTIFACT_DIR="$REPO_ROOT/.artifacts/harness-export"
CATALOG_COPY="$ARTIFACT_DIR/catalog.sqlite"
ORIGINALS_DIR="$ARTIFACT_DIR/originals"
EXPORT_DIR="$ARTIFACT_DIR/exported"
EXPORT_DIR_MENU="$ARTIFACT_DIR/exported-menu"
# #320 crop-export regression: a synthesised >2048px source plus its
# cropped and uncropped export destinations.
LARGE_SRC_DIR="$ARTIFACT_DIR/large-src"
CROP_EXPORT_DIR="$ARTIFACT_DIR/exported-crop"
UNCROP_EXPORT_DIR="$ARTIFACT_DIR/exported-uncrop"
IMPORT_SOURCE="$REPO_ROOT/fixtures/import"
SOCKET="/tmp/dimroom-harness-export-$$.sock"
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

# --- #320 crop-export regression helpers ------------------------------
# The system python3 has neither Quartz nor PIL, so we hand-roll a minimal
# uncompressed-TIFF writer and reader (stdlib `struct` only). The writer
# emits a known left-red / right-blue split so a sampled pixel of the
# exported crop has a deterministic expected colour; the reader decodes
# ImageIO's uncompressed RGB(A) TIFF output (either byte order).
write_split_tiff() {
    # write_split_tiff <path> <width> <height>
    /usr/bin/python3 - "$1" "$2" "$3" <<'PY'
import sys, struct
path, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
RED = bytes((210, 20, 20)); BLUE = bytes((20, 20, 210))
half = w // 2
pixels = (RED * half + BLUE * (w - half)) * h
def entry(tag, typ, cnt, val):
    return struct.pack('<HHI', tag, typ, cnt) + struct.pack('<I', val)
header_len = 8
ifd_off = header_len + len(pixels)
n = 9
bps_off = ifd_off + 2 + n * 12 + 4
entries = [entry(256, 4, 1, w), entry(257, 4, 1, h), entry(258, 3, 3, bps_off),
           entry(259, 3, 1, 1), entry(262, 3, 1, 2), entry(273, 4, 1, header_len),
           entry(277, 3, 1, 3), entry(278, 4, 1, h), entry(279, 4, 1, len(pixels))]
out = bytearray(b'II' + struct.pack('<H', 42) + struct.pack('<I', ifd_off))
out += pixels
out += struct.pack('<H', n) + b''.join(entries) + struct.pack('<I', 0)
out += struct.pack('<HHH', 8, 8, 8)
open(path, 'wb').write(bytes(out))
PY
}

read_tiff_rgb() {
    # read_tiff_rgb <path> <x> <y> -> prints "R G B"; exits 2 on an
    # encoding this minimal reader doesn't handle (compressed/16-bit/planar).
    # Handles either byte order, inline-or-offset value arrays, and the
    # multi-strip layout ImageIO uses for large images.
    /usr/bin/python3 - "$1" "$2" "$3" <<'PY'
import sys, struct
path, x, y = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
d = open(path, 'rb').read()
bo = '<' if d[:2] == b'II' else '>'
ifd = struct.unpack(bo + 'I', d[4:8])[0]
n = struct.unpack(bo + 'H', d[ifd:ifd + 2])[0]
ents = {}
for i in range(n):
    o = ifd + 2 + i * 12
    tag, typ, cnt = struct.unpack(bo + 'HHI', d[o:o + 8])
    ents[tag] = (typ, cnt, d[o + 8:o + 12])

def vals(tag, default=None):
    if tag not in ents:
        return default
    typ, cnt, raw = ents[tag]
    fmt = {3: 'H', 4: 'I'}.get(typ)
    if fmt is None:
        return default
    width = {3: 2, 4: 4}[typ]
    base = raw if cnt * width <= 4 else d[struct.unpack(bo + 'I', raw)[0]:]
    return [struct.unpack(bo + fmt, base[j * width:(j + 1) * width])[0] for j in range(cnt)]

w = vals(256)[0]
comp = vals(259, [1])[0]
planar = vals(284, [1])[0]
bps = vals(258, [8])[0]
spp = vals(277, [3])[0]
rps = vals(278, [vals(257)[0]])[0]
offsets = vals(273)
if comp != 1 or planar != 1 or bps != 8:
    sys.stderr.write("unsupported TIFF comp=%d planar=%d bps=%d\n" % (comp, planar, bps))
    sys.exit(2)
strip = y // rps
row_in_strip = y % rps
off = offsets[strip] + (row_in_strip * w + x) * spp
print(d[off], d[off + 1], d[off + 2])
PY
}

# |a - b| <= 70 — generous tolerance for sRGB / preview-resample drift.
px_near() {
    local diff=$(( $1 - $2 ))
    [ "$diff" -lt 0 ] && diff=$(( -diff ))
    [ "$diff" -le 70 ]
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

echo "=== Preparing working directories ==="
rm -rf "$ARTIFACT_DIR"
mkdir -p "$ARTIFACT_DIR" "$ORIGINALS_DIR" "$EXPORT_DIR" "$EXPORT_DIR_MENU" \
    "$LARGE_SRC_DIR" "$CROP_EXPORT_DIR" "$UNCROP_EXPORT_DIR"
rm -f "$CATALOG_COPY"

echo "=== Launching app in harness mode ==="
# DIMROOM_HARNESS_AUTO_CONFIRM_RESTORE=0 short-circuits the first-launch
# catalog-restore alert path introduced by #234 (offerConnectForRestore
# runs an NSAlert.runModal that otherwise blocks the launch when there's
# no Drive auth and no local catalog).
FIXTURE_CATALOG="$CATALOG_COPY"
HARNESS_WORK_DIR="$ARTIFACT_DIR"
HARNESS_ENV=(DIMROOM_HARNESS_DISABLE_DRIVE=1 DIMROOM_HARNESS_AUTO_CONFIRM_RESTORE=0)
harness_launch_app

echo "=== Import fixtures (expect 3 imported) ==="
IMPORT_OUT=$("$CLI_BIN" import-folder "$IMPORT_SOURCE" --socket "$SOCKET")
echo "$IMPORT_OUT"
assert_json_field "import status" "$IMPORT_OUT" "status" "ok"
assert_json_field "import importedCount" "$IMPORT_OUT" "data.importedCount" "3"

echo "=== Clear scope to show all assets ==="
"$CLI_BIN" set-scope --socket "$SOCKET" > /dev/null

echo "=== First export to JPEG (expect 3 exported) ==="
EXPORT_OUT=$("$CLI_BIN" export "$EXPORT_DIR" --format jpeg --socket "$SOCKET")
echo "$EXPORT_OUT"
assert_json_field "first export status" "$EXPORT_OUT" "status" "ok"
assert_json_field "first export exportedCount" "$EXPORT_OUT" "data.exportedCount" "3"
assert_json_field "first export skippedCount" "$EXPORT_OUT" "data.skippedCount" "0"
assert_json_field "first export failedCount" "$EXPORT_OUT" "data.failedCount" "0"

echo "=== Verify 3 JPEG files exist ==="
JPG_COUNT=$(find "$EXPORT_DIR" -name "*.jpg" | wc -l | tr -d ' ')
if [ "$JPG_COUNT" -ne 3 ]; then
    echo "ERROR: Expected 3 .jpg files, found $JPG_COUNT"
    ls -la "$EXPORT_DIR"
    exit 1
fi
echo "  OK: Found $JPG_COUNT .jpg files"

echo "=== Second export to same dir (expect collision naming) ==="
EXPORT_OUT2=$("$CLI_BIN" export "$EXPORT_DIR" --format jpeg --socket "$SOCKET")
echo "$EXPORT_OUT2"
assert_json_field "second export status" "$EXPORT_OUT2" "status" "ok"
assert_json_field "second export exportedCount" "$EXPORT_OUT2" "data.exportedCount" "3"
assert_json_field "second export skippedCount" "$EXPORT_OUT2" "data.skippedCount" "0"
assert_json_field "second export failedCount" "$EXPORT_OUT2" "data.failedCount" "0"

echo "=== Verify 6 JPEG files exist (3 original + 3 with _1 suffix) ==="
JPG_COUNT2=$(find "$EXPORT_DIR" -name "*.jpg" | wc -l | tr -d ' ')
if [ "$JPG_COUNT2" -ne 6 ]; then
    echo "ERROR: Expected 6 .jpg files after second export, found $JPG_COUNT2"
    ls -la "$EXPORT_DIR"
    exit 1
fi
echo "  OK: Found $JPG_COUNT2 .jpg files after second export"

# Verify at least one _1 suffix file exists
COLLISION_COUNT=$(find "$EXPORT_DIR" -name "*_1.jpg" | wc -l | tr -d ' ')
if [ "$COLLISION_COUNT" -lt 1 ]; then
    echo "ERROR: Expected at least one _1.jpg file, found $COLLISION_COUNT"
    ls -la "$EXPORT_DIR"
    exit 1
fi
echo "  OK: Found $COLLISION_COUNT collision-named files"

# ----------------------------------------------------------------------
# Menu → sheet → coordinator end-to-end (regression test for #242).
#
# `export` above drives the coordinator directly; this stanza exercises
# the same path the menu's File → Export… item takes: notification →
# ContentView's exportSheetPublisher → showExportSheet → onExport
# closure → AppDelegate.startExport → ExportCoordinator. Previously the
# coordinator was reached two different ways (UI vs. harness), so a
# regression that dropped the sheet presentation looked identical to
# "nothing happened" without surfacing as a harness failure.
# ----------------------------------------------------------------------
# When the capture-screenshots skill runs the flow, $SCREENSHOT_DIR is
# set to the per-flow output directory. Grab a library-after-export shot
# so reviewers can see the state before exercising the menu path.
if [ -n "${SCREENSHOT_DIR:-}" ]; then
    mkdir -p "$SCREENSHOT_DIR"
    "$CLI_BIN" screenshot "$SCREENSHOT_DIR/library-after-direct-export.png" --socket "$SOCKET" > /dev/null || true
fi

echo "=== Pre-select an asset so the confirmation dialog stays out of the way ==="
TARGET_ID=$(printf '%s' "$(\
    "$CLI_BIN" list-assets --socket "$SOCKET" \
)" | "$REPO_ROOT/bin/harness-json-extract" 'data[0].id')
if [ -z "$TARGET_ID" ]; then
    echo "ERROR: list-assets returned no ids"
    exit 1
fi
echo "  Selecting asset $TARGET_ID"
"$CLI_BIN" select-asset "$TARGET_ID" --socket "$SOCKET" > /dev/null

echo "=== Trigger File → Export menu via notification ==="
TRIGGER_OUT=$("$CLI_BIN" trigger-export-menu --socket "$SOCKET")
if [ -n "${SCREENSHOT_DIR:-}" ]; then
    "$CLI_BIN" screenshot "$SCREENSHOT_DIR/export-sheet-visible.png" --socket "$SOCKET" > /dev/null || true
fi
echo "$TRIGGER_OUT"
assert_json_field "trigger-export-menu status" "$TRIGGER_OUT" "status" "ok"
# The export-sheet visibility flag is what proves the sheet mounted
# rather than being silently dropped (the #242 regression). The
# selection branch should bypass the confirmation dialog and land
# directly on the sheet.
assert_json_field "trigger-export-menu sheet visible" "$TRIGGER_OUT" "data.exportSheetVisible" "true"

echo "=== Complete the export sheet (substitutes for NSOpenPanel) ==="
MENU_EXPORT_OUT=$("$CLI_BIN" complete-export-sheet "$EXPORT_DIR_MENU" --format jpeg --socket "$SOCKET")
echo "$MENU_EXPORT_OUT"
assert_json_field "menu export status" "$MENU_EXPORT_OUT" "status" "ok"
# 1 because we pre-selected a single asset; selection wins over the
# fallback-to-visible branch.
assert_json_field "menu export exportedCount" "$MENU_EXPORT_OUT" "data.exportedCount" "1"
assert_json_field "menu export skippedCount" "$MENU_EXPORT_OUT" "data.skippedCount" "0"
assert_json_field "menu export failedCount" "$MENU_EXPORT_OUT" "data.failedCount" "0"

MENU_JPG_COUNT=$(find "$EXPORT_DIR_MENU" -name "*.jpg" | wc -l | tr -d ' ')
if [ "$MENU_JPG_COUNT" -ne 1 ]; then
    echo "ERROR: Expected 1 .jpg file in menu export, found $MENU_JPG_COUNT"
    ls -la "$EXPORT_DIR_MENU"
    exit 1
fi
echo "  OK: menu-driven export produced $MENU_JPG_COUNT .jpg file"

# ======================================================================
# #320 regression: a crop authored against the ~2048px master preview
# must export at the full-resolution original's framing, not a tiny
# corner ROI. We synthesise a 3000×2000 source (well above the 2048
# preview cap), crop its left half, and assert the exported TIFF is
# ~1500×2000 (½ the 3000px original) — not ~1024px, which is what the
# bug produced by feeding the preview-pixel rect straight into the
# original. A sampled centre pixel must be the left-half colour (red),
# proving the export holds the right content so this can't regress
# silently. Runs last so it can't disturb the import/export-count
# assertions above (which read fixtures/import).
# ======================================================================
echo "=== #320: synthesise a >2048px split-colour source ==="
SRC_W=3000
SRC_H=2000
write_split_tiff "$LARGE_SRC_DIR/cropsrc.tiff" "$SRC_W" "$SRC_H"

echo "=== Import the large source (expect 1 imported) ==="
LARGE_IMPORT=$("$CLI_BIN" import-folder "$LARGE_SRC_DIR" --socket "$SOCKET")
echo "$LARGE_IMPORT"
assert_json_field "large import status" "$LARGE_IMPORT" "status" "ok"
assert_json_field "large import importedCount" "$LARGE_IMPORT" "data.importedCount" "1"

echo "=== Refresh scope so the new asset is in the visible rows ==="
"$CLI_BIN" set-scope --socket "$SOCKET" > /dev/null

echo "=== Find the large asset's id by filename ==="
LARGE_ID=$("$CLI_BIN" list-assets --socket "$SOCKET" | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
for a in doc['data']:
    if a['originalFilename'] == 'cropsrc.tiff':
        print(a['id']); break
")
if [ -z "$LARGE_ID" ]; then
    echo "ERROR: could not find imported cropsrc.tiff asset id"
    exit 1
fi
echo "  Large asset: $LARGE_ID"

echo "=== Select, navigate develop, crop the left half ==="
"$CLI_BIN" select-asset "$LARGE_ID" --socket "$SOCKET" > /dev/null
"$CLI_BIN" navigate develop --socket "$SOCKET" > /dev/null
# Let DevelopViewModel.activate load the preview before committing a crop.
sleep 1
CROP_OUT=$("$CLI_BIN" set-crop "$LARGE_ID" --x 0 --y 0 --width 0.5 --height 1.0 --angle 0 --socket "$SOCKET")
assert_json_field "large set-crop status" "$CROP_OUT" "status" "ok"
# Wait for the debounced render + auto-save.
sleep 1

echo "=== getEdit — cropRect and cropReferenceSize must be present (#320) ==="
LARGE_EDIT=$("$CLI_BIN" get-edit "$LARGE_ID" --socket "$SOCKET")
echo "$LARGE_EDIT"
CROP_PRESENT=$(printf '%s' "$LARGE_EDIT" | "$REPO_ROOT/bin/harness-json-extract" "data.cropRect" --absent)
REF_PRESENT=$(printf '%s' "$LARGE_EDIT" | "$REPO_ROOT/bin/harness-json-extract" "data.cropReferenceSize" --absent)
if [ "$CROP_PRESENT" != "present" ]; then
    echo "ERROR: cropRect missing after set-crop"
    exit 1
fi
if [ "$REF_PRESENT" != "present" ]; then
    echo "ERROR: cropReferenceSize missing — export would corner-crop (#320)"
    exit 1
fi
echo "  OK: cropRect + cropReferenceSize stored"

# Crop mode is committed (not active), so the Develop preview now shows
# the cropped result — exactly what the full-res export must match.
if [ -n "${SCREENSHOT_DIR:-}" ]; then
    mkdir -p "$SCREENSHOT_DIR"
    "$CLI_BIN" screenshot "$SCREENSHOT_DIR/develop-crop-left-half.png" --socket "$SOCKET" > /dev/null || true
fi

echo "=== Export the cropped asset as TIFF (apply edits) ==="
"$CLI_BIN" navigate library --socket "$SOCKET" > /dev/null
CROP_EXPORT=$("$CLI_BIN" export "$CROP_EXPORT_DIR" --format tiff --apply-edits --socket "$SOCKET")
echo "$CROP_EXPORT"
assert_json_field "crop export status" "$CROP_EXPORT" "status" "ok"
assert_json_field "crop export exportedCount" "$CROP_EXPORT" "data.exportedCount" "1"

CROP_FILE=$(find "$CROP_EXPORT_DIR" -name "*.tiff" | head -1)
if [ -z "$CROP_FILE" ]; then
    echo "ERROR: no cropped TIFF exported"
    ls -la "$CROP_EXPORT_DIR"
    exit 1
fi

CW=$(sips -g pixelWidth "$CROP_FILE" | awk '/pixelWidth/{print $2}')
CH=$(sips -g pixelHeight "$CROP_FILE" | awk '/pixelHeight/{print $2}')
echo "  Exported crop dimensions: ${CW}x${CH}"
EXPECT_W=$(( SRC_W / 2 ))
if [ "$CW" -lt $(( EXPECT_W - 40 )) ] || [ "$CW" -gt $(( EXPECT_W + 40 )) ]; then
    echo "ERROR: cropped export width $CW not ≈ $EXPECT_W (½ of $SRC_W)."
    echo "       The #320 corner-crop bug yields ≈1024 (the preview-pixel width)."
    exit 1
fi
if [ "$CH" -lt $(( SRC_H - 40 )) ] || [ "$CH" -gt $(( SRC_H + 40 )) ]; then
    echo "ERROR: cropped export height $CH not ≈ $SRC_H (full height)."
    exit 1
fi
echo "  OK: cropped export ≈ ${EXPECT_W}x${SRC_H} — full-resolution crop, not a corner ROI"

echo "=== Byte-compare a sampled pixel — must be the left-half colour (red) ==="
if ! CROP_PX=$(read_tiff_rgb "$CROP_FILE" $(( CW / 2 )) $(( CH / 2 ))); then
    echo "ERROR: could not decode exported TIFF pixel (unexpected encoding)"
    exit 1
fi
read -r RPX GPX BPX <<< "$CROP_PX"
echo "  Centre pixel RGB = $RPX $GPX $BPX (expected ≈ 210 20 20)"
if ! px_near "$RPX" 210 || ! px_near "$GPX" 20 || ! px_near "$BPX" 20; then
    echo "ERROR: cropped export centre pixel ($RPX,$GPX,$BPX) is not the left-half red — wrong region."
    exit 1
fi
echo "  OK: cropped export samples the left-half colour"

echo "=== Uncropped export of the same asset must cover the full frame ==="
UNCROP_EXPORT=$("$CLI_BIN" export "$UNCROP_EXPORT_DIR" --format tiff --socket "$SOCKET")
echo "$UNCROP_EXPORT"
assert_json_field "uncrop export status" "$UNCROP_EXPORT" "status" "ok"
assert_json_field "uncrop export exportedCount" "$UNCROP_EXPORT" "data.exportedCount" "1"
UNCROP_FILE=$(find "$UNCROP_EXPORT_DIR" -name "*.tiff" | head -1)
UW=$(sips -g pixelWidth "$UNCROP_FILE" | awk '/pixelWidth/{print $2}')
UH=$(sips -g pixelHeight "$UNCROP_FILE" | awk '/pixelHeight/{print $2}')
echo "  Uncropped export dimensions: ${UW}x${UH}"
if [ "$UW" -ne "$SRC_W" ] || [ "$UH" -ne "$SRC_H" ]; then
    echo "ERROR: uncropped export ${UW}x${UH} != full ${SRC_W}x${SRC_H}"
    exit 1
fi
echo "  OK: uncropped export covers the full ${SRC_W}x${SRC_H} frame"

echo "=== Quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness export flow PASSED ==="
