#!/bin/bash
#
# Run the swift-testing unit suite.
#
# On a machine with only the Command Line Tools (no full Xcode), `swift test`
# can't find swift-testing's framework/dylib on its own. This script locates the
# active developer dir and passes the right search + rpath flags. On a full Xcode
# install the extra flags are harmless.
#
set -euo pipefail

DEV="$(xcode-select -p 2>/dev/null || echo /Library/Developer/CommandLineTools)"
FW="$DEV/Library/Developer/Frameworks"
INTEROP="$DEV/Library/Developer/usr/lib"

if [[ -d "$FW/Testing.framework" ]]; then
    exec swift test \
        -Xswiftc -F -Xswiftc "$FW" \
        -Xlinker -F -Xlinker "$FW" \
        -Xlinker -rpath -Xlinker "$FW" \
        -Xlinker -rpath -Xlinker "$INTEROP" "$@"
else
    # Full Xcode toolchain resolves swift-testing without help.
    exec swift test "$@"
fi
