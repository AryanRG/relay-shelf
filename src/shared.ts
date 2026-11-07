export type StorageMode = "reference" | "copy";
export type ItemKind = "file" | "folder" | "text" | "url";
export interface Shelf {
  id: string;
  name: string;
  pinned: boolean;
  createdAt: string;
}
export interface ShelfItem {
  id: string;
  shelfId: string;
  name: string;
  path: string;
  sourcePath?: string;
  kind: ItemKind;
  extension: string;
  size: number;
  modifiedAt: string;
  addedAt: string;
  storage: StorageMode;
  exists: boolean;
  line?: number;
  content?: string;
}
export interface WatchedFolder {
  id: string;
  path: string;
  shelfId: string;
  enabled: boolean;
}
export interface Destination {
  id: string;
  name: string;
  path: string;
}
export type FileOperation =
  | "resizeImage"
  | "convertImage"
  | "compressImage"
  | "stripMetadata"
  | "ocr"
  | "mergePDF"
  | "imagesToPDF";
export interface FileProcessingOptions {
  width?: number;
  height?: number;
  format?: "png" | "jpeg" | "heic";
  quality?: number;
}
export interface Settings {
  theme: "system" | "light" | "dark";
  activation: "shake" | "edge" | "drag" | "off";
  alwaysOnTop: boolean;
  defaultStorage: StorageMode;
  projectRoot: string;
  launchAtLogin: boolean;
  watchExtensions: string;
}
export interface ShelfState {
  version: 1;
  shelves: Shelf[];
  items: ShelfItem[];
  watchedFolders: WatchedFolder[];
  destinations: Destination[];
  settings: Settings;
  canUndo: boolean;
  helperAvailable: boolean;
  capturedIDs?: string[]; // Present on a screenshot action response; empty on cancellation.
}
export interface ResolvedPath {
  input: string;
  path: string;
  name: string;
  exists: boolean;
  kind: "file" | "folder";
  size: number;
  modifiedAt: string;
  extension: string;
  line?: number;
  error?: string;
}
export interface Preview {
  type:
    | "markdown"
    | "text"
    | "json"
    | "csv"
    | "image"
    | "pdf"
    | "folder"
    | "url"
    | "unsupported";
  path: string;
  name: string;
  text?: string;
  url?: string;
  truncated?: boolean;
  entries?: ResolvedPath[];
  error?: string;
}
export interface RelayAPI {
  invoke<T = ShelfState>(
    command: string,
    payload?: Record<string, unknown>,
  ): Promise<T>;
  onState(callback: (state: ShelfState) => void): () => void;
  onNotice(callback: (message: string) => void): () => void;
  onCapture(callback: () => void): () => void;
  filePath(file: File): string;
  startDrag(ids: string[]): void;
  prepareDrag(ids: string[]): void;
  setDragRegions(
    regions: {
      id: string;
      ids: string[];
      x: number;
      y: number;
      width: number;
      height: number;
    }[],
  ): void;
}
declare global {
  interface Window {
    relay?: RelayAPI;
  }
}

/* Native command contract
getState -> ShelfState
resolve {text, basePath?} -> ResolvedPath[]
preview {path} -> Preview (paths from resolve/items/folder entries)
add {paths:string[], shelfId, storage?, lines?:Record<string,number>} -> ShelfState
addText {text, shelfId, name?} -> ShelfState
captureClipboard {shelfId} -> ShelfState (files, existing paths, image, text/link)
chooseFiles {shelfId, storage?} -> ShelfState
chooseFolder -> string | null
grantAccess {path} -> boolean (native file selection for macOS protected locations)
createShelf {name} / renameShelf {id,name} / pinShelf {id,pinned} / deleteShelf {id} -> ShelfState
remove {ids} / undo / refresh / clearShelf {shelfId} -> ShelfState
open {path} / reveal {path} / quickLook {path} -> void
copyFiles {ids} / copyPaths {ids} / copyContents {ids} -> void
copyText {text,html?} -> void
snapshot {ids} -> ShelfState (replace selected references with managed copies)
exportZip {ids} -> {path?:string}
exportPDF {path} -> {path?:string}
updateSettings {settings:Partial<Settings>} -> ShelfState
addWatch {path,shelfId} / removeWatch {id} / toggleWatch {id,enabled} -> ShelfState
addDestination {path,name?} / removeDestination {id} -> ShelfState
copyToDestination {ids:string[],destinationId} -> {paths:string[]}
processFiles {ids:string[],shelfId,operation:FileOperation,options?:FileProcessingOptions} -> ShelfState
  resizeImage: width defaults to 1600, height optional (pixels)
  convertImage: format png/jpeg/heic; compressImage: quality 0.1..1, default 0.75
  stripMetadata: images; ocr: images/PDF to .txt
  mergePDF / imagesToPDF: ids specify the input order
captureScreenshot {shelfId} -> ShelfState (interactive selection; cancellation returns unchanged state)
listShortcuts -> string[]
runShortcut {ids:string[],shelfId,name} -> ShelfState (adds shortcut outputs)
showFloatingShelf {ids:string[]} / reopenFloatingShelf -> null
locate {id} -> ShelfState (native picker to relink missing file)
openExternal {url} -> void (http/https only)
Window state pushes follow every mutation. UI must show errors and empty states.
*/
