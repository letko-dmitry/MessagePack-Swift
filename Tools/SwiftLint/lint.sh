#!/bin/sh
#
# Lints the package against the root .swiftlint.yml. Run it after Tools/SwiftFormat/format.sh, so anything the
# formatter can fix never reaches the linter; safe to run from anywhere:
#
#     Tools/SwiftLint/lint.sh
#
# Arguments are passed on to `swiftlint lint` — `--strict` fails on warnings too.
#
# The binary is downloaded from the pinned GitHub release on first use and cached outside the repository, the same
# way Tools/SwiftFormat/format.sh does it and for the same reasons: a fresh clone needs no setup, every machine runs
# the same version, and no binary is ever checked out of git (and quarantined).
#
# To bump SwiftLint, change VERSION and CHECKSUM together — nothing else. CHECKSUM is `shasum -a 256` of the
# release's portable_swiftlint.zip.

set -eu

VERSION="0.65.1"
CHECKSUM="c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0"

# This script lives in Tools/SwiftLint/, so the repository root is two levels up.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Not `swiftlint/$VERSION`: on a case-insensitive volume that is SwiftLint's own result cache, ~/Library/Caches/SwiftLint.
CACHE="${XDG_CACHE_HOME:-$HOME/Library/Caches}/swiftlint-binary/$VERSION"
BINARY="$CACHE/swiftlint"

if [ ! -x "$BINARY" ]; then
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT INT TERM

    echo "note: downloading SwiftLint $VERSION"
    curl -fsSL -o "$TMP/swiftlint.zip" \
        "https://github.com/realm/SwiftLint/releases/download/$VERSION/portable_swiftlint.zip"

    # Verified before it is ever unpacked: the checksum is all that stands between a tampered release asset and a
    # binary this script runs.
    echo "$CHECKSUM  $TMP/swiftlint.zip" | shasum -a 256 -c - >/dev/null

    unzip -qo "$TMP/swiftlint.zip" -d "$TMP"
    chmod +x "$TMP/swiftlint"
    mkdir -p "$CACHE"
    # Atomic within one filesystem, so a second run racing this one either sees no binary yet or sees the finished
    # copy — never a half-written one.
    mv -f "$TMP/swiftlint" "$BINARY"

    rm -rf "$TMP"
    trap - EXIT INT TERM
fi

# SwiftLint reads .swiftlint.yml, and resolves its `included` paths, from the working directory.
cd "$ROOT"
exec "$BINARY" lint --quiet "$@"
