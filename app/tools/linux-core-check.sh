#!/bin/sh
# Builds and runs the portable YakuCore tests (scheduler, request budget,
# loopback proxy, rotating logs, startup limit) with a Linux Swift toolchain. The rest of
# the app needs AppKit, SwiftData and Darwin and is not compiled here; this
# is no substitute for `swift build` and `swift test` on a Mac.
#
#   app/tools/linux-core-check.sh [scratch-dir]
#
# Uses `swift` from PATH, or SWIFT_BIN=<toolchain>/usr/bin. Toolchain used:
# https://download.swift.org/swift-6.1.2-release/ubuntu2404/swift-6.1.2-RELEASE/swift-6.1.2-RELEASE-ubuntu24.04.tar.gz
# (on Ubuntu 24.04 it also needs libncurses6, libz3-4 and libpython3.12t64).
set -eu

repo=$(cd "$(dirname "$0")/../.." && pwd)
work=${1:-${TMPDIR:-/tmp}/yaku-linux-core-check}
if [ -n "${SWIFT_BIN:-}" ]; then PATH="$SWIFT_BIN:$PATH"; export PATH; fi

sources="PFML3 CompletionRequest RequestBudget EngineScheduling EngineProxy RotatingLogFile EngineStartupWait"
tests="EngineSchedulingTests RotatingLogFileTests EngineStartupWaitTests"

mkdir -p "$work/Sources/YakuCore" "$work/Tests/CheckTests"
rm -f "$work"/Sources/YakuCore/*.swift "$work"/Tests/CheckTests/*.swift
for name in $sources; do
    ln -s "$repo/app/Sources/YakuCore/$name.swift" "$work/Sources/YakuCore/$name.swift"
done
for name in $tests; do
    ln -s "$repo/app/Tests/YakuCoreTests/$name.swift" "$work/Tests/CheckTests/$name.swift"
done
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "LinuxCheck",
    targets: [
        .target(name: "YakuCore", path: "Sources/YakuCore"),
        .testTarget(name: "CheckTests", dependencies: ["YakuCore"], path: "Tests/CheckTests"),
    ]
)
SWIFT

cd "$work"
swift build --build-tests
swift test --skip-build
