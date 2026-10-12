import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'crypto_util.dart';
import 'messages.dart';
import 'release_key.dart';

/// Self-update for installed versions, the same way CalSec updates itself:
///
///  1. ask the release channel (GitHub Releases API or a compatible URL) for
///     the latest release,
///  2. download the file for this platform and its `.sig` from that release
///     through Tor:
///     - Tails/Linux: `RedCourier-<version>-x86_64.AppImage`
///     - Windows: `RedCourier-<version>-windows-x64-setup.exe`
///     - Android: `RedCourier-<version>.apk`
///  3. verify the Ed25519 signature over the downloaded file with the release
///     key built into this app (fail closed: no signature, a damaged or a
///     wrong one means no update),
///  4. install it:
///     - Linux: unpack the AppImage next to the installed copy (Tails has no
///       FUSE, so the app runs unpacked) and swap the `app` folder, then
///       start the new version;
///     - Windows: run the verified installer silently. It replaces the
///       program (per user, no administrator rights) and starts it again,
///     - Android: hand the verified APK to the system installer, which checks
///       that it is signed with the same key and asks the user to confirm.
///       Only for APKs from GitHub; F-Droid and stores update the app
///       themselves (see [selfUpdateAllowed]),
///  5. exit (desktop) or wait for the user (Android).

const officialUpdateChannel = 'https://api.github.com/repos/inflac/redcourier/releases/latest';

class UpdateException extends AppException {
  UpdateException(super.template, [super.args]);
}

class UpdateInfo {
  final String version;
  final String fileName;
  final Uri fileUrl;
  final Uri sigUrl;
  UpdateInfo(this.version, this.fileName, this.fileUrl, this.sigUrl);
}

/// Unpacks an AppImage into a folder and returns the unpacked app folder.
typedef AppImageExtractor = Future<Directory> Function(File appImage, Directory work);

/// The kinds of installation that can update themselves.
enum UpdatePlatform { linux, windows, android }

UpdatePlatform? get currentUpdatePlatform => Platform.isLinux
    ? UpdatePlatform.linux
    : Platform.isWindows
        ? UpdatePlatform.windows
        : Platform.isAndroid
            ? UpdatePlatform.android
            : null;

/// Android: the app may update itself only if it was installed from a
/// downloaded APK (system package installer, adb, or an earlier in-app
/// update). Installs from F-Droid or a store are updated by those.
bool selfUpdateAllowed(String? installerPackage, String ownPackage) =>
    installerPackage == null ||
    installerPackage == ownPackage ||
    const {
      'com.android.packageinstaller',
      'com.google.android.packageinstaller',
      'com.android.shell',
    }.contains(installerPackage);

/// Where the app was installed, or null if it was not installed by one of
/// our installers (then self-update is not available, like CalSec outside
/// frozen builds).
String? installedDir() {
  if (Platform.isWindows) return windowsInstallDir(Platform.resolvedExecutable);
  if (!Platform.isLinux) return null;
  final dir = Platform.environment['REDCOURIER_INSTALL_DIR'];
  if (dir == null || dir.isEmpty) return null;
  if (!File(p.join(dir, 'app', 'AppRun')).existsSync()) return null;
  return dir;
}

/// The Windows installer (Inno Setup) puts its uninstaller next to the
/// program; a copied or self-built program has none and is not updated.
String? windowsInstallDir(String executable) {
  final dir = p.dirname(executable);
  return File(p.join(dir, 'unins000.exe')).existsSync() ? dir : null;
}

class Updater {
  static const maxDownloadBytes = 1024 * 1024 * 1024;

  /// Release file names per platform; group 1 is the version.
  static RegExp assetPattern(UpdatePlatform platform) => switch (platform) {
        UpdatePlatform.linux => RegExp(r'^RedCourier-(\d+(?:\.\d+)*)-x86_64\.AppImage$'),
        UpdatePlatform.windows => RegExp(r'^RedCourier-(\d+(?:\.\d+)*)-windows-x64-setup\.exe$'),
        UpdatePlatform.android => RegExp(r'^RedCourier-(\d+(?:\.\d+)*)\.apk$'),
      };

