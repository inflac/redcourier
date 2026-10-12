import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:redcourier/core/release_key.dart';
import 'package:redcourier/core/updater.dart';

String spkiPem(List<int> raw) {
  const prefix = [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00];
  return '-----BEGIN PUBLIC KEY-----\n${base64.encode([...prefix, ...raw])}\n-----END PUBLIC KEY-----';
}

/// Stands in for `--appimage-extract`: the "AppImage" is just text here.
Future<Directory> fakeExtract(File appImage, Directory work) async {
  final dir = Directory(p.join(work.path, 'squashfs-root'));
  await dir.create();
  await File(p.join(dir.path, 'AppRun')).writeAsString(await appImage.readAsString());
  return dir;
}

void main() {
  late HttpServer server;
  late Map<String, List<int>> files;
  late Map<String, dynamic> release;
  late SimpleKeyPair key;
  late String pubPem;
  late Directory tmp;

  Future<String> sig(List<int> data, [SimpleKeyPair? with_]) async =>
      base64.encode((await Ed25519().sign(data, keyPair: with_ ?? key)).bytes);

  Updater updater(String current) => Updater(
        currentVersion: current,
        channel: 'http://127.0.0.1:${server.port}/latest',
        clientFactory: () async => HttpClient(),
        publicKeyPem: pubPem,
        platform: UpdatePlatform.linux,
        requireHttps: false,
      );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('rc_upd_');
    key = await Ed25519().newKeyPair();
    pubPem = spkiPem((await key.extractPublicKey()).bytes);
    files = {};
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      if (r.uri.path == '/latest') {
        r.response.write(jsonEncode(release));
      } else if (files.containsKey(r.uri.path)) {
        r.response.add(files[r.uri.path]!);
      } else {
        r.response.statusCode = 404;
      }
      await r.response.close();
    });
    final appImage = utf8.encode('appimage 1.2.0');
    files['/a'] = appImage;
    files['/a.sig'] = utf8.encode(await sig(appImage));
    final base = 'http://127.0.0.1:${server.port}';
    release = {
      'tag_name': 'v1.2.0',
      'assets': [
        {'name': 'redcourier-1.2.0-linux-x86_64.zip', 'browser_download_url': '$base/z.zip'},
        {'name': 'RedCourier-1.2.0-x86_64.AppImage', 'browser_download_url': '$base/a'},
        {'name': 'RedCourier-1.2.0-x86_64.AppImage.sig', 'browser_download_url': '$base/a.sig'},
      ],
    };
  });

  tearDown(() async {
    await server.close(force: true);
    await tmp.delete(recursive: true);
  });

  test('built-in release key equals assets/release_signing_key.pem', () {
    final file = File('assets/release_signing_key.pem').readAsStringSync().trim();
    expect(releasePublicKeyPem.trim(), file);
    expect(Updater.ed25519KeyFromPem(releasePublicKeyPem), hasLength(32));
  });

  test('version comparison', () {
    expect(Updater.compareVersions('v1.10.0', '1.9.2'), 1);
    expect(Updater.compareVersions('1.0.0', '1.0.0+5'), 0);
    expect(Updater.compareVersions('1.0', '1.0.1'), -1);
  });

  test('finds the AppImage of a newer release and verifies it with the published signature', () async {
    final u = updater('1.0.0');
    final info = await u.check();
    expect(info, isNotNull);
    expect(info!.version, '1.2.0');
    expect(info.fileName, 'RedCourier-1.2.0-x86_64.AppImage');
    final file = await u.download(info, Directory(p.join(tmp.path, 'dl')));
    expect(await file.readAsString(), 'appimage 1.2.0');
  });

  test('Windows looks for the signed setup file of the release', () async {
    final setup = utf8.encode('setup 1.2.0');
    files['/s'] = setup;
    files['/s.sig'] = utf8.encode(await sig(setup));
    final base = 'http://127.0.0.1:${server.port}';
    release['assets'] = [
      ...(release['assets'] as List),
      {'name': 'RedCourier-1.2.0-windows-x64-setup.exe', 'browser_download_url': '$base/s'},
      {'name': 'RedCourier-1.2.0-windows-x64-setup.exe.sig', 'browser_download_url': '$base/s.sig'},
    ];
    final u = Updater(
      currentVersion: '1.0.0',
      channel: '$base/latest',
      clientFactory: () async => HttpClient(),
      publicKeyPem: pubPem,
      platform: UpdatePlatform.windows,
      requireHttps: false,
    );
    final info = (await u.check())!;
    expect(info.fileName, 'RedCourier-1.2.0-windows-x64-setup.exe');
    expect(await (await u.download(info, Directory(p.join(tmp.path, 'w')))).readAsString(), 'setup 1.2.0');

    files['/s'] = utf8.encode('setup 1.2.0 with malware');
    await expectLater(u.download(info, Directory(p.join(tmp.path, 'w2'))), throwsA(isA<UpdateException>()));

    expect(Updater.windowsSetupArgs, containsAll(['/VERYSILENT', '/CLOSEAPPLICATIONS']));
  });

  test('Android: APK asset, and self-update only for APKs from GitHub', () {
    final pattern = Updater.assetPattern(UpdatePlatform.android);
    expect(pattern.firstMatch('RedCourier-1.2.0.apk')!.group(1), '1.2.0');
    expect(pattern.hasMatch('RedCourier-1.2.0-x86_64.AppImage'), isFalse);

    const own = 'de.red.redcourier';
    expect(selfUpdateAllowed(null, own), isTrue, reason: 'adb');
    expect(selfUpdateAllowed('com.google.android.packageinstaller', own), isTrue, reason: 'downloaded APK');
    expect(selfUpdateAllowed('com.android.packageinstaller', own), isTrue);
    expect(selfUpdateAllowed(own, own), isTrue, reason: 'updated by itself before');
    expect(selfUpdateAllowed('org.fdroid.fdroid', own), isFalse, reason: 'F-Droid updates it');
    expect(selfUpdateAllowed('com.android.vending', own), isFalse, reason: 'store');
    expect(selfUpdateAllowed('dev.imranr.obtainium', own), isFalse, reason: 'other updater');
  });

  test('a Windows installation is recognized by its uninstaller', () {
    final dir = Directory(p.join(tmp.path, 'RedCourier'))..createSync();
    final exe = p.join(dir.path, 'redcourier.exe');
    expect(windowsInstallDir(exe), isNull, reason: 'copied or self-built: no self-update');
    File(p.join(dir.path, 'unins000.exe')).writeAsStringSync('');
    expect(windowsInstallDir(exe), dir.path);
  });

  test('no update when current or newer', () async {
    expect(await updater('1.2.0').check(), isNull);
    expect(await updater('2.0.0').check(), isNull);
  });

  test('a changed AppImage is rejected and deleted', () async {
    final u = updater('1.0.0');
    final info = (await u.check())!;
    files['/a'] = utf8.encode('appimage 1.2.0 with a backdoor');
    await expectLater(u.download(info, Directory(p.join(tmp.path, 'dl'))), throwsA(isA<UpdateException>()));
    expect(File(p.join(tmp.path, 'dl', info.fileName)).existsSync(), isFalse);
  });

  test('an AppImage signed with another key is rejected', () async {
    files['/a.sig'] = utf8.encode(await sig(files['/a']!, await Ed25519().newKeyPair()));
    final u = updater('1.0.0');
    await expectLater(u.download((await u.check())!, Directory(p.join(tmp.path, 'dl'))),
        throwsA(isA<UpdateException>()));
  });

  test('a damaged or missing signature means no update', () async {
    files['/a.sig'] = utf8.encode('not base64 !!');
    final u = updater('1.0.0');
    await expectLater(u.download((await u.check())!, Directory(p.join(tmp.path, 'dl'))),
        throwsA(isA<UpdateException>()));

    files.remove('/a.sig'); // listed in the release, but the download fails
    await expectLater(u.download((await u.check())!, Directory(p.join(tmp.path, 'dl2'))),
        throwsA(isA<UpdateException>()));

    (release['assets'] as List).removeWhere((a) => (a['name'] as String).endsWith('.sig'));
    await expectLater(u.check(), throwsA(isA<UpdateException>()));
  });

  test('plain http channels are refused outside tests', () async {
    final strict = Updater(
      currentVersion: '1.0.0',
      channel: 'http://127.0.0.1:${server.port}/latest',
      clientFactory: () async => HttpClient(),
      publicKeyPem: pubPem,
      platform: UpdatePlatform.linux,
    );
    await expectLater(strict.check(), throwsA(isA<UpdateException>()));
  });

  group('installing', () {
    late Directory install;
    late File appImage;

    setUp(() async {
      install = Directory(p.join(tmp.path, 'install'));
      await Directory(p.join(install.path, 'app')).create(recursive: true);
      await File(p.join(install.path, 'app', 'AppRun')).writeAsString('old');
      appImage = File(p.join(tmp.path, 'new.AppImage'))..writeAsStringSync('new');
    });

    test('the app folder is swapped; the old one goes on the next start', () async {
      await Updater.install(install.path, appImage, extractor: fakeExtract);
      expect(File(p.join(install.path, 'app', 'AppRun')).readAsStringSync(), 'new');
      final previous = Directory(p.join(install.path, Updater.previousAppFolder));
      expect(File(p.join(previous.path, 'AppRun')).readAsStringSync(), 'old');
      expect(install.listSync().map((e) => p.basename(e.path)).where((n) => n.startsWith('.update-')), isEmpty);

      await Updater.cleanupPrevious(install.path);
      expect(previous.existsSync(), isFalse);

      // A second update works with a leftover previous folder, too.
      await Updater.install(install.path, appImage, extractor: fakeExtract);
      await Updater.install(install.path, appImage, extractor: fakeExtract);
      expect(File(p.join(install.path, 'app', 'AppRun')).readAsStringSync(), 'new');
    });

    test('a broken package leaves the installed version untouched', () async {
      Future<Directory> broken(File f, Directory work) async =>
          Directory(p.join(work.path, 'squashfs-root'))..createSync();
      await expectLater(Updater.install(install.path, appImage, extractor: broken),
          throwsA(isA<UpdateException>()));
      expect(File(p.join(install.path, 'app', 'AppRun')).readAsStringSync(), 'old');

      Future<Directory> failing(File f, Directory work) async => throw UpdateException('x');
      await expectLater(Updater.install(install.path, appImage, extractor: failing),
          throwsA(isA<UpdateException>()));
      expect(File(p.join(install.path, 'app', 'AppRun')).readAsStringSync(), 'old');
    });
  });
}
