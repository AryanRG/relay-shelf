# Relay Shelf

A lightweight macOS file shelf for collecting files, pasting paths, and previewing documents. Keep a report, screenshot, folder, or snippet together while moving between your editor, terminal, Finder, and other apps.

Built with **Swift + AppKit**, **system WebKit**, and **React + shadcn/ui**. Available under the **MIT license**.

[Download the macOS prerelease](https://github.com/AryanRG/relay-shelf/releases/tag/v1.0.1) · [Build from source](#build-from-source) · [Report an issue](https://github.com/AryanRG/relay-shelf/issues)

> **Early prerelease.** Requires Apple Silicon and macOS 14 or newer. The download is ad-hoc signed and unnotarized, so macOS may block it from opening. Cross-application drag delivery still needs manual verification.

## What you can do

| Workflow | Features |
| --- | --- |
| Capture | Paste file and folder paths, choose files, capture clipboard files, images, links, and text |
| Preview | Rendered and source Markdown, text, JSON, CSV, images, PDFs, and browsable folders |
| Organize | Named and pinned shelves, original-file references, independent saved copies, and undo for removals |
| Use elsewhere | Copy files to Finder, open originals, reveal locations, use Quick Look, export ZIPs and rendered PDFs |
| Collect outputs | Watch selected folders for newly completed files, with extension filtering |
| Stay within reach | Menu-bar access, global shortcuts, always-on-top mode, and configurable drag activation |
| Work from the terminal | Import files into a running instance and route them to a named shelf |

## Install

1. Download `Relay-Shelf-macOS.zip` from the release page.
2. Extract the archive and move **Relay Shelf.app** into **Applications**.
3. Open the app. Use its menu-bar icon or **⌘⇧Space** to bring the shelf back after closing the window.

The published build is for Apple Silicon. Runtime checks were performed on macOS 27.2. Developer ID signing and notarization are still pending. [Release downloads](https://github.com/AryanRG/relay-shelf/releases/tag/v1.0.1)

To verify the archives, download both ZIP assets and `SHA256SUMS.txt` into the same folder, then run the following command from that folder.

```sh
shasum -a 256 -c SHA256SUMS.txt
```

## Paste a path and see the file

1. Open **Paste location** and paste a file or folder location.
2. Select a resolved result to preview its contents before adding it.
3. Choose **Reference original** or **Keep a copy**, then add it to the current shelf.
4. Use **Open**, **Quick Look**, or **Copy files** when you need the item elsewhere. After copying files, paste in a Finder folder with **⌘V**.

The following examples use placeholder locations. Replace them with paths on your Mac.

| Input | Example |
| --- | --- |
| Home-relative path | `~/Documents/report.md` |
| Quoted path with spaces | `"~/Documents/Project notes.md"` |
| Absolute path | `/Users/you/Documents/report.pdf` |
| File URL | `file:///Users/you/Documents/report.pdf` |
| Markdown link | `[Report](~/Documents/report.md)` |
| Source location | `./src/App.tsx:42` or `./src/App.tsx#L42` |
| Multiple items | Paste one file or folder path per line |

For relative paths such as `./src/App.tsx`, set **Project root** in Preferences. Source-location suffixes are recognized while resolving the underlying file. Folder paths open a browsable preview.

## Everyday use

### Keep a reference or save a copy

**Reference original** points to the source on disk and reflects changes to that file. Moving or deleting the original can make the reference unavailable.

**Keep a copy** stores an independent snapshot in Relay Shelf’s local data folder. Use it when you want to retain the captured version.

Removing an item removes its shelf membership. Undo restores the last removed group or shelf and is invalidated by unrelated changes.

### Capture the clipboard

Press **⌘⌥⇧V** to capture clipboard files, an image, text, or a link. Captured text and images are saved locally. The paste dialog also has a **Text or link** tab.

### Collect files from a folder

Add a folder under **Preferences → Folder watches** and choose its destination shelf. The watcher observes that folder’s immediate children. Set **Watch file extensions** to filter the files collected.

### Choose how the shelf appears

Preferences offer pointer shake while dragging, dragging to a screen edge, activation when a supported file drag begins, and manual activation. You can also enable **Always on top**, **Open at login**, and light, dark, or system appearance.

After a drop, the floating shelf displays the captured item or item count and stays available for dragging out. Additional drops join the same floating shelf. Use **Open shelf** to view the full collection or the close button to dismiss the small window.

The floating shelf closes after a successful drag-out or 60 seconds of inactivity. Hovering, receiving a drop, and dragging out pause the idle timeout. A canceled drag keeps the shelf available. Captured items remain in the main shelf after the floating window closes.

End-to-end drag delivery between applications remains a manual verification item for this prerelease.

## Command line

From a source checkout, the launcher imports files into the running app or starts it as needed.

```sh
./scripts/relay-shelf ~/Documents/report.md
./scripts/relay-shelf --shelf "Project handoff" ~/Documents/report.md ~/Desktop/evidence.png
```

The launcher uses the installed application in `/Applications` when available, then the sibling build output. The native executable accepts `--add`, `--shelf NAME`, and `--show`.

## Local storage and permissions

Shelf state and captured files live in the following directory.

```text
~/Library/Application Support/RelayShelf
```

Back up this folder to preserve shelves and saved copies. Original-file references point to their existing locations. Clipboard capture runs when invoked, and watched folders are selected explicitly in Preferences.

macOS may request access to Documents, Desktop, or Downloads. If a preview is waiting for permission, use **Choose file…** to select the file or its containing folder through the native picker. Rebuilding an ad-hoc-signed app can trigger another permission request.

## Performance and preview limits

Swift/AppKit handles filesystem operations and native integration. The interface uses the operating system’s WebKit, and Node.js is a build-time dependency. Folder monitoring is event-driven.

Preview work is bounded to keep large files manageable.

| Preview | Limit |
| --- | --- |
| Text | Reads up to 256 KB |
| Rendered Markdown | Renders up to 120,000 characters |
| Images | Downsamples to a maximum dimension of 1,600 pixels |
| Folders | Lists up to 500 visible children |

Use **Open** or **Quick Look** to view the original document beyond these preview limits.

## Build from source

Install Apple Command Line Tools with a current Swift compiler and Node.js 22 or newer. The build script targets `arm64-apple-macos14.0`.

```sh
git clone https://github.com/AryanRG/relay-shelf.git
cd relay-shelf
npm ci
npm run package
open "../Relay Shelf.app"
```

The build writes `../Relay Shelf.app` with a local ad-hoc signature. Set `RELAY_APP_OUTPUT` to choose a different output location.

```sh
npm run typecheck
npm test
```

For isolated development, set `RELAY_SHELF_DATA_DIR` to a separate directory when launching the native executable.

### Source map

| Location | Responsibility |
| --- | --- |
| `native/App.swift` | App lifecycle, windows, menu bar, shortcuts, WebKit bridge, and single-instance delivery |
| `native/DragController.swift` | Native drag sources, floating target, and file-promise reception |
| `native/NativeDragOverlay.swift` | Floating shelf view and native drag interaction over shelf rows |
| `native/FloatingShelfLifecycle.swift` | Floating shelf retention, idle expiry, and drag outcomes |
| `native/ShelfStore.swift` | Persistent state, captures, copies, previews, and shelf actions |
| `native/PathResolver.swift` | Local filesystem path parsing |
| `native/DirectoryWatcher.swift` | Event-driven folder monitoring |
| `native/DocumentPDFExporter.swift` | Bounded rendered PDF generation |
| `src/` | React interface and shadcn/ui components |
| `tests/` | Native regression and integration tests |

## Verification status

- **Automated checks passed** — 427 path-resolution assertions, 63 directory-watcher assertions, and integration checks for storage, persistence, concurrent imports, cleanup, undo, preview limits, CLI routing, instance locking, PDF generation, and floating-shelf lifecycle behavior.
- **Live checks passed** — quoted home-relative path import, document previews, persistent shelves, native file selection, clipboard file delivery into Finder, ZIP export, and rendered PDF export.
- **Manual verification pending** — cross-application drag-and-drop delivery.
- **Distribution limits** — Apple Silicon build, runtime-tested on macOS 27.2, ad-hoc signing, and Developer ID notarization pending.

When reporting an issue, include your macOS version, app version, reproduction steps, and expected behavior. Use placeholder paths and sample files that are safe to share publicly. [Issue tracker](https://github.com/AryanRG/relay-shelf/issues)

## License

Relay Shelf uses the MIT license. Dependencies retain their respective licenses. The app bundle includes `Contents/Resources/ThirdPartyNotices.txt` and the Relay Shelf license. [MIT license](LICENSE)