  final String currentVersion;
  final String channel;
  final Future<HttpClient> Function() clientFactory;
  final Uint8List publicKey;

  /// Which release file to look for.
  final UpdatePlatform platform;

  /// Only tests turn this off to talk to a local plain-HTTP server.
  final bool requireHttps;

  Updater({
    required this.currentVersion,
    required this.clientFactory,
    String? channel,
    String publicKeyPem = releasePublicKeyPem,
    UpdatePlatform? platform,
    this.requireHttps = true,
  })  : platform = platform ?? currentUpdatePlatform ?? UpdatePlatform.linux,
        channel =
            (channel == null || channel.isEmpty || channel == 'official') ? officialUpdateChannel : channel,
        publicKey = ed25519KeyFromPem(publicKeyPem);

  /// Raw 32-byte key from a SubjectPublicKeyInfo PEM of an Ed25519 key.
  static Uint8List ed25519KeyFromPem(String pem) {
    final body = pem.split('\n').where((l) => !l.startsWith('-----')).join().replaceAll(RegExp(r'\s'), '');
    final der = base64.decode(body);
    const prefix = [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00];
    if (der.length != 44 || !List.generate(12, (i) => der[i] == prefix[i]).every((x) => x)) {
      throw UpdateException('The release key is not an Ed25519 public key.');
    }
    return Uint8List.fromList(der.sublist(12));
  }

  /// Compares dotted version numbers ("v1.10.0" > "1.9.2").
  static int compareVersions(String a, String b) {
    List<int> parts(String v) => v
        .replaceFirst(RegExp(r'^v'), '')
        .split('+')
        .first
        .split('.')
        .map((x) => int.tryParse(x) ?? 0)
        .toList();
    final x = parts(a), y = parts(b);
    for (var i = 0; i < x.length || i < y.length; i++) {
      final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
      if (d != 0) return d.sign;
    }
    return 0;
  }

