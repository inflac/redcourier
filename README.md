# RedCourier

End-to-end encrypted file delivery for small groups. No own server is needed:

- a shared WebDAV folder (for example on Nextcloud) holds one signed and
  encrypted `sync.json` with the members and the links of every delivery,
- the files themselves are encrypted, split into ZIP parts and uploaded to
  public file sharing services (filebin.net, temp.sh, litterbox, and termbin
  for very small deliveries),
- all traffic goes through Tor.

- Choose one or more recipients by their identifier and send files with a note.
- Recipients see new deliveries with sender and size the next time they open the
  app, and download them with one tap. While a group is unlocked, the app syncs
  every 10 minutes and can show a notification (without sender or group name).
- Uploads and downloads can be stopped. A stopped or broken download keeps its
  finished parts and resumes with the first missing one.
- Large deliveries are split into several ZIP parts and spread over the file
  hosts. If a host fails, the next one is tried.
- Deliveries expire automatically (after at most about six days, depending on
  the hosts).
- Admins add and remove members. Removing someone rotates the group keys.
- Keys are exchanged with hybrid X25519 + ML-KEM-768 (post-quantum).
- Several groups on one device, for example "Work" and "Family". Each group
  has its own identity, password, WebDAV folder, sync file and Tor circuits.
- English and German, selectable in the settings.
- Runs on Android, Windows and Linux (including Tails). iOS, macOS and the web
  are not supported.

How it works and what it protects against is described in
[WHITEPAPER.md](WHITEPAPER.md).

## Install on Tails

