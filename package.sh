#!/usr/bin/env bash
# Package RedCourier for Tails / Linux:
#
#   dist/redcourier-<version>-linux-x86_64.zip
#     redcourier-<version>-linux-x86_64/
#       RedCourier-x86_64.AppImage
#       install_redcourier.sh     installer for Tails (persistent storage)
#       icon.png
#       README.html, WHITEPAPER.html
#       release_signing_key.pem   the public release key
#       SHA256SUMS, SHA256SUMS.sig
#   dist/redcourier-<version>-linux-x86_64.zip.sig
#   dist/RedCourier-<version>-x86_64.AppImage       for the in-app updater
#   dist/RedCourier-<version>-x86_64.AppImage.sig
#
# Upload all four files to the GitHub release. The app updates itself from
# the AppImage after checking its .sig against the built-in release key.
#
#   ./package.sh               build with ./build.sh, then package and sign
#   ./package.sh --skip-build  package the existing AppImage
#   ./package.sh --unsigned    test package without signature
#
# Signing uses the Ed25519 private key from one of:
#   RELEASE_SIGNING_KEY       the PEM text (for CI secrets)
#   RELEASE_SIGNING_KEY_FILE  path to the PEM file
# An encrypted key asks for its password (or set RELEASE_SIGNING_KEY_PASSWORD).
# The key must match assets/release_signing_key.pem.
#
# Needs: pandoc, openssl, sha256sum and zip (or python3).
# ./setup_linux.sh installs them.

set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BUILD=1
SIGN=1

for arg in "$@"; do
  case "$arg" in
    --skip-build) BUILD=0 ;;
    --unsigned) SIGN=0 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg (see --help)" >&2; exit 2 ;;
  esac
done

step() { echo -e "\n[*] $*"; }
die()  { echo -e "\n[!] $*" >&2; exit 1; }

cd "$ROOT"

VERSION="$(sed -n 's/^version:[[:space:]]*\([0-9][0-9.]*\).*/\1/p' pubspec.yaml | head -1)"
[ -n "$VERSION" ] || die "Could not read the version from pubspec.yaml."
NAME="redcourier-$VERSION-linux-x86_64"
[ "$SIGN" = 1 ] || NAME="$NAME-UNSIGNED"
DIST="$ROOT/dist"
STAGE="$DIST/$NAME"
ZIP="$DIST/$NAME.zip"
APPIMAGE="$ROOT/AppImage/RedCourier-x86_64.AppImage"

command -v pandoc >/dev/null || die "pandoc is missing: sudo apt install pandoc"
command -v sha256sum >/dev/null || die "sha256sum is missing (coreutils)."
if ! command -v zip >/dev/null && ! command -v python3 >/dev/null; then
  die "zip is missing: sudo apt install zip"
fi

PUBKEY="${RELEASE_PUBLIC_KEY_FILE:-$ROOT/assets/release_signing_key.pem}"
KEYDIR=""
cleanup() { [ -n "$KEYDIR" ] && rm -rf "$KEYDIR"; return 0; }
trap cleanup EXIT

der() { openssl pkey "$@" -outform DER 2>/dev/null | sha256sum | cut -c1-64; }
fingerprint() { der -pubin -in "$1" | sed 's/.\{4\}/& /g; s/ $//' | tr 'a-f' 'A-F'; }

if [ "$SIGN" = 1 ]; then
  command -v openssl >/dev/null || die "openssl is missing: sudo apt install openssl"
  [ -f "$PUBKEY" ] || die "Public release key not found: $PUBKEY"
  openssl pkey -pubin -in "$PUBKEY" -noout -text 2>/dev/null | grep -q ED25519 \
    || die "$PUBKEY is not an Ed25519 public key."

  KEYDIR="$(mktemp -d)"
  chmod 700 "$KEYDIR"
  if [ -n "${RELEASE_SIGNING_KEY:-}" ]; then
    (umask 077; printf '%s\n' "$RELEASE_SIGNING_KEY" > "$KEYDIR/key.pem")
  elif [ -n "${RELEASE_SIGNING_KEY_FILE:-}" ]; then
    [ -f "$RELEASE_SIGNING_KEY_FILE" ] || die "Signing key not found: $RELEASE_SIGNING_KEY_FILE"
    cp "$RELEASE_SIGNING_KEY_FILE" "$KEYDIR/key.pem"
  else
    die "No signing key. Set RELEASE_SIGNING_KEY_FILE=/path/to/private.pem
    (or RELEASE_SIGNING_KEY for CI), or build a test package with --unsigned."
  fi
  PASSARG=()
  [ -n "${RELEASE_SIGNING_KEY_PASSWORD:-}" ] && PASSARG=(-passin env:RELEASE_SIGNING_KEY_PASSWORD)
  # Decrypt once (asks for the password if needed) so signing does not ask again.
  openssl pkey -in "$KEYDIR/key.pem" "${PASSARG[@]}" -out "$KEYDIR/plain.pem" \
    || die "Could not read the signing key (wrong password?)."
  chmod 600 "$KEYDIR/plain.pem"
  [ "$(der -in "$KEYDIR/plain.pem" -pubout)" = "$(der -pubin -in "$PUBKEY")" ] \
    || die "The signing key does not belong to $PUBKEY."
  grep -qF "$(sed -n 2p "$PUBKEY")" WHITEPAPER.md \
    || die "WHITEPAPER.md does not show the current release key. Update its 'Release integrity' section."
  export RC_RELEASE_KEY_PEM="$(cat "$PUBKEY")"
  export RC_RELEASE_KEY_FPR="$(fingerprint "$PUBKEY")"
