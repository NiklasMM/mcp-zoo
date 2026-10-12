#!/usr/bin/env bash
# Create or rotate the X-MCP-PROXY-PASS token for one wrapped server.
# Usage: ./add-auth.sh <server-name> [--add]
#   rotate (default): replace auth/<server-name>.tokens with a fresh token
#   --add:            append a token next to the existing ones (zero-downtime
#                     rotation: add, reload nginx, remove the old line, reload)
# Prints the header to send, once. Reload nginx afterwards so the master
# process re-reads the token file at config load:
#   docker compose exec nginx nginx -s reload
set -euo pipefail

name="${1:?usage: $0 <server-name> [--add]}"
mode="${2:-rotate}"

tokens_file="auth/${name}.tokens"
mkdir -p auth

# 43-char base64url token (~256 bits). Restricted to [A-Za-z0-9_-] so it is a
# safe unquoted key in an nginx map.
token="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')"

case "$mode" in
    rotate) printf '%s 1;\n' "$token" > "$tokens_file" ;;
    --add)  printf '%s 1;\n' "$token" >> "$tokens_file" ;;
    *) echo "unknown mode: $mode (expected 'rotate' or '--add')" >&2; exit 1 ;;
esac

# Read once at config load by the nginx master (root); workers never read it.
chmod 600 "$tokens_file"

echo "Server: $name"
echo "Header: X-MCP-PROXY-PASS: $token"
echo
echo "Save this now; the token is not stored anywhere."
echo "Then reload nginx to apply:"
echo "  docker compose exec nginx nginx -s reload"
