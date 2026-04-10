#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILED=0

for pkg in "$REPO_ROOT"/Packages/*/; do
    if [ -f "$pkg/Package.swift" ]; then
        echo "::group::swift test $pkg"
        if (cd "$pkg" && swift test --parallel); then
            echo "PASS: $pkg"
        else
            echo "FAIL: $pkg"
            FAILED=1
        fi
        echo "::endgroup::"
    fi
done

if [ "$FAILED" -ne 0 ]; then
    echo "One or more packages failed testing."
    exit 1
fi

echo "All packages passed."
