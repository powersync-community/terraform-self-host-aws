###############################################################################
# Database role passwords for PowerSync's two least-privilege Postgres roles. locals.tf builds the
# connection URIs (baked into the config secret) from these. The companion toolkit's one-time
# bootstrap (`cd example-client && npm run bootstrap`) creates the roles with these passwords, along
# with the `powersync` publication, the bucket-storage database, and the source-read grants.
#
# special=false keeps the generated passwords alphanumeric (no URL-encoding in the connection URIs).
###############################################################################

resource "random_password" "pg_source" {
  length  = 32
  special = false
}

resource "random_password" "pg_storage" {
  length  = 32
  special = false
}
