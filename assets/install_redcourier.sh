#!/bin/bash
# RedCourier installer for Tails.
#
# Requires Persistent Storage with the "Dotfiles" feature enabled.
# Installs to ~/Persistent/programs/redcourier and keeps the app's data
# (keys, groups, settings) in ~/Persistent/programs/redcourier/data.
#
# RedCourier opens every connection through Tor's SOCKS port
# (127.0.0.1:9050, provided by Tails), like socks5h in CalSec. It also works
# when started with torsocks, but then all groups share torsocks' circuits.
#
# The package is signed: SHA256SUMS.sig is an Ed25519 signature over
# SHA256SUMS, which lists every file. On the first installation the key's
# fingerprint is shown for comparison; later updates must be signed with the
# same key, which is stored in the install folder.

set -euo pipefail

APP_ID="redcourier"
INSTALL_DIR="$HOME/Persistent/programs/redcourier"
DATA_DIR="$INSTALL_DIR/data"
PERSISTENCE="${TAILS_PERSISTENCE:-/live/persistence/TailsData_unlocked}"
DOTFILES_APPS="$PERSISTENCE/dotfiles/.local/share/applications"
SESSION_APPS="$HOME/.local/share/applications"
DESKTOP_NAME="$APP_ID.desktop"

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
# The app updates itself (Settings > Updates). For a manual update, run the
# INSTALLED installer with the unpacked new package as argument. Then the
# package is checked against the key pinned on this device, and the installer
# inside the new package does not need to be trusted.
#
#   install_redcourier.sh <package folder>
if [ $# -ge 1 ]; then
  [ -d "$1" ] || { echo "Not a folder: $1"; exit 1; }
  SOURCE_DIR="$(cd "$1" && pwd)"
fi
APPIMAGE="$SOURCE_DIR/RedCourier-x86_64.AppImage"
PINNED_KEY="$INSTALL_DIR/release_signing_key.pem"

# Release signing key, filled in by package.sh.
RELEASE_PUBLIC_KEY="$(cat <<'KEY'
__RELEASE_PUBLIC_KEY__
KEY
)"

ask() {  # ask "Question" default(y/N) -> returns 0 for yes
  local answer
  read -r -p "$1 " answer
  answer="${answer:-$2}"
  [[ "$answer" == "y" || "$answer" == "Y" ]]
}

key_fingerprint() {  # key_fingerprint <public key PEM file>
  openssl pkey -pubin -in "$1" -outform DER 2>/dev/null | sha256sum | cut -c1-64 \
    | sed 's/.\{4\}/& /g; s/ $//' | tr 'a-f' 'A-F'
}

# Checks signature and checksums. Prints nothing on success except the
# first-install fingerprint dialog. Exits on any problem.
verify_package() {
  local sums="$SOURCE_DIR/SHA256SUMS" sig="$SOURCE_DIR/SHA256SUMS.sig"
  if [[ "$RELEASE_PUBLIC_KEY" == *__RELEASE_PUBLIC_KEY__* ]] || [ ! -f "$sig" ]; then
    echo
    echo "WARNING: This package is NOT signed. Nobody can confirm where it comes from."
    echo "         Only continue for your own test builds."
    local answer
    read -r -p "Type 'unsigned' to install it anyway: " answer
    [ "$answer" = "unsigned" ] || { echo "Cancelled."; exit 1; }
    if [ -f "$sums" ] && ! (cd "$SOURCE_DIR" && sha256sum --quiet -c SHA256SUMS); then
      echo "A file does not match its checksum. Aborting."
      exit 1
    fi
    return
  fi

  command -v openssl >/dev/null || { echo "openssl is missing, the signature cannot be checked."; exit 1; }
  [ -f "$sums" ] || { echo "SHA256SUMS is missing. Aborting."; exit 1; }

  local tmp
  tmp="$(mktemp -d)"
  printf '%s\n' "$RELEASE_PUBLIC_KEY" > "$tmp/key.pem"
  if ! base64 -d "$sig" > "$tmp/sig.bin" 2>/dev/null ||
     ! openssl pkeyutl -verify -pubin -inkey "$tmp/key.pem" -rawin \
         -in "$sums" -sigfile "$tmp/sig.bin" >/dev/null 2>&1; then
    rm -rf "$tmp"
    echo
    echo "The signature is INVALID for the release key. The package was modified, damaged"
    echo "or signed with a different key. Aborting."
    exit 1
  fi
  if ! (cd "$SOURCE_DIR" && sha256sum --quiet -c SHA256SUMS); then
    rm -rf "$tmp"
    echo "A file does not match its signed checksum. Aborting."
    exit 1
  fi

  local fpr
  fpr="$(key_fingerprint "$tmp/key.pem")"
  echo "[*] Signature valid."
  if [ -f "$PINNED_KEY" ]; then
    if ! cmp -s <(openssl pkey -pubin -in "$PINNED_KEY" -outform DER 2>/dev/null) \
                <(openssl pkey -pubin -in "$tmp/key.pem" -outform DER 2>/dev/null); then
      echo
      echo "WARNING: This package is signed with a DIFFERENT key than your installed version."
      echo "  Installed key: $(key_fingerprint "$PINNED_KEY")"
      echo "  Package key:   $fpr"
      echo "This happens if the release key was replaced, but it can also mean the package"
      echo "was forged. Only continue if you got the new fingerprint from a trusted source."
      local answer
      read -r -p "Type 'new key' to trust the package key: " answer
      [ "$answer" = "new key" ] || { rm -rf "$tmp"; echo "Cancelled."; exit 1; }
    fi
  else
    echo
    echo "Release key fingerprint:"
    echo "  $fpr"
    echo "Compare it with the fingerprint published by the RedCourier developers"
    echo "(for example on the release page or from a person you trust)."
    if ! ask "Does it match exactly? [y/N]:" N; then
      rm -rf "$tmp"
      echo "Cancelled. Do not install packages with an unknown key."
      exit 1
    fi
  fi
  VERIFIED_KEY="$tmp/key.pem"
}

