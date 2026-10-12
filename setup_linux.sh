#!/usr/bin/env bash
# One-time setup for building the Linux version on Ubuntu or in WSL.
#
# Installs the Linux build tools and a Linux Flutter SDK in ~/flutter.
# In WSL this is required: the Windows Flutter SDK must not be used from
# Linux, it would replace its Dart SDK and break Flutter on Windows.

set -euo pipefail

# Same version as the Windows SDK used for this project.
FLUTTER_VERSION="3.47.7"

echo "[*] Installing build tools (needs sudo)"
sudo apt-get update
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev \
  libstdc++-12-dev git curl unzip xz-utils file pandoc zip openssl

if [ ! -x "$HOME/flutter/bin/flutter" ]; then
  echo "[*] Installing Flutter $FLUTTER_VERSION to ~/flutter"
  git clone --depth 1 --branch "$FLUTTER_VERSION" https://github.com/flutter/flutter.git "$HOME/flutter"
fi

# Put the Linux Flutter in front of the Windows PATH entries WSL adds.
line='export PATH="$HOME/flutter/bin:$PATH"'
grep -qxF "$line" "$HOME/.bashrc" || echo "$line" >> "$HOME/.bashrc"
export PATH="$HOME/flutter/bin:$PATH"

flutter config --no-analytics >/dev/null
flutter precache --linux
flutter --version

echo
echo "[*] Done. Open a new shell (or run: source ~/.bashrc), then ./package.sh"
