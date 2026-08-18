/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_POWERSYNC_ENDPOINT: string;
  readonly VITE_POWERSYNC_TOKEN: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
