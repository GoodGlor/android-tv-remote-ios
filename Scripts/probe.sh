#!/bin/bash
# Runs the rc-probe debug harness against a real Android TV.
#
#   ./Scripts/probe.sh discover
#   ./Scripts/probe.sh pair 192.168.0.103
#   ./Scripts/probe.sh key  192.168.0.103 down
#
# Why a wrapper: rc-probe needs the same macOS deployment-target flag as the
# test script (the dependency declares only iOS platforms, so CryptoKit's
# SHA256 is unavailable at SwiftPM's default macOS target). Passing those
# flags via a shell variable does NOT work in zsh — zsh does not word-split
# unquoted variables, so `swift run $F rc-probe …` is parsed as one argument
# and fails with "Unknown option". Hence a script rather than a snippet.
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/../RemoteCore"
exec swift run \
  -Xswiftc -target -Xswiftc "$(uname -m)-apple-macosx14.0" \
  rc-probe "$@"
