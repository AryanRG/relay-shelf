import { lazy, Suspense, useEffect, useRef, useState } from "react";
import {
  ArrowLeft,
  ArrowUpRight,
  Check,
  ChevronRight,
  Copy,
  Download,
  FileQuestion,
  FolderOpen,
  Loader2,
  Maximize2,
  Plus,
  Search,
  X,
} from "lucide-react";
import type { Preview, ResolvedPath, ShelfItem } from "@/shared";
import { useBridge } from "@/lib/bridge";
import { bytes, date, parentPath, safeUrl } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { EmptyState, IconButton, ItemIcon } from "./common";
const Markdown = lazy(() => import("./MarkdownPreview"));
export function asItem(entry: ResolvedPath, shelfId: string): ShelfItem {
  return {
    ...entry,
    id: `candidate:${entry.path}`,
    shelfId,
    storage: "reference",
    addedAt: entry.modifiedAt,
    sourcePath: entry.path,
  };
}
const mediaUrl = (value?: string) =>
  value &&
  /^(relay-file:|data:image\/|data:application\/pdf|blob:)/i.test(value)
    ? value
    : undefined;
function CSV({ text }: { text: string }) {
  // A bounded RFC-4180 parser: quoted commas, newlines, and escaped quotes are preserved.
  const rows: string[][] = [];
  let row: string[] = [];
  let cell = "";
  let quoted = false;
  const input = text.slice(0, 120_000);
  for (let i = 0; i < input.length && rows.length < 100; i++) {
    const c = input[i];
    if (c === '"') {
      if (quoted && input[i + 1] === '"') {
        cell += '"';
        i++;
      } else quoted = !quoted;
    } else if (c === "," && !quoted) {
      row.push(cell);
      cell = "";
    } else if ((c === "\n" || c === "\r") && !quoted) {
      if (c === "\r" && input[i + 1] === "\n") i++;
      row.push(cell);
      rows.push(row);
      row = [];
      cell = "";
    } else cell += c;
  }
  if (cell || row.length) {
    row.push(cell);
    rows.push(row);
  }
  return (
    <div className="csv-wrap">
      <table className="csv-table">
        <thead>
          <tr>
            {rows[0]?.slice(0, 12).map((cell, i) => (
              <th key={i}>{cell || `Column ${i + 1}`}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.slice(1, 100).map((row, i) => (
            <tr key={i}>
              {row.slice(0, 12).map((cell, j) => (
                <td key={j}>{cell}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
      <p className="preview-limit">Showing up to 100 rows and 12 columns.</p>
    </div>
  );
}
export function PreviewPanel({
  item,
  shelfId,
  transient = false,
  onClose,
  onAdd,
}: {
  item: ShelfItem | null;
  shelfId: string;
  transient?: boolean;
  onClose?: () => void;
  onAdd?: (paths: string[]) => void;
}) {
  const { invoke, perform, state } = useBridge();
  const [preview, setPreview] = useState<Preview | null>(null);
  const [location, setLocation] = useState<{
    id: string;
    path: string;
    history: string[];
  } | null>(null);
  const current = location?.id === item?.id ? location : null;
  const path = current?.path || item?.path || "";
  const history = current?.history || [];
  const contentRoot = useRef<HTMLDivElement>(null);
  const [loading, setLoading] = useState(false);
  const [retry, setRetry] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [tab, setTab] = useState("rendered");
  const request = useRef(0);
  useEffect(() => {
    setTab("rendered");
  }, [item?.id, item?.path]);
  useEffect(() => {
    const id = ++request.current;
    setPreview(null);
    setError(null);
    if (!item || !path || item.exists === false || item.kind === "url") {
      setLoading(false);
      return;
    }
    setLoading(true);
    invoke<Preview>("preview", { path })
      .then((result) => {
        if (request.current === id) {
          setPreview(result);
          setError(result.error || null);
        }
      })
      .catch((err) => {
        if (request.current === id)
          setError(err instanceof Error ? err.message : String(err));
      })
      .finally(() => {
        if (request.current === id) setLoading(false);
      });
    return () => {
      request.current++;
    };
  }, [
    path,
    item?.id,
    item?.kind,
    item?.exists,
    item?.modifiedAt,
    invoke,
    retry,
  ]);
  const navigate = (next: string) => {
    if (item)
      setLocation({ id: item.id, path: next, history: [...history, path] });
    setTab("rendered");
  };
  async function link(href: string) {
    const external = safeUrl(href);
    if (external) {
      void perform("openExternal", { url: external });
      return;
    }
    if (href.startsWith("#")) {
      document.getElementById(href.slice(1))?.scrollIntoView();
      return;
    }
    const result = await perform<ResolvedPath[]>("resolve", {
      text: href,
      basePath: parentPath(path),
    });
    if (result?.[0]?.exists) navigate(result[0].path);
  }
  if (!item)
    return (
      <aside className="preview-panel preview-unselected">
        <div className="panel-label">PREVIEW</div>
        <EmptyState
          icon={Search}
          title="A closer look"
          description="Select an item to preview its contents and details."
        />
        <div className="preview-hint">
          <kbd>space</kbd> Quick Look <span>·</span> <kbd>↵</kbd> Open
        </div>
      </aside>
    );
  const name =
    preview?.name ||
    (history.length ? path.split("/").pop() : item.name) ||
    item.name;
  const fullText = preview?.text ?? item.content ?? "";
  const text = fullText.slice(0, 200_000);
  const type =
    preview?.type ??
    (item.kind === "text"
      ? "text"
      : item.kind === "url"
        ? "url"
        : "unsupported");
  const add = (paths: string[]) =>
    onAdd
      ? onAdd(paths)
      : void perform("add", {
          paths,
          shelfId,
          storage: state?.settings.defaultStorage,
        });
  const open = () =>
    item.kind === "url"
      ? void perform("openExternal", {
          url: safeUrl(item.content || item.path) || "",
        })
      : void perform("open", { path });
  const truncated =
    !!preview?.truncated ||
    fullText.length > 200_000 ||
    (type === "markdown" && fullText.length > 120_000);
  const renderedMarkdown = () =>
    contentRoot.current?.querySelector<HTMLElement>(".markdown");
  const exportPDF = async () => {
    const rendered = renderedMarkdown();
    const result = await perform<{ path?: string }>("exportPDF", {
      path,
      html: !truncated ? rendered?.innerHTML : undefined,
    });
    if (result?.path) void perform("reveal", { path: result.path });
  };
  const copyContents = () => {
    const rendered = renderedMarkdown();
    if (!transient && !history.length && (truncated || !rendered)) {
      void perform("copyContents", { ids: [item.id] }, "Contents copied");
      return;
    }
    void perform(
      "copyText",
      {
        text: rendered?.innerText || text || item.content || path,
        html: rendered?.innerHTML,
      },
      truncated ? "Preview copied" : "Contents copied",
    );
  };
  const source = () => {
    if (type === "json" && text.length < 100_000) {
      try {
        return JSON.stringify(JSON.parse(text), null, 2);
      } catch {
        return text;
      }
    }
    return text;
  };
  return (
    <aside className="preview-panel">
      <div className="preview-header">
        <span className="panel-label">PREVIEW</span>
        <div className="inline-actions">
          {history.length > 0 && (
            <IconButton
              label="Back to parent"
              onClick={() => {
                setLocation({
                  id: item.id,
                  path: history[history.length - 1],
                  history: history.slice(0, -1),
                });
              }}
            >
              <ArrowLeft size={15} />
            </IconButton>
          )}
          {onClose && (
            <IconButton label="Close preview" onClick={onClose}>
              <X size={15} />
            </IconButton>
          )}
        </div>
      </div>
      <div className="preview-title">
        <ItemIcon
          kind={
            preview?.type === "folder"
              ? "folder"
              : history.length
                ? "file"
                : item.kind
          }
          extension={history.length ? name.split(".").pop() : item.extension}
        />
        <div>
          <h2 title={name}>{name}</h2>
          <span>
            {item.kind === "text"
              ? "Captured text"
              : item.kind === "url"
                ? "Saved link"
                : history.length
                  ? "Folder item"
                  : `${item.extension?.replace(/^\./, "").toUpperCase() || item.kind} · ${item.kind === "folder" ? "Folder" : bytes(item.size)}`}
          </span>
        </div>
      </div>
      <Tabs value={tab} onValueChange={setTab} className="preview-tabs">
        <TabsList>
          <TabsTrigger value="rendered">Preview</TabsTrigger>
          <TabsTrigger
            value="source"
            disabled={loading || (!text && type !== "folder")}
          >
            Source
          </TabsTrigger>
          <TabsTrigger value="details">Details</TabsTrigger>
        </TabsList>
      </Tabs>
      <div className="preview-content" aria-busy={loading} ref={contentRoot}>
        {item.exists === false ? (
          <EmptyState
            icon={FileQuestion}
            title="File moved or missing"
            description="Relink this item to its new location. Your shelf reference will be updated."
          >
            <Button
              size="sm"
              onClick={() => void perform("locate", { id: item.id })}
            >
              <Search size={14} />
              Locate file
            </Button>
          </EmptyState>
        ) : loading ? (
          <div className="loading-state">
            <Loader2 size={19} className="spin" />
            Loading preview…
          </div>
        ) : error ? (
          <EmptyState
            icon={FileQuestion}
            title="Preview unavailable"
            description={error}
          >
            <Button
              variant="outline"
              size="sm"
              onClick={async () => {
                const granted = await perform<boolean>("grantAccess", { path });
                if (granted) setRetry((value) => value + 1);
              }}
            >
              <FolderOpen size={14} />
              Choose file…
            </Button>
            <Button
              variant="ghost"
              size="sm"
              onClick={() => setRetry((value) => value + 1)}
            >
              Retry
            </Button>
            <Button variant="outline" size="sm" onClick={open}>
              Open in default app
              <ArrowUpRight size={14} />
            </Button>
          </EmptyState>
        ) : tab === "details" ? (
          <dl className="details">
            <dt>Name</dt>
            <dd>{name}</dd>
            <dt>Location</dt>
            <dd className="break-all">{path || "Stored on this shelf"}</dd>
            {item.sourcePath && item.sourcePath !== path && (
              <>
                <dt>Original</dt>
                <dd className="break-all">{item.sourcePath}</dd>
              </>
            )}
            <dt>Storage</dt>
            <dd>
              {item.storage === "copy" ? "Managed copy" : "Original reference"}
            </dd>
            <dt>Size</dt>
            <dd>{bytes(item.size)}</dd>
            <dt>Modified</dt>
            <dd>{date(item.modifiedAt)}</dd>
            <dt>Added</dt>
            <dd>{date(item.addedAt)}</dd>
            {item.line && (
              <>
                <dt>Line</dt>
                <dd>{item.line}</dd>
              </>
            )}
            <dt>Status</dt>
            <dd>
              <span className="status-dot" />
              Available
            </dd>
          </dl>
        ) : tab === "source" ? (
          <pre className="source-code" tabIndex={0}>
            {type === "folder"
              ? preview?.entries
                  ?.slice(0, 1000)
                  .map((e) => e.path)
                  .join("\n")
              : source() || "No text source is available."}
          </pre>
        ) : type === "folder" ? (
          <div className="folder-entries">
            <div className="folder-summary">
              {preview?.entries?.length || 0} items<span>Click to preview</span>
            </div>
            {preview?.entries?.slice(0, 1000).map((entry) => (
              <div className="folder-entry" key={entry.path}>
                <button
                  className="folder-entry-main"
                  onClick={() => navigate(entry.path)}
                >
                  <ItemIcon kind={entry.kind} extension={entry.extension} />
                  <span title={entry.name}>
                    {entry.name}
                    <small>
                      {entry.kind === "folder" ? "Folder" : bytes(entry.size)}
                    </small>
                  </span>
                  <ChevronRight size={13} />
                </button>
                <IconButton
                  label={`Add ${entry.name} to shelf`}
                  onClick={() => add([entry.path])}
                >
                  <Plus size={14} />
                </IconButton>
              </div>
            ))}
            {!preview?.entries?.length && (
              <p className="preview-limit">This folder is empty.</p>
            )}
            {(preview?.entries?.length || 0) > 1000 && (
              <p className="preview-limit">
                Showing the first 1,000 entries. Open in Finder to see all.
              </p>
            )}
          </div>
        ) : type === "markdown" ? (
          <Suspense
            fallback={<div className="loading-state">Rendering document…</div>}
          >
            <Markdown text={text} onLink={link} />
          </Suspense>
        ) : type === "csv" ? (
          <CSV text={text} />
        ) : type === "text" || type === "json" ? (
          <pre
            className={type === "json" ? "source-code" : "text-preview"}
            tabIndex={0}
          >
            {source() || "This file is empty."}
          </pre>
        ) : type === "image" && mediaUrl(preview?.url) ? (
          <div className="image-preview">
            <img
              src={mediaUrl(preview?.url)}
              alt={name}
              loading="lazy"
              decoding="async"
              onError={() =>
                setError(
                  "The image could not be loaded. Open it in the default app.",
                )
              }
            />
          </div>
        ) : type === "pdf" && mediaUrl(preview?.url) ? (
          <div className="pdf-container">
            <div className="pdf-tools">
              <span>PDF document</span>
              <Button
                variant="outline"
                size="sm"
                onClick={() => void perform("quickLook", { path })}
              >
                <Maximize2 size={13} />
                Quick Look
              </Button>
            </div>
            <iframe
              className="pdf-preview"
              src={mediaUrl(preview?.url)}
              title={name}
            />
            {text && (
              <details className="pdf-text-fallback">
                <summary>Read extracted text</summary>
                <pre className="text-preview">{text}</pre>
              </details>
            )}
          </div>
        ) : type === "url" ? (
          <div className="url-preview">
            <div className="url-preview-icon">
              <ArrowUpRight size={28} />
            </div>
            <h3>{item.name}</h3>
            <p>{item.content || path}</p>
            <Button size="sm" onClick={open}>
              Open in browser
              <ArrowUpRight size={14} />
            </Button>
            <p className="preview-limit">Links open in your default browser.</p>
          </div>
        ) : (
          <EmptyState
            icon={FileQuestion}
            title="Ready to open"
            description="Use Quick Look or open this file in its default app."
          >
            <Button
              variant="outline"
              size="sm"
              onClick={() => void perform("quickLook", { path })}
            >
              <Maximize2 size={14} />
              Quick Look
            </Button>
          </EmptyState>
        )}
        {truncated && (
          <div className="preview-limit">
            {type === "folder"
              ? "Showing the first 500 folder entries. Open in Finder to see all."
              : "Preview shortened to keep Relay Shelf fast. Open the original for the full content."}
          </div>
        )}
      </div>
      <div className="preview-actions">
        {item.exists !== false && (
          <>
            <Button
              variant="outline"
              size="sm"
              onClick={open}
              disabled={item.kind === "text" && !path}
            >
              Open
              <ArrowUpRight size={13} />
            </Button>
            {item.kind !== "url" && (
              <>
                <IconButton
                  label="Reveal in Finder"
                  onClick={() => void perform("reveal", { path })}
                >
                  <FolderOpen size={16} />
                </IconButton>
                <IconButton
                  label="Quick Look"
                  onClick={() => void perform("quickLook", { path })}
                >
                  <Maximize2 size={16} />
                </IconButton>
              </>
            )}
            {(!!text || type === "url") && (
              <IconButton
                label={
                  truncated && (transient || history.length > 0)
                    ? "Copy preview"
                    : "Copy contents"
                }
                onClick={copyContents}
              >
                <Copy size={15} />
              </IconButton>
            )}
            {type === "markdown" && (
              <IconButton
                label="Export document as PDF"
                onClick={() => void exportPDF()}
              >
                <Download size={16} />
              </IconButton>
            )}
            {(transient || history.length > 0) && (
              <Button size="sm" className="ml-auto" onClick={() => add([path])}>
                <Plus size={14} />
                Add
              </Button>
            )}
            {!transient && !history.length && (
              <span className="preview-saved">
                <Check size={12} />
                On shelf
              </span>
            )}
          </>
        )}
      </div>
    </aside>
  );
}
