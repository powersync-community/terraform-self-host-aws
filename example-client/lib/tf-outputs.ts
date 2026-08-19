// Reads live values from the infra Terraform state so nothing here is hardcoded; survives
// destroy/apply (new db password, new standard_srv host, regenerated signing key, etc.).
import { execFileSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const INFRA_DIR = resolve(here, "..", "..", "infra");

let cache: Record<string, unknown> | null = null;

function load(): Record<string, unknown> {
  if (cache) return cache;
  let raw: string;
  try {
    raw = execFileSync("terraform", [`-chdir=${INFRA_DIR}`, "output", "-json"], {
      encoding: "utf8",
      maxBuffer: 16 * 1024 * 1024,
    });
  } catch (e) {
    throw new Error(
      `Failed to read terraform outputs from ${INFRA_DIR}. Is infra applied and are your AWS creds loaded? (${e})`
    );
  }
  const parsed = JSON.parse(raw) as Record<string, { value: unknown }>;
  cache = Object.fromEntries(Object.entries(parsed).map(([k, v]) => [k, v.value]));
  return cache;
}

export function tfOutput(name: string): string {
  const v = load()[name];
  if (v == null) throw new Error(`terraform output "${name}" is missing. Has infra been applied?`);
  return String(v);
}
