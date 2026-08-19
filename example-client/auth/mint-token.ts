// Mint a local RS256 JWT for the PowerSync client (no deployed backend).
// Reads the private key from Secrets Manager (the key Terraform generated), signs a token
// the deployed PowerSync accepts (validated against the ALB-served JWKS), and writes
// web/.env.local so `npm run dev` in web/ picks up the endpoint + token.
//
//   npm run token
import { SecretsManagerClient, GetSecretValueCommand } from "@aws-sdk/client-secrets-manager";
import { createPrivateKey } from "node:crypto";
import { writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { SignJWT } from "jose";
import { tfOutput } from "../lib/tf-outputs.ts";

const secretArn = tfOutput("jwt_signing_key_secret_arn");
const kid = tfOutput("jwt_signing_kid");
const audience = tfOutput("jwt_audience");
const endpoint = tfOutput("domain_url"); // https://<domain>, the PowerSync ALB

const region = secretArn.split(":")[3];
const sm = new SecretsManagerClient({ region });
const { SecretString } = await sm.send(new GetSecretValueCommand({ SecretId: secretArn }));
if (!SecretString) throw new Error("jwt-signing-key secret is empty");

// createPrivateKey handles the PKCS#1 ("BEGIN RSA PRIVATE KEY") PEM that tls_private_key emits;
// jose's SignJWT accepts the resulting KeyObject directly.
const key = createPrivateKey(SecretString);

// The subject becomes request.user_id() in the sync rules, so it must match the owner_id the seed
// script writes (example-user) for any rows to sync.
const token = await new SignJWT({})
  .setProtectedHeader({ alg: "RS256", kid })
  .setSubject("example-user")
  .setAudience(audience)
  .setIssuedAt()
  .setExpirationTime("12h")
  .sign(key);

const here = dirname(fileURLToPath(import.meta.url));
const envFile = resolve(here, "..", "web", ".env.local");
writeFileSync(envFile, `VITE_POWERSYNC_ENDPOINT=${endpoint}\nVITE_POWERSYNC_TOKEN=${token}\n`);

console.log("✅ minted a 12h token and wrote web/.env.local");
console.log(`   endpoint: ${endpoint}`);
console.log(`   token:    ${token}`);
