# Relay Shelf

A personal macOS shelf for files, folders, pasted locations, images, links, and text. The app uses Swift/AppKit for filesystem operations, system integration, and drag-and-drop. Its bundled React interface uses shadcn/ui components inside macOS WebKit.

## Download

The initial release is a prerelease for Apple Silicon Macs running macOS 14 or newer. Cross-application drag delivery still needs manual verification.

Download `Relay-Shelf-macOS.zip`, extract it, and move **Relay Shelf.app** into Applications. The download is locally ad-hoc signed and has no Developer ID notarization, so macOS may block it from opening. Building from source is also supported. [GitHub releases](https://github.com/AryanRG/relay-shelf/releases)

Release assets include a `SHA256SUMS.txt` file. To check downloaded archives, place them beside that file and run `shasum -a 256 -c SHA256SUMS.txt`.

## Use

Open **Relay Shelf.app**. Its menu-bar icon keeps the app available after closing the main window.

- **⌘⇧Space** opens the shelf.
- **⌘⌥⇧V** captures the clipboard into the app.
- **Paste location** accepts quoted paths, `~/` paths, file URLs, Markdown links, multiple lines, and line references.
- Select an item to preview it. Markdown has rendered and source views. Folders can be browsed inside the preview panel.
- Native drag-out is implemented for selected items. Cross-application delivery is awaiting manual verification. **Copy files** and Finder paste passed a live check.
- Shake the pointer while dragging to open the floating native target. Settings also offer screen-edge activation and activation whenever a supported drag begins.
- Add watched folders in Settings to collect newly completed outputs. A watcher observes the selected folder's immediate children.
- Use named shelves to organize files. Selected files can be copied, retained as separate snapshots, or exported together as a ZIP.

**Reference original** follows the source file. **Keep a copy** creates an independent app-managed copy. Removing an entry removes its shelf membership. Undo restores the last removed group or shelf. Captured text and images are stored locally.

Text previews read up to 256 KB, image previews are downsampled to a maximum dimension of 1,600 pixels, and folder previews include up to 500 visible children. The interface labels shortened previews. Quick Look and Open provide access to the original document.

macOS may request access to protected locations such as Documents. If a read is waiting on permission, the preview offers **Choose file…** to select that file or its containing folder through the native picker. Rebuilding an ad-hoc-signed app can cause macOS to request access again.

## Command line

The included script launches the app and forwards imports to the running instance.

```sh
./scripts/relay-shelf ~/Documents/report.md
./scripts/relay-shelf --shelf "Project handoff" ~/Documents/report.md ~/Desktop/evidence.png
```

The executable also accepts `--add`, `--shelf NAME`, and `--show`.

## Build

Requires macOS, Apple Command Line Tools with a current Swift compiler, and Node.js 22 or newer. The supplied build targets Apple Silicon and macOS 14 or newer.

```sh
npm ci
npm run package
```

The application is written to `../Relay Shelf.app` and receives a local ad-hoc signature. The production app uses the operating system's WebKit and runs independently of Node.js.

```sh
npm test
npm run typecheck
```

Native tests cover path parsing, storage, persistence, snapshots, undo, folder monitoring, missing files, preview limits, CLI argument ordering, and the single-writer instance lock.

## Local data

State and captured files are stored under `~/Library/Application Support/RelayShelf`. Back up this folder to preserve shelves and saved copies. Referenced originals remain at the locations shown in each item's details.

For isolated development and tests, launch the executable with `RELAY_SHELF_DATA_DIR` set to a separate directory. Folder watching and login startup are configured explicitly in Settings.

## Source layout

- `native/App.swift` contains the app lifecycle, menu bar, window, shortcuts, WebKit bridge, and single-instance delivery.
- `native/DragController.swift` implements native drag sources, floating targets, and file-promise reception.
- `native/ShelfStore.swift` handles storage and application actions.
- `native/PathResolver.swift` parses filesystem references.
- `native/DirectoryWatcher.swift` monitors folder changes without an idle polling loop.
- `src/` contains the React and shadcn/ui interface.

Third-party license notices are bundled in the application's Resources directory.

## Verification status

Path parsing passed 427 assertions and directory monitoring passed 63 assertions. Storage, concurrent imports, recovery, CLI routing, and bounded PDF generation passed integration tests. Live checks covered a quoted home-relative Markdown path, document preview, persisted shelves, native file selection, copying a file into Finder, and rendered PDF export. Manual confirmation of cross-application drag delivery remains pending.

## License

Relay Shelf is distributed under the MIT license. Included dependencies retain their respective licenses. Third-party notices ship inside the app bundle. [MIT license](LICENSE)
