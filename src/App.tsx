import {
  lazy,
  Suspense,
  useCallback,
  useDeferredValue,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import {
  Archive,
  ArrowDownWideNarrow,
  ArrowUpRight,
  Check,
  ChevronDown,
  Clipboard,
  ClipboardPaste,
  Command,
  Copy,
  Ellipsis,
  FilePlus2,
  Folder,
  FolderOpen,
  FolderPlus,
  Inbox,
  Layers,
  Link2,
  ListFilter,
  Loader2,
  PanelLeft,
  PanelRight,
  Pin,
  Plus,
  Search,
  Settings2,
  Trash2,
  Undo2,
  WifiOff,
  X,
} from "lucide-react";
import { Toaster, toast } from "sonner";
import type { Shelf, ShelfItem } from "@/shared";
import { useBridge } from "@/lib/bridge";
import { bytes, cn, isEditing, safeUrl } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Checkbox } from "@/components/ui/checkbox";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { TooltipProvider } from "@/components/ui/tooltip";
import { Brand, EmptyState, IconButton } from "@/components/common";
import { ItemList } from "@/components/ItemList";
import { PreviewPanel } from "@/components/PreviewPanel";
const PasteDialog = lazy(() =>
  import("@/components/PasteDialog").then((m) => ({ default: m.PasteDialog })),
);
const SettingsDialog = lazy(() =>
  import("@/components/SettingsDialog").then((m) => ({
    default: m.SettingsDialog,
  })),
);
const CommandPalette = lazy(() =>
  import("@/components/CommandPalette").then((m) => ({
    default: m.CommandPalette,
  })),
);
type ShelfDialog =
  { mode: "create" } | { mode: "rename" | "delete" | "clear"; shelf: Shelf };
