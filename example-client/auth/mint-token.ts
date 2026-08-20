// Mint a local RS256 JWT and write web/.env.local so `npm run dev` in web/ picks up the endpoint +
// token. There is no deployed auth backend; the token is signed locally from the key in Secrets
// Manager. Tokens are valid 12h; re-run when one expires.
//
//   npm run token
import { writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { mintToken } from "../lib/mint.ts";

const { endpoint, token } = await mintToken();

const here = dirname(fileURLToPath(import.meta.url));
const envFile = resolve(here, "..", "web", ".env.local");
writeFileSync(envFile, `VITE_POWERSYNC_ENDPOINT=${endpoint}\nVITE_POWERSYNC_TOKEN=${token}\n`);

console.log("minted a 12h token and wrote web/.env.local");
console.log(`   endpoint: ${endpoint}`);
console.log(`   token:    ${token}`);
