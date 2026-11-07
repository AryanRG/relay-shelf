import { useEffect, useRef, useState, type FormEvent } from "react";
import {
  ArrowDown,
  ArrowUp,
  FolderOpen,
  Loader2,
  RefreshCw,
  Trash2,
} from "lucide-react";
import type {
  FileOperation,
  FileProcessingOptions,
  ShelfItem,
  ShelfState,
} from "@/shared";
import { useBridge } from "@/lib/bridge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";

export type FileActionsTab =
  "image" | "pdf" | "text" | "destinations" | "shortcuts";
const imageExtensions = new Set([
  "png",
  "jpg",
  "jpeg",
  "heic",
  "heif",
  "tif",
  "tiff",
  "gif",
  "bmp",
  "webp",
]);
function extension(item: ShelfItem) {
  return (item.extension || item.name.split(".").pop() || "")
    .replace(/^\./, "")
    .toLowerCase();
}
function isImage(item: ShelfItem) {
  return item.kind === "file" && imageExtensions.has(extension(item));
}
function isPDF(item: ShelfItem) {
  return item.kind === "file" && extension(item) === "pdf";
}
const operationLabels: Record<FileOperation, string> = {
  resizeImage: "Resize images",
  convertImage: "Convert images",
  compressImage: "Compress images",
  stripMetadata: "Strip image metadata",
  ocr: "Extract text",
  mergePDF: "Merge PDFs",
  imagesToPDF: "Create PDF from images",
};

