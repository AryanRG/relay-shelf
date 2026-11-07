#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/relay-shelf-tests.XXXXXX")"
trap 'rm -rf "$TEST_BUILD"' EXIT
swiftc -swift-version 5 native/PathResolver.swift tests/PathResolverTests.swift -o "$TEST_BUILD/path-tests"
"$TEST_BUILD/path-tests"
swiftc -swift-version 5 native/PathResolver.swift native/ShelfStore.swift native/DirectoryWatcher.swift native/DocumentPDFExporter.swift tests/StoreTests.swift \
  -o "$TEST_BUILD/store-tests" -framework AppKit -framework WebKit -framework PDFKit -framework ServiceManagement
"$TEST_BUILD/store-tests"
swiftc -swift-version 5 native/DirectoryWatcher.swift tests/DirectoryWatcherTests.swift -o "$TEST_BUILD/watcher-tests"
"$TEST_BUILD/watcher-tests"
swiftc -swift-version 5 native/PathResolver.swift native/ShelfStore.swift native/DirectoryWatcher.swift native/DocumentPDFExporter.swift tests/StoreRaceTests.swift \
  -o "$TEST_BUILD/store-race-tests" -framework AppKit -framework WebKit -framework PDFKit -framework ServiceManagement
"$TEST_BUILD/store-race-tests"
swiftc -swift-version 5 native/PathResolver.swift native/ShelfStore.swift native/DirectoryWatcher.swift native/DocumentPDFExporter.swift tests/ExportTests.swift \
  -o "$TEST_BUILD/export-tests" -framework AppKit -framework WebKit -framework PDFKit -framework ServiceManagement
"$TEST_BUILD/export-tests"
swiftc -swift-version 5 -D RELAY_TESTING native/*.swift tests/ShellTests.swift \
  -o "$TEST_BUILD/shell-tests" -framework AppKit -framework WebKit -framework PDFKit -framework Carbon -framework ServiceManagement
"$TEST_BUILD/shell-tests"