1. Enable the Persistent Storage with the **Dotfiles** feature.
2. Verify the zip as described [below](#verify-the-download).
3. Unpack `redcourier-<version>-linux-x86_64.zip` into `~/Persistent`.
4. Open a terminal in the unpacked folder and run:

   ```bash
   ./install_redcourier.sh
   ```

5. Start RedCourier from the Applications menu.

The installer unpacks the app to `~/Persistent/programs/redcourier` and keeps
your groups and keys in `~/Persistent/programs/redcourier/data`, so they
survive reboots. It asks whether received files should also be kept; by
default they go to `~/Tor Browser` and are gone after a reboot.

To **update**, unpack the new package and run the *installed* installer with
the new folder. It checks the new package against the release key stored on
your device, so the new package's own installer does not have to be trusted:

```bash
~/Persistent/programs/redcourier/install_redcourier.sh ~/Persistent/redcourier-<version>-linux-x86_64
```

Run `~/Persistent/programs/redcourier/install_redcourier.sh` without an
argument to uninstall.

### Automatic updates

Like CalSec, RedCourier can update itself. In *Settings → Updates* (only
shown for versions installed with the installer):

- **Check for updates at start**, off by default.
- **Install automatically** checks at start and installs a new version before
  you unlock. **Only notify** checks in the background and shows a banner with
  an *Install now* button.
- **Channel**: the official GitHub releases or a custom URL that returns the
  same release JSON.

Like CalSec, the app replaces itself: it downloads the new
`RedCourier-<version>-x86_64.AppImage` and its `.sig` from the release through
Tor and checks the signature with the release key built into the app. Without
a valid signature nothing is installed. It then unpacks the new version next
to the installed one, swaps the `app` folder and restarts. The previous
version is deleted on the next start.

> [!IMPORTANT]
> Start RedCourier from the menu entry. It needs the entry's settings to store
> its data in the Persistent Storage. The app talks to Tor's SOCKS port itself;
> starting it with `torsocks` also works, but then all groups share circuits.

### Verify the download

Every release is signed with the RedCourier release key (Ed25519). The
installer checks the signature itself and shows the key's fingerprint on the
first installation. Compare it with the fingerprint below or in
[WHITEPAPER.md](WHITEPAPER.md#release-integrity).

For the **first** installation, check the zip yourself before unpacking it.
A forged package could contain an installer that skips all checks; only a
check with the published key, done before running anything from the package,
catches that.

<!-- release-key -->

To check the zip before unpacking it, save the release public key as
`release_signing_key.pem` and run:

```bash
base64 -d redcourier-<version>-linux-x86_64.zip.sig > zip.sig.bin
openssl pkeyutl -verify -pubin -inkey release_signing_key.pem -rawin \
  -in redcourier-<version>-linux-x86_64.zip -sigfile zip.sig.bin
```

`Signature Verified Successfully` means the zip is exactly what the developers
published.

> [!WARNING]
> Updates must be signed with the same key. If the installer reports a
> different key, stop and confirm the new fingerprint through a channel you
> trust before continuing.

## Getting started

RedCourier needs a running Tor: Tails provides it, on Windows start Tor
Browser or the Tor service, on Android start Orbot.

### Making sure nothing bypasses Tor

The app itself refuses every connection that does not go to Tor's SOCKS port
(see the whitepaper). As a second, independent layer, let the operating
system enforce it too:

- **Tails:** nothing to do. The Tails firewall only lets Tor out.
- **Android:** in Orbot, enable the VPN mode and select RedCourier as a
  Tor-enabled app. Then in Android *Settings → Network → VPN → Orbot (gear)*
  switch on *Always-on VPN* and *Block connections without VPN*. Android then
  drops anything that does not go through Tor, even if the app had a bug.
- **Windows:** block all outgoing traffic of RedCourier except to the local
  computer (where Tor runs). In an administrator PowerShell, with the path of
  your `redcourier.exe`:

  ```powershell
  $exe = "C:\Path\To\RedCourier\redcourier.exe"
  New-NetFirewallRule -DisplayName "RedCourier: only through Tor" -Direction Outbound `
    -Program $exe -Action Block `
    -RemoteAddress "0.0.0.0-126.255.255.255","128.0.0.0-255.255.255.255","::2-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"
  ```

  The rule leaves out only 127.0.0.0/8 and ::1, so RedCourier can still
  reach Tor on 127.0.0.1 but nothing else. Tor itself (Tor Browser or the Tor
  service) is a different program and is not affected. Remove the rule with
  `Remove-NetFirewallRule -DisplayName "RedCourier: only through Tor"`.

### Admin, once per group

1. Create an empty folder on your Nextcloud and an app password. The folder
   only ever holds `sync.json`; the files go to the file sharing services.
2. In RedCourier, name the group and enter your identifier and a password, then choose
   *Start a new group as admin* and
   enter the WebDAV folder URL, for example
   `https://cloud.example.com/remote.php/dav/files/USER/redcourier/`.

### New member

1. Name the group, enter your identifier and a password, and send your join request to an admin.
2. The admin adds you under *Members* and sends you two things over **two
   different channels**:
   - the invite (`RCINVITE2:…`, WebDAV access), for example over a messenger,
   - the group fingerprint, for example by e-mail. In the Android app you can
     instead scan the fingerprint's QR code from the admin's screen.
3. Paste (or scan) the invite, enter the fingerprint and choose *Join group*.
   The app refuses to join if the group does not match the fingerprint.

## Development

```bash
flutter pub get
flutter test        # crypto, sync logic, Tor (SOCKS) and translations
flutter run
```

### Linux AppImage and Tails package (Linux or WSL)

```bash
./setup_linux.sh    # once: build tools, pandoc, zip and a Linux Flutter in ~/flutter
./build.sh          # builds AppImage/RedCourier-x86_64.AppImage
RELEASE_SIGNING_KEY_FILE=~/keys/redcourier_release.pem ./package.sh
                    # builds, packages and signs dist/redcourier-<version>-linux-x86_64.zip
```

The zip contains the AppImage, the Tails installer, the icon, this README and
the whitepaper as HTML, the public release key, `SHA256SUMS` and its signature
`SHA256SUMS.sig`. The zip itself is signed as `<zip>.sig`.

- The private key never goes into the repository. Pass it with
  `RELEASE_SIGNING_KEY_FILE` or, in CI, as the secret `RELEASE_SIGNING_KEY`.
- It must match `assets/release_signing_key.pem`, the only place the public
  key lives. `package.sh` writes it into the installer and the documentation.
- `./package.sh --skip-build` packages an existing AppImage,
  `./package.sh --unsigned` builds a test package that is marked as unsigned.

In WSL, never run the Windows Flutter SDK from Linux: it replaces the SDK's
Dart with a Linux build and breaks Flutter on Windows. `build.sh` refuses to
do that and builds in a copy under `~/.cache/redcourier-build`.

### Releases (GitHub Actions)

Pushing a version tag that matches `version:` in `pubspec.yaml` builds and
publishes a release (`.github/workflows/release.yml`):

```bash
git tag v1.0.0 && git push origin v1.0.0
```

The workflow runs the tests, then builds on GitHub's machines:

| Platform | Files in the release |
| --- | --- |
| Linux / Tails | `redcourier-<version>-linux-x86_64.zip` (+ `.sig`), `RedCourier-<version>-x86_64.AppImage` (+ `.sig`, for the in-app updater) |
| Android | `RedCourier-<version>.apk` (+ `.sig`) |
| Windows | `RedCourier-<version>-windows-x64.zip` (+ `.sig`) |

plus `SHA256SUMS.txt`. The release is only created when every platform
built. `appimagetool` and the AppImage runtime are pinned by version and
SHA-256.

Repository **secrets** (Settings → Secrets and variables → Actions →
*Secrets*, not *Variables*: variables are stored in plain text):

| Secret | Content |
| --- | --- |
| `RELEASE_SIGNING_KEY` | the Ed25519 release private key (PEM) |
| `RELEASE_SIGNING_KEY_PASSWORD` | only if that key is encrypted |
| `ANDROID_KEYSTORE_BASE64` | `base64 -w0 redcourier-android.jks` |
| `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` | as in `key.properties` |

`scripts/sign_files.sh` signs single files the same way as `package.sh`.

### Android release key (GitHub, F-Droid)

RedCourier is published on GitHub (and possibly F-Droid), not in the Play
Store. Android installs an update only if it is signed with the same key as
the installed app, so create one release key and keep it (with a backup)
for as long as the app exists:

```bash
keytool -genkeypair -v -keystore ~/keys/redcourier-android.jks \
  -alias redcourier -keyalg RSA -keysize 4096 -validity 36500
```

Then create `android/key.properties` (ignored by git):

```properties
storeFile=/home/USER/keys/redcourier-android.jks
storePassword=...
keyAlias=redcourier
keyPassword=...
```

`flutter build apk --release` then signs with this key. Without the file the
APK is signed with the local debug key and Gradle prints a warning; such an
APK is only for testing.

F-Droid builds the app from source and normally signs it with its own key.
An APK from F-Droid and one from GitHub can then not update each other; a
user has to uninstall first (and lose the local data). The Google-signed
dependency list that F-Droid rejects is switched off in `build.gradle`.

The core logic lives in `lib/core/` and has no Flutter dependency. The tests use
an in-memory WebDAV backend.

Building for Windows needs Developer Mode, because Flutter links plugins with
symlinks, and the **C++ ATL** component of the Visual Studio Build Tools (for
the notification plugin). Add it in the Visual Studio Installer under
*Modify → Individual components → "C++ ATL for latest v143 build tools (x86 &
x64)"*, or in an administrator PowerShell:

```powershell
& "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vs_installer.exe" modify `
  --installPath "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools" `
  --add Microsoft.VisualStudio.Component.VC.ATL --passive --norestart
```

The launcher icons are generated from `assets/icon/` with
`dart run flutter_launcher_icons`. German texts live in `lib/i18n_de.dart`; a
test fails if a text is missing.
