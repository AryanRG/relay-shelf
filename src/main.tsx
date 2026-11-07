import ReactDOM from "react-dom/client";
import "@fontsource/inter/latin-400.css";
import "@fontsource/inter/latin-500.css";
import "@fontsource/inter/latin-600.css";
import "./styles.css";
import { BridgeProvider } from "@/lib/bridge";
import App from "@/App";
import MarkdownViewer from "@/MarkdownViewer";
ReactDOM.createRoot(document.getElementById("root")!).render(
  window.__relayMarkdownViewer ? (
    <MarkdownViewer />
  ) : (
    <BridgeProvider>
      <App />
    </BridgeProvider>
  ),
);
