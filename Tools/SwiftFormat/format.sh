#!/bin/sh
#
# Formats the whole repository in place, the benchmark packages included, against the root .swiftformat; safe to
# run from anywhere:
#
#     Tools/SwiftFormat/format.sh
#
# It rewrites files rather than checking them, and that is the point: run before Tools/SwiftLint/lint.sh, it
# fixes everything the formatter can before the linter sees it. Do not add --lint or --dryrun — that would hand
# the race back to the linter.
#
# The binary is downloaded from the pinned GitHub release on first use and cached outside the repository, so a
# fresh clone still needs no setup and every machine runs the same version. It is NOT committed: git does not
# carry extended attributes, so Sourcetree re-stamped com.apple.quarantine onto the checked-out binary on every
# pull and Gatekeeper blocked it (`spctl -a`: rejected — the release binary is adhoc-signed, not notarized, so a
# quarantined copy can never pass). curl and unzip set no quarantine, which is what makes the cached copy
# runnable.
#
# To bump SwiftFormat, change VERSION and CHECKSUM together — nothing else. CHECKSUM is `shasum -a 256` of the
# release's swiftformat.zip.

set -eu

VERSION="0.64.4"
CHECKSUM="bb42fbfb0b9d5f1b8b83db3147087220ea414916fce8c5cf71abaea5ad5a3175"

# This script lives in Tools/SwiftFormat/, so the repository root is two levels up. Derived from $0 so that
# running it works from any directory.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Keyed by version and kept outside the checkout, so worktrees and fresh clones share one download and a version
# bump can never collide with the copy it replaces.
CACHE="${XDG_CACHE_HOME:-$HOME/Library/Caches}/swiftformat/$VERSION"
BINARY="$CACHE/swiftformat"

if [ ! -x "$BINARY" ]; then
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT INT TERM

    echo "note: downloading SwiftFormat $VERSION"
    curl -fsSL -o "$TMP/swiftformat.zip" \
        "https://github.com/nicklockwood/SwiftFormat/releases/download/$VERSION/swiftformat.zip"

    # Verified before it is ever unpacked: the binary is adhoc-signed, so this checksum is the only thing standing
    # between a tampered release asset and a formatter that rewrites every source file.
    echo "$CHECKSUM  $TMP/swiftformat.zip" | shasum -a 256 -c - >/dev/null

    unzip -qo "$TMP/swiftformat.zip" -d "$TMP"
    chmod +x "$TMP/swiftformat"
    mkdir -p "$CACHE"
    # Atomic within one filesystem, so a second run racing this one either sees no binary yet or sees the finished
    # copy — never a half-written one.
    mv -f "$TMP/swiftformat" "$BINARY"

    rm -rf "$TMP"
    trap - EXIT INT TERM
fi

exec "$BINARY" "$ROOT"
