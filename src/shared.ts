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
  settings: Settings;
  canUndo: boolean;
  helperAvailable: boolean;
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
locate {id} -> ShelfState (native picker to relink missing file)
openExternal {url} -> void (http/https only)
Window state pushes follow every mutation. UI must show errors and empty states.
*/
