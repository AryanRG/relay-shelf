#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/relay-shelf-tests.XXXXXX")"
trap 'rm -rf "$TEST_BUILD"' EXIT
swiftc -swift-version 5 native/PathResolver.swift tests/PathResolverTests.swift -o "$TEST_BUILD/path-tests"
"$TEST_BUILD/path-tests"
swiftc -swift-version 5 native/PathResolver.swift native/ShelfStore.swift native/DirectoryWatcher.swift native/DocumentPDFExporter.swift native/DestinationCopier.swift native/FileActions.swift native/SystemActions.swift tests/StoreTests.swift \
  -o "$TEST_BUILD/store-tests" -framework AppKit -framework WebKit -framework PDFKit -framework ServiceManagement -framework Vision
"$TEST_BUILD/store-tests"
swiftc -swift-version 5 native/DirectoryWatcher.swift tests/DirectoryWatcherTests.swift -o "$TEST_BUILD/watcher-tests"
"$TEST_BUILD/watcher-tests"
swiftc -swift-version 5 native/PathResolver.swift native/ShelfStore.swift native/DirectoryWatcher.swift native/DocumentPDFExporter.swift native/DestinationCopier.swift native/FileActions.swift native/SystemActions.swift tests/StoreRaceTests.swift \
  -o "$TEST_BUILD/store-race-tests" -framework AppKit -framework WebKit -framework PDFKit -framework ServiceManagement -framework Vision
"$TEST_BUILD/store-race-tests"
swiftc -swift-version 5 native/PathResolver.swift native/ShelfStore.swift native/DirectoryWatcher.swift native/DocumentPDFExporter.swift native/DestinationCopier.swift native/FileActions.swift native/SystemActions.swift tests/ExportTests.swift \
  -o "$TEST_BUILD/export-tests" -framework AppKit -framework WebKit -framework PDFKit -framework ServiceManagement -framework Vision
"$TEST_BUILD/export-tests"
swiftc -swift-version 5 -D RELAY_TESTING native/*.swift tests/ShellTests.swift \
  -o "$TEST_BUILD/shell-tests" -framework AppKit -framework WebKit -framework PDFKit -framework Carbon -framework ServiceManagement -framework Vision
"$TEST_BUILD/shell-tests"
swiftc -swift-version 5 -D RELAY_TESTING native/*.swift tests/DragControllerTests.swift \
  -o "$TEST_BUILD/drag-tests" -framework AppKit -framework WebKit -framework PDFKit -framework Carbon -framework ServiceManagement -framework Vision
"$TEST_BUILD/drag-tests"
swiftc -swift-version 5 -D RELAY_TESTING native/*.swift tests/ActionStoreTests.swift \
  -o "$TEST_BUILD/action-store-tests" -framework AppKit -framework WebKit -framework PDFKit -framework Carbon -framework ServiceManagement -framework Vision
"$TEST_BUILD/action-store-tests"
swiftc -swift-version 5 -D RELAY_TESTING native/*.swift tests/FileActionsTests.swift \
  -o "$TEST_BUILD/file-action-tests" -framework AppKit -framework WebKit -framework PDFKit -framework Carbon -framework ServiceManagement -framework Vision
"$TEST_BUILD/file-action-tests"
swiftc -swift-version 5 -D RELAY_TESTING native/*.swift tests/SystemActionsTests.swift \
  -o "$TEST_BUILD/system-action-tests" -framework AppKit -framework WebKit -framework PDFKit -framework Carbon -framework ServiceManagement -framework Vision
"$TEST_BUILD/system-action-tests"
swiftc -swift-version 5 -D RELAY_TESTING native/*.swift tests/MarkdownViewerTests.swift \
  -o "$TEST_BUILD/markdown-viewer-tests" -framework AppKit -framework WebKit -framework PDFKit -framework Carbon -framework ServiceManagement -framework Vision
"$TEST_BUILD/markdown-viewer-tests"
