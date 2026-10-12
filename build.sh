#!/usr/bin/env bash
# Build RedCourier for Linux and pack it as an AppImage.
#
#   ./build.sh            Linux release + AppImage/RedCourier-x86_64.AppImage
#   ./build.sh --android  additionally build the Android release APK
#                         (needs the Android SDK in ANDROID_HOME)
#
# Runs on Linux and in WSL. First time in WSL: run ./setup_linux.sh.
#
#   APPIMAGETOOL=/path        use this appimagetool instead of AppImage/
#   APPIMAGE_RUNTIME=/path    pack with this AppImage runtime instead of
#                             letting appimagetool download one (CI pins it)
#
# The build happens in a copy of the project on the Linux file system, so it
# neither touches the Windows build folders nor rewrites .dart_tool with Linux
# paths, and it is much faster than building on /mnt/c.

set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
WORK="${XDG_CACHE_HOME:-$HOME/.cache}/redcourier-build"
OUT_APPIMAGE="$ROOT/AppImage/RedCourier-x86_64.AppImage"
ANDROID=0

for arg in "$@"; do
  case "$arg" in
    --android) ANDROID=1 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg (see --help)" >&2; exit 2 ;;
  esac
done

step() { echo -e "\n[*] $*"; }
die()  { echo -e "\n[!] $*" >&2; exit 1; }

# ── Checks ───────────────────────────────────────────────────────────────────

# Prefer a Flutter installed by setup_linux.sh.
if [ -x "$HOME/flutter/bin/flutter" ]; then
  export PATH="$HOME/flutter/bin:$PATH"
fi

FLUTTER="$(command -v flutter || true)"
[ -n "$FLUTTER" ] || die "Flutter is not installed. Run ./setup_linux.sh first."
case "$(readlink -f "$FLUTTER")" in
  /mnt/*)
    die "This would use the Windows Flutter SDK ($FLUTTER).
    Running it from WSL replaces its Dart SDK with a Linux one and breaks Flutter on Windows.
    Run ./setup_linux.sh once to install Flutter inside WSL." ;;
esac

missing=()
for tool in clang cmake ninja pkg-config; do
  path="$(command -v "$tool" || true)"
  case "$path" in ""|/mnt/*) missing+=("$tool") ;; esac
done
pkg-config --exists gtk+-3.0 2>/dev/null || missing+=("gtk3")
if [ ${#missing[@]} -gt 0 ]; then
  die "Missing build tools: ${missing[*]}
    Install them with:
      sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-12-dev"
fi

if [ "$ANDROID" = 1 ] && [ -z "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}" ]; then
  die "--android needs the Android SDK (set ANDROID_HOME). On Windows, build the APK with:
      flutter build apk --release"
fi

APPIMAGETOOL="${APPIMAGETOOL:-$ROOT/AppImage/appimagetool-x86_64.AppImage}"
[ -f "$APPIMAGETOOL" ] || die "appimagetool is missing. Download it to $APPIMAGETOOL from
    https://github.com/AppImage/appimagetool/releases"

# ── Copy the project ─────────────────────────────────────────────────────────

step "Copying project to $WORK"
mkdir -p "$WORK"
# Keep the work folder's build/ and .dart_tool/ for faster rebuilds.
find "$WORK" -mindepth 1 -maxdepth 1 ! -name build ! -name .dart_tool -exec rm -rf {} +
tar -C "$ROOT" \
    --exclude=./build --exclude=./.dart_tool --exclude=./.git \
    --exclude='./AppImage/*.AppImage' --exclude='./*.snap' \
    --exclude='./AppImage/RedCourier/AppDir/usr/bin/*' \
    --exclude='./linux/flutter/ephemeral' --exclude='./windows/flutter/ephemeral' \
    --exclude='./macos/Flutter/ephemeral' --exclude='./android/local.properties' \
    -cf - . | tar -C "$WORK" -xf -
cd "$WORK"

# ── Build ────────────────────────────────────────────────────────────────────

step "Fetching packages"
flutter pub get

step "Building Linux release"
flutter build linux --release

if [ "$ANDROID" = 1 ]; then
  step "Building Android release APK"
  flutter build apk --release
  mkdir -p "$ROOT/dist"
  cp build/app/outputs/flutter-apk/app-release.apk "$ROOT/dist/redcourier-release.apk"
fi

# ── AppImage ─────────────────────────────────────────────────────────────────

step "Packing AppImage"
APPDIR="$WORK/AppImage/RedCourier/AppDir"
mkdir -p "$APPDIR/usr/bin"
find "$APPDIR/usr/bin" -mindepth 1 ! -name .gitkeep -exec rm -rf {} +
cp -R build/linux/x64/release/bundle/. "$APPDIR/usr/bin/"
chmod +x "$APPDIR/AppRun" "$APPDIR/usr/bin/redcourier"

TMP_APPIMAGE="$WORK/RedCourier-x86_64.AppImage"
rm -f "$TMP_APPIMAGE"
RUNTIME_ARGS=()
if [ -n "${APPIMAGE_RUNTIME:-}" ]; then
  [ -f "$APPIMAGE_RUNTIME" ] || die "AppImage runtime not found: $APPIMAGE_RUNTIME"
  RUNTIME_ARGS=(--runtime-file "$APPIMAGE_RUNTIME")
fi
# Extract-and-run works without FUSE (WSL, containers).
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$APPIMAGETOOL" "${RUNTIME_ARGS[@]}" "$APPDIR" "$TMP_APPIMAGE"

# Only replace the old AppImage once the new one exists.
mv -f "$TMP_APPIMAGE" "$OUT_APPIMAGE"

step "Done"
echo "    AppImage: $OUT_APPIMAGE"
[ "$ANDROID" = 1 ] && echo "    APK:      $ROOT/dist/redcourier-release.apk"
exit 0