echo "=== RedCourier installer for Tails ==="

if [ "$(whoami)" != "amnesia" ]; then
  echo "Please run this as the 'amnesia' user (not as root)."
  exit 1
fi
if [ ! -d "$HOME/Persistent" ]; then
  echo "~/Persistent was not found. Unlock or create the Persistent Storage first."
  exit 1
fi
if [ ! -d "$PERSISTENCE/dotfiles" ]; then
  echo "WARNING: The 'Dotfiles' feature of the Persistent Storage is not enabled."
  echo "         Without it, the menu entry disappears after a reboot."
  echo "         (The app and its data in ~/Persistent stay in any case.)"
  echo
fi

is_installed=false
[ -x "$INSTALL_DIR/app/AppRun" ] && is_installed=true

echo
echo "What would you like to do?"
if $is_installed; then
  echo "  1) Update"
  echo "  2) Uninstall"
else
  echo "  1) Install"
fi
echo "  0) Cancel"
echo
read -r -p "Choice: " choice

remove_menu_entry() {
  for f in "$DOTFILES_APPS/$DESKTOP_NAME" "$SESSION_APPS/$DESKTOP_NAME"; do
    if [ -e "$f" ] || [ -L "$f" ]; then rm -f "$f" && echo "  Removed: $f"; fi
  done
  local current
  current=$(gsettings get org.gnome.shell favorite-apps 2>/dev/null || echo "[]")
  if [[ "$current" == *"$DESKTOP_NAME"* ]]; then
    local new
    new=$(echo "$current" | sed "s/, '$DESKTOP_NAME'//;s/'$DESKTOP_NAME', //;s/'$DESKTOP_NAME'//")
    gsettings set org.gnome.shell favorite-apps "$new" 2>/dev/null && echo "  Removed from dash." || true
  fi
}

case "$choice" in
  1) ;;  # install / update below
  2)
    if ! $is_installed; then echo "Invalid choice."; exit 1; fi
    echo
    delete_data=false
    if ask "Also delete all groups, keys and settings in $DATA_DIR? [y/N]:" N; then
      if ask "WARNING: Keys cannot be recovered. Really delete them? [y/N]:" N; then
        delete_data=true
      fi
    fi
    ask "Proceed with uninstall? [y/N]:" N || { echo "Uninstall cancelled."; exit 0; }

    rm -rf "$INSTALL_DIR/app" "$INSTALL_DIR/.app-previous" && echo "  Removed: $INSTALL_DIR/app"
    for f in "$INSTALL_DIR/icon.png" "$INSTALL_DIR/$SCRIPT_NAME" "$INSTALL_DIR/README.html" \
             "$INSTALL_DIR/WHITEPAPER.html" "$PINNED_KEY"; do
      [ -f "$f" ] && rm -f "$f" && echo "  Removed: $f"
    done
    if $delete_data; then
      rm -rf "$DATA_DIR" && echo "  Removed: $DATA_DIR"
    else
      [ -d "$DATA_DIR" ] && echo "  Kept: $DATA_DIR (groups and keys)"
    fi
    remove_menu_entry
    rmdir "$INSTALL_DIR" 2>/dev/null && echo "  Removed: $INSTALL_DIR" || true
    echo
    echo "RedCourier uninstalled."
    exit 0
    ;;
  0) echo "Cancelled."; exit 0 ;;
  *) echo "Invalid choice."; exit 1 ;;
