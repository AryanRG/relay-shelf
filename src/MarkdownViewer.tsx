import {
  memo,
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
} from "react";
import {
  ArrowDown,
  ArrowUp,
  Check,
  Copy,
  Download,
  Ellipsis,
  FileText,
  FolderOpen,
  List,
  Loader2,
  Minus,
  PanelLeftClose,
  Plus,
  RotateCw,
  Search,
  X,
} from "lucide-react";
import type { MarkdownDocument } from "@/shared";
import MarkdownPreview from "@/components/MarkdownPreview";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";

async function invoke<T = null>(
  command: string,
  payload?: Record<string, unknown>,
): Promise<T> {
  if (!window.relay)
    throw new Error(
      "The document connection is unavailable. Retry in Relay Shelf.",
    );
  return window.relay.invoke<T>(command, payload);
}
const message = (error: unknown) =>
  error instanceof Error ? error.message : String(error);

const approvedImageURL = (url?: string) =>
  url &&
  (/^relay-file:/i.test(url) ||
    /^data:image\/png;base64,[a-z\d+/=]+$/i.test(url))
    ? url
    : undefined;
// Serialize native image work so large documents cannot flood the file reader.
let imageWork: Promise<unknown> = Promise.resolve();
function resolveImage(source: string, active: () => boolean = () => true) {
  const job = imageWork.then(async () =>
    active()
      ? approvedImageURL(
          (await invoke<{ url?: string }>("markdownImage", { source }))?.url,
        )
      : undefined,
  );
  imageWork = job.catch(() => undefined);
  return job;
}
const LocalImage = memo(function LocalImage({
  source,
  alt,
  title,
}: {
  source: string;
  alt: string;
  title?: string;
}) {
  const [url, setUrl] = useState<string>();
  const [failed, setFailed] = useState(false);
  const [visible, setVisible] = useState(false);
  const element = useRef<HTMLSpanElement>(null);
  const blocked =
    !source ||
    (/^(?:[a-z][a-z\d+.-]*:|[\\/]{2})/i.test(source) &&
      !/^file:/i.test(source));
  useEffect(() => {
    if (blocked || !element.current) return;
    if (!window.IntersectionObserver) {
      setVisible(true);
      return;
    }
    const observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((entry) => entry.isIntersecting)) {
          setVisible(true);
          observer.disconnect();
        }
      },
      { rootMargin: "400px 0px" },
    );
    observer.observe(element.current);
    return () => observer.disconnect();
  }, [source, blocked]);
  useEffect(() => {
    let active = true;
    if (!blocked && visible)
      void resolveImage(source, () => active)
        .then((result) => {
          if (active) {
            setUrl(result);
            setFailed(!result);
          }
        })
        .catch(() => {
          if (active) setFailed(true);
        });
    return () => {
      active = false;
    };
  }, [source, blocked, visible]);
  return (
    <span
      ref={element}
      className="reader-local-image"
      data-reader-image-source={blocked ? undefined : source}
      data-reader-image-alt={alt}
    >
      {url && !failed ? (
        <img
          src={url}
          alt={alt}
          title={title}
          loading="lazy"
          decoding="async"
          onError={() => setFailed(true)}
        />
      ) : (
        <span className="reader-image-placeholder" title={source}>
          {alt || "Embedded image"}
          <small>
            {blocked
              ? "Remote images are not loaded"
              : failed
                ? "Local image unavailable"
                : visible
                  ? "Loading local image…"
                  : "Local image · loads when in view"}
          </small>
        </span>
      )}
    </span>
  );
});

type Heading = { id: string; text: string; level: number };
const RenderedDocument = memo(function RenderedDocument({
  document: doc,
  onLink,
}: {
  document: MarkdownDocument;
  onLink: (href: string) => void;
}) {
  // IDs match ordinary Markdown anchors, including repeated and Unicode headings.
  const used = new Set<string>();
  return (
    <MarkdownPreview
      text={doc.text}
      onLink={onLink}
      maxCharacters={null}
      allowFileLinks
      renderImage={(props) => (
        <LocalImage
          key={`${doc.path}:${doc.modifiedAt}:${props.source}`}
          {...props}
        />
      )}
      headingProps={({ text }) => {
        const base = text
          .toLowerCase()
          .trim()
          .replace(/[^\p{L}\p{N}\p{M}_\-\s]/gu, "")
          .replace(/\s/g, "-");
        let id = base || "section";
        let suffix = 0;
        while (used.has(id)) id = `${base || "section"}-${++suffix}`;
        used.add(id);
        return { id, tabIndex: -1 };
      }}
    />
  );
});