  Future<HttpClientResponse> _get(HttpClient c, Uri uri, {bool json = false}) async {
    if (requireHttps && uri.scheme != 'https' && !(uri.host.endsWith('.onion') && uri.scheme == 'http')) {
      throw UpdateException('Update URLs must use https.');
    }
    final req = await c.getUrl(uri);
    req.headers.set(HttpHeaders.userAgentHeader, 'redcourier-updater/$currentVersion');
    if (json) req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    final res = await req.close().timeout(const Duration(seconds: 120));
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw UpdateException('The update server answered with {status}.', {'status': res.statusCode});
    }
    return res;
  }

  /// Returns the newer release, or null if this version is current.
  Future<UpdateInfo?> check() async {
    final c = await clientFactory();
    try {
      final res = await _get(c, Uri.parse(channel), json: true);
      final Map<String, dynamic> data;
      try {
        data = jsonDecode(await utf8.decodeStream(res)) as Map<String, dynamic>;
      } catch (_) {
        throw UpdateException('The update channel did not return a release.');
      }
      final tag = data['tag_name'] as String? ?? '';
      if (compareVersions(tag, currentVersion) <= 0) return null;

      final assets = (data['assets'] as List? ?? const [])
          .whereType<Map>()
          .map((a) => (a['name'] as String? ?? '', a['browser_download_url'] as String? ?? ''))
          .toList();
      for (final (name, url) in assets) {
        final m = assetPattern(platform).firstMatch(name);
        if (m == null || compareVersions(m.group(1)!, tag) != 0) continue;
        final sig = assets.where((a) => a.$1 == '$name.sig').map((a) => a.$2).firstOrNull;
        if (sig == null) {
          throw UpdateException('The release has no signature. The update was not installed.');
        }
        return UpdateInfo(m.group(1)!, name, Uri.parse(url), Uri.parse(sig));
      }
      return null;
    } finally {
      c.close(force: true);
    }
  }

  /// Downloads the AppImage and its signature from the release into [work]
  /// and verifies the signature with the built-in release key. Returns the
  /// verified file; on any problem nothing is kept.
  Future<File> download(UpdateInfo info, Directory work, {void Function(double)? onProgress}) async {
    await work.create(recursive: true);
    final file = File(p.join(work.path, info.fileName));
    final c = await clientFactory();
    try {
      final sigRes = await _get(c, info.sigUrl);
      final sigText = (await utf8.decodeStream(sigRes)).trim();
      final Uint8List signature;
      try {
        signature = base64.decode(sigText);
      } on FormatException {
        throw UpdateException('The release signature is damaged.');
      }
      if (signature.length != 64) throw UpdateException('The release signature is damaged.');

      final res = await _get(c, info.fileUrl);
      final total = res.contentLength;
      final sink = file.openWrite();
      var received = 0;
      try {
        await for (final chunk in res) {
          received += chunk.length;
          if (received > maxDownloadBytes) throw UpdateException('The download is too large.');
          sink.add(chunk);
          if (total > 0) onProgress?.call(received / total);
        }
      } finally {
        await sink.close();
      }

      if (!await verifyFile(file, signature)) {
        await file.delete();
        throw UpdateException('The signature of the update is invalid. It was not installed.');
      }
      return file;
    } catch (_) {
      if (await file.exists()) await file.delete();
      rethrow;
    } finally {
      c.close(force: true);
    }
  }

  Future<bool> verifyFile(File file, List<int> signature) async =>
      verify(b64e(publicKey), b64e(signature), await file.readAsBytes());

  /// Unpacks a verified AppImage with its own `--appimage-extract` (Tails
  /// has no FUSE). Only called after [download] checked the signature.
  static Future<Directory> extractAppImage(File appImage, Directory work) async {
    final chmod = await Process.run('chmod', ['755', appImage.path]);
    if (chmod.exitCode != 0) throw UpdateException('The update could not be unpacked.');
    final r = await Process.run(appImage.path, ['--appimage-extract'], workingDirectory: work.path);
    if (r.exitCode != 0) throw UpdateException('The update could not be unpacked.');
    return Directory(p.join(work.path, 'squashfs-root'));
  }

  /// Unpacks [appImage] inside [installDir] and replaces the `app` folder.
  /// The running process keeps its files open; the new version takes effect
  /// on restart. If anything fails, the installed version stays.
  static Future<void> install(String installDir, File appImage,
      {AppImageExtractor extractor = extractAppImage}) async {
    // Unpack on the same file system as the installation, so the folders can
    // be swapped by renaming (on Tails /tmp is in memory).
    final work = await Directory(installDir).createTemp('.update-');
    try {
      final unpacked = await extractor(appImage, work);
      if (!await File(p.join(unpacked.path, 'AppRun')).exists()) {
        throw UpdateException('The update package is incomplete.');
      }
      final app = Directory(p.join(installDir, 'app'));
      // The running version may still read files from its folder, so it is
      // only deleted on the next start (cleanupPrevious).
      final old = Directory(p.join(installDir, previousAppFolder));
      if (await old.exists()) await old.delete(recursive: true);
      await app.rename(old.path);
      try {
        await unpacked.rename(app.path);
      } catch (_) {
        await old.rename(app.path);
        throw UpdateException('The update could not be installed. The installed version was kept.');
      }
    } finally {
      try {
        await work.delete(recursive: true);
      } catch (_) {}
    }
  }

  static const previousAppFolder = '.app-previous';

  /// Deletes the app folder replaced by the last update.
  static Future<void> cleanupPrevious(String installDir) async {
    try {
      final old = Directory(p.join(installDir, previousAppFolder));
      if (await old.exists()) await old.delete(recursive: true);
    } catch (_) {}
  }

  /// Options for a silent update with the Inno Setup installer: no wizard,
  /// no message boxes, close a running RedCourier. The installer starts the
  /// app again when it is done (see windows/installer/redcourier.iss).
  static const windowsSetupArgs = ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS'];

  /// Runs the verified Windows installer and ends this process, so the
  /// installer can replace the program files.
  static Future<Never> runWindowsSetup(File setup) async {
    await Process.start(setup.path, windowsSetupArgs, mode: ProcessStartMode.detached);
    exit(0);
  }

  /// Starts the updated app and ends this process.
  static Future<Never> restart(String installDir) async {
    await Process.start(p.join(installDir, 'app', 'AppRun'), const [], mode: ProcessStartMode.detached);
    exit(0);
  }
}
