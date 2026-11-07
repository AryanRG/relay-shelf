import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { fileURLToPath } from "node:url";
export default defineConfig({
  plugins: [react(), tailwindcss()],
  base: "./",
  define: {
    "import.meta.url": "document.baseURI",
    "import.meta.resolve": "undefined",
    "import.meta.hot": "undefined",
  },
  resolve: { alias: { "@": fileURLToPath(new URL("./src", import.meta.url)) } },
  build: {
    outDir: "dist",
    modulePreload: false,
    rolldownOptions: { output: { format: "iife", codeSplitting: false } },
  },
});
