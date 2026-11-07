import { useEffect, useMemo, useRef, useState } from "react";
import {
  ArrowRight,
  Check,
  ClipboardPaste,
  FileText,
  Link2,
  Loader2,
  Search,
  XCircle,
} from "lucide-react";
import { toast } from "sonner";
import type { ResolvedPath, StorageMode } from "@/shared";
import { useBridge } from "@/lib/bridge";
import { bytes, cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import { Input } from "@/components/ui/input";
import { Checkbox } from "@/components/ui/checkbox";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { ItemIcon } from "./common";
import { asItem, PreviewPanel } from "./PreviewPanel";
export function PasteDialog({
  shelfId,
  initial = "",
  onClose,
}: {
  shelfId: string;
  initial?: string;
  onClose: () => void;
}) {
  const { state, invoke, perform } = useBridge();
  const [mode, setMode] = useState("paths");
  const [text, setText] = useState(initial);
  const [title, setTitle] = useState("");
  const [storage, setStorage] = useState<StorageMode>(
    state?.settings.defaultStorage || "reference",
  );
  const [entries, setEntries] = useState<ResolvedPath[]>([]);
  const [checked, setChecked] = useState<Set<string>>(new Set());
  const [candidate, setCandidate] = useState<ResolvedPath | null>(null);
  const [resolving, setResolving] = useState(false);
  const [resolvedInput, setResolvedInput] = useState("");
  const [failure, setFailure] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const sequence = useRef(0);
  const candidateItem = useMemo(
    () => (candidate ? asItem(candidate, shelfId) : null),
    [candidate, shelfId],
  );
  useEffect(() => {
    const seq = ++sequence.current;
    if (mode !== "paths" || !text.trim()) {
      setEntries([]);
      setCandidate(null);
      setResolving(false);
      setFailure(null);
      return;
    }
    setResolving(true);
    setFailure(null);
    const timer = window.setTimeout(() => {
      invoke<ResolvedPath[]>("resolve", {
        text,
        basePath: state?.settings.projectRoot || undefined,
      })
        .then((results) => {
          if (seq !== sequence.current) return;
          setEntries(results);
          setChecked(
            new Set(
              results.filter((e) => e.exists && !e.error).map((e) => e.path),
            ),
          );
          setResolvedInput(text);
          setCandidate(null);
        })
        .catch((error) => {
          if (seq === sequence.current) {
            setFailure(error instanceof Error ? error.message : String(error));
            setEntries([]);
          }
        })
        .finally(() => {
          if (seq === sequence.current) setResolving(false);
        });
    }, 280);
    return () => {
      clearTimeout(timer);
      sequence.current++;
    };
  }, [text, mode, invoke, state?.settings.projectRoot]);
  async function add(paths?: string[]) {
    setSaving(true);
    const selected = paths || Array.from(checked);
    const lines = Object.fromEntries(
      entries
        .filter((e) => selected.includes(e.path) && e.line)
        .map((e) => [e.path, e.line!]),
    );
    const result =
      mode === "paths"
        ? await perform("add", { paths: selected, shelfId, storage, lines })
        : await perform("addText", {
            text,
            shelfId,
            name: title.trim() || undefined,
          });
    setSaving(false);
    if (result) {
      toast.success(
        mode === "paths"
          ? `${selected.length} ${selected.length === 1 ? "item" : "items"} added to shelf`
          : "Saved to shelf",
      );
      onClose();
    }
  }
  return (
    <Dialog open onOpenChange={(open) => !open && !saving && onClose()}>
      <DialogContent
        className={cn("paste-dialog", candidate && "paste-dialog-expanded")}
      >
        <DialogHeader>
          <span className="dialog-eyebrow">
            <ClipboardPaste size={15} />
            CAPTURE
          </span>
          <DialogTitle>
            Add to{" "}
            {state?.shelves.find((s) => s.id === shelfId)?.name || "shelf"}
          </DialogTitle>
          <DialogDescription>
            Bring files, folders, links, and ideas into one place.
          </DialogDescription>
        </DialogHeader>
        <div className="paste-layout">
          <div className="paste-form">
            <Tabs value={mode} onValueChange={setMode}>
              <TabsList>
                <TabsTrigger value="paths">
                  <Link2 size={14} />
                  File paths
                </TabsTrigger>
                <TabsTrigger value="note">
                  <FileText size={14} />
                  Text or link
                </TabsTrigger>
              </TabsList>
            </Tabs>
            <label className="field-label" htmlFor="paste-content">
              {mode === "paths"
                ? "Paste your paths"
                : "What would you like to save?"}
            </label>
            <Textarea
              id="paste-content"
              autoFocus
              rows={5}
              maxLength={200000}
              value={text}
              onChange={(e) => setText(e.target.value)}
              placeholder={
                mode === "paths"
                  ? '"/Users/you/Documents/Project brief.pdf"\n~/Desktop/Designs\n./src/App.tsx:42'
                  : "A useful link, a quick note, or text to keep close…"
              }
              className={mode === "paths" ? "path-input" : ""}
            />
            {mode === "paths" ? (
              <>
                <p className="field-hint">
                  One or more paths. Quotes, file URLs, relative paths, and line
                  numbers are supported.
                </p>
                <div className="storage-options">
                  <button
                    className={cn(storage === "reference" && "chosen")}
                    onClick={() => setStorage("reference")}
                  >
                    <span>
                      <Link2 size={15} />
                      Reference original
                      {storage === "reference" && <Check size={13} />}
                    </span>
                    <small>Keep files where they are.</small>
                  </button>
                  <button
                    className={cn(storage === "copy" && "chosen")}
                    onClick={() => setStorage("copy")}
                  >
                    <span>
                      <ClipboardPaste size={15} />
                      Keep a copy{storage === "copy" && <Check size={13} />}
                    </span>
                    <small>Store a snapshot in Relay Shelf.</small>
                  </button>
                </div>
                <div className="resolve-heading">
                  <span>
                    {resolving ? (
                      <>
                        <Loader2 size={13} className="spin" />
                        Resolving paths…
                      </>
                    ) : (
                      `${entries.length} ${entries.length === 1 ? "candidate" : "candidates"} found`
                    )}
                  </span>
                  <span>{checked.size} selected</span>
                </div>
                {failure && (
                  <div className="inline-error" role="alert">
                    {failure}
                  </div>
                )}
                <div className="candidate-list">
                  {entries.slice(0, 200).map((entry, index) => (
                    <div
                      className={cn(
                        "candidate-row",
                        !entry.exists && "candidate-missing",
                        candidate?.path === entry.path && "active",
                      )}
                      key={`${entry.path}-${index}`}
                    >
                      <Checkbox
                        aria-label={`Include ${entry.name}`}
                        checked={checked.has(entry.path)}
                        disabled={!entry.exists || !!entry.error}
                        onCheckedChange={(value) =>
                          setChecked((old) => {
                            const next = new Set(old);
                            value
                              ? next.add(entry.path)
                              : next.delete(entry.path);
                            return next;
                          })
                        }
                      />
                      <ItemIcon kind={entry.kind} extension={entry.extension} />
                      <button
                        className="candidate-name"
                        disabled={!entry.exists || !!entry.error}
                        onClick={() => setCandidate(entry)}
                      >
                        <strong>{entry.name || entry.input}</strong>
                        <span title={entry.path}>
                          {entry.error ||
                            (!entry.exists
                              ? "Not found · check the path"
                              : `${entry.path}${entry.line ? `:${entry.line}` : ""}`)}
                        </span>
                      </button>
                      <span className="candidate-size">
                        {entry.exists ? (
                          entry.kind === "folder" ? (
                            "Folder"
                          ) : (
                            bytes(entry.size)
                          )
                        ) : (
                          <XCircle size={15} />
                        )}
                      </span>
                      {entry.exists && (
                        <button
                          className="candidate-preview"
                          aria-label={`Preview ${entry.name}`}
                          onClick={() => setCandidate(entry)}
                        >
                          <Search size={14} />
                        </button>
                      )}
                    </div>
                  ))}
                  {!entries.length && !resolving && !failure && (
                    <div className="candidate-empty">
                      <Search size={18} />
                      {text.trim()
                        ? "No paths found. Save this as text or check your project root."
                        : "Resolved files will appear here for review."}
                    </div>
                  )}
                  {entries.length > 200 && (
                    <p className="field-hint">
                      Showing the first 200 candidates. All {checked.size}{" "}
                      selected paths will be added.
                    </p>
                  )}
                </div>
              </>
            ) : (
              <>
                <label className="field-label" htmlFor="note-title">
                  Title <span className="muted">(optional)</span>
                </label>
                <Input
                  id="note-title"
                  placeholder="Give this a name"
                  value={title}
                  maxLength={180}
                  onChange={(e) => setTitle(e.target.value)}
                />
                <p className="field-hint">
                  Web addresses are saved as links. Everything else is saved as
                  a text note.
                </p>
              </>
            )}
          </div>
          {candidateItem && (
            <PreviewPanel
              item={candidateItem}
              shelfId={shelfId}
              transient
              onClose={() => setCandidate(null)}
              onAdd={(paths) => void add(paths)}
            />
          )}
        </div>
        <div className="dialog-footer">
          <Button variant="ghost" onClick={onClose} disabled={saving}>
            Cancel
          </Button>
          <Button
            onClick={() => void add()}
            disabled={
              saving ||
              !text.trim() ||
              (mode === "paths" &&
                (resolving || resolvedInput !== text || !checked.size))
            }
          >
            {saving ? <Loader2 size={14} className="spin" /> : <PlusIcon />}
            {mode === "paths"
              ? `Add ${checked.size || ""} ${checked.size === 1 ? "item" : "items"}`
              : "Save to shelf"}
            <ArrowRight size={14} />
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  );
}
function PlusIcon() {
  return <span aria-hidden="true">+</span>;
}
