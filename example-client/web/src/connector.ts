import type { PowerSyncBackendConnector } from "@powersync/web";

const endpoint = import.meta.env.VITE_POWERSYNC_ENDPOINT;
const token = import.meta.env.VITE_POWERSYNC_TOKEN;

// Read-only demo. The token is minted locally (../auth/mint-token.ts -> web/.env.local); the
// endpoint is the deployed PowerSync ALB. This example only reads (writes would go to your own
// backend API's uploadData handler), so uploadData is a no-op.
export const connector: PowerSyncBackendConnector = {
  async fetchCredentials() {
    if (!endpoint || !token) {
      throw new Error(
        "Missing VITE_POWERSYNC_ENDPOINT / VITE_POWERSYNC_TOKEN — run `npm run token` in example-client/ first."
      );
    }
    return { endpoint, token };
  },
  async uploadData() {
    /* read-only */
  },
};
