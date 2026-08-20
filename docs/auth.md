# Client authentication

This guide is for whoever integrates client apps against this deployment. PowerSync's general token behavior is covered upstream, so this page links to the official docs for the parts that apply to every PowerSync instance and documents only what is specific to this repo: where the signing key comes from, the values this deployment accepts, how to mint a token locally, and the constraint the ALB puts on key rotation.

The infrastructure lives in [`../infra/README.md`](../infra/README.md); the token-minting tooling lives in [`../example-client/README.md`](../example-client/README.md).

## How PowerSync validates tokens

Clients authenticate to the PowerSync API with a signed JWT. PowerSync fetches a JWKS from a configured URL, caches it, refreshes it every few minutes, and verifies each token's signature and claims locally against the cached public key. Because validation happens inside the service, this example runs no auth backend. The token requirements (the `kid` match, the `aud`/`sub`/`iat`/`exp` claims, and the supported signature algorithms) and the JWKS format are documented in full at [Custom Authentication: JWT Requirements](https://docs.powersync.com/configuration/auth/custom#jwt-requirements). See also [Authentication Setup](https://docs.powersync.com/configuration/auth/overview) for the overall flow.

## Where the key comes from

Terraform owns the RS256 keypair (`infra/auth.tf`), so the issuer and the verifier stay in lockstep across destroy and apply:

- **Private half.** A 2048-bit RSA private key (`tls_private_key`) stored in AWS Secrets Manager at `<deployment>/jwt-signing-key`. You read it locally to sign tokens. The deployed PowerSync task never needs it.
- **Public half.** Rendered into a JWKS by the `jwks_from_key` data source (the `iwarapter/jwks` provider) rather than a committed static file. This is what the ALB serves.

The JWKS is published at `https://<domain>/api/auth/keys`, the URL PowerSync uses as its `jwks_uri` (`infra/locals.tf`, `jwks_uri`). The ALB serves it with a fixed-response listener rule (`infra/modules/alb/main.tf`): the rule matches the `/api/auth/keys` path and returns the JWKS JSON directly, with no target task involved. This is one of the two supported self-hosted setups, a JWKS URI rather than static keys in the config file (see [Self-Hosted Configuration](https://docs.powersync.com/configuration/auth/custom#self-hosted-configuration)).

A `jwks_uri` must return a set (`{"keys":[...]}`), while the data source returns a single JWK, so `infra/locals.tf` wraps it in a one-element `keys` array (`jwks_json`).

### The 1024-byte ALB limit and what it means for rotation

An ALB fixed-response body is capped at 1024 bytes. The single-key JWKS here is about 435 bytes, so it fits. Two RSA public keys would not. This is a hard constraint of serving the JWKS off the ALB: only one key fits, so rotating the key means re-running `terraform apply` to replace it, and you cannot publish an old and a new key side by side. See [Rotating the key](#rotating-the-key) for what that rules out.

## Token claims for this deployment

The official [JWT Requirements](https://docs.powersync.com/configuration/auth/custom#jwt-requirements) list the claims every PowerSync token must carry. The values this deployment expects:

- **`kid` (key id):** `powersync-example` (`infra/locals.tf`, `jwt_kid`; exposed as the `jwt_signing_kid` output). The same `kid` is baked into the JWKS, so already-issued tokens stay verifiable after an apply that regenerates the key, because the new JWKS carries that same `kid`.
- **`aud` (audience):** this deployment accepts `powersync-dev` and `authenticated` (`infra/locals.tf`, `jwt_audience`, rendered into `client_auth.audience` in `infra/config/service.yaml.tftpl`). A token's `aud` must be one of them. The example mints with `powersync-dev` (the `jwt_audience` output). The audience derives from `deployment_name` and `base_domain`-based naming, so it stays stable across a redeploy or a source-database migration.
- **`sub` (subject):** becomes `request.user_id()` inside the sync rules. The demo sync rules sync only the `lists` rows whose `owner_id` matches that subject, so `sub` must equal the row owner for anything to sync.

## Minting a token locally

The example client mints tokens with no deployed auth backend:

```
cd example-client
npm run token
```

The script (`example-client/auth/mint-token.ts`) reads the private key from Secrets Manager using your AWS credentials, signs an RS256 JWT with the `kid` and `aud` from the Terraform outputs, sets the subject to `example-user` (which matches the `owner_id` the seed script writes), and gives the token a 12-hour expiry. It writes the endpoint URL and the token into `web/.env.local` so the test client picks them up.

For a real app, mint tokens the same way from your own backend: hold the private key, sign a JWT with the right `kid` and `aud`, and set `sub` to the authenticated user's id. Keep token lifetimes short; PowerSync rejects tokens older than 60 minutes.

## Rotating the key

PowerSync supports zero-downtime rotation by publishing the old and new public keys in the JWKS at once, cutting over to the new key after the cache refresh window, then dropping the old key once its tokens expire. The full procedure is documented at [Rotating Keys](https://docs.powersync.com/configuration/auth/custom#rotating-keys).

That procedure needs a JWKS that can hold two keys at once, which this deployment cannot serve. The ALB fixed-response JWKS holds only one key (see [above](#the-1024-byte-alb-limit-and-what-it-means-for-rotation)), so re-running `terraform apply` swaps the single key in place and there is a brief window where a token signed with the previous key fails to verify. For a real multi-key rotation, move the JWKS to a host that can serve the full `{"keys":[...]}` set: a static file on S3 fronted by CloudFront, or a small endpoint. Point PowerSync's `jwks_uri` at that host instead of the ALB rule, and the upstream procedure works as written.