export function FileActionsDialog({
  items: originalItems,
  shelfId,
  initialTab,
  onClose,
}: {
  items: ShelfItem[];
  shelfId: string;
  initialTab?: FileActionsTab;
  onClose: () => void;
}) {
  const { state, invoke, busy, status } = useBridge();
  // Keep the opening selection and its order stable when native state pushes arrive.
  const [order, setOrder] = useState(() =>
    originalItems.map((item) => item.id),
  );
  const originals = useRef(originalItems);
  const items = order.map(
    (id) =>
      state?.items.find((item) => item.id === id) || {
        ...originals.current.find((item) => item.id === id)!,
        exists: false,
      },
  );
  const ids = items.map((item) => item.id);
  const [tab, setTab] = useState<FileActionsTab>(() => {
    if (initialTab) return initialTab;
    if (!items.length) return "destinations";
    if (items.every(isPDF)) return "pdf";
    if (items.every(isImage)) return "image";
    if (items.every((item) => isImage(item) || isPDF(item))) return "text";
    return "destinations";
  });
  const [operation, setOperation] = useState<FileOperation>("resizeImage");
  const [pdfOperation, setPDFOperation] = useState<"mergePDF" | "imagesToPDF">(
    () =>
      items.length > 0 && items.every(isImage) ? "imagesToPDF" : "mergePDF",
  );
  const [width, setWidth] = useState("1600");
  const [height, setHeight] = useState("");
  const [format, setFormat] = useState<"png" | "jpeg" | "heic">("png");
  const [quality, setQuality] = useState("0.75");
  const [destinationId, setDestinationId] = useState(
    state?.destinations[0]?.id || "",
  );
  const [destinationPath, setDestinationPath] = useState("");
  const [destinationName, setDestinationName] = useState("");
  const [shortcuts, setShortcuts] = useState<string[] | null>(null);
  const [shortcut, setShortcut] = useState("");
  const [pending, setPending] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [message, setMessage] = useState<string | null>(null);
  const lock = useRef(false);
  const mounted = useRef(true);
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);
  const disabled = !!pending || !!busy || status !== "connected";
  const shelfExists = !!state?.shelves.some((shelf) => shelf.id === shelfId);
  const shelfName =
    state?.shelves.find((shelf) => shelf.id === shelfId)?.name ||
    "selected shelf";
  const filesExist =
    items.length > 0 && items.every((item) => item.exists && !!item.path);
  const withinInputLimit = items.length <= 100;
  const withinMediaSizeLimit =
    items.every((item) => item.size > 0 && item.size <= 256 * 1024 * 1024) &&
    items.reduce((sum, item) => sum + item.size, 0) <= 512 * 1024 * 1024;
  const allImages = filesExist && items.every(isImage);
  const allPDFs = filesExist && items.every(isPDF);
  const copyable =
    filesExist &&
    withinInputLimit &&
    items.every(
      (item) =>
        item.kind === "file" || item.kind === "folder" || item.kind === "text",
    );
  const validMedia = shelfExists && withinInputLimit && withinMediaSizeLimit;
  const validImages = allImages && validMedia;
  const validPDF =
    validMedia &&
    (pdfOperation === "mergePDF" ? allPDFs && items.length >= 2 : allImages);
  const validOCR =
    filesExist &&
    validMedia &&
    items.every((item) => isImage(item) || isPDF(item));
  const validShortcut =
    filesExist &&
    withinInputLimit &&
    shelfExists &&
    items.every((item) => item.kind !== "url");
  const selectedDestination = state?.destinations.find(
    (destination) => destination.id === destinationId,
  );
  const positiveInteger = (value: string) =>
    !!value.trim() &&
    Number.isSafeInteger(Number(value)) &&
    Number(value) > 0 &&
    Number(value) <= 32768;
  const validDimensions =
    positiveInteger(width) && (!height.trim() || positiveInteger(height));
  const validQuality =
    !!quality.trim() &&
    Number.isFinite(Number(quality)) &&
    Number(quality) >= 0.1 &&
    Number(quality) <= 1;
  const selectionHint = !items.length
    ? "Select shelf items to process or copy. Saved destinations are available below."
    : !withinInputLimit
      ? "File actions support up to 100 selected items. Saved destinations are available below."
      : !filesExist
        ? "Some files are unavailable. Relink them or change your selection."
        : null;

  async function run<T>(
    label: string,
    work: () => Promise<T>,
    success?: (result: T) => void,
  ) {
    if (lock.current || busy || status !== "connected") return;
    lock.current = true;
    setPending(label);
    setError(null);
    setMessage(null);
    try {
      const result = await work();
      if (mounted.current) success?.(result);
    } catch (err) {
      if (mounted.current)
        setError(err instanceof Error ? err.message : String(err));
    } finally {
      lock.current = false;
      if (mounted.current) setPending(null);
    }
  }
  function outputMessage(next: ShelfState, prefix = "Action completed.") {
    const previous = new Set(state?.items.map((item) => item.id));
    const count = next.items.filter(
      (item) => item.shelfId === shelfId && !previous.has(item.id),
    ).length;
    setMessage(
      count
        ? `${prefix} ${count} ${count === 1 ? "output added" : "outputs added"} to ${shelfName}.`
        : prefix,
    );
  }
  function process(
    event: FormEvent,
    action: FileOperation,
    allowed: boolean,
    options?: FileProcessingOptions,
  ) {
    event.preventDefault();
    if (!allowed) return;
    void run(
      `${operationLabels[action]}…`,
      () =>
        invoke<ShelfState>("processFiles", {
          ids,
          shelfId,
          operation: action,
          ...(options ? { options } : {}),
        }),
      outputMessage,
    );
  }
  function move(index: number, direction: -1 | 1) {
    setOrder((old) => {
      const next = [...old];
      [next[index], next[index + direction]] = [
        next[index + direction],
        next[index],
      ];
      return next;
    });
  }
  function loadShortcuts() {
    void run(
      "Loading shortcuts…",
      () => invoke<string[]>("listShortcuts"),
      (names) => {
        const sorted = [...new Set(names)].sort((a, b) => a.localeCompare(b));
        setShortcuts(sorted);
        setShortcut((old) => (sorted.includes(old) ? old : sorted[0] || ""));
      },
    );
  }
  // Listing shortcuts is read-only. A shortcut only executes from the Run form below.
  useEffect(() => {
    if (tab === "shortcuts" && shortcuts === null) loadShortcuts();
  }, [tab]);

  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open && !lock.current) onClose();
      }}
    >
      <DialogContent
        className="file-actions-dialog"
        showCloseButton={!pending}
        aria-busy={!!pending}
      >
        <DialogHeader>
          <DialogTitle>File actions</DialogTitle>
          <DialogDescription>
            {items.length
              ? `${items.length} ${items.length === 1 ? "item" : "items"} selected. `
              : "No items selected. "}
            Outputs are saved to {shelfName} as managed copies.
          </DialogDescription>
        </DialogHeader>
        {selectionHint && (
          <p className="file-actions-notice">{selectionHint}</p>
        )}
        <Tabs
          value={tab}
          onValueChange={(value) => {
            if (!lock.current) {
              setTab(value as FileActionsTab);
              setError(null);
              setMessage(null);
            }
          }}
        >
          <TabsList aria-label="File action categories">
            <TabsTrigger value="image" disabled={!!pending}>
              Image
            </TabsTrigger>
            <TabsTrigger value="pdf" disabled={!!pending}>
              PDF
            </TabsTrigger>
            <TabsTrigger value="text" disabled={!!pending}>
              Text / OCR
            </TabsTrigger>
            <TabsTrigger value="destinations" disabled={!!pending}>
              Destinations
            </TabsTrigger>
            <TabsTrigger value="shortcuts" disabled={!!pending}>
              Shortcuts
            </TabsTrigger>
          </TabsList>
          <TabsContent value="image" className="file-actions-body">
            <form
              onSubmit={(event) =>
                process(
                  event,
                  operation,
                  validImages &&
                    (operation !== "resizeImage" || validDimensions) &&
                    (operation !== "compressImage" || validQuality),
                  operation === "resizeImage"
                    ? {
                        width: Number(width),
                        ...(height.trim() ? { height: Number(height) } : {}),
                      }
                    : operation === "convertImage"
                      ? { format }
                      : operation === "compressImage"
                        ? { quality: Number(quality) }
                        : undefined,
                )
              }
            >
              <fieldset disabled={disabled}>
                <legend className="sr-only">Image processing</legend>
                <label className="field-label" htmlFor="image-operation">
                  Action
                </label>
                <select
                  id="image-operation"
                  value={operation}
                  onChange={(event) =>
                    setOperation(event.target.value as FileOperation)
                  }
                >
                  <option value="resizeImage">Resize images</option>
                  <option value="convertImage">Convert image format</option>
                  <option value="compressImage">Compress images</option>
                  <option value="stripMetadata">Strip metadata</option>
                </select>
                <p className="field-hint">
                  Supports PNG, JPEG, HEIC/HEIF, TIFF, GIF, BMP, and WebP still
                  images. Animated and multi-frame files are unsupported.
                </p>
                {operation === "resizeImage" && (
                  <>
                    <div className="file-actions-fields">
                      <div>
                        <label className="field-label" htmlFor="image-width">
                          Maximum width (px)
                        </label>
                        <Input
                          id="image-width"
                          type="number"
                          min="1"
                          max="32768"
                          step="1"
                          required
                          value={width}
                          onChange={(event) => setWidth(event.target.value)}
                        />
                      </div>
                      <div>
                        <label className="field-label" htmlFor="image-height">
                          Maximum height (optional)
                        </label>
                        <Input
                          id="image-height"
                          type="number"
                          min="1"
                          max="32768"
                          step="1"
                          value={height}
                          placeholder="Automatic"
                          onChange={(event) => setHeight(event.target.value)}
                        />
                      </div>
                    </div>
                    <p className="field-hint">
                      Use 1–32,768 pixels. Preserves aspect ratio and keeps
                      smaller images at their original size.
                    </p>
                  </>
                )}
                {operation === "convertImage" && (
                  <>
                    <label className="field-label" htmlFor="image-format">
                      Output format
                    </label>
                    <select
                      id="image-format"
                      value={format}
                      onChange={(event) =>
                        setFormat(event.target.value as typeof format)
                      }
                    >
                      <option value="png">PNG</option>
                      <option value="jpeg">JPEG</option>
                      <option value="heic">HEIC</option>
                    </select>
                    <p className="field-hint">
                      JPEG flattens transparency onto a white background.
                    </p>
                  </>
                )}
                {operation === "compressImage" && (
                  <>
                    <label className="field-label" htmlFor="image-quality">
                      Quality (0.1–1)
                    </label>
                    <Input
                      id="image-quality"
                      type="number"
                      min="0.1"
                      max="1"
                      step="0.01"
                      required
                      value={quality}
                      onChange={(event) => setQuality(event.target.value)}
                    />
                    <p className="field-hint">
                      Creates JPEG. Transparent areas become white. File size
                      may increase.
                    </p>
                  </>
                )}
                {operation === "stripMetadata" && (
                  <p className="field-hint">
                    Preserves PNG, JPEG, or HEIC encoding. Other formats become
                    PNG.
                  </p>
                )}
                <Button
                  type="submit"
                  size="sm"
                  className="file-actions-submit"
                  disabled={
                    !validImages ||
                    (operation === "resizeImage" && !validDimensions) ||
                    (operation === "compressImage" && !validQuality)
                  }
                >
                  {operationLabels[operation]}
                </Button>
              </fieldset>
            </form>
            {!allImages && !selectionHint && (
              <p className="file-actions-notice">
                Select supported image files to use this action.
              </p>
            )}
          </TabsContent>
          <TabsContent value="pdf" className="file-actions-body">
            <form onSubmit={(event) => process(event, pdfOperation, validPDF)}>
              <fieldset disabled={disabled}>
                <legend className="sr-only">
                  PDF processing and input order
                </legend>
                <label className="field-label" htmlFor="pdf-operation">
                  Action
                </label>
                <select
                  id="pdf-operation"
                  value={pdfOperation}
                  onChange={(event) =>
                    setPDFOperation(event.target.value as typeof pdfOperation)
                  }
                >
                  <option value="mergePDF">Merge PDFs</option>
                  <option value="imagesToPDF">Images to PDF</option>
                </select>
                <p className="field-hint">
                  {pdfOperation === "mergePDF"
                    ? "Requires 2–100 PDFs. Pages follow the order below."
                    : "Requires 1–100 still images. Each becomes a page in the order below."}
                </p>
                <h3 className="file-actions-order-label">
                  Input order ({items.length})
                </h3>
                {items.length ? (
                  <ol
                    className="file-actions-order"
                    aria-label="PDF input order"
                  >
                    {items.map((item, index) => (
                      <li key={item.id}>
                        <span className="file-actions-position">
                          {index + 1}
                        </span>
                        <span
                          className="file-actions-filename"
                          title={item.path || item.name}
                        >
                          {item.name}
                          {!item.exists ? " (missing)" : ""}
                        </span>
                        <Button
                          type="button"
                          variant="ghost"
                          size="icon-xs"
                          aria-label={`Move ${item.name} up`}
                          disabled={index === 0}
                          onClick={() => move(index, -1)}
                        >
                          <ArrowUp size={14} />
                        </Button>
                        <Button
                          type="button"
                          variant="ghost"
                          size="icon-xs"
                          aria-label={`Move ${item.name} down`}
                          disabled={index === items.length - 1}
                          onClick={() => move(index, 1)}
                        >
                          <ArrowDown size={14} />
                        </Button>
                      </li>
                    ))}
                  </ol>
                ) : (
                  <p className="field-hint">No input files selected.</p>
                )}
                <Button
                  type="submit"
                  size="sm"
                  className="file-actions-submit"
                  disabled={!validPDF}
                >
                  {operationLabels[pdfOperation]}
                </Button>
              </fieldset>
            </form>
            {!validPDF && !selectionHint && (
              <p className="file-actions-notice">
                {pdfOperation === "mergePDF"
                  ? "Select at least two PDF files to merge."
                  : "Select supported still images to create a PDF."}
              </p>
            )}
          </TabsContent>
          <TabsContent value="text" className="file-actions-body">
            <form onSubmit={(event) => process(event, "ocr", validOCR)}>
              <fieldset disabled={disabled}>
                <legend>Extract text with OCR</legend>
                <p className="field-hint">
                  Creates a .txt file per image or PDF in {shelfName}.
                </p>
                <Button
                  type="submit"
                  size="sm"
                  className="file-actions-submit"
                  disabled={!validOCR}
                >
                  Extract text to .txt
                </Button>
              </fieldset>
            </form>
            {!validOCR && !selectionHint && (
              <p className="file-actions-notice">
                Select images or PDFs to extract text.
              </p>
            )}
            <p className="field-hint">
              For screenshots, use Add → Capture screenshot, then select the
              image here.
            </p>
          </TabsContent>
          <TabsContent value="destinations" className="file-actions-body">
            <form
              onSubmit={(event) => {
                event.preventDefault();
                if (!copyable || !selectedDestination) return;
                void run(
                  "Copying to destination…",
                  () =>
                    invoke<{ paths: string[] }>("copyToDestination", {
                      ids,
                      destinationId: selectedDestination.id,
                    }),
                  (result) =>
                    setMessage(
                      `${result.paths.length} ${result.paths.length === 1 ? "item copied" : "items copied"} to ${selectedDestination.name}.`,
                    ),
                );
              }}
            >
              <fieldset disabled={disabled}>
                <legend>Copy selection</legend>
                <label className="field-label" htmlFor="copy-destination">
                  Saved destination
                </label>
                <select
                  id="copy-destination"
                  value={selectedDestination?.id || ""}
                  onChange={(event) => setDestinationId(event.target.value)}
                >
                  <option value="" disabled>
                    Choose a destination
                  </option>
                  {state?.destinations.map((destination) => (
                    <option key={destination.id} value={destination.id}>
                      {destination.name}
                    </option>
                  ))}
                </select>
                {selectedDestination && (
                  <p className="field-hint file-actions-path">
                    {selectedDestination.path}
                  </p>
                )}
                <p className="field-hint">
                  Copies selected local files and folders. Originals stay in
                  place.
                </p>
                <Button
                  type="submit"
                  size="sm"
                  className="file-actions-submit"
                  disabled={!copyable || !selectedDestination}
                >
                  Copy to destination
                </Button>
              </fieldset>
            </form>
            <section
              className="file-actions-section"
              aria-label="Manage saved destinations"
            >
              <h3>Saved destinations</h3>
              {state?.destinations.length ? (
                <ul className="file-actions-destinations">
                  {state.destinations.map((destination) => (
                    <li key={destination.id}>
                      <FolderOpen size={16} />
                      <div>
                        <strong>{destination.name}</strong>
                        <small title={destination.path}>
                          {destination.path}
                        </small>
                      </div>
                      <Button
                        type="button"
                        variant="ghost"
                        size="icon-sm"
                        disabled={disabled}
                        aria-label={`Remove destination ${destination.name}`}
                        onClick={() =>
                          void run(
                            "Removing destination…",
                            () =>
                              invoke<ShelfState>("removeDestination", {
                                id: destination.id,
                              }),
                            () =>
                              setMessage(
                                "Destination removed. Its folder and files are kept.",
                              ),
                          )
                        }
                      >
                        <Trash2 size={14} />
                      </Button>
                    </li>
                  ))}
                </ul>
              ) : (
                <p className="field-hint">
                  Choose a folder to save your first destination.
                </p>
              )}
              <form
                onSubmit={(event) => {
                  event.preventDefault();
                  if (!destinationPath) return;
                  void run(
                    "Saving destination…",
                    () =>
                      invoke<ShelfState>("addDestination", {
                        path: destinationPath,
                        ...(destinationName.trim()
                          ? { name: destinationName.trim() }
                          : {}),
                      }),
                    (next) => {
                      const destination = next.destinations.find(
                        (entry) => entry.path === destinationPath,
                      );
                      if (destination) setDestinationId(destination.id);
                      setDestinationPath("");
                      setDestinationName("");
                      setMessage("Destination saved.");
                    },
                  );
                }}
              >
                <fieldset disabled={disabled}>
                  <legend className="sr-only">Add a saved destination</legend>
                  <label className="field-label" htmlFor="destination-path">
                    Folder
                  </label>
                  <div className="file-actions-folder-picker">
                    <Input
                      id="destination-path"
                      readOnly
                      value={destinationPath}
                      placeholder="Choose a folder on your Mac"
                    />
                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
                      onClick={() =>
                        void run(
                          "Choosing folder…",
                          () => invoke<string | null>("chooseFolder"),
                          (path) => {
                            if (path) setDestinationPath(path);
                          },
                        )
                      }
                    >
                      Choose folder…
                    </Button>
                  </div>
                  <label className="field-label" htmlFor="destination-name">
                    Name (optional)
                  </label>
                  <Input
                    id="destination-name"
                    value={destinationName}
                    maxLength={80}
                    placeholder="Uses the folder name if blank"
                    onChange={(event) => setDestinationName(event.target.value)}
                  />
                  <Button
                    type="submit"
                    size="sm"
                    className="file-actions-submit"
                    disabled={!destinationPath}
                  >
                    Save destination
                  </Button>
                </fieldset>
              </form>
            </section>
          </TabsContent>
          <TabsContent value="shortcuts" className="file-actions-body">
            <form
              onSubmit={(event) => {
                event.preventDefault();
                if (
                  !validShortcut ||
                  !shortcut ||
                  !shortcuts?.includes(shortcut)
                )
                  return;
                void run(
                  "Running shortcut…",
                  () =>
                    invoke<ShelfState>("runShortcut", {
                      ids,
                      shelfId,
                      name: shortcut,
                    }),
                  (next) => outputMessage(next, "Shortcut finished."),
                );
              }}
            >
              <fieldset disabled={disabled}>
                <legend>Run an Apple Shortcut</legend>
                <p className="field-hint">
                  Sends selected local files to a shortcut that accepts their
                  file types. Returned files become managed copies in{" "}
                  {shelfName}.
                </p>
                <label className="field-label" htmlFor="shortcut-name">
                  Shortcut
                </label>
                <div className="file-actions-shortcut-picker">
                  <select
                    id="shortcut-name"
                    value={shortcut}
                    onChange={(event) => setShortcut(event.target.value)}
                    disabled={!shortcuts?.length}
                  >
                    <option value="" disabled>
                      Choose a shortcut
                    </option>
                    {shortcuts?.map((name) => (
                      <option key={name} value={name}>
                        {name}
                      </option>
                    ))}
                  </select>
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    onClick={loadShortcuts}
                  >
                    <RefreshCw size={14} />
                    Refresh
                  </Button>
                </div>
                {shortcuts !== null && !shortcuts.length && (
                  <p className="field-hint">
                    No shortcuts found. Add one in Shortcuts, then refresh.
                  </p>
                )}
                {!validShortcut && !selectionHint && (
                  <p className="field-hint">
                    Select local files or folders to run a shortcut.
                  </p>
                )}
                <p className="field-hint">
                  Nothing runs until you press Run shortcut.
                </p>
                <Button
                  type="submit"
                  size="sm"
                  className="file-actions-submit"
                  disabled={
                    !validShortcut ||
                    !shortcut ||
                    !shortcuts?.includes(shortcut)
                  }
                >
                  Run shortcut
                </Button>
              </fieldset>
            </form>
          </TabsContent>
        </Tabs>
        {["image", "pdf", "text"].includes(tab) ? (
          <p className="field-hint">
            Up to 100 inputs · 100 PDF pages total · 256 MiB/file · 512 MiB/batch.
          </p>
        ) : (
          <p className="field-hint">Up to 100 selected items per action.</p>
        )}
        {["image", "pdf", "text"].includes(tab) &&
          filesExist &&
          !withinMediaSizeLimit && (
            <p className="file-actions-notice">
              Select nonempty files within the media size limits.
            </p>
          )}
        {!shelfExists && (
          <p className="file-actions-notice">
            Select a shelf for outputs.
          </p>
        )}
        {error && (
          <p className="file-actions-error" role="alert">
            {error}
          </p>
        )}
        {message && (
          <p className="file-actions-success" role="status">
            {message}
          </p>
        )}
        <div className="dialog-footer">
          <span className="field-hint" role="status">
            {pending && (
              <>
                <Loader2 size={13} className="spin" /> {pending}
              </>
            )}
          </span>
          <Button
            type="button"
            variant="outline"
            size="sm"
            disabled={!!pending}
            onClick={onClose}
          >
            Done
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  );
}
