#!/usr/bin/env bash
# bin/lib/originals-isolation.sh — pure path classifier for the harness
# originals-dir isolation guard (#386, Layer C for #367).
#
# SOURCE this file (do not execute it). It holds the single pure function
# that both the CI-enrolled `--default-launch` guard
# (bin/harness-originals-isolation-check.sh) and its Layer-A unit test
# (bin/tests/test-originals-isolation.sh) rely on: deciding whether a
# *resolved* originals directory — the path the app prints as
# `originals dir = …` at launch — landed in the per-flow temp sandbox
# (#367's app-level default) rather than in the user's real Application
# Support originals cache.
#
# Pure string logic only: no `stat`, no filesystem access, no macOS-only
# calls, so it runs unchanged in the Ubuntu `bash-tests` CI job. The
# macOS-only manifest snapshot stays inline in the guard script, which only
# runs in the macOS `harness-smoke` job.

# The namespace path component the app nests every harness originals sandbox
# under — see resolveOriginalsDirectory in App/Sources/DimroomApp.swift:
# "<temp>/dimroom-harness-originals/<digest>/". Keying on this component,
# rather than on a specific temp root, keeps the classifier robust to
# FileManager.temporaryDirectory being /var/folders/…/T, $TMPDIR, or /tmp
# (same shape the Layer-A HarnessOriginalsDirectoryTests pin).
ORIGINALS_ISOLATION_NAMESPACE="dimroom-harness-originals"

# originals_path_is_isolated <resolved> <real_app_support>
#
# Returns 0 (isolated — good) iff <resolved>:
#   * is non-empty, AND
#   * contains the "/dimroom-harness-originals/" namespace component, AND
#   * is not the real App Support originals dir nor a descendant of it.
# Returns non-zero otherwise (empty/garbage input, or an App Support leak).
# Pure: reads only its arguments, writes nothing, mutates nothing.
originals_path_is_isolated() {
    local resolved="${1:-}" real_app_support="${2:-}"

    # An empty / missing resolved path is never isolated.
    [ -n "$resolved" ] || return 1

    # Must sit inside the shared harness sandbox namespace. The bracketing
    # slashes ensure we match a whole path component
    # (…/dimroom-harness-originals/<digest>) — not a sibling directory that
    # merely starts with the name (…/dimroom-harness-originals-leak/…).
    case "$resolved" in
        */"$ORIGINALS_ISOLATION_NAMESPACE"/*) ;;
        *) return 1 ;;
    esac

    # Must not be the real App Support originals dir or anything under it.
    # Only meaningful when a real path was supplied (defence in depth: the
    # namespace match above already excludes it in practice).
    if [ -n "$real_app_support" ]; then
        case "$resolved" in
            "$real_app_support" | "$real_app_support"/*) return 1 ;;
        esac
    fi

    return 0
}
