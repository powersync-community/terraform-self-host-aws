###############################################################################
# JWT signing key for PowerSync client auth.
#
# Terraform owns the RSA keypair so it survives destroy/apply with issuer and verifier
# always in lockstep:
#   - private half -> Secrets Manager. Read locally by example-client/auth/mint-token.ts
#     (via your AWS creds) to sign client JWTs. The deployed PowerSync task never needs it.
#   - public half  -> the JWKS the ALB serves at /api/auth/keys (PowerSync's jwks_uri),
#     via the iwarapter/jwks data source instead of a committed static file.
# A fixed kid (local.jwt_kid) keeps tokens valid even after a key regen, because the
# regenerated JWKS carries the same kid and the mint script reads the new key from the secret.
###############################################################################

resource "tls_private_key" "jwt" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

data "jwks_from_key" "jwt" {
  key = tls_private_key.jwt.public_key_pem
  kid = local.jwt_kid
  use = "sig"
  alg = "RS256"
}

resource "aws_secretsmanager_secret" "jwt_signing_key" {
  name                    = "${local.name_prefix}/jwt-signing-key"
  description             = "RS256 private key (PEM) for minting PowerSync client JWTs. The public half is the ALB-served JWKS."
  recovery_window_in_days = 0 # demo: 0-day recovery window so destroy is immediate; raise it for production
}

resource "aws_secretsmanager_secret_version" "jwt_signing_key" {
  secret_id     = aws_secretsmanager_secret.jwt_signing_key.id
  secret_string = tls_private_key.jwt.private_key_pem
}