esac

# ── Install / update ─────────────────────────────────────────────────────────

if [ ! -f "$APPIMAGE" ]; then
  echo "RedCourier-x86_64.AppImage was not found in $SOURCE_DIR."
  if $is_installed; then
    echo "To update, unpack the new package and run:"
    echo "  $INSTALL_DIR/$SCRIPT_NAME /path/to/redcourier-<version>-linux-x86_64"
  fi
  exit 1
fi

echo
echo "[*] Checking the package signature..."
VERIFIED_KEY=""
verify_package

echo
echo "[*] Installing to $INSTALL_DIR ..."
mkdir -p "$INSTALL_DIR" "$DATA_DIR"
chmod 700 "$DATA_DIR"

# Tails has no FUSE for AppImages, so the AppImage is unpacked once.
work="$(mktemp -d "$INSTALL_DIR/.unpack.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cp "$APPIMAGE" "$work/app.AppImage"
chmod +x "$work/app.AppImage"
(cd "$work" && ./app.AppImage --appimage-extract >/dev/null)
rm -rf "$INSTALL_DIR/app" "$INSTALL_DIR/.app-previous"
mv "$work/squashfs-root" "$INSTALL_DIR/app"

cp "$SOURCE_DIR/icon.png" "$INSTALL_DIR/icon.png"
for doc in README.html WHITEPAPER.html; do
  [ -f "$SOURCE_DIR/$doc" ] && cp "$SOURCE_DIR/$doc" "$INSTALL_DIR/$doc"
done
if [ "$SOURCE_DIR" != "$INSTALL_DIR" ]; then
  # Replace via a new file: this script may be the one being replaced, and
  # bash reads scripts while running them.
  cp "$SOURCE_DIR/install_redcourier.sh" "$INSTALL_DIR/.install_redcourier.sh.new"
  chmod +x "$INSTALL_DIR/.install_redcourier.sh.new"
  mv -f "$INSTALL_DIR/.install_redcourier.sh.new" "$INSTALL_DIR/install_redcourier.sh"
fi
if [ -n "$VERIFIED_KEY" ]; then
  # Updates must be signed with this key from now on.
  cp "$VERIFIED_KEY" "$PINNED_KEY"
  rm -rf "$(dirname "$VERIFIED_KEY")"
fi

# Received deliveries stay encrypted in the data folder; the user picks a
# folder (for example a VeraCrypt volume) for each delivery in the app.

echo "[*] Creating menu entry..."
mkdir -p "$SESSION_APPS"
if [ -d "$PERSISTENCE/dotfiles" ]; then
  mkdir -p "$DOTFILES_APPS"
  target="$DOTFILES_APPS/$DESKTOP_NAME"
else
  target="$SESSION_APPS/$DESKTOP_NAME"
fi
cat > "$target" <<EOF
[Desktop Entry]
Type=Application
Name=RedCourier
Comment=End-to-end encrypted file delivery over Tor
Exec=env REDCOURIER_DATA_DIR="$DATA_DIR" REDCOURIER_INSTALL_DIR="$INSTALL_DIR" "$INSTALL_DIR/app/AppRun"
Icon=$INSTALL_DIR/icon.png
Terminal=false
Categories=Network;FileTransfer;
StartupNotify=true
StartupWMClass=redcourier
EOF
chmod +x "$target"
# Make the entry available in this session without a reboot.
[ "$target" != "$SESSION_APPS/$DESKTOP_NAME" ] && ln -sf "$target" "$SESSION_APPS/$DESKTOP_NAME"

current=$(gsettings get org.gnome.shell favorite-apps 2>/dev/null || echo "[]")
if [[ "$current" != *"$DESKTOP_NAME"* ]]; then
  if [[ "$current" == "@as []" || "$current" == "[]" ]]; then
    new="['$DESKTOP_NAME']"
  else
    new=$(echo "$current" | sed "s/]$/, '$DESKTOP_NAME']/")
  fi
  gsettings set org.gnome.shell favorite-apps "$new" 2>/dev/null && echo "[*] Added to the dash." || true
fi

echo
echo "Installation complete."
echo
echo "Start RedCourier from the Applications menu. Next steps:"
echo "  1. Name a group, enter your identifier and a password."
echo "  2. Send your join request to the group's admin, or start a new group as admin."
echo "  3. Paste the invite you receive from the admin."
echo
echo "Your groups and keys are stored in: $DATA_DIR"
echo "Received deliveries stay encrypted until you save them to a folder you choose."
echo
echo "To update later, unpack the new package and run THIS installed copy:"
echo "  $INSTALL_DIR/install_redcourier.sh /path/to/redcourier-<version>-linux-x86_64"