// Find spans text nodes so a match can cross emphasis/code boundaries without
// mutating React's DOM. CSS Highlights paints all hits; Selection is a fallback.
type HighlightAPI = { highlights?: Map<string, unknown> };
type HighlightConstructor = new (...ranges: Range[]) => unknown;
function findRanges(
  root: HTMLElement,
  query: string,
): { ranges: Range[]; capped: boolean } {
  if (!query) return { ranges: [], capped: false };
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  const nodes: { node: Text; start: number; end: number }[] = [];
  const chunks: string[] = [];
  let length = 0;
  while (walker.nextNode()) {
    const node = walker.currentNode as Text;
    nodes.push({ node, start: length, end: length + node.length });
    chunks.push(node.data);
    length += node.length;
  }
  // Use a length-preserving comparison; locale case folding can expand Unicode.
  const insensitive = new RegExp(
    query.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"),
    "giu",
  );
  const text = chunks.join("");
  const ranges: Range[] = [];
  let cursor = 0;
  let hit: RegExpExecArray | null;
  while ((hit = insensitive.exec(text))) {
    if (ranges.length === 5000) return { ranges, capped: true };
    const start = hit.index;
    const end = start + hit[0].length;
    while (cursor < nodes.length && nodes[cursor].end <= start) cursor++;
    let last = cursor;
    while (last < nodes.length && nodes[last].end < end) last++;
    if (!nodes[cursor] || !nodes[last]) break;
    const range = document.createRange();
    range.setStart(nodes[cursor].node, start - nodes[cursor].start);
    range.setEnd(nodes[last].node, end - nodes[last].start);
    ranges.push(range);
  }
  return { ranges, capped: false };
}

