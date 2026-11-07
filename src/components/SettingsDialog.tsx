import { useState } from "react";
import {
  Check,
  Folder,
  FolderPlus,
  Loader2,
  Monitor,
  Moon,
  Sun,
  Trash2,
} from "lucide-react";
import type { Settings } from "@/shared";
import { useBridge } from "@/lib/bridge";
import { cn } from "@/lib/utils";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Switch } from "@/components/ui/switch";
import { EmptyState, IconButton } from "./common";
export function SettingsDialog({
  shelfId,
  initialTab = "general",
  onClose,
  onDestinations,
}: {
  shelfId: string;
  initialTab?: "general" | "watches";
  onClose: () => void;
  onDestinations: () => void;
}) {
  const { state, perform, busy } = useBridge();
  const [draft, setDraft] = useState<Settings>(state!.settings);
  const [watchShelf, setWatchShelf] = useState(shelfId);
  const [saving, setSaving] = useState(false);
  const [watchBusy, setWatchBusy] = useState(false);
  const update = <K extends keyof Settings>(key: K, value: Settings[K]) =>
    setDraft((d) => ({ ...d, [key]: value }));
  async function save() {
    setSaving(true);
    const result = await perform(
      "updateSettings",
      { settings: draft },
      "Preferences saved",
    );
    setSaving(false);
    if (result) onClose();
  }
  async function chooseRoot() {
    const path = await perform<string | null>("chooseFolder");
    if (path) update("projectRoot", path);
  }
  async function addWatch() {
    setWatchBusy(true);
    const path = await perform<string | null>("chooseFolder");
    if (path)
      await perform(
        "addWatch",
        { path, shelfId: watchShelf },
        "Folder watch added",
      );
    setWatchBusy(false);
  }
  const dirty = JSON.stringify(draft) !== JSON.stringify(state!.settings);
  return (
    <Dialog open onOpenChange={(open) => !open && !saving && onClose()}>
      <DialogContent className="settings-dialog">
        <DialogHeader>
          <span className="dialog-eyebrow">MAKE IT YOURS</span>
          <DialogTitle>Preferences</DialogTitle>
          <DialogDescription>
            A quiet home for the things you’re working with.
          </DialogDescription>
        </DialogHeader>
        <Tabs defaultValue={initialTab}>
          <TabsList>
            <TabsTrigger value="general">General</TabsTrigger>
            <TabsTrigger value="watches">
              Folder watches
              <span className="tab-count">
                {state?.watchedFolders.length || 0}
              </span>
            </TabsTrigger>
          </TabsList>
          <TabsContent value="general" className="settings-body">
            <div className="settings-section">
              <h3>Appearance</h3>
              <div className="theme-options">
                {(
                  [
                    { value: "light", label: "Light", icon: Sun },
                    { value: "dark", label: "Dark", icon: Moon },
                    { value: "system", label: "System", icon: Monitor },
                  ] as const
                ).map(({ value, label, icon: Icon }) => (
                  <button
                    key={value}
                    className={cn(
                      "theme-option",
                      draft.theme === value && "chosen",
                    )}
                    onClick={() => update("theme", value)}
                  >
                    <span className={`theme-thumbnail theme-${value}`}>
                      <i />
                      <i />
                      <i />
                    </span>
                    <span>
                      <Icon size={14} />
                      {label}
                      {draft.theme === value && (
                        <Check size={13} className="ml-auto" />
                      )}
                    </span>
                  </button>
                ))}
              </div>
            </div>
            <div className="settings-section">
              <h3>Window & activation</h3>
              <label className="setting-row" htmlFor="activation">
                <span>
                  <strong>Bring the shelf into view</strong>
                  <small>Choose how Relay Shelf appears while you work.</small>
                </span>
                <select
                  id="activation"
                  value={draft.activation}
                  onChange={(e) =>
                    update(
                      "activation",
                      e.target.value as Settings["activation"],
                    )
                  }
                >
                  <option value="shake">Shake while dragging</option>
                  <option value="edge">Drag to screen edge</option>
                  <option value="drag">When dragging a file</option>
                  <option value="off">Manually</option>
                </select>
              </label>
              <label className="setting-row" htmlFor="on-top">
                <span>
                  <strong>Always on top</strong>
                  <small>Keep the shelf above your other windows.</small>
                </span>
                <Switch
                  id="on-top"
                  checked={draft.alwaysOnTop}
                  onCheckedChange={(v) => update("alwaysOnTop", v)}
                />
              </label>
              <label className="setting-row" htmlFor="login">
                <span>
                  <strong>Open at login</strong>
                  <small>Have Relay Shelf ready when you start your Mac.</small>
                </span>
                <Switch
                  id="login"
                  checked={draft.launchAtLogin}
                  onCheckedChange={(v) => update("launchAtLogin", v)}
                />
              </label>
            </div>
            <div className="settings-section">
              <h3>Files & paths</h3>
              <div className="setting-row">
                <span>
                  <strong>Saved destinations</strong>
                  <small>Keep folders ready for copying selected files.</small>
                </span>
                <Button
                  type="button"
                  size="sm"
                  variant="outline"
                  disabled={saving || watchBusy || !!busy}
                  onClick={onDestinations}
                >
                  Manage ({state?.destinations.length || 0})
                </Button>
              </div>
              <label className="setting-row" htmlFor="storage">
                <span>
                  <strong>Default storage</strong>
                  <small>
                    References use the original. Copies keep a snapshot.
                  </small>
                </span>
                <select
                  id="storage"
                  value={draft.defaultStorage}
                  onChange={(e) =>
                    update(
                      "defaultStorage",
                      e.target.value as Settings["defaultStorage"],
                    )
                  }
                >
                  <option value="reference">Reference original</option>
                  <option value="copy">Keep a copy</option>
                </select>
              </label>
              <label className="field-label" htmlFor="project-root">
                Project root
              </label>
              <div className="input-action">
                <Input
                  id="project-root"
                  value={draft.projectRoot}
                  placeholder="Optional base folder for relative paths"
                  onChange={(e) => update("projectRoot", e.target.value)}
                />
                <IconButton
                  label="Choose project root"
                  onClick={() => void chooseRoot()}
                >
                  <Folder size={16} />
                </IconButton>
              </div>
              <p className="field-hint">
                Resolve paths like ./src/App.tsx from this folder.
              </p>
              <label className="field-label" htmlFor="extensions">
                Watch file extensions
              </label>
              <Input
                id="extensions"
                value={draft.watchExtensions}
                placeholder="pdf, md, png, txt"
                onChange={(e) => update("watchExtensions", e.target.value)}
              />
              <p className="field-hint">
                Comma-separated extensions for watched folders. Leave blank to
                include all files.
              </p>
            </div>
          </TabsContent>
          <TabsContent value="watches" className="settings-body">
            <div className="settings-section">
              <h3>Let files come to you</h3>
              <p className="field-hint">
                New or changed files from a watched folder are sent to its
                shelf. Watching runs in the native app.
              </p>
              <div className="watch-toolbar">
                <label className="sr-only" htmlFor="watch-shelf">
                  Destination shelf
                </label>
                <select
                  id="watch-shelf"
                  value={watchShelf}
                  onChange={(e) => setWatchShelf(e.target.value)}
                >
                  {state?.shelves.map((s) => (
                    <option key={s.id} value={s.id}>
                      {s.name}
                    </option>
                  ))}
                </select>
                <Button
                  size="sm"
                  onClick={() => void addWatch()}
                  disabled={watchBusy || !watchShelf}
                >
                  {watchBusy ? (
                    <Loader2 size={14} className="spin" />
                  ) : (
                    <FolderPlus size={14} />
                  )}
                  Choose folder
                </Button>
              </div>
              {state?.watchedFolders.length ? (
                <div className="watch-list">
                  {state.watchedFolders.map((watch) => (
                    <div className="watch-row" key={watch.id}>
                      <Folder size={18} />
                      <div>
                        <strong title={watch.path}>
                          {watch.path.split("/").pop() || watch.path}
                        </strong>
                        <small title={watch.path}>{watch.path}</small>
                        <small>
                          →{" "}
                          {state.shelves.find((s) => s.id === watch.shelfId)
                            ?.name || "Unknown shelf"}
                        </small>
                      </div>
                      <Switch
                        aria-label={`Watch ${watch.path}`}
                        checked={watch.enabled}
                        onCheckedChange={(enabled) =>
                          void perform("toggleWatch", { id: watch.id, enabled })
                        }
                      />
                      <IconButton
                        label={`Remove watch for ${watch.path}`}
                        onClick={() =>
                          void perform("removeWatch", { id: watch.id })
                        }
                      >
                        <Trash2 size={14} />
                      </IconButton>
                    </div>
                  ))}
                </div>
              ) : (
                <EmptyState
                  icon={FolderPlus}
                  title="No folders watched"
                  description="Choose a folder to automatically keep its files close at hand."
                />
              )}
            </div>
          </TabsContent>
        </Tabs>
        <div className="dialog-footer">
          <span className="field-hint">Changes are stored on this Mac.</span>
          <Button variant="ghost" onClick={onClose} disabled={saving}>
            Cancel
          </Button>
          <Button onClick={() => void save()} disabled={saving || !dirty}>
            {saving && <Loader2 size={14} className="spin" />}Save changes
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  );
}
