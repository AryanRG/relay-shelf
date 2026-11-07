import {
  useDeferredValue,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from "react";
import {
  ArrowUpRight,
  Clipboard,
  ClipboardPaste,
  Command,
  FilePlus2,
  FolderOpen,
  Plus,
  Search,
  Settings2,
  Undo2,
} from "lucide-react";
import type { ShelfItem } from "@/shared";
import { useBridge } from "@/lib/bridge";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogTitle,
} from "@/components/ui/dialog";
import { ItemIcon } from "./common";
import { cn } from "@/lib/utils";
interface Entry {
  id: string;
  label: string;
  detail?: string;
  icon: ReactNode;
  shortcut?: string;
  action: () => void;
}
export function CommandPalette({
  onClose,
  onSelectItem,
  onShelf,
  actions,
}: {
  onClose: () => void;
  onSelectItem: (item: ShelfItem) => void;
  onShelf: (id: string) => void;
  actions: {
    paste: () => void;
    capture: () => void;
    add: () => void;
    settings: () => void;
    create: () => void;
    undo: () => void;
  };
}) {
  const { state } = useBridge();
  const [query, setQuery] = useState("");
  const deferred = useDeferredValue(query);
  const [index, setIndex] = useState(0);
  const results = useMemo(() => {
    const q = deferred.toLowerCase().trim();
    const commands: Entry[] = [
      {
        id: "capture",
        label: "Capture clipboard",
        detail: "Files, paths, text, and links",
        icon: <Clipboard size={17} />,
        shortcut: "⌘V",
        action: actions.capture,
      },
      {
        id: "paste",
        label: "Paste file paths or text…",
        icon: <ClipboardPaste size={17} />,
        action: actions.paste,
      },
      {
        id: "add",
        label: "Add files and folders…",
        icon: <FilePlus2 size={17} />,
        shortcut: "⌘O",
        action: actions.add,
      },
      {
        id: "create",
        label: "Create a new shelf…",
        icon: <Plus size={17} />,
        shortcut: "⇧⌘N",
        action: actions.create,
      },
      {
        id: "settings",
        label: "Open preferences",
        icon: <Settings2 size={17} />,
        shortcut: "⌘,",
        action: actions.settings,
      },
      ...(state?.canUndo
        ? [
            {
              id: "undo",
              label: "Undo last removal",
              icon: <Undo2 size={17} />,
              shortcut: "⌘Z",
              action: actions.undo,
            },
          ]
        : []),
    ];
    const shelves: Entry[] = (state?.shelves || [])
      .filter((s) => !q || s.name.toLowerCase().includes(q))
      .slice(0, 6)
      .map((s) => ({
        id: `shelf:${s.id}`,
        label: s.name,
        detail: "Go to shelf",
        icon: <FolderOpen size={17} />,
        action: () => onShelf(s.id),
      }));
    const items: Entry[] = [];
    if (q)
      for (const item of state?.items || []) {
        if (
          `${item.name} ${item.path} ${item.content?.slice(0, 1000) || ""}`
            .toLowerCase()
            .includes(q)
        ) {
          items.push({
            id: item.id,
            label: item.name,
            detail: item.path || "Captured text",
            icon: <ItemIcon kind={item.kind} extension={item.extension} />,
            action: () => onSelectItem(item),
          });
          if (items.length >= 24) break;
        }
      }
    return [
      ...commands.filter(
        (c) =>
          !!state &&
          (state.shelves.length > 0 ||
            ["create", "settings", "undo"].includes(c.id)) &&
          (!q || c.label.toLowerCase().includes(q)),
      ),
      ...shelves,
      ...items,
    ];
  }, [
    deferred,
    state?.shelves,
    state?.items,
    state?.canUndo,
    actions,
    onShelf,
    onSelectItem,
  ]);
  useEffect(() => {
    setIndex(0);
  }, [deferred]);
  useEffect(() => {
    document
      .getElementById(`command-${index}`)
      ?.scrollIntoView({ block: "nearest" });
  }, [index]);
  const activate = (entry: Entry) => {
    onClose();
    entry.action();
  };
  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="command-dialog" showCloseButton={false}>
        <DialogTitle className="sr-only">Search Relay Shelf</DialogTitle>
        <DialogDescription className="sr-only">
          Find items, switch shelves, or run a command. Use arrow keys to
          navigate and Return to select.
        </DialogDescription>
        <div className="command-input">
          <Search size={19} />
          <input
            autoFocus
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Find anything, or run a command…"
            role="combobox"
            aria-expanded
            aria-controls="command-results"
            aria-autocomplete="list"
            aria-activedescendant={
              results[index] ? `command-${index}` : undefined
            }
            onKeyDown={(e) => {
              if (e.key === "ArrowDown" || e.key === "ArrowUp") {
                e.preventDefault();
                setIndex((i) =>
                  results.length
                    ? (i + (e.key === "ArrowDown" ? 1 : -1) + results.length) %
                      results.length
                    : 0,
                );
              } else if (e.key === "Enter" && results[index]) {
                e.preventDefault();
                activate(results[index]);
              }
            }}
          />
          <kbd>esc</kbd>
        </div>
        <div className="command-results" role="listbox" id="command-results">
          <div className="command-group-label">
            {query ? `${results.length} results` : "QUICK ACTIONS & SHELVES"}
          </div>
          {results.map((entry, i) => (
            <button
              id={`command-${i}`}
              role="option"
              aria-selected={i === index}
              tabIndex={-1}
              className={cn("command-row", i === index && "active")}
              key={entry.id}
              onMouseMove={() => setIndex(i)}
              onClick={() => activate(entry)}
            >
              {entry.icon}
              <span>
                <strong>{entry.label}</strong>
                {entry.detail && <small>{entry.detail}</small>}
              </span>
              {entry.shortcut ? (
                <kbd>{entry.shortcut}</kbd>
              ) : (
                <ArrowUpRight size={13} />
              )}
            </button>
          ))}
          {!results.length && (
            <div className="command-empty">
              {state
                ? "No matching items or commands."
                : "Open the Relay Shelf macOS app to use search and commands."}
            </div>
          )}
        </div>
        <div className="command-footer">
          <span>
            <kbd>↑</kbd>
            <kbd>↓</kbd> to navigate
          </span>
          <span>
            <kbd>↵</kbd> to select
          </span>
          <Command size={13} />
        </div>
      </DialogContent>
    </Dialog>
  );
}
