#!/usr/bin/env bash
# Sign release files with the Ed25519 release key, like package.sh:
#
#   scripts/sign_files.sh FILE...   writes FILE.sig = base64(Ed25519(key, FILE))
#
# The private key comes from RELEASE_SIGNING_KEY (PEM text, for CI secrets) or
# RELEASE_SIGNING_KEY_FILE; RELEASE_SIGNING_KEY_PASSWORD unlocks an encrypted
# key. Every signature is checked against assets/release_signing_key.pem, so a
# wrong key fails instead of producing unusable signatures.

set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
PUBKEY="${RELEASE_PUBLIC_KEY_FILE:-$ROOT/assets/release_signing_key.pem}"

die() { echo -e "[!] $*" >&2; exit 1; }
der() { openssl pkey "$@" -outform DER 2>/dev/null | sha256sum | cut -c1-64; }

[ $# -ge 1 ] || die "Usage: $0 FILE..."
command -v openssl >/dev/null || die "openssl is missing."
[ -f "$PUBKEY" ] || die "Public release key not found: $PUBKEY"

KEYDIR="$(mktemp -d)"
trap 'rm -rf "$KEYDIR"' EXIT
chmod 700 "$KEYDIR"
if [ -n "${RELEASE_SIGNING_KEY:-}" ]; then
  (umask 077; printf '%s\n' "$RELEASE_SIGNING_KEY" > "$KEYDIR/key.pem")
elif [ -n "${RELEASE_SIGNING_KEY_FILE:-}" ]; then
  cp "$RELEASE_SIGNING_KEY_FILE" "$KEYDIR/key.pem"
else
  die "No signing key: set RELEASE_SIGNING_KEY or RELEASE_SIGNING_KEY_FILE."
fi
PASSARG=()
[ -n "${RELEASE_SIGNING_KEY_PASSWORD:-}" ] && PASSARG=(-passin env:RELEASE_SIGNING_KEY_PASSWORD)
openssl pkey -in "$KEYDIR/key.pem" "${PASSARG[@]}" -out "$KEYDIR/plain.pem" \
  || die "Could not read the signing key (wrong password?)."
[ "$(der -in "$KEYDIR/plain.pem" -pubout)" = "$(der -pubin -in "$PUBKEY")" ] \
  || die "The signing key does not belong to $PUBKEY."

for f in "$@"; do
  [ -f "$f" ] || die "Not found: $f"
  openssl pkeyutl -sign -inkey "$KEYDIR/plain.pem" -rawin -in "$f" | base64 -w0 > "$f.sig"
  base64 -d "$f.sig" > "$KEYDIR/check.bin"
  openssl pkeyutl -verify -pubin -inkey "$PUBKEY" -rawin -in "$f" -sigfile "$KEYDIR/check.bin" >/dev/null \
    || die "Signature check failed for $f."
  echo "[*] Signed $f"
done
