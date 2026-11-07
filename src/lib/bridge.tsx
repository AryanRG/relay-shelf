import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { toast } from "sonner";
import type { RelayAPI, ShelfState } from "@/shared";
type Status = "connecting" | "connected" | "disconnected";
interface Bridge {
  busy: string | null;
  state: ShelfState | null;
  status: Status;
  error: string | null;
  invoke: <T = ShelfState>(
    command: string,
    payload?: Record<string, unknown>,
  ) => Promise<T>;
  perform: <T = ShelfState>(
    command: string,
    payload?: Record<string, unknown>,
    success?: string,
  ) => Promise<T | undefined>;
  reconnect: () => void;
}
const Context = createContext<Bridge>(null!);
function isState(value: unknown): value is ShelfState {
  return (
    !!value &&
    typeof value === "object" &&
    "version" in value &&
    "shelves" in value &&
    "items" in value &&
    "settings" in value
  );
}
export function BridgeProvider({ children }: { children: ReactNode }) {
  const [pending, setPending] = useState<{ id: number; label: string }[]>([]);
  const nextPending = useRef(0);
  const [state, setState] = useState<ShelfState | null>(null);
  const [status, setStatus] = useState<Status>("connecting");
  const [error, setError] = useState<string | null>(null);
  const [connection, setConnection] = useState(0);
  const api = useRef<RelayAPI | undefined>(window.relay);
  const revision = useRef(0);
  useEffect(() => {
    api.current = window.relay;
    if (!api.current) {
      setStatus("disconnected");
      setError("Open Relay Shelf on your Mac to connect to your files.");
      return;
    }
    let active = true;
    setStatus("connecting");
    const unState = api.current.onState((next) => {
      if (active) {
        revision.current++;
        setState(next);
        setStatus("connected");
        setError(null);
      }
    });
    const unNotice = api.current.onNotice((message) => toast(message));
    const initialRevision = revision.current;
    api.current
      .invoke<ShelfState>("getState")
      .then((next) => {
        if (active) {
          if (revision.current === initialRevision) setState(next);
          setStatus("connected");
          setError(null);
        }
      })
      .catch((err) => {
        if (active) {
          setStatus("disconnected");
          setError(String(err instanceof Error ? err.message : err));
        }
      });
    return () => {
      active = false;
      unState();
      unNotice();
    };
  }, [connection]);
  const invoke = useCallback(
    async <T = ShelfState,>(
      command: string,
      payload?: Record<string, unknown>,
    ): Promise<T> => {
      if (!api.current)
        throw new Error("This action needs the Relay Shelf macOS app.");
      const labels: Record<string, string> = {
        add: "Importing items…",
        chooseFiles: "Importing files…",
        captureClipboard: "Capturing clipboard…",
        snapshot: "Saving snapshot…",
        exportZip: "Exporting ZIP…",
        exportPDF: "Exporting PDF…",
        chooseFolder: "Choosing folder…",
        addDestination: "Saving destination…",
        removeDestination: "Removing destination…",
        copyToDestination: "Copying to destination…",
        processFiles: "Processing files…",
        captureScreenshot: "Select an area to capture…",
        listShortcuts: "Loading shortcuts…",
        runShortcut: "Running shortcut…",
        showFloatingShelf: "Opening floating shelf…",
        reopenFloatingShelf: "Reopening floating shelf…",
      };
      const initialRevision = revision.current;
      const id = ++nextPending.current;
      if (labels[command])
        setPending((old) => [...old, { id, label: labels[command] }]);
      try {
        const result = await api.current.invoke<T>(command, payload);
        if (isState(result) && revision.current === initialRevision) {
          revision.current++;
          setState(result);
        }
        return result;
      } finally {
        if (labels[command])
          setPending((old) => old.filter((entry) => entry.id !== id));
      }
    },
    [],
  );
  const perform = useCallback(
    async <T = ShelfState,>(
      command: string,
      payload?: Record<string, unknown>,
      success?: string,
    ) => {
      try {
        const result = await invoke<T>(command, payload);
        if (success) toast.success(success);
        return result;
      } catch (err) {
        toast.error(err instanceof Error ? err.message : String(err));
        return undefined;
      }
    },
    [invoke],
  );
  const reconnect = useCallback(() => setConnection((n) => n + 1), []);
  return (
    <Context.Provider
      value={{
        busy: pending[0]?.label || null,
        state,
        status,
        error,
        invoke,
        perform,
        reconnect,
      }}
    >
      {children}
    </Context.Provider>
  );
}
export function useBridge() {
  return useContext(Context);
}
