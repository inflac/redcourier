import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redcourier/core/updater.dart';
import 'package:redcourier/logger.dart';
import 'package:redcourier/main.dart';
import 'package:redcourier/theme.dart';
import 'package:redcourier/ui/update_ui.dart';
import 'package:redcourier/ui/widgets.dart';

import 'support/ui.dart';

/// Widget tests replace HttpClient with a stub; the local release server
/// needs the real one.
class RealHttp extends HttpOverrides {}

HttpClient realClient() => HttpOverrides.runWithHttpOverrides(HttpClient.new, RealHttp());

Widget host(Widget child) => MaterialApp(
      theme: buildAppTheme(Brightness.light),
      scaffoldMessengerKey: scaffoldMessengerKey,
      navigatorKey: navigatorKey,
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('rc_ui_w_'));
  tearDown(() async {
    // A settings write may still be finishing; Windows locks the file meanwhile.
    for (var i = 0; i < 20; i++) {
      try {
        return await tmp.delete(recursive: true);
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  testWidgets('on phones, secret fields use the built-in keyboard', (t) async {
    await prepare(t, tmp);
    final controller = TextEditingController();
    await t.pumpWidget(host(SecureTextField(controller: controller, label: 'Secret', obscure: true)));
    await t.tap(find.byType(TextField));
    await t.pumpAndSettle();

    for (final key in ['a', 'b', '1']) {
      await t.tap(find.text(key));
    }
    await t.tap(find.text('Shift'));
    await t.pump();
    await t.tap(find.text('Q'));
    await t.tap(find.text('Sym'));
    await t.pump();
    await t.tap(find.text('@'));
    await t.tap(find.text('Sym'));
    await t.pump();
    expect(controller.text, 'ab1Q@');
    expect(find.text('•••••'), findsOneWidget, reason: 'obscured in the preview');

    await t.tap(find.byIcon(Icons.backspace));
    expect(controller.text, 'ab1Q');

    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': 'XYZ'};
      return null;
    });
    await t.tap(find.text('Paste'));
    await t.pump();
    expect(controller.text, 'ab1QXYZ');
    await t.tap(find.text('C'));
    expect(controller.text, isEmpty);
    await t.tap(find.text('Done'));
    await t.pumpAndSettle();
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('helpers format sizes, times and confirmations', (t) async {
    expect(formatSize(500), '500 B');
    expect(formatSize(1536), '1.5 KB');
    expect(formatSize(300 * 1024 * 1024), '300 MB');
    expect(formatRemaining(DateTime.now().subtract(const Duration(minutes: 1))), 'expired');
    expect(formatRemaining(DateTime.now().add(const Duration(minutes: 30))), contains('min'));
    expect(formatRemaining(DateTime.now().add(const Duration(hours: 5))), contains('h'));
    expect(formatRemaining(DateTime.now().add(const Duration(days: 1, hours: 2))), 'expires in 1 day');
    expect(formatRemaining(DateTime.now().add(const Duration(days: 3, hours: 2))), 'expires in 3 days');

    AppLogger.init(isEnabled: true);
    AppLogger.debug('d', 1);
    AppLogger.info('i', 2);
    AppLogger.warn('w', 3);
    AppLogger.error('e', StateError('x'), StackTrace.current);
    AppLogger.init(isEnabled: false);
    AppLogger.info('silent');

    late bool answer;
    await t.pumpWidget(host(Builder(
        builder: (context) => TextButton(
            onPressed: () async => answer = await confirm(context, 'Sure?', 'Really?', danger: true),
            child: const Text('ask')))));
    await t.tap(find.text('ask'));
    await t.pumpAndSettle();
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(answer, isFalse);
    await t.tap(find.text('ask'));
    await t.pumpAndSettle();
    await t.tap(find.text('OK'));
    await t.pumpAndSettle();
    expect(answer, isTrue);
  });

  group('update dialog', () {
    late HttpServer server;
    late Map<String, dynamic> release;
    late SimpleKeyPair key;

    setUp(() async {
      key = await Ed25519().newKeyPair();
      final pub = (await key.extractPublicKey()).bytes;
      const prefix = [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00];
      final pem = '-----BEGIN PUBLIC KEY-----\n${base64.encode([...prefix, ...pub])}\n-----END PUBLIC KEY-----';
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((r) async {
        if (r.uri.path == '/latest') {
          r.response.write(jsonEncode(release));
        } else if (r.uri.path == '/a') {
          r.response.write('appimage');
        } else if (r.uri.path == '/a.sig') {
          r.response.write('not a signature');
        } else {
          r.response.statusCode = 404;
        }
        await r.response.close();
      });
      final base = 'http://127.0.0.1:${server.port}';
      release = {'tag_name': 'v0.0.1', 'assets': []};
      updaterFactory = () async => Updater(
            currentVersion: '0.0.1',
            channel: '$base/latest',
            clientFactory: () async => realClient(),
            publicKeyPem: pem,
            requireHttps: false,
          );
      updateInstallDir = tmp.path;
    });

    tearDown(() async {
      updateInstallDir = installedDir();
      pendingUpdate.value = null;
      await server.close(force: true);
    });

    Future<void> open(WidgetTester t) async {
      await t.pumpWidget(host(Builder(
          builder: (context) =>
              TextButton(onPressed: () => showUpdateDialog(context), child: const Text('check')))));
      await t.tap(find.text('check'));
      await t.pump();
    }

    testWidgets('reports "up to date"', (t) async {
      await prepare(t, tmp);
      await open(t);
      await waitFor(t, find.text('RedCourier is up to date.'));
      await tapText(t, 'OK');
      await t.pumpAndSettle();
    });

    testWidgets('a release with a bad signature is not installed', (t) async {
      await prepare(t, tmp);
      final base = 'http://127.0.0.1:${server.port}';
      release = {
        'tag_name': 'v0.0.2',
        'assets': [
          {'name': 'RedCourier-0.0.2-x86_64.AppImage', 'browser_download_url': '$base/a'},
          {'name': 'RedCourier-0.0.2-x86_64.AppImage.sig', 'browser_download_url': '$base/a.sig'},
        ],
      };
      // The banner of the "notify" mode leads to the same dialog.
      pendingUpdate.value = await t.runAsync<UpdateInfo?>(() async => (await updaterFactory()).check());
      await t.pumpWidget(host(const UpdateBanner()));
      expect(find.text('Update 0.0.2 is available.'), findsOneWidget);
      await tapText(t, 'Install now');
      await waitFor(t, find.textContaining('Update failed'));
      expect(find.textContaining('signature'), findsOneWidget);
      await tapText(t, 'Close');
      await t.pumpAndSettle();
      await tapText(t, 'Later');
      expect(pendingUpdate.value, isNull);
    });

    testWidgets('the settings card stores the update options', (t) async {
      await prepare(t, tmp);
      await t.pumpWidget(host(SingleChildScrollView(
          child: UpdateSettingsCard(
              card: ({required title, required icon, required children}) =>
                  Column(children: [Text(title), ...children])))));
      Future<void> until(bool Function() ok) async {
        for (var i = 0; i < 100 && !ok(); i++) {
          await idle(t);
        }
        expect(ok(), isTrue);
      }

      await tapText(t, 'Check for updates at start');
      await waitFor(t, find.text('Only notify'));
      expect(UpdatePrefs.enabled, isTrue);
      await tapText(t, 'Only notify');
      await until(() => UpdatePrefs.mode == 'notify');
      await tapText(t, 'Install automatically');
      await until(() => UpdatePrefs.mode == 'auto');
      await tapText(t, 'Custom channel');
      await waitFor(t, find.byType(TextField));
      await t.enterText(find.byType(TextField), 'https://example.org/latest');
      await until(() => UpdatePrefs.channel == 'https://example.org/latest');
      await tapText(t, 'Official releases (GitHub)');
      await until(() => UpdatePrefs.channel == 'official');
    });
  });
}
