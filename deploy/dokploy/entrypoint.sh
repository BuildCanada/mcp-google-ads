#!/bin/sh
# Materialise the Google OAuth credentials from an env var so the container
# needs no volume. GOOGLE_ADS_CREDENTIALS_JSON is the "authorized_user" JSON:
#   {"type":"authorized_user","client_id":"…","client_secret":"…","refresh_token":"…"}
set -eu
if [ -n "${GOOGLE_ADS_CREDENTIALS_JSON:-}" ]; then
  umask 077
  printf '%s' "$GOOGLE_ADS_CREDENTIALS_JSON" > "$GOOGLE_ADS_CREDENTIALS_PATH"
fi
exec /usr/local/bin/mcp-google-ads "$@"