function remember(key: string, value: string) {
  try {
    localStorage.setItem(`relay:${key}`, value);
  } catch {
    /* WebView storage may be disabled. */
  }
}
function recalled(key: string, fallback: string) {
  try {
    return localStorage.getItem(`relay:${key}`) || fallback;
  } catch {
    return fallback;
  }
}
export default function App() {
  const { state, status, error, perform, reconnect, busy } = useBridge();
  const [active, setActive] = useState(() => recalled("shelf", ""));
  const [query, setQuery] = useState("");
  const search = useDeferredValue(query);
  const [filter, setFilter] = useState("all");
  const [sort, setSort] = useState(() => recalled("sort", "added"));
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [previewVisible, setPreviewVisible] = useState(
    () => recalled("preview", "true") !== "false",
  );
  const [sidebarVisible, setSidebarVisible] = useState(true);
  const [paste, setPaste] = useState<{ text: string } | null>(null);
  const [settings, setSettings] = useState(false);
  const [settingsTab, setSettingsTab] = useState<"general" | "watches">(
    "general",
  );
  const [palette, setPalette] = useState(false);
  const [shelfDialog, setShelfDialog] = useState<ShelfDialog | null>(null);
  const anchor = useRef<string | null>(null);
  const searchInput = useRef<HTMLInputElement>(null);
  const shelves = state?.shelves || [];
  const shelf = shelves.find((s) => s.id === active) || shelves[0];
  const shelfId = shelf?.id || "";
  const all = active === "all";
  const connected = status === "connected";
  const modal = !!paste || settings || palette || !!shelfDialog;
  useEffect(() => {
    if (
      state &&
      active !== "all" &&
      !state.shelves.some((s) => s.id === active)
    )
      setActive(state.shelves[0]?.id || "");
  }, [state?.shelves, active]);
  useEffect(() => {
    if (active) remember("shelf", active);
  }, [active]);
  useEffect(() => {
    remember("sort", sort);
  }, [sort]);
  useEffect(() => {
    remember("preview", String(previewVisible));
  }, [previewVisible]);
  useEffect(() => {
    const scheme = window.matchMedia("(prefers-color-scheme: dark)");
    const apply = () => {
      const dark =
        state?.settings.theme === "dark" ||
        (state?.settings.theme !== "light" && scheme.matches);
      document.documentElement.classList.toggle("dark", dark);
      document.documentElement.style.colorScheme = dark ? "dark" : "light";
    };
    apply();
    scheme.addEventListener("change", apply);
    return () => scheme.removeEventListener("change", apply);
  }, [state?.settings.theme]);
  const counts = useMemo(() => {
    const map = new Map<string, number>();
    for (const item of state?.items || [])
      map.set(item.shelfId, (map.get(item.shelfId) || 0) + 1);
    return map;
  }, [state?.items]);
  const shelfNames = useMemo(
    () => new Map(shelves.map((s) => [s.id, s.name])),
    [state?.shelves],
  );
  const items = useMemo(() => {
    const q = search.trim().toLowerCase();
    const result = (state?.items || []).filter(
      (item) =>
        (all || item.shelfId === shelfId) &&
        (filter === "all" || item.kind === filter) &&
        (!q ||
          `${item.name}\n${item.path}\n${item.content?.slice(0, 8000) || ""}`
            .toLowerCase()
            .includes(q)),
    );
    return result.sort(
      sort === "name"
        ? (a, b) => a.name.localeCompare(b.name, undefined, { numeric: true })
        : sort === "size"
          ? (a, b) => b.size - a.size
          : sort === "modified"
            ? (a, b) => b.modifiedAt.localeCompare(a.modifiedAt)
            : (a, b) => b.addedAt.localeCompare(a.addedAt),
    );
  }, [state?.items, all, shelfId, filter, search, sort]);
  useEffect(() => {
    const valid = new Set(items.map((i) => i.id));
    setSelected((old) => {
      const next = new Set([...old].filter((id) => valid.has(id)));
      return next.size === old.size ? old : next;
    });
  }, [items]);
  const selectedItems = useMemo(
    () => items.filter((i) => selected.has(i.id)),
    [items, selected],
  );
  const selectedIds = useMemo(
    () => selectedItems.map((i) => i.id),
    [selectedItems],
  );
  const item = selectedItems.length === 1 ? selectedItems[0] : null;
  const totalSize = useMemo(
    () => items.reduce((sum, item) => sum + item.size, 0),
    [items],
  );
  const chooseShelf = useCallback((id: string) => {
    setActive(id);
    setQuery("");
    setFilter("all");
    setSelected(new Set());
    anchor.current = null;
  }, []);
  const selectItem = useCallback(
    (id: string, options: { toggle?: boolean; range?: boolean }) => {
      setSelected((old) => {
        if (options.range && anchor.current) {
          const start = items.findIndex((i) => i.id === anchor.current);
          const end = items.findIndex((i) => i.id === id);
          if (start >= 0 && end >= 0)
            return new Set(
              items
                .slice(Math.min(start, end), Math.max(start, end) + 1)
                .map((i) => i.id),
            );
        }
        anchor.current = id;
        if (options.toggle) {
          const next = new Set(old);
          next.has(id) ? next.delete(id) : next.add(id);
          return next;
        }
        return new Set([id]);
      });
    },
    [items],
  );
  const remove = useCallback(
    async (ids: string[]) => {
      if (!ids.length) return;
      const result = await perform("remove", { ids });
      if (result)
        toast(
          `${ids.length} ${ids.length === 1 ? "item" : "items"} removed from shelf`,
          {
            description: "Your original files are kept.",
            action: {
              label: "Undo",
              onClick: () => {
                void perform("undo");
              },
            },
          },
        );
    },
    [perform],
  );
  const open = useCallback(
    (item: ShelfItem) => {
      if (!item.exists) {
        void perform("locate", { id: item.id });
        return;
      }
      if (item.kind === "url") {
        const url = safeUrl(item.content || item.path);
        if (url) void perform("openExternal", { url });
        else toast.error("This link is not a valid web address.");
      } else void perform("open", { path: item.path });
    },
    [perform],
  );
  const capture = useCallback(() => {
    if (shelfId) void perform("captureClipboard", { shelfId });
  }, [shelfId, perform]);
  const addFiles = useCallback(() => {
    if (shelfId)
      void perform("chooseFiles", {
        shelfId,
        storage: state?.settings.defaultStorage,
      });
  }, [perform, shelfId, state?.settings.defaultStorage]);
  const undo = useCallback(() => {
    void perform("undo");
  }, [perform]);
  const actions = useMemo(
    () => ({
      paste: () => setPaste({ text: "" }),
      capture,
      add: addFiles,
      settings: () => setSettings(true),
      create: () => setShelfDialog({ mode: "create" }),
      undo,
    }),
    [capture, addFiles, undo],
  );
  const findItem = useCallback((next: ShelfItem) => {
    setActive(next.shelfId);
    setQuery("");
    setFilter("all");
    setSelected(new Set([next.id]));
    setPreviewVisible(true);
  }, []);
  // Native menu / global shortcut capture uses the currently visible destination shelf.
  useEffect(() => {
    if (!connected || !window.relay) return;
    return window.relay.onCapture(capture);
  }, [connected, capture]);
  useEffect(() => {
    function keydown(e: KeyboardEvent) {
      const mod = e.metaKey || e.ctrlKey;
      if (mod && e.key.toLowerCase() === "k") {
        e.preventDefault();
        setPalette((v) => !v);
        return;
      }
      if (modal || isEditing(e.target)) return;
      if (mod && e.key.toLowerCase() === "f") {
        e.preventDefault();
        searchInput.current?.focus();
        return;
      }
      if (!connected) return;
      if (mod && e.key.toLowerCase() === "v") {
        e.preventDefault();
        if (e.shiftKey) setPaste({ text: "" });
        else if (!busy) capture();
      } else if (mod && e.key.toLowerCase() === "o") {
        e.preventDefault();
        if (!busy) addFiles();
      } else if (mod && e.key === ",") {
        e.preventDefault();
        setSettings(true);
      } else if (mod && e.shiftKey && e.key.toLowerCase() === "n") {
        e.preventDefault();
        setShelfDialog({ mode: "create" });
      } else if (mod && e.key.toLowerCase() === "a") {
        e.preventDefault();
        setSelected(new Set(items.map((i) => i.id)));
      } else if (mod && e.key.toLowerCase() === "z" && state?.canUndo) {
        e.preventDefault();
        undo();
      } else if (mod && e.key.toLowerCase() === "c" && selectedIds.length) {
        e.preventDefault();
        void perform(
          e.shiftKey ? "copyPaths" : "copyFiles",
          { ids: selectedIds },
          e.shiftKey ? "Paths copied" : "Files copied",
        );
      } else if (
        (e.key === "Delete" || e.key === "Backspace") &&
        selectedIds.length
      ) {
        e.preventDefault();
        void remove(selectedIds);
      } else if (e.key === "Enter" && item) {
        e.preventDefault();
        open(item);
      } else if (e.code === "Space" && item) {
        e.preventDefault();
        if (item.exists && item.path)
          void perform("quickLook", { path: item.path });
        else setPreviewVisible(true);
      } else if (e.key === "Escape") {
        setSelected(new Set());
        setQuery("");
      }
    }
    window.addEventListener("keydown", keydown);
    return () => window.removeEventListener("keydown", keydown);
  }, [
    modal,
    connected,
    busy,
    capture,
    addFiles,
    items,
    selectedIds,
    item,
    perform,
    remove,
    open,
    undo,
    state?.canUndo,
  ]);
  async function exportZip() {
    const result = await perform<{ path?: string }>("exportZip", {
      ids: selectedIds.length ? selectedIds : items.map((i) => i.id),
    });
    if (result?.path) {
      toast.success("ZIP exported", {
        description: result.path,
        action: {
          label: "Reveal",
          onClick: () => {
            void perform("reveal", { path: result.path });
          },
        },
      });
    }
  }
  async function dropped(event: React.DragEvent) {
    event.preventDefault();
    if (!connected || !shelfId || busy) return;
    // Files dropped on the native overlay are handled by AppKit. Browser fallback uses the injected path helper.
    const paths = Array.from(event.dataTransfer.files)
      .map((file) => window.relay?.filePath(file))
      .filter((path): path is string => !!path);
    if (paths.length) {
      await perform("add", {
        paths,
        shelfId,
        storage: state?.settings.defaultStorage,
      });
      return;
    }
    const text =
      event.dataTransfer.getData("text/plain") ||
      event.dataTransfer
        .getData("text/uri-list")
        .split("\n")
        .filter((l) => !l.startsWith("#"))
        .join("\n");
    if (text.trim()) {
      if (/^(https?:\/\/)/i.test(text.trim()) && !text.trim().includes("\n"))
        await perform("addText", { text, shelfId });
      else setPaste({ text });
    }
  }
  function shelfRow(s: Shelf) {
    return (
      <div
        className={cn("shelf-nav-wrap", active === s.id && "active")}
        key={s.id}
      >
        <button className="shelf-nav" onClick={() => chooseShelf(s.id)}>
          <span className="shelf-nav-icon">
            {s.pinned ? (
              <Pin size={15} />
            ) : s.id === shelves[0]?.id ? (
              <Inbox size={17} />
            ) : (
              <Folder size={16} />
            )}
          </span>
          <span>{s.name}</span>
          <span className="nav-count">{counts.get(s.id) || 0}</span>
        </button>
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <button className="shelf-more" aria-label={`Manage ${s.name}`}>
              <Ellipsis size={15} />
            </button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="start">
            <DropdownMenuLabel>{s.name}</DropdownMenuLabel>
            <DropdownMenuItem
              onSelect={() =>
                void perform("pinShelf", { id: s.id, pinned: !s.pinned })
              }
            >
              <Pin />
              {s.pinned ? "Unpin shelf" : "Pin shelf"}
            </DropdownMenuItem>
            <DropdownMenuItem
              onSelect={() => setShelfDialog({ mode: "rename", shelf: s })}
            >
              <Folder />
              Rename shelf…
            </DropdownMenuItem>
            <DropdownMenuSeparator />
            <DropdownMenuItem
              variant="destructive"
              onSelect={() => setShelfDialog({ mode: "delete", shelf: s })}
            >
              <Trash2 />
              Delete shelf…
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>
    );
  }
  return (
    <TooltipProvider delayDuration={450}>
      <div
        className={cn("app-shell", !sidebarVisible && "sidebar-hidden")}
        onDragOver={(e) => {
          if (
            e.dataTransfer.types.some((type) =>
              ["Files", "text/plain", "text/uri-list"].includes(type),
            )
          )
            e.preventDefault();
        }}
        onDrop={(e) => void dropped(e)}
      >
        <header className="window-titlebar">
          <span className="window-title">
            <Brand small />
            Relay Shelf
          </span>
          <div className="window-toolbar">
            <IconButton
              label={
                state?.settings.alwaysOnTop
                  ? "Turn off always on top"
                  : "Keep window on top"
              }
              disabled={!connected}
              onClick={() =>
                void perform("updateSettings", {
                  settings: { alwaysOnTop: !state?.settings.alwaysOnTop },
                })
              }
              className={cn(state?.settings.alwaysOnTop && "is-active")}
            >
              <Pin size={14} />
            </IconButton>
          </div>
        </header>
        {sidebarVisible && (
          <aside className="sidebar">
            <div className="sidebar-brand">
              <Brand />
              <div>
                <strong>Relay Shelf</strong>
              </div>
            </div>
            <button
              className="sidebar-command"
              onClick={() => setPalette(true)}
            >
              <Search size={14} />
              <span>Find anything</span>
              <kbd>⌘K</kbd>
            </button>
            <nav aria-label="Shelves">
              <button
                className={cn("all-nav", all && "active")}
                onClick={() => chooseShelf("all")}
              >
                <Layers size={17} />
                <span>All items</span>
                <span className="nav-count">{state?.items.length || 0}</span>
              </button>
              {shelves.some((s) => s.pinned) && (
                <>
                  <div className="nav-section-label">PINNED</div>
                  {shelves.filter((s) => s.pinned).map(shelfRow)}
                </>
              )}
              <div className="nav-section-label">
                <span>SHELVES</span>
                <IconButton
                  label="New shelf"
                  size="icon-xs"
                  disabled={!connected}
                  onClick={() => setShelfDialog({ mode: "create" })}
                >
                  <Plus size={14} />
                </IconButton>
              </div>
              {shelves.filter((s) => !s.pinned).map(shelfRow)}
              <button
                className="new-shelf"
                onClick={() => setShelfDialog({ mode: "create" })}
                disabled={!connected}
              >
                <Plus size={15} />
                New shelf
              </button>
            </nav>
            <div className="sidebar-bottom">
              <div className="watch-summary">
                <span className="watch-summary-icon">
                  <FolderOpen size={16} />
                </span>
                <div>
                  <strong>Folder watches</strong>
                  <small>
                    {state?.watchedFolders.filter((w) => w.enabled).length || 0}{" "}
                    active
                  </small>
                </div>
                <IconButton
                  label="Manage folder watches"
                  disabled={!connected}
                  onClick={() => {
                    setSettingsTab("watches");
                    setSettings(true);
                  }}
                >
                  <ChevronDown size={14} />
                </IconButton>
              </div>
              <button
                className="settings-nav"
                onClick={() => setSettings(true)}
                disabled={!connected}
              >
                <Settings2 size={16} />
                <span>Preferences</span>
                <kbd>⌘,</kbd>
              </button>
            </div>
          </aside>
        )}
        <main className="main">
          <div className="main-heading">
            <div className="main-heading-title">
              <IconButton
                label={sidebarVisible ? "Hide sidebar" : "Show sidebar"}
                onClick={() => setSidebarVisible((v) => !v)}
              >
                <PanelLeft size={17} />
              </IconButton>
              <span className="breadcrumb">
                Your workspace<span>/</span>
                <strong>{all ? "All items" : shelf?.name || "Welcome"}</strong>
              </span>
              <div className="heading-spacer" />
              <IconButton
                label={previewVisible ? "Hide preview" : "Show preview"}
                onClick={() => setPreviewVisible((v) => !v)}
                className={cn(previewVisible && "is-active")}
              >
                <PanelRight size={17} />
              </IconButton>
            </div>
            <div className="shelf-heading">
              <div>
                <div className="shelf-title-line">
                  <h1>{all ? "All items" : shelf?.name || "Shelves"}</h1>
                  {shelf?.pinned && !all && (
                    <Pin size={14} className="heading-pin" />
                  )}
                </div>
              </div>
              <div className="heading-actions">
                <Button
                  size="sm"
                  onClick={addFiles}
                  disabled={!connected || !shelfId || !!busy}
                >
                  <Plus size={15} />
                  Add files
                </Button>
                <DropdownMenu>
                  <DropdownMenuTrigger asChild>
                    <Button
                      size="icon-sm"
                      variant="outline"
                      aria-label="More ways to add"
                      disabled={!connected || !shelfId || !!busy}
                    >
                      <ChevronDown size={15} />
                    </Button>
                  </DropdownMenuTrigger>
                  <DropdownMenuContent align="end">
                    <DropdownMenuLabel>
                      Add to {shelf?.name || "shelf"}
                    </DropdownMenuLabel>
                    <DropdownMenuItem onSelect={() => setPaste({ text: "" })}>
                      <ClipboardPaste />
                      Paste paths or text…
                    </DropdownMenuItem>
                    <DropdownMenuItem onSelect={capture}>
                      <Clipboard />
                      Capture clipboard<span className="menu-shortcut">⌘V</span>
                    </DropdownMenuItem>
                    <DropdownMenuSeparator />
                    <DropdownMenuItem
                      onSelect={() => setShelfDialog({ mode: "create" })}
                    >
                      <FolderPlus />
                      New shelf…
                    </DropdownMenuItem>
                  </DropdownMenuContent>
                </DropdownMenu>
              </div>
            </div>
          </div>
          {!connected && (
            <div className="connection-banner" role="status">
              {status === "connecting" ? (
                <Loader2 size={15} className="spin" />
              ) : (
                <WifiOff size={15} />
              )}
              <div>
                <strong>
                  {status === "connecting"
                    ? "Connecting to Relay Shelf…"
                    : "Waiting for the macOS app"}
                </strong>
                <span>
                  {error ||
                    "Your shelves will appear as soon as the native bridge connects."}
                </span>
              </div>
              {status === "disconnected" && (
                <Button variant="outline" size="sm" onClick={reconnect}>
                  Reconnect
                </Button>
              )}
            </div>
          )}
          <div className="workspace">
            <section className="shelf-content">
              <div className="search-toolbar">
                <div className="search-field">
                  <Search size={16} />
                  <Input
                    ref={searchInput}
                    aria-label="Search current shelf"
                    value={query}
                    onChange={(e) => setQuery(e.target.value)}
                    placeholder={
                      all ? "Search all items…" : "Search this shelf…"
                    }
                  />
                  {query ? (
                    <button
                      aria-label="Clear search"
                      onClick={() => setQuery("")}
                    >
                      <X size={13} />
                    </button>
                  ) : (
                    <kbd>⌘F</kbd>
                  )}
                </div>
                <DropdownMenu>
                  <DropdownMenuTrigger asChild>
                    <Button
                      size="icon-sm"
                      variant="ghost"
                      aria-label="Filter item types"
                      className={cn(filter !== "all" && "is-active")}
                    >
                      <ListFilter size={16} />
                    </Button>
                  </DropdownMenuTrigger>
                  <DropdownMenuContent align="end">
                    <DropdownMenuLabel>Item type</DropdownMenuLabel>
                    {[
                      ["all", "All types"],
                      ["file", "Files"],
                      ["folder", "Folders"],
                      ["text", "Text notes"],
                      ["url", "Links"],
                    ].map(([value, label]) => (
                      <DropdownMenuItem
                        key={value}
                        onSelect={() => setFilter(value)}
                      >
                        <span className="menu-check">
                          {filter === value && <Check size={14} />}
                        </span>
                        {label}
                      </DropdownMenuItem>
                    ))}
                  </DropdownMenuContent>
                </DropdownMenu>
                <DropdownMenu>
                  <DropdownMenuTrigger asChild>
                    <Button
                      size="icon-sm"
                      variant="ghost"
                      aria-label="Sort items"
                    >
                      <ArrowDownWideNarrow size={16} />
                    </Button>
                  </DropdownMenuTrigger>
                  <DropdownMenuContent align="end">
                    <DropdownMenuLabel>Sort by</DropdownMenuLabel>
                    {[
                      ["added", "Recently added"],
                      ["modified", "Recently modified"],
                      ["name", "Name A–Z"],
                      ["size", "Largest first"],
                    ].map(([value, label]) => (
                      <DropdownMenuItem
                        key={value}
                        onSelect={() => setSort(value)}
                      >
                        <span className="menu-check">
                          {sort === value && <Check size={14} />}
                        </span>
                        {label}
                      </DropdownMenuItem>
                    ))}
                  </DropdownMenuContent>
                </DropdownMenu>
              </div>
              <div className="list-toolbar">
                <span className="select-all">
                  <Checkbox
                    aria-label="Select all visible items"
                    checked={
                      items.length > 0 && selected.size === items.length
                        ? true
                        : selected.size
                          ? "indeterminate"
                          : false
                    }
                    disabled={!items.length}
                    onCheckedChange={(value) =>
                      setSelected(
                        value ? new Set(items.map((i) => i.id)) : new Set(),
                      )
                    }
                  />
                  <span>
                    {selected.size
                      ? `${selected.size} selected`
                      : filter !== "all"
                        ? `${filter === "url" ? "Links" : filter === "text" ? "Text notes" : filter === "folder" ? "Folders" : "Files"} · ${items.length}`
                        : `${items.length} ${items.length === 1 ? "item" : "items"}`}
                  </span>
                </span>
                <div className="inline-actions">
                  {busy ? (
                    <span className="import-status" role="status">
                      <Loader2 size={13} className="spin" />
                      {busy}
                    </span>
                  ) : selected.size > 0 ? (
                    <>
                      <IconButton
                        label="Copy selected files"
                        onClick={() =>
                          void perform(
                            "copyFiles",
                            { ids: selectedIds },
                            "Files copied",
                          )
                        }
                      >
                        <Copy size={14} />
                      </IconButton>
                      <IconButton
                        label="Remove selected items"
                        onClick={() => void remove(selectedIds)}
                      >
                        <Trash2 size={14} />
                      </IconButton>
                    </>
                  ) : (
                    <span className="sort-label">
                      {sort === "name"
                        ? "Name A–Z"
                        : sort === "size"
                          ? "Largest first"
                          : sort === "modified"
                            ? "Modified"
                            : "Newest first"}
                    </span>
                  )}
                  <DropdownMenu>
                    <DropdownMenuTrigger asChild>
                      <Button
                        variant="ghost"
                        size="icon-xs"
                        aria-label="Shelf actions"
                        disabled={!connected}
                      >
                        <Ellipsis size={16} />
                      </Button>
                    </DropdownMenuTrigger>
                    <DropdownMenuContent align="end">
                      <DropdownMenuLabel>
                        {selected.size
                          ? `${selected.size} selected`
                          : "Shelf actions"}
                      </DropdownMenuLabel>
                      <DropdownMenuItem
                        onSelect={() => void exportZip()}
                        disabled={!items.length}
                      >
                        <Archive />
                        Export {selected.size ? "selection" : "shelf"} as ZIP…
                      </DropdownMenuItem>
                      <DropdownMenuItem
                        onSelect={() =>
                          void perform(
                            "snapshot",
                            { ids: selectedIds },
                            "Snapshot saved",
                          )
                        }
                        disabled={!selectedIds.length || !!busy}
                      >
                        <Copy />
                        Snapshot selected items
                      </DropdownMenuItem>
                      <DropdownMenuItem
                        onSelect={() =>
                          void perform(
                            "copyPaths",
                            { ids: selectedIds },
                            "Paths copied",
                          )
                        }
                        disabled={!selectedIds.length}
                      >
                        <Link2 />
                        Copy paths
                      </DropdownMenuItem>
                      <DropdownMenuItem
                        onSelect={() =>
                          void perform(
                            "copyContents",
                            { ids: selectedIds },
                            "Contents copied",
                          )
                        }
                        disabled={!selectedIds.length}
                      >
                        <Clipboard />
                        Copy contents
                      </DropdownMenuItem>
                      <DropdownMenuItem
                        onSelect={undo}
                        disabled={!state?.canUndo}
                      >
                        <Undo2 />
                        Undo last removal
                      </DropdownMenuItem>
                      <DropdownMenuSeparator />
                      <DropdownMenuItem
                        onSelect={() => void perform("refresh")}
                      >
                        <FolderOpen />
                        Refresh file status
                      </DropdownMenuItem>
                      {!all && shelf && (
                        <>
                          <DropdownMenuItem
                            onSelect={() =>
                              setShelfDialog({ mode: "rename", shelf })
                            }
                          >
                            <Folder />
                            Rename shelf…
                          </DropdownMenuItem>
                          <DropdownMenuItem
                            variant="destructive"
                            onSelect={() =>
                              setShelfDialog({ mode: "clear", shelf })
                            }
                            disabled={!items.length}
                          >
                            <Trash2 />
                            Clear shelf…
                          </DropdownMenuItem>
                        </>
                      )}
                    </DropdownMenuContent>
                  </DropdownMenu>
                </div>
              </div>
              {items.length > 0 ? (
                <ItemList
                  items={items}
                  selected={selected}
                  onSelect={selectItem}
                  onOpen={open}
                  onRemove={remove}
                  shelfNames={shelfNames}
                  allShelves={all}
                />
              ) : !connected ? (
                <EmptyState
                  icon={Inbox}
                  title="Native app required"
                  description="Open the Relay Shelf macOS app to access your shelves."
                />
              ) : !shelfId ? (
                <EmptyState
                  icon={Layers}
                  title="No shelves"
                  description="Create your first shelf to collect files, folders, notes, and links."
                >
                  <Button
                    size="sm"
                    onClick={() => setShelfDialog({ mode: "create" })}
                  >
                    <Plus size={14} />
                    Create a shelf
                  </Button>
                </EmptyState>
              ) : query || filter !== "all" ? (
                <EmptyState
                  icon={Search}
                  title="No matching items"
                  description="Try another search or show all item types."
                >
                  <Button
                    size="sm"
                    variant="outline"
                    onClick={() => {
                      setQuery("");
                      setFilter("all");
                    }}
                  >
                    Clear filters
                  </Button>
                </EmptyState>
              ) : (
                <EmptyState
                  icon={Inbox}
                  title="This shelf is empty"
                  description="Drop files here, paste a path, or capture something from your clipboard."
                >
                  <Button size="sm" onClick={addFiles} disabled={!!busy}>
                    <FilePlus2 size={15} />
                    Add files
                  </Button>
                  <Button
                    size="sm"
                    variant="outline"
                    onClick={() => setPaste({ text: "" })}
                    disabled={!!busy}
                  >
                    Paste paths
                  </Button>
                  <span className="empty-shortcut">
                    <kbd>⌘V</kbd> captures your clipboard
                  </span>
                </EmptyState>
              )}
              <div className="shelf-bottom">
                <span>
                  <span className={cn("status-dot", !connected && "offline")} />
                  {busy ||
                    (connected
                      ? `${bytes(totalSize)} on this shelf`
                      : "Local workspace")}
                </span>
                <span>
                  Drag items into any app
                  <ArrowUpRight size={12} />
                </span>
              </div>
            </section>
            {previewVisible &&
              (selectedItems.length > 1 ? (
                <aside className="preview-panel">
                  <div className="preview-header">
                    <span className="panel-label">SELECTION</span>
                    <IconButton
                      label="Close preview"
                      onClick={() => setPreviewVisible(false)}
                    >
                      <X size={15} />
                    </IconButton>
                  </div>
                  <EmptyState
                    icon={Layers}
                    title={`${selectedItems.length} items, together`}
                    description={`${bytes(selectedItems.reduce((sum, i) => sum + i.size, 0))} selected across ${new Set(selectedItems.map((i) => i.kind)).size} item types.`}
                  >
                    <Button
                      size="sm"
                      onClick={() =>
                        void perform(
                          "copyFiles",
                          { ids: selectedIds },
                          "Files copied",
                        )
                      }
                    >
                      <Copy size={14} />
                      Copy files
                    </Button>
                    <Button
                      size="sm"
                      variant="outline"
                      onClick={() => void exportZip()}
                    >
                      <Archive size={14} />
                      Export ZIP
                    </Button>
                  </EmptyState>
                  <div className="selection-summary">
                    {selectedItems.slice(0, 8).map((i) => (
                      <div key={i.id}>
                        <span>{i.name}</span>
                        <small>{bytes(i.size)}</small>
                      </div>
                    ))}
                    {selectedItems.length > 8 && (
                      <p>+{selectedItems.length - 8} more items</p>
                    )}
                  </div>
                </aside>
              ) : (
                <PreviewPanel
                  item={item}
                  shelfId={shelfId}
                  onClose={() => setPreviewVisible(false)}
                />
              ))}
          </div>
        </main>
        <footer className="app-footer">
          <span>
            <Command size={12} />
            <kbd>⌘K</kbd>Search & commands
          </span>
          <span>
            <kbd>⌘⇧Space</kbd> Show shelf
            <span className="footer-divider" />
            <kbd>⌘⌥⇧V</kbd>Capture clipboard
          </span>
          <button onClick={() => setPalette(true)}>
            Keyboard shortcuts
            <ArrowUpRight size={11} />
          </button>
        </footer>
        <Suspense
          fallback={
            <div className="dialog-loading" role="status">
              <Loader2 size={18} className="spin" />
              Opening…
            </div>
          }
        >
          {paste && shelfId && (
            <PasteDialog
              shelfId={shelfId}
              initial={paste.text}
              onClose={() => setPaste(null)}
            />
          )}{" "}
          {settings && state && (
            <SettingsDialog
              shelfId={shelfId}
              initialTab={settingsTab}
              onClose={() => {
                setSettings(false);
                setSettingsTab("general");
              }}
            />
          )}{" "}
          {palette && (
            <CommandPalette
              onClose={() => setPalette(false)}
              onSelectItem={findItem}
              onShelf={chooseShelf}
              actions={actions}
            />
          )}
        </Suspense>
        {shelfDialog && (
          <ShelfEditor
            dialog={shelfDialog}
            onClose={() => setShelfDialog(null)}
            onCreated={(id) => chooseShelf(id)}
          />
        )}
        <Toaster
          position="bottom-center"
          richColors
          closeButton
          theme={state?.settings.theme || "system"}
          toastOptions={{ className: "relay-toast" }}
        />
      </div>
    </TooltipProvider>
  );
}
function ShelfEditor({
  dialog,
  onClose,
  onCreated,
}: {
  dialog: ShelfDialog;
  onClose: () => void;
  onCreated: (id: string) => void;
}) {
  const { state, perform } = useBridge();
  const [name, setName] = useState(
    dialog.mode === "create" ? "" : dialog.shelf.name,
  );
  const [saving, setSaving] = useState(false);
  const destructive = dialog.mode === "delete" || dialog.mode === "clear";
  async function submit(e: React.FormEvent) {
    e.preventDefault();
    if (saving) return;
    setSaving(true);
    const command =
      dialog.mode === "create"
        ? "createShelf"
        : dialog.mode === "rename"
          ? "renameShelf"
          : dialog.mode === "clear"
            ? "clearShelf"
            : "deleteShelf";
    const result = await perform(
      command,
      dialog.mode === "create"
        ? { name: name.trim() }
        : dialog.mode === "clear"
          ? { shelfId: dialog.shelf.id }
          : { id: dialog.shelf.id, name: name.trim() },
    );
    setSaving(false);
    if (result) {
      if (dialog.mode === "create") {
        const previous = new Set(state?.shelves.map((s) => s.id));
        const added = result.shelves.find((s) => !previous.has(s.id));
        if (added) onCreated(added.id);
      }
      if (destructive)
        toast.success(
          dialog.mode === "clear" ? "Shelf cleared" : "Shelf deleted",
        );
      onClose();
    }
  }
  return (
    <Dialog open onOpenChange={(open) => !open && !saving && onClose()}>
      <DialogContent className="shelf-dialog">
        <form onSubmit={(e) => void submit(e)}>
          <DialogHeader>
            <DialogTitle>
              {dialog.mode === "create"
                ? "New shelf"
                : dialog.mode === "rename"
                  ? "Rename shelf"
                  : dialog.mode === "clear"
                    ? `Clear “${dialog.shelf.name}”?`
                    : `Delete “${dialog.shelf.name}”?`}
            </DialogTitle>
            <DialogDescription className={destructive ? undefined : "sr-only"}>
              {destructive
                ? "Items will be removed from this shelf. Your original files stay where they are."
                : "Enter a shelf name."}
            </DialogDescription>
          </DialogHeader>
          {!destructive && (
            <div className="shelf-name-field">
              <label className="field-label" htmlFor="shelf-name">
                Shelf name
              </label>
              <Input
                id="shelf-name"
                autoFocus
                value={name}
                onChange={(e) => setName(e.target.value)}
                maxLength={80}
                placeholder="e.g. Website refresh"
                required
              />
            </div>
          )}
          <div className="dialog-footer">
            <Button
              type="button"
              variant="ghost"
              onClick={onClose}
              disabled={saving}
            >
              Cancel
            </Button>
            <Button
              type="submit"
              variant={destructive ? "destructive" : "default"}
              disabled={saving || (!destructive && !name.trim())}
            >
              {saving && <Loader2 size={14} className="spin" />}
              {dialog.mode === "create"
                ? "Create shelf"
                : dialog.mode === "rename"
                  ? "Save name"
                  : dialog.mode === "clear"
                    ? "Clear shelf"
                    : "Delete shelf"}
            </Button>
          </div>
        </form>
      </DialogContent>
    </Dialog>
  );
}
