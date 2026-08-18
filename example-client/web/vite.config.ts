import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import wasm from "vite-plugin-wasm";
import topLevelAwait from "vite-plugin-top-level-await";

export default defineConfig({
  optimizeDeps: {
    // These ship web workers + WASM; don't pre-bundle them.
    exclude: ["@journeyapps/wa-sqlite", "@powersync/web"],
  },
  plugins: [wasm(), react(), topLevelAwait()],
});
