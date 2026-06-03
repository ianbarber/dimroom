#!/usr/bin/env bash
# Layer A guard for #425: bin/build-app-bundle.sh must re-sign the assembled
# .app with an explicit, stable ad-hoc identifier (com.ianbarber.dimroom).
#
# Why this matters: the macOS login Keychain's "Always Allow Dimroom" ACL keys
# off the requesting app's *designated requirement*, which is derived from the
# code-signing identifier — not off kSecAttrService. The Swift toolchain's
# inherited ad-hoc signature uses a content-hash-derived identifier that changes
# on every rebuild, so without an explicit identifier macOS treats each rebuild
# as a different app and re-prompts on every `make run`. An explicit identifier
# keeps the requirement stable so the "Always Allow" decision persists.
#
# This replaces the keychain-readback acceptance test the issue originally asked
# for: kSecAttrAccessible is inert on the macOS *login* (file-based) keychain
# and SecItemCopyMatching there never returns it, so that test could only "pass"
# by being gate-skipped. The load-bearing fix is the stable identifier, so we
# guard that instead — mapping directly to acceptance criterion #1.
#
# Two layers:
#  1. Static (runs everywhere, incl. the Ubuntu bash-tests CI job): the script
#     contains the explicit `codesign ... --identifier com.ianbarber.dimroom`
#     step. Trips if someone drops or renames the signing step.
#  2. Behavioural (macOS only, where `codesign` exists): run the same codesign
#     invocation against a throwaway bundle and assert `codesign -dvv` reports
#     Identifier=com.ianbarber.dimroom. Skipped where codesign is unavailable.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/bin/build-app-bundle.sh"
EXPECTED_ID="com.ianbarber.dimroom"

PASS=0
FAIL=0

ok() {
    printf 'PASS: %s\n' "$1"
    PASS=$((PASS + 1))
}

bad() {
    printf 'FAIL: %s\n  %s\n' "$1" "$2"
    FAIL=$((FAIL + 1))
}

# 1. Static assertion — the explicit signing step is present with the right id.
if grep -Eq "codesign.*--identifier[[:space:]]+$EXPECTED_ID" "$SCRIPT"; then
    ok "build-app-bundle.sh signs with explicit identifier $EXPECTED_ID"
else
    bad "build-app-bundle.sh signs with explicit identifier $EXPECTED_ID" \
        "missing 'codesign --identifier $EXPECTED_ID' step — the Keychain ACL keys off a stable identifier (#425)"
fi

# 2. Behavioural check — prove the invocation actually yields that identifier.
#    Only where codesign exists (macOS). A real Mach-O is required for codesign
#    to accept the bundle, so we copy a system binary as the bundle executable.
if command -v codesign >/dev/null 2>&1; then
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    BUNDLE="$TMP/Probe.app"
    mkdir -p "$BUNDLE/Contents/MacOS"
    cp /bin/echo "$BUNDLE/Contents/MacOS/Probe"
    cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.ianbarber.dimroom</string>
    <key>CFBundleName</key>
    <string>Probe</string>
    <key>CFBundleExecutable</key>
    <string>Probe</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
</dict>
</plist>
PLIST

    if codesign --force --sign - --identifier "$EXPECTED_ID" "$BUNDLE" >/dev/null 2>&1; then
        got_id="$(codesign -dvv "$BUNDLE" 2>&1 | sed -n 's/^Identifier=//p')"
        if [ "$got_id" = "$EXPECTED_ID" ]; then
            ok "codesign --identifier $EXPECTED_ID yields Identifier=$EXPECTED_ID"
        else
            bad "codesign --identifier $EXPECTED_ID yields Identifier=$EXPECTED_ID" \
                "codesign -dvv reported Identifier='$got_id'"
        fi
    else
        bad "codesign accepts the probe bundle" \
            "codesign --force --sign - failed on the throwaway bundle"
    fi
else
    printf 'SKIP: codesign unavailable — behavioural identifier check skipped\n'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
