#!/bin/bash
# Runs the unit tests.
#
# On a bare Command Line Tools install (no Xcode.app), Testing.framework and its
# interop dylib live outside every default search path — AND the flags must be
# passed on the CLI (not the manifest) so they also reach SwiftPM's synthesized
# test runner: that runner is gated on `#if canImport(Testing)`, so if it is
# compiled without the -F flag it silently becomes an empty entry point and
# `swift test` "passes" having run nothing.
#
# Note: the extra flags create a separate build configuration, so alternating
# ./test.sh with plain `swift build` triggers a full rebuild each way. On a
# full-Xcode machine (e.g. CI) no flags are needed and `swift test` is used
# directly.
set -e
cd "$(dirname "$0")"

FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib

# Whether the flags are needed depends on the *active* toolchain, not whether
# Xcode.app merely exists on disk: a machine can have Xcode installed yet still
# have `xcode-select` pointed at the Command Line Tools (which don't put Testing
# on the default search path). Key off the active developer dir instead.
DEVDIR=$(xcode-select -p 2>/dev/null)
if [[ "$DEVDIR" == *CommandLineTools* ]] && [ -d "$FW/Testing.framework" ]; then
  exec swift test \
    -Xswiftc -F"$FW" \
    -Xlinker -F"$FW" \
    -Xlinker -rpath -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$LIB" \
    "$@"
fi
exec swift test "$@"
