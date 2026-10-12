import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:redcourier/core/messages.dart';
import 'package:redcourier/core/updater.dart';
import 'package:redcourier/i18n.dart';
import 'package:redcourier/notifications.dart';
import 'package:redcourier/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;

  setUp(() async => tmp = await Directory.systemTemp.createTemp('rc_misc_'));
  tearDown(() => tmp.delete(recursive: true));

  test('settings survive a restart; a damaged settings file starts empty', () async {
    await Prefs.init(tmp);
    await I18n.load();
    expect(I18n.language.value, 'en', reason: 'English until the user picks another language');
    await Prefs.set('tor_port', 9150);
    await Prefs.set('language', 'de');
    await Prefs.init(tmp);
    expect(Prefs.getInt('tor_port'), 9150);

    await I18n.load();
    expect(I18n.language.value, 'de', reason: 'the saved language wins');
    expect(tr('Cancel'), 'Abbrechen');
    await I18n.set('xx'); // unsupported: ignored
    expect(I18n.language.value, 'de');
    await I18n.set('en');

    File(p.join(tmp.path, 'settings.json')).writeAsStringSync('{ not json');
    await Prefs.init(tmp);
    expect(Prefs.getInt('tor_port'), isNull);
  });

  test('messages and cancellation', () {
    const e = AppException('{n} files', {'n': 3});
    expect(e.toString(), '3 files');
    expect(errorMessage(const FormatException('Invalid URL.')), 'Invalid URL.');
    expect(errorMessage(Exception('boom')), 'boom');

    final token = CancelToken()..cancel();
    var called = 0;
    token.onCancel(() => called++); // registered after cancelling: runs at once
    token.cancel(); // a second cancel does nothing
    expect(called, 1);
    expect(token.throwIfCancelled, throwsA(isA<CancelledException>()));
  });

  test('updater: broken key and a channel that is not a release', () async {
    expect(() => Updater.ed25519KeyFromPem('-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----'),
        throwsA(isA<UpdateException>()));

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      r.response.write(r.uri.path == '/latest' ? '<html>not json</html>' : jsonEncode({}));
      await r.response.close();
    });
    final u = Updater(
      currentVersion: '0.0.1',
      channel: 'http://127.0.0.1:${server.port}/latest',
      clientFactory: () async => HttpClient(),
      platform: UpdatePlatform.windows,
      requireHttps: false,
    );
    await expectLater(u.check(), throwsA(isA<UpdateException>()));
    await server.close(force: true);
  });

  test('notifications without the platform plugin stay silent', () async {
    await Prefs.init(tmp);
    await Notifications.init(); // no native plugin in tests: reported, not thrown
    await Notifications.newDeliveries(2);
    await Notifications.setEnabled(false);
    expect(Notifications.enabled, isFalse);
    await Notifications.setEnabled(true);
    expect(Notifications.enabled, isTrue);
    expect(await Notifications.requestPermission(onlyOnce: true), isTrue);
  });
}
