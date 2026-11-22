#!/bin/zsh
set -euo pipefail
REPOSITORY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for filename in HealthExchange.swift DuplicatePolicy.swift ImportHistory.swift; do
    cmp "$REPOSITORY_ROOT/Shared/$filename" "$REPOSITORY_ROOT/Mac/Sources/BridgeCore/$filename"
done
print "Shared Swift definitions match."
