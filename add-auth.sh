#!/usr/bin/env bash
# Create or rotate the basic-auth credential for one wrapped server.
# Usage: ./add-auth.sh <server-name> [username]
# Writes auth/<server-name>.htpasswd and prints the credential once.
set -euo pipefail

name="${1:?usage: $0 <server-name> [username]}"
user="${2:-$name}"

mkdir -p auth
pass="$(openssl rand -base64 36 | tr -d '/+=\n' | cut -c1-32)"

printf '%s:%s\n' "$user" "$(openssl passwd -apr1 "$pass")" > "auth/${name}.htpasswd"
chmod 644 "auth/${name}.htpasswd"   # hashes only; nginx workers must be able to read it

echo "Server:   $name"
echo "Username: $user"
echo "Password: $pass"
echo "Header:   Authorization: Basic $(printf '%s:%s' "$user" "$pass" | base64 | tr -d '\n')"
echo
echo "Save these now; the password is not stored anywhere."
