#!/bin/bash
# Runs the RemoteCore package tests.
#
# Why the -target flag: AndroidTVRemoteControl declares platforms: [.iOS(.v13)]
# and no macOS platform, so SwiftPM builds it against macOS 10.13 — where
# CryptoKit's SHA256 does not exist, and the dependency fails to compile.
# Forcing the macOS deployment target to 14.0 for the whole graph fixes it
# without forking or vendoring the library. (Cannot use .unsafeFlags in
# Package.swift: that would make RemoteCore ineligible as the app's dependency.)
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/../RemoteCore"
exec swift test -Xswiftc -target -Xswiftc "$(uname -m)-apple-macosx14.0" "$@"
