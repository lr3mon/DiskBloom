#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# Build only the CLI. The installed app and its signature remain untouched.
swift build -c release --product diskbloom-scan >&2
if (( $# == 0 )); then
    set -- --all-local --repeat 3 --json
fi
exec "$ROOT/.build/release/diskbloom-scan" "$@"
