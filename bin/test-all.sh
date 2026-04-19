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

echo "::group::bash tests (bin/tests/run.sh)"
if "$REPO_ROOT/bin/tests/run.sh"; then
    echo "PASS: bin/tests/run.sh"
else
    echo "FAIL: bin/tests/run.sh"
    FAILED=1
fi
echo "::endgroup::"

if [ "$FAILED" -ne 0 ]; then
    echo "One or more packages failed testing."
    exit 1
fi

echo "All packages passed."
