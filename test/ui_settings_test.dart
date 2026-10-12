import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:redcourier/app_controller.dart';
import 'package:redcourier/core/identity.dart';
import 'package:redcourier/core/tor.dart';
import 'package:redcourier/i18n.dart';
import 'package:redcourier/notifications.dart';

import 'support/fakes.dart';
import 'support/ui.dart';

void main() {
  late Directory tmp;
  late MemDav dav;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('rc_ui_s_');
    dav = MemDav();
  });
  tearDown(() async {
    TorNetwork.configuredPort = null;
    await tmp.delete(recursive: true);
  });

  testWidgets('unlocking, switching groups, settings and deleting a group', (t) async {
    await prepare(t, tmp);
    final c = testController(dav, tmp);
    await t.runAsync(() async {
      await c.init(tmp);
      await c.addGroup('Work', 'alice', 'correct horse');
      await c.createGroup(WebDavConfig('https://cloud.example/dav/work/', 'u', 'p'));
      c.startAddingGroup();
      await c.addGroup('Family', 'ally', 'other horse');
      await c.createGroup(WebDavConfig('https://cloud.example/dav/family/', 'u', 'p'));
      c.lock();
      c.selectGroup('Work');
    });
    await pumpApp(t, c, tmp, init: false);
    expect(c.phase, AppPhase.locked);

    // Unlock screen: wrong password, default group, switching group.
    await enter(t, 'Password', 'nope');
    await tapText(t, 'Unlock');
    await waitFor(t, find.text('Wrong password.'));
    await tapText(t, 'Open this group at start');
    expect(c.defaultGroup, 'Work');
    await t.tap(find.text('Work').first);
    await t.pumpAndSettle();
    await t.tap(find.text('Family').last);
    await t.pumpAndSettle();
    expect(c.groupName, 'Family');
    await t.tap(find.byTooltip('Add group'));
    await t.pumpAndSettle();
    expect(find.text('Add group'), findsWidgets);
    await t.tap(find.byTooltip('Cancel'));
    await t.pumpAndSettle();
    await enter(t, 'Password', 'other horse');
    await tapText(t, 'Unlock');
    await waitFor(t, find.text('Inbox'));

    // Settings.
    await t.tap(find.byTooltip('Settings'));
    await t.pumpAndSettle();
    for (final mode in ['Dark', 'Light', 'System']) {
      await tapText(t, mode);
      await idle(t);
    }
    await t.tap(find.text('English'));
    await t.pumpAndSettle();
    await t.tap(find.text('Deutsch').last);
    await idle(t);
    expect(I18n.language.value, 'de');
    await t.pumpAndSettle();
    expect(find.text('Einstellungen'), findsOneWidget);
    await t.tap(find.text('Deutsch').first);
    await t.pumpAndSettle();
    await t.tap(find.text('English').last);
    await idle(t);
    expect(I18n.language.value, 'en');

    final notify = Notifications.enabled;
    await tapText(t, 'Notify about new deliveries');
    await idle(t);
    expect(Notifications.enabled, !notify);

    await tapText(t, 'Find Tor automatically');
    await idle(t);
    await enter(t, 'Tor SOCKS port on 127.0.0.1', '99999');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await waitFor(t, find.text('Please enter a port between 1 and 65535.'));
    await enter(t, 'Tor SOCKS port on 127.0.0.1', '1');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await idle(t);
    expect(TorNetwork.configuredPort, 1);
    await tapText(t, 'Test Tor connection');
    await waitFor(t, find.textContaining('Tor is not reachable'));
    await tapText(t, 'Find Tor automatically');
    await idle(t);
    expect(TorNetwork.configuredPort, isNull);

    // Admin: publish new WebDAV credentials.
    await tapText(t, 'Publish new WebDAV credentials');
    await t.pumpAndSettle();
    await tapText(t, 'Publish');
    await waitFor(t, find.text('Username and password are required.'));
    await tapText(t, 'Publish new WebDAV credentials');
    await t.pumpAndSettle();
    await enter(t, 'New app password', 'new-secret');
    await tapText(t, 'Publish');
    await waitFor(t, find.textContaining('Members receive the new credentials'));
    expect(c.session!.local.webdav.password, 'new-secret');

    // Downloads, locking, switching.
    await tapText(t, 'Delete downloaded files');
    await t.pumpAndSettle();
    await tapText(t, 'Delete');
    await waitFor(t, find.text('Downloads deleted.'));
    await tapText(t, 'Switch group');
    await waitFor(t, find.text('Unlock'));
    expect(c.phase, AppPhase.locked);

    await enter(t, 'Password', 'other horse');
    await tapText(t, 'Unlock');
    await waitFor(t, find.text('Inbox'));
    await t.tap(find.byTooltip('Settings'));
    await t.pumpAndSettle();
    await tapText(t, 'Lock now');
    await waitFor(t, find.text('Unlock'));

    // Forgot the password: delete the group from this device.
    await tapText(t, 'Forgot password? Delete this group from this device');
    await t.pumpAndSettle();
    await tapText(t, 'Delete');
    await waitFor(t, find.text('Work'));
    await idle(t);
    expect(c.groups, ['Work']);

    // Delete the last group from the settings.
    await enter(t, 'Password', 'correct horse');
    await tapText(t, 'Unlock');
    await waitFor(t, find.text('Inbox'));
    await t.tap(find.byTooltip('Settings'));
    await t.pumpAndSettle();
    await tapText(t, 'Delete this group from this device');
    await t.pumpAndSettle();
    await tapText(t, 'Delete');
    await waitFor(t, find.text('Welcome to RedCourier'));
    expect(c.groups, isEmpty);

    await unmount(t);
  }, variant: desktop);
}
