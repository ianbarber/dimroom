#!/usr/bin/env bash
set -euo pipefail

# Run swift test in every package that has a Package.swift.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

failed=0

for manifest in "$REPO_ROOT"/Packages/*/Package.swift; do
    pkg_dir="$(dirname "$manifest")"
    pkg_name="$(basename "$pkg_dir")"

    echo "==> Testing $pkg_name"
    if (cd "$pkg_dir" && swift test 2>&1); then
        echo "==> $pkg_name: OK"
    else
        echo "==> $pkg_name: FAILED"
        failed=1
        break
    fi
    echo
done

if [ "$failed" -ne 0 ]; then
    echo "FAIL: one or more packages failed."
    exit 1
fi

echo "All packages passed."