fi

sign() {  # sign <file>  ->  <file>.sig (base64 Ed25519) and verify it
  openssl pkeyutl -sign -inkey "$KEYDIR/plain.pem" -rawin -in "$1" | base64 -w0 > "$1.sig"
  base64 -d "$1.sig" > "$KEYDIR/check.bin"
  openssl pkeyutl -verify -pubin -inkey "$PUBKEY" -rawin -in "$1" -sigfile "$KEYDIR/check.bin" >/dev/null \
    || die "Signature check failed for $1."
}

if [ "$BUILD" = 1 ]; then
  step "Building"
  "$ROOT/build.sh"
fi
[ -f "$APPIMAGE" ] || die "No AppImage found. Run ./build.sh first or drop --skip-build."

step "Preparing $NAME"
UPDATE_IMAGE="$DIST/RedCourier-$VERSION-x86_64.AppImage"
rm -rf "$STAGE" "$ZIP" "$ZIP.sig" "$UPDATE_IMAGE" "$UPDATE_IMAGE.sig"
mkdir -p "$STAGE"

cp "$APPIMAGE" "$STAGE/RedCourier-x86_64.AppImage"
if [ "$SIGN" = 1 ]; then
  # Put the public key into the installer.
  awk -v keyfile="$PUBKEY" '
    $0 == "__RELEASE_PUBLIC_KEY__" { while ((getline line < keyfile) > 0) print line; next }
    { print }' assets/install_redcourier.sh > "$STAGE/install_redcourier.sh"
  grep -qx "__RELEASE_PUBLIC_KEY__" "$STAGE/install_redcourier.sh" && die "Key was not inserted into the installer."
  cp "$PUBKEY" "$STAGE/release_signing_key.pem"
  chmod 644 "$STAGE/release_signing_key.pem"
else
  cp assets/install_redcourier.sh "$STAGE/install_redcourier.sh"
fi
cp assets/icon/app_icon_rounded.png "$STAGE/icon.png"
chmod 755 "$STAGE/RedCourier-x86_64.AppImage" "$STAGE/install_redcourier.sh"
chmod 644 "$STAGE/icon.png"

step "Rendering documentation"
render() {  # render <markdown> <html> <title>
  pandoc "$1" -o "$STAGE/$2" \
    --from markdown --to html5 --standalone \
    --include-in-header=assets/docs/style.css \
    --lua-filter=assets/docs/docs.lua \
    --metadata title="$3" --metadata lang=en
  chmod 644 "$STAGE/$2"
}
render README.md README.html "RedCourier"
render WHITEPAPER.md WHITEPAPER.html "RedCourier – Whitepaper"

step "Writing checksums"
(cd "$STAGE" && sha256sum RedCourier-x86_64.AppImage install_redcourier.sh icon.png \
  README.html WHITEPAPER.html $( [ "$SIGN" = 1 ] && echo release_signing_key.pem ) > SHA256SUMS)
if [ "$SIGN" = 1 ]; then
  step "Signing"
  sign "$STAGE/SHA256SUMS"
  chmod 644 "$STAGE/SHA256SUMS.sig"
fi

step "Creating $(basename "$ZIP")"
if command -v zip >/dev/null; then
  (cd "$DIST" && zip -q -r -X "$ZIP" "$NAME")
else
  # Fallback that keeps the executable bits like zip does.
  python3 - "$ZIP" "$DIST" "$NAME" <<'PY'
import os, sys, zipfile
out, base, name = sys.argv[1:]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for folder, _, files in os.walk(os.path.join(base, name)):
        for f in sorted(files):
            path = os.path.join(folder, f)
            z.write(path, os.path.relpath(path, base))
PY
fi

[ "$SIGN" = 1 ] && sign "$ZIP"

if [ "$SIGN" = 1 ]; then
  step "Signing the AppImage for the in-app updater"
  cp "$APPIMAGE" "$UPDATE_IMAGE"
  chmod 755 "$UPDATE_IMAGE"
  sign "$UPDATE_IMAGE"
fi

step "Done"
echo "    $ZIP"
echo "    SHA-256: $(sha256sum "$ZIP" | cut -d' ' -f1)"
if [ "$SIGN" = 1 ]; then
  echo "    $UPDATE_IMAGE (+ .sig)"
  echo "Upload all files from dist/ (zip, AppImage and both .sig) to the GitHub release."
fi
if [ "$SIGN" = 1 ]; then
  echo "    Signature: $ZIP.sig"
  echo "    Release key fingerprint: $RC_RELEASE_KEY_FPR"
else
  echo "    UNSIGNED test package. Do not publish it."
fi
