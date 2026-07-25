#!/bin/bash
# run-tests.sh — compile-and-run regression suites against the real Sources.
#
# Not `swift test`: this repo builds under Command Line Tools, where SwiftPM
# cannot resolve XCTest ("unable to lookup item 'PlatformPath'"). Each suite is a
# standalone driver compiled directly against the source files it exercises, so it
# runs anywhere swiftc does and always tests the SHIPPING code, never a copy.
#
# Usage: tests/run-tests.sh          (from anywhere; exits non-zero on failure)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

fails=0

run_suite() {
    local name="$1"; shift
    echo "── $name"
    if ! swiftc "$@" -o "$BUILD/$name" 2>&1 | grep -v "warning: could not determine XCTest paths"; then
        :  # swiftc diagnostics already printed; check the binary below
    fi
    if [ ! -x "$BUILD/$name" ]; then
        echo "   COMPILE FAILED"
        fails=$((fails + 1))
        return
    fi
    if "$BUILD/$name"; then
        echo "   ok"
    else
        echo "   SUITE FAILED"
        fails=$((fails + 1))
    fi
    echo
}

run_suite date-parsing \
    "$REPO/Sources/EventKitCore.swift" \
    "$REPO/tests/date-parsing/main.swift"

if [ "$fails" -ne 0 ]; then
    echo "FAILED: $fails suite(s)"
    exit 1
fi
echo "All suites passed."
