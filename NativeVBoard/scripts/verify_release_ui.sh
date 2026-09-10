#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 /absolute/path/to/VBoardApp.app/VBoardApp" >&2
    exit 2
fi

binary=$1
if [ ! -x "$binary" ]; then
    echo "release executable not found: $binary" >&2
    exit 2
fi

forbidden='Developer Diagnostics|Continue as Test User|Developer Testing|Test accounts are unavailable|Tool: |Input: |State: |Selected: |Camera: |FPS:|Paths:|Candidates:|/api/auth/debug'
matches=$(strings "$binary" | grep -E "$forbidden" || true)
if [ -n "$matches" ]; then
    echo "Release executable contains developer-only interface text:" >&2
    echo "$matches" >&2
    exit 1
fi

echo "Release UI check passed: no developer-only interface text found."
