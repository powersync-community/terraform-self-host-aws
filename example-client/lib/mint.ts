// Mint a local RS256 JWT for the PowerSync client. Reads the private key Terraform generated from
// Secrets Manager and signs a token the deployed PowerSync accepts (validated against the ALB-served
// JWKS). Shared by the token script (writes web/.env.local) and the headless connect script.
import { SecretsManagerClient, GetSecretValueCommand } from "@aws-sdk/client-secrets-manager";
import { createPrivateKey } from "node:crypto";
import { SignJWT } from "jose";
import { tfOutput } from "./tf-outputs.ts";

// The subject becomes request.user_id() in the sync rules, so it must match a row's owner_id for
// anything to sync. Expiry stays within PowerSync's 24h maximum.
export async function mintToken(subject = "example-user", expiresIn = "12h"): Promise<{ endpoint: string; token: string }> {
  const { endpoint, mint } = await createMinter();
  return { endpoint, token: await mint(subject, expiresIn) };
}

// Load the signing key once and return a function that signs tokens for any subject. Used by the
// load generator, which needs one token per virtual user without a Secrets Manager call each time.
export async function createMinter(): Promise<{
  endpoint: string;
  mint: (subject: string, expiresIn?: string) => Promise<string>;
}> {
  const secretArn = tfOutput("jwt_signing_key_secret_arn");
  const kid = tfOutput("jwt_signing_kid");
  const audience = tfOutput("jwt_audience");
  const endpoint = tfOutput("domain_url"); // https://<domain> - the PowerSync ALB

  const region = secretArn.split(":")[3];
  const sm = new SecretsManagerClient({ region });
  const { SecretString } = await sm.send(new GetSecretValueCommand({ SecretId: secretArn }));
  if (!SecretString) throw new Error("jwt-signing-key secret is empty");

  // createPrivateKey handles the PKCS#1 ("BEGIN RSA PRIVATE KEY") PEM that tls_private_key emits;
  // jose's SignJWT accepts the resulting KeyObject directly.
  const key = createPrivateKey(SecretString);

  const mint = (subject: string, expiresIn = "12h") =>
    new SignJWT({})
      .setProtectedHeader({ alg: "RS256", kid })
      .setSubject(subject)
      .setAudience(audience)
      .setIssuedAt()
      .setExpirationTime(expiresIn)
      .sign(key);

  return { endpoint, mint };
}
