#!/usr/bin/env bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")" && pwd)"
TASK_OUTPUT="$TASK_ROOT/build/performance"
mkdir -p "$TASK_OUTPUT" "$TASK_OUTPUT/module-cache"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
    -module-cache-path "$TASK_OUTPUT/module-cache" \
    "$TASK_ROOT/Sources/RunnerMenu/Models/RunnerConfig.swift" \
    "$TASK_ROOT/Sources/RunnerMenu/Models/GitHubModels.swift" \
    "$TASK_ROOT/Sources/RunnerMenu/Services/GitHubClient.swift" \
    "$TASK_ROOT/Sources/RunnerMenu/Services/Shell.swift" \
    "$TASK_ROOT/Sources/RunnerMenu/Services/ProcessMonitor.swift" \
    "$TASK_ROOT/Sources/RunnerMenu/Services/LogTailer.swift" \
    "$TASK_ROOT/scripts/benchmark-performance.swift" \
    -o "$TASK_OUTPUT/benchmark-performance"
"$TASK_OUTPUT/benchmark-performance" "$@"
