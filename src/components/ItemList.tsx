import {
  memo,
  useEffect,
  useMemo,
  useRef,
  useState,
  type MouseEvent,
  type KeyboardEvent,
} from "react";
import {
  Copy,
  Ellipsis,
  ExternalLink,
  FileQuestion,
  FolderOpen,
  Link2,
  Maximize2,
  PackageCheck,
  Trash2,
} from "lucide-react";
import type { ShelfItem } from "@/shared";
import { bytes, cn, date } from "@/lib/utils";
import { useBridge } from "@/lib/bridge";
import { Checkbox } from "@/components/ui/checkbox";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Button } from "@/components/ui/button";
import { ItemIcon } from "./common";
const ROW_HEIGHT = 72;
interface RowProps {
  item: ShelfItem;
  selected: boolean;
  onSelect: (
    id: string,
    options: { toggle?: boolean; range?: boolean },
  ) => void;
  onOpen: (item: ShelfItem) => void;
  onRemove: (ids: string[]) => void;
  selectedIds: string[];
  shelfName?: string;
}
const ItemRow = memo(function ItemRow({
  item,
  selected,
  onSelect,
  onOpen,
  onRemove,
  selectedIds,
  shelfName,
}: RowProps) {
  const { perform } = useBridge();
  const ids = selected ? selectedIds : [item.id];
  const select = (event: MouseEvent) =>
    onSelect(item.id, {
      toggle: event.metaKey || event.ctrlKey,
      range: event.shiftKey,
    });
  return (
    <div
      className={cn(
        "item-row",
        selected && "selected",
        !item.exists && "missing",
      )}
      role="option"
      id={`item-${item.id}`}
      data-native-id={item.exists ? item.id : undefined}
      aria-selected={selected}
      draggable={false}
      onClick={select}
      onDoubleClick={() => onOpen(item)}
      onPointerDown={(event) => {
        if (event.button !== 0 || !item.exists) return;
        if (
          (event.target as HTMLElement).closest(
            'button, input, [role="checkbox"]',
          )
        )
          return;
        window.relay?.prepareDrag(ids);
      }}
    >
      <span
        className="row-checkbox"
        onClick={(e) => e.stopPropagation()}
        onDoubleClick={(e) => e.stopPropagation()}
      >
        <Checkbox
          aria-label={`Select ${item.name}`}
          checked={selected}
          onCheckedChange={() => onSelect(item.id, { toggle: true })}
          tabIndex={-1}
        />
      </span>
      <ItemIcon kind={item.kind} extension={item.extension} />
      <div className="item-info">
        <div className="item-name">
          <span title={item.name}>{item.name}</span>
          {item.line && <span className="line-badge">:{item.line}</span>}
          {!item.exists && <FileQuestion size={13} className="missing-mark" />}
        </div>
        <div className="item-meta">
          <span>
            {!item.exists
              ? "Missing file"
              : item.kind === "url"
                ? "Link"
                : item.kind === "text"
                  ? "Text"
                  : item.kind === "folder"
                    ? "Folder"
                    : item.extension.replace(/^\./, "").toUpperCase() || "File"}
          </span>
          {item.kind !== "folder" && (
            <>
              <i /> <span>{bytes(item.size)}</span>
            </>
          )}
          {shelfName && (
            <>
              <i />
              <span className="meta-shelf">{shelfName}</span>
            </>
          )}
          <i />
          <span>{date(item.addedAt)}</span>
        </div>
      </div>
      <span
        className={cn(
          "storage-indicator",
          item.storage === "copy" && "managed",
        )}
        title={
          item.storage === "copy" ? "Managed copy" : "Reference to original"
        }
      >
        {item.storage === "copy" ? (
          <PackageCheck size={13} />
        ) : (
          <Link2 size={13} />
        )}
      </span>
      <div
        className="row-menu"
        onClick={(e) => e.stopPropagation()}
        onDoubleClick={(e) => e.stopPropagation()}
      >
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button
              variant="ghost"
              size="icon-xs"
              aria-label={`Actions for ${item.name}`}
            >
              <Ellipsis size={16} />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end" className="item-context-menu">
            <DropdownMenuLabel>
              {ids.length > 1 ? `${ids.length} selected items` : "Item actions"}
            </DropdownMenuLabel>
            <DropdownMenuItem
              onSelect={() => onOpen(item)}
              disabled={!item.exists}
            >
              <ExternalLink />
              Open<span className="menu-shortcut">↵</span>
            </DropdownMenuItem>
            {item.kind !== "text" && item.kind !== "url" && (
              <>
                <DropdownMenuItem
                  onSelect={() => void perform("reveal", { path: item.path })}
                  disabled={!item.exists}
                >
                  <FolderOpen />
                  Reveal in Finder
                </DropdownMenuItem>
                <DropdownMenuItem
                  onSelect={() =>
                    void perform("quickLook", { path: item.path })
                  }
                  disabled={!item.exists}
                >
                  <Maximize2 />
                  Quick Look<span className="menu-shortcut">space</span>
                </DropdownMenuItem>
              </>
            )}
            <DropdownMenuSeparator />
            <DropdownMenuItem
              onSelect={() =>
                void perform("copyFiles", { ids }, "Files copied")
              }
              disabled={!item.exists}
            >
              <Copy />
              Copy files
            </DropdownMenuItem>
            <DropdownMenuItem
              onSelect={() =>
                void perform("copyPaths", { ids }, "Paths copied")
              }
            >
              <Link2 />
              Copy paths
            </DropdownMenuItem>
            <DropdownMenuItem
              onSelect={() =>
                void perform("copyContents", { ids }, "Contents copied")
              }
            >
              <Copy />
              Copy contents
            </DropdownMenuItem>
            {item.storage === "reference" &&
              item.kind !== "text" &&
              item.kind !== "url" && (
                <DropdownMenuItem
                  onSelect={() =>
                    void perform("snapshot", { ids }, "Snapshot saved")
                  }
                  disabled={!item.exists}
                >
                  <PackageCheck />
                  Keep a snapshot
                </DropdownMenuItem>
              )}
            {!item.exists && (
              <DropdownMenuItem
                onSelect={() => void perform("locate", { id: item.id })}
              >
                <FileQuestion />
                Locate missing file
              </DropdownMenuItem>
            )}
            <DropdownMenuSeparator />
            <DropdownMenuItem
              variant="destructive"
              onSelect={() => onRemove(ids)}
            >
              <Trash2 />
              Remove from shelf
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>
    </div>
  );
});
export function ItemList({
  items,
  selected,
  onSelect,
  onOpen,
  onRemove,
  shelfNames,
  allShelves,
}: {
  items: ShelfItem[];
  selected: Set<string>;
  onSelect: RowProps["onSelect"];
  onOpen: RowProps["onOpen"];
  onRemove: RowProps["onRemove"];
  shelfNames: Map<string, string>;
  allShelves: boolean;
}) {
  const viewport = useRef<HTMLDivElement>(null);
  const [scrollTop, setScrollTop] = useState(0);
  const [height, setHeight] = useState(500);
  useEffect(() => {
    const element = viewport.current!;
    const observer = new ResizeObserver((entries) =>
      setHeight(entries[0].contentRect.height),
    );
    observer.observe(element);
    return () => observer.disconnect();
  }, []);
  useEffect(() => {
    if (viewport.current) viewport.current.scrollTop = 0;
    setScrollTop(0);
  }, [items]);
  const start = Math.max(0, Math.floor(scrollTop / ROW_HEIGHT) - 5);
  const end = Math.min(
    items.length,
    Math.ceil((scrollTop + height) / ROW_HEIGHT) + 5,
  );
  const selectedIds = useMemo(() => Array.from(selected), [selected]);
  useEffect(() => {
    const element = viewport.current;
    if (!element || !window.relay) return;
    let frame = 0;
    const report = () => {
      frame = 0;
      if (document.querySelector('[role="dialog"], [role="menu"]')) {
        window.relay?.setDragRegions([]);
        return;
      }
      const visible = element.getBoundingClientRect();
      const regions = Array.from(
        element.querySelectorAll<HTMLElement>("[data-native-id]"),
      ).flatMap((row) => {
        const rect = row.getBoundingClientRect();
        const icon = row.querySelector(".file-icon")?.getBoundingClientRect();
        const id = row.dataset.nativeId;
        if (!icon || !id) return [];
        const top = Math.max(rect.top, visible.top);
        const bottom = Math.min(rect.bottom, visible.bottom);
        if (bottom <= top) return [];
        return [
          {
            id,
            ids: selected.has(id) ? selectedIds : [id],
            x: icon.left,
            y: top,
            width: Math.max(0, rect.right - icon.left - 38),
            height: bottom - top,
          },
        ];
      });
      window.relay?.setDragRegions(regions);
    };
    const schedule = () => {
      if (!frame) frame = requestAnimationFrame(report);
    };
    const observer = new MutationObserver(schedule);
    observer.observe(document.body, { childList: true, subtree: true });
    window.addEventListener("resize", schedule);
    window.addEventListener("scroll", schedule, true);
    schedule();
    return () => {
      observer.disconnect();
      window.removeEventListener("resize", schedule);
      window.removeEventListener("scroll", schedule, true);
      cancelAnimationFrame(frame);
      window.relay?.setDragRegions([]);
    };
  }, [selected, selectedIds, items, start, end, height]);
  function keydown(event: KeyboardEvent) {
    if (
      event.key !== "ArrowDown" &&
      event.key !== "ArrowUp" &&
      event.key !== "Home" &&
      event.key !== "End"
    )
      return;
    event.preventDefault();
    event.stopPropagation();
    const index = items.findIndex((item) => selected.has(item.id));
    const next =
      event.key === "Home"
        ? 0
        : event.key === "End"
          ? items.length - 1
          : Math.min(
              items.length - 1,
              Math.max(0, index + (event.key === "ArrowDown" ? 1 : -1)),
            );
    if (!items[next]) return;
    onSelect(items[next].id, { range: event.shiftKey });
    const element = viewport.current!;
    const top = next * ROW_HEIGHT;
    if (top < element.scrollTop) element.scrollTop = top;
    else if (top + ROW_HEIGHT > element.scrollTop + height)
      element.scrollTop = top + ROW_HEIGHT - height;
  }
  return (
    <div
      className="item-list"
      ref={viewport}
      role="listbox"
      aria-label="Shelf items"
      aria-multiselectable
      tabIndex={0}
      onKeyDown={keydown}
      onScroll={(event) => setScrollTop(event.currentTarget.scrollTop)}
      aria-activedescendant={
        selectedIds[0] &&
        items.slice(start, end).some((i) => i.id === selectedIds[0])
          ? `item-${selectedIds[0]}`
          : undefined
      }
    >
      <div style={{ height: items.length * ROW_HEIGHT, position: "relative" }}>
        <div
          style={{
            position: "absolute",
            top: start * ROW_HEIGHT,
            left: 0,
            right: 0,
          }}
        >
          {items.slice(start, end).map((item) => (
            <ItemRow
              key={item.id}
              item={item}
              selected={selected.has(item.id)}
              onSelect={onSelect}
              onOpen={onOpen}
              onRemove={onRemove}
              selectedIds={selectedIds}
              shelfName={allShelves ? shelfNames.get(item.shelfId) : undefined}
            />
          ))}
        </div>
      </div>
    </div>
  );
}