type Position = { top: number; heading?: string; offset?: number };
export default function MarkdownViewer() {
  const [doc, setDoc] = useState<MarkdownDocument | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState("");
  const [commandError, setCommandError] = useState(false);
  const [busy, setBusy] = useState(false);
  const [tab, setTab] = useState("rendered");
  const [outlineOpen, setOutlineOpen] = useState(true);
  const [headings, setHeadings] = useState<Heading[]>([]);
  const [activeHeading, setActiveHeading] = useState("");
  const [fontSize, setFontSize] = useState(16);
  const [findOpen, setFindOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [matchIndex, setMatchIndex] = useState(0);
  const [findStep, setFindStep] = useState(0);
  const [findResult, setFindResult] = useState<{
    ranges: Range[];
    capped: boolean;
  }>({ ranges: [], capped: false });
  const scroll = useRef<HTMLElement>(null);
  const rendered = useRef<HTMLDivElement>(null);
  const source = useRef<HTMLPreElement>(null);
  const findInput = useRef<HTMLInputElement>(null);
  const request = useRef(0);
  const currentDoc = useRef(doc);
  const currentTab = useRef(tab);
  const restore = useRef<Position | null>(null);
  const pendingAnchor = useRef<string | null>(null);
  const pendingHeading = useRef<string | null>(null);
  const tabPositions = useRef<Record<string, number>>({
    rendered: 0,
    source: 0,
  });
  const actionLock = useRef(false);
  const scrollToMatch = useRef(false);
  const lastFind = useRef({ query: "", tab: "rendered", open: false });
  currentDoc.current = doc;
  currentTab.current = tab;

  const capturePosition = useCallback((): Position => {
    const container = scroll.current;
    if (!container) return { top: 0 };
    if (currentTab.current === "source") return { top: container.scrollTop };
    const top = container.getBoundingClientRect().top;
    const headings =
      rendered.current?.querySelectorAll<HTMLElement>("h1,h2,h3,h4,h5,h6");
    let nearest: HTMLElement | undefined;
    for (const heading of headings || []) {
      if (heading.getBoundingClientRect().top <= top + 32) nearest = heading;
      else break;
    }
    return {
      top: container.scrollTop,
      heading: nearest?.id,
      offset: nearest ? nearest.getBoundingClientRect().top - top : undefined,
    };
  }, []);

  const refresh = useCallback(async () => {
    const id = ++request.current;
    setLoading(true);
    setError(null);
    try {
      const next = await invoke<MarkdownDocument>("markdownDocument");
      if (request.current !== id) return;
      if (
        !next ||
        typeof next.text !== "string" ||
        typeof next.path !== "string" ||
        typeof next.name !== "string"
      )
        throw new Error("The document could not be read.");
      const samePath = currentDoc.current?.path === next.path;
      restore.current = samePath ? capturePosition() : { top: 0 };
      if (!samePath) {
        tabPositions.current = { rendered: 0, source: 0 };
        if (pendingAnchor.current === null && typeof next.anchor === "string")
          pendingAnchor.current = next.anchor;
      }
      setDoc(next);
    } catch (error) {
      if (request.current === id) setError(message(error));
    } finally {
      if (request.current === id) setLoading(false);
    }
  }, [capturePosition]);

  useEffect(() => {
    void refresh();
    const changed = () => {
      void refresh();
    };
    window.addEventListener("relay-markdown-changed", changed);
    return () => {
      request.current++;
      window.removeEventListener("relay-markdown-changed", changed);
    };
  }, [refresh]);

  useEffect(() => {
    const scheme = window.matchMedia("(prefers-color-scheme: dark)");
    const apply = () => {
      document.documentElement.classList.toggle("dark", scheme.matches);
      document.documentElement.style.colorScheme = scheme.matches
        ? "dark"
        : "light";
    };
    apply();
    scheme.addEventListener("change", apply);
    return () => scheme.removeEventListener("change", apply);
  }, []);
  useEffect(() => {
    document.title = doc
      ? `${doc.name} — Relay Shelf`
      : "Markdown — Relay Shelf";
  }, [doc?.name]);
  useEffect(() => {
    if (!notice || commandError) return;
    const timeout = window.setTimeout(() => setNotice(""), 3500);
    return () => window.clearTimeout(timeout);
  }, [notice, commandError]);

  const trackHeading = useCallback(() => {
    if (!scroll.current || currentTab.current !== "rendered") return;
    const top = scroll.current.getBoundingClientRect().top;
    let active = "";
    for (const heading of rendered.current?.querySelectorAll<HTMLElement>(
      "h1,h2,h3,h4,h5,h6",
    ) || []) {
      if (!active || heading.getBoundingClientRect().top <= top + 72)
        active = heading.id;
      else break;
    }
    setActiveHeading(active);
  }, []);
  useLayoutEffect(() => {
    setHeadings(
      Array.from(
        rendered.current?.querySelectorAll<HTMLElement>("h1,h2,h3,h4,h5,h6") ||
          [],
      ).map((heading) => ({
        id: heading.id,
        text: heading.textContent || "Untitled section",
        level: Number(heading.tagName[1]),
      })),
    );
    const position = restore.current;
    if (position && scroll.current) {
      scroll.current.scrollTop = position.top;
      const heading = position.heading
        ? document.getElementById(position.heading)
        : null;
      if (heading && tab === "rendered")
        scroll.current.scrollTop +=
          heading.getBoundingClientRect().top -
          scroll.current.getBoundingClientRect().top -
          (position.offset || 0);
      restore.current = null;
    }
    trackHeading();
  }, [doc, trackHeading, tab]);

  const changeTab = (next: string) => {
    if (next === tab) return;
    tabPositions.current[tab] = scroll.current?.scrollTop || 0;
    restore.current = { top: tabPositions.current[next] || 0 };
    setTab(next);
  };
  const goToHeading = useCallback((id: string) => {
    if (currentTab.current !== "rendered") {
      tabPositions.current.source = scroll.current?.scrollTop || 0;
      pendingHeading.current = id;
      setTab("rendered");
      return;
    }
    requestAnimationFrame(() => {
      const target = rendered.current?.querySelectorAll<HTMLElement>("[id]");
      const heading = Array.from(target || []).find(
        (element) => element.id === id,
      );
      if (heading) {
        heading.scrollIntoView({ block: "start" });
        heading.focus({ preventScroll: true });
        setActiveHeading(id);
      } else {
        setCommandError(true);
        setNotice("This section was not found in the document.");
      }
    });
  }, []);
  useLayoutEffect(() => {
    if (tab !== "rendered" || pendingHeading.current === null) return;
    const id = pendingHeading.current;
    pendingHeading.current = null;
    goToHeading(id);
  }, [tab, goToHeading]);
  const goToAnchor = useCallback(
    (value: string) => {
      const fragment = value.replace(/^#/, "");
      if (!fragment) {
        if (scroll.current) scroll.current.scrollTop = 0;
        return;
      }
      try {
        goToHeading(decodeURIComponent(fragment));
      } catch {
        goToHeading(fragment);
      }
    },
    [goToHeading],
  );
  useLayoutEffect(() => {
    if (!doc || pendingAnchor.current === null) return;
    const anchor = pendingAnchor.current;
    pendingAnchor.current = null;
    goToAnchor(anchor);
  }, [doc, goToAnchor]);
  useEffect(() => {
    const anchor = (event: Event) => {
      const detail = (event as CustomEvent<unknown>).detail;
      if (typeof detail !== "string") return;
      if (currentDoc.current) goToAnchor(detail);
      else pendingAnchor.current = detail;
    };
    window.addEventListener("relay-markdown-anchor", anchor);
    return () => window.removeEventListener("relay-markdown-anchor", anchor);
  }, [goToAnchor]);

  const action = useCallback(
    async <T,>(
      command: string,
      payload?: Record<string, unknown>,
      success?: string,
      operation?: () => Promise<T>,
    ): Promise<T | undefined> => {
      if (actionLock.current) return;
      actionLock.current = true;
      setBusy(true);
      setNotice("");
      try {
        const result = operation
          ? await operation()
          : await invoke<T>(command, payload);
        setCommandError(false);
        if (success) setNotice(success);
        return result;
      } catch (error) {
        setCommandError(true);
        setNotice(message(error));
      } finally {
        actionLock.current = false;
        setBusy(false);
      }
    },
    [],
  );
  const openLink = useCallback(
    (href: string) => {
      if (href.startsWith("#")) {
        goToAnchor(href);
      } else void action("markdownOpenLink", { href });
    },
    [action, goToAnchor],
  );

  const showFind = useCallback(() => {
    setFindOpen(true);
    requestAnimationFrame(() => {
      findInput.current?.focus();
      findInput.current?.select();
    });
  }, []);
  const advanceMatch = useCallback(
    (direction: number) => {
      scrollToMatch.current = true;
      setMatchIndex(
        (index) =>
          (index + direction + findResult.ranges.length) %
          (findResult.ranges.length || 1),
      );
      setFindStep((step) => step + 1);
    },
    [findResult.ranges.length],
  );
  useEffect(() => {
    const key = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && !event.altKey) {
        if (event.key.toLowerCase() === "f") {
          event.preventDefault();
          showFind();
        }
        if (event.key.toLowerCase() === "r") {
          event.preventDefault();
          void refresh();
        }
        if (event.key.toLowerCase() === "g" && findOpen) {
          event.preventDefault();
          advanceMatch(event.shiftKey ? -1 : 1);
        }
      }
      if (event.key === "Escape" && findOpen) {
        setFindOpen(false);
        scroll.current?.focus();
      }
    };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [showFind, refresh, findOpen, advanceMatch]);
  useEffect(() => {
    const timeout = window.setTimeout(() => {
      const root = tab === "source" ? source.current : rendered.current;
      const result =
        root && findOpen
          ? findRanges(root, query)
          : { ranges: [], capped: false };
      const changed =
        lastFind.current.query !== query ||
        lastFind.current.tab !== tab ||
        lastFind.current.open !== findOpen;
      lastFind.current = { query, tab, open: findOpen };
      scrollToMatch.current = changed;
      setFindResult(result);
      setMatchIndex((index) =>
        changed ? 0 : Math.min(index, Math.max(0, result.ranges.length - 1)),
      );
    }, 120);
    return () => window.clearTimeout(timeout);
  }, [query, doc, tab, findOpen]);
  useEffect(() => {
    const registry = (CSS as unknown as HighlightAPI).highlights;
    const Highlight = (
      window as unknown as { Highlight?: HighlightConstructor }
    ).Highlight;
    const range = findResult.ranges[matchIndex];
    if (registry && Highlight) {
      registry.set("reader-find", new Highlight(...findResult.ranges));
      registry.set(
        "reader-find-current",
        new Highlight(...(range ? [range] : [])),
      );
    } else if (range) {
      window.getSelection()?.removeAllRanges();
      window.getSelection()?.addRange(range);
    }
    if (range && scroll.current && scrollToMatch.current) {
      const rect = range.getBoundingClientRect();
      const viewport = scroll.current.getBoundingClientRect();
      if (rect.top < viewport.top + 20 || rect.bottom > viewport.bottom - 20)
        scroll.current.scrollTop +=
          rect.top - viewport.top - viewport.height / 3;
    }
    scrollToMatch.current = false;
    return () => {
      registry?.delete("reader-find");
      registry?.delete("reader-find-current");
      const selection = window.getSelection();
      if (
        !(registry && Highlight) &&
        range &&
        selection?.rangeCount &&
        selection.getRangeAt(0) === range
      )
        selection.removeAllRanges();
    };
  }, [findResult, matchIndex, findStep]);

  const exportPDF = async () => {
    const article = rendered.current?.querySelector(".markdown");
    if (!article || doc?.truncated) return;
    const snapshot = article.cloneNode(true) as HTMLElement;
    const result = await action<{ path?: string }>(
      "markdownExportPDF",
      undefined,
      undefined,
      async () => {
        let omitted = 0;
        // Resolve every offscreen local image sequentially into the export snapshot.
        // The visible reader stays lazy and its reading position is unaffected.
        for (const holder of snapshot.querySelectorAll<HTMLElement>(
          "[data-reader-image-source]",
        )) {
          if (holder.querySelector("img")) continue;
          const source = holder.dataset.readerImageSource!;
          let url: string | undefined;
          try {
            url = await resolveImage(source);
          } catch {
            /* Keep an explicit placeholder below. */
          }
          if (url) {
            const image = document.createElement("img");
            image.src = url;
            image.alt = holder.dataset.readerImageAlt || "Embedded image";
            holder.replaceChildren(image);
          } else {
            omitted++;
            holder.textContent = `[Image unavailable in PDF: ${holder.dataset.readerImageAlt || source}]`;
          }
          if (snapshot.outerHTML.length > 2_000_000)
            throw new Error(
              "The document and its images exceed the PDF export limit. Open it in TextEdit to export.",
            );
        }
        if (omitted) {
          const note = document.createElement("p");
          note.textContent = `${omitted} local image${omitted === 1 ? "" : "s"} could not be included. Placeholders identify each omission.`;
          snapshot.prepend(note);
        }
        for (const image of snapshot.querySelectorAll("img")) {
          image.removeAttribute("loading");
          image.removeAttribute("decoding");
        }
        return invoke<{ path?: string }>("markdownExportPDF", {
          html: snapshot.outerHTML,
        });
      },
    );
    if (result?.path) {
      setCommandError(false);
      setNotice(`PDF saved to ${result.path}`);
    }
  };
  const modified = useMemo(() => {
    const date = doc?.modifiedAt ? new Date(doc.modifiedAt) : null;
    return date && !Number.isNaN(date.getTime())
      ? date.toLocaleString(undefined, {
          dateStyle: "medium",
          timeStyle: "short",
        })
      : "";
  }, [doc?.modifiedAt]);
  const readerStyle = {
    "--reader-font-size": `${fontSize}px`,
  } as CSSProperties;
  const findCount = findResult.ranges.length;

  return (
    <div className="markdown-reader" style={readerStyle}>
      <header className="reader-toolbar">
        <Button
          variant="ghost"
          size="icon-sm"
          aria-label={outlineOpen ? "Hide outline" : "Show outline"}
          title="Document outline"
          aria-expanded={outlineOpen}
          onClick={() => setOutlineOpen((open) => !open)}
        >
          {outlineOpen ? <PanelLeftClose /> : <List />}
        </Button>
        <div className="reader-document-title">
          <strong title={doc?.path}>{doc?.name || "Markdown"}</strong>
          <span title={doc?.path}>{doc?.path || "Relay Shelf"}</span>
        </div>
        <Tabs
          value={tab}
          onValueChange={changeTab}
          className="reader-tabs"
          aria-label="Document view"
        >
          <TabsList>
            <TabsTrigger
              value="rendered"
              id="reader-tab-rendered"
              aria-controls="reader-rendered"
            >
              Rendered
            </TabsTrigger>
            <TabsTrigger
              value="source"
              id="reader-tab-source"
              aria-controls="reader-source"
            >
              Source
            </TabsTrigger>
          </TabsList>
        </Tabs>
        <div className="reader-toolbar-actions">
          <Button
            variant="ghost"
            size="icon-sm"
            aria-label="Find in document"
            title="Find in document (⌘F)"
            onClick={showFind}
          >
            <Search />
          </Button>
          <Button
            variant="ghost"
            size="icon-sm"
            aria-label="Reload document"
            title="Reload (⌘R)"
            onClick={() => void refresh()}
          >
            <RotateCw className={loading ? "spin" : ""} />
          </Button>
          <div
            className="reader-font-controls"
            role="group"
            aria-label="Reading font size"
          >
            <Button
              variant="ghost"
              size="icon-sm"
              aria-label="Decrease font size"
              disabled={fontSize <= 12}
              onClick={() => setFontSize((size) => Math.max(12, size - 1))}
            >
              <Minus />
            </Button>
            <span aria-live="polite">{fontSize}</span>
            <Button
              variant="ghost"
              size="icon-sm"
              aria-label="Increase font size"
              disabled={fontSize >= 24}
              onClick={() => setFontSize((size) => Math.min(24, size + 1))}
            >
              <Plus />
            </Button>
          </div>
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <Button
                variant="ghost"
                size="icon-sm"
                aria-label="Document actions"
                title="Document actions"
              >
                <Ellipsis />
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end">
              <DropdownMenuItem
                disabled={!doc || busy}
                onSelect={() =>
                  void action(
                    "markdownCopy",
                    { kind: "source" },
                    "Source copied",
                  )
                }
              >
                <Copy />
                Copy source
              </DropdownMenuItem>
              <DropdownMenuItem
                disabled={!doc || busy}
                onSelect={() =>
                  void action("markdownCopy", { kind: "path" }, "Path copied")
                }
              >
                <Copy />
                Copy path
              </DropdownMenuItem>
              <DropdownMenuItem
                disabled={!doc || busy}
                onSelect={() => void action("markdownReveal")}
              >
                <FolderOpen />
                Reveal in Finder
              </DropdownMenuItem>
              <DropdownMenuItem
                disabled={!doc || busy || doc.truncated}
                title={
                  doc?.truncated
                    ? "Open in TextEdit to export the complete document"
                    : undefined
                }
                onSelect={() => void exportPDF()}
              >
                <Download />
                Export PDF…
              </DropdownMenuItem>
              <DropdownMenuItem
                disabled={busy}
                onSelect={() => void action<boolean>("markdownChooseAccess")}
              >
                <FolderOpen />
                Choose file or folder…
              </DropdownMenuItem>
              <DropdownMenuItem
                disabled={busy}
                onSelect={() => void action("markdownOpenInEditor")}
              >
                <FileText />
                Open in TextEdit
              </DropdownMenuItem>
              <DropdownMenuSeparator />
              <DropdownMenuItem
                disabled={busy}
                onSelect={() => void action("markdownOpenShelf")}
              >
                <FolderOpen />
                Open shelf
              </DropdownMenuItem>
              <DropdownMenuItem
                disabled={busy}
                onSelect={() =>
                  void action(
                    "markdownMakeDefault",
                    undefined,
                    "Relay Shelf is the default Markdown viewer.",
                  )
                }
              >
                <Check />
                Set as default Markdown reader…
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
      </header>
      {findOpen && (
        <form
          className="reader-find"
          role="search"
          onSubmit={(event) => {
            event.preventDefault();
            advanceMatch(1);
          }}
        >
          <Search size={15} />
          <Input
            ref={findInput}
            aria-label="Find text"
            placeholder="Find in document"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter" && event.shiftKey) {
                event.preventDefault();
                advanceMatch(-1);
              }
            }}
          />
          <span role="status">
            {query
              ? findCount
                ? `${matchIndex + 1} of ${findCount}${findResult.capped ? "+" : ""}`
                : "No matches"
              : ""}
          </span>
          <Button
            type="button"
            variant="ghost"
            size="icon-sm"
            aria-label="Previous match"
            disabled={!findCount}
            onClick={() => advanceMatch(-1)}
          >
            <ArrowUp />
          </Button>
          <Button
            type="submit"
            variant="ghost"
            size="icon-sm"
            aria-label="Next match"
            disabled={!findCount}
          >
            <ArrowDown />
          </Button>
          <Button
            type="button"
            variant="ghost"
            size="icon-sm"
            aria-label="Close find"
            onClick={() => {
              setFindOpen(false);
              scroll.current?.focus();
            }}
          >
            <X />
          </Button>
        </form>
      )}
      {doc?.truncated && (
        <div className="reader-banner reader-warning" role="note">
          <span>Showing the first 2 MiB. This document is truncated.</span>
          <Button
            variant="ghost"
            size="sm"
            disabled={busy}
            onClick={() => void action("markdownOpenInEditor")}
          >
            Open in TextEdit
          </Button>
        </div>
      )}
      {error && (
        <div className="reader-banner reader-error" role="alert">
          <span>
            {doc
              ? "Couldn’t reload. Showing the last loaded version. "
              : "Couldn’t read this document. "}
            {error}{" "}
            macOS may need access. Choose this file or its containing folder.
          </span>
          <Button variant="outline" size="sm" onClick={() => void refresh()}>
            Retry
          </Button>
          <Button
            variant="outline"
            size="sm"
            disabled={busy}
            onClick={() => void action<boolean>("markdownChooseAccess")}
          >
            Choose file or folder…
          </Button>
          <Button
            variant="ghost"
            size="sm"
            disabled={busy}
            onClick={() => void action("markdownOpenInEditor")}
          >
            Open in TextEdit
          </Button>
        </div>
      )}
      {notice && (
        <div
          className={`reader-banner${commandError ? " reader-error" : ""}`}
          role={commandError ? "alert" : "status"}
        >
          <span>{notice}</span>
          <Button
            variant="ghost"
            size="icon-sm"
            aria-label="Dismiss message"
            onClick={() => setNotice("")}
          >
            <X />
          </Button>
        </div>
      )}
      <div
        className={`reader-layout${outlineOpen ? " reader-with-outline" : ""}`}
      >
        {outlineOpen && (
          <nav className="reader-outline" aria-label="Document outline">
            <div className="reader-outline-label">On this page</div>
            {headings.length ? (
              headings.map((heading) => (
                <button
                  key={heading.id}
                  className={activeHeading === heading.id ? "active" : ""}
                  aria-current={
                    activeHeading === heading.id ? "location" : undefined
                  }
                  style={{ paddingLeft: `${12 + (heading.level - 1) * 12}px` }}
                  onClick={() => goToHeading(heading.id)}
                  title={heading.text}
                >
                  {heading.text}
                </button>
              ))
            ) : (
              <p>{loading ? "Loading…" : "No headings in this document."}</p>
            )}
          </nav>
        )}
        <main
          className="reader-scroll"
          ref={scroll}
          tabIndex={-1}
          aria-label="Markdown document"
          aria-busy={loading}
          onScroll={trackHeading}
        >
          {!doc ? (
            <div className="reader-empty">
              {loading ? (
                <>
                  <Loader2 className="spin" size={22} />
                  <p>Loading document…</p>
                </>
              ) : (
                <>
                  <FileText size={26} />
                  <h1>Document unavailable</h1>
                  <p>Retry above or open the file in TextEdit.</p>
                </>
              )}
            </div>
          ) : (
            <>
              <div
                className="reader-rendered"
                id="reader-rendered"
                role="tabpanel"
                aria-labelledby="reader-tab-rendered"
                ref={rendered}
                hidden={tab !== "rendered"}
              >
                <RenderedDocument document={doc} onLink={openLink} />
                {!doc.text && (
                  <p className="reader-empty">This document is empty.</p>
                )}
              </div>
              <pre
                className="reader-source"
                id="reader-source"
                role="tabpanel"
                aria-labelledby="reader-tab-source"
                ref={source}
                hidden={tab !== "source"}
              >
                {doc.text || "This document is empty."}
              </pre>
            </>
          )}
        </main>
      </div>
      <footer className="reader-footer">
        <span>
          {loading
            ? "Reading document…"
            : busy
              ? "Working…"
              : doc?.truncated
                ? "Partial document"
                : "Markdown"}
        </span>
        <span>{modified && `Modified ${modified}`}</span>
      </footer>
    </div>
  );
}
