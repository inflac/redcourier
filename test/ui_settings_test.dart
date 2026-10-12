import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:redcourier/app_controller.dart';
import 'package:redcourier/core/identity.dart';
import 'package:redcourier/core/remote.dart';
import 'package:redcourier/core/tor.dart';
import 'package:redcourier/core/updater.dart';
import 'package:redcourier/i18n.dart';
import 'package:redcourier/notifications.dart';
import 'package:redcourier/ui/update_ui.dart';

import 'support/fakes.dart';
import 'support/ui.dart';

/// A WebDAV folder that only accepts the current app password.
class PasswordStore implements RemoteStore {
  final WebDavConfig Function() config;
  final MemoryStore backing;
  final String Function() password;
  PasswordStore(this.config, this.backing, this.password);

  void _login() {
    if (config().password != password()) {
      throw RemoteException('WebDAV login failed (401). Check username and password.');
    }
  }

  @override
  Future<RemoteFile?> getSync() async {
    _login();
    return backing.getSync();
  }

  @override
  Future<void> putSync(Uint8List bytes, {String? ifMatch, bool createOnly = false}) async {
    _login();
    return backing.putSync(bytes, ifMatch: ifMatch, createOnly: createOnly);
  }
}

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

  testWidgets('after a new app password, the sync banner leads to a checked access change', (t) async {
    await prepare(t, tmp);
    final backing = MemoryStore();
    var serverPassword = 'old';
    final c = AppController(
      storeFactory: (config) => PasswordStore(config, backing, () => serverPassword),
      hostingFactory: testController(dav, tmp).hostingFactory,
    );
    await t.runAsync(() async {
      await c.init(tmp);
      await c.addGroup('Work', 'alice', 'correct horse');
      await c.createGroup(WebDavConfig('https://cloud.example/dav/work/', 'alice', 'old'));
    });
    await pumpApp(t, c, tmp, init: false);
    await waitFor(t, find.text('Inbox'));

    // The admin changed the app password on the server.
    serverPassword = 'new';
    await syncNow(t);
    await waitFor(t, find.textContaining('login failed'));
    await tapText(t, 'Change WebDAV access');
    await t.pumpAndSettle();
    await enter(t, 'WebDAV app password', 'typo');
    await tapText(t, 'Check and save');
    await waitFor(t, find.textContaining('login failed (401)').last);
    expect(c.session!.local.webdav.password, 'old', reason: 'nothing is saved before the check passed');

    await enter(t, 'WebDAV app password', 'new');
    await tapText(t, 'Check and save');
    await waitFor(t, find.text('Up to date'));
    expect(c.session!.local.webdav.password, 'new');
    expect(find.text('Change WebDAV access'), findsNothing, reason: 'the banner is gone');
    await unmount(t);
  }, variant: desktop);

  testWidgets('the access dialog checks the URL and asks for a fingerprint for another group', (t) async {
    await prepare(t, tmp);
    final c = testController(dav, tmp);
    final other = testController(dav, Directory('${tmp.path}/other')..createSync());
    await t.runAsync(() async {
      await other.init(Directory('${tmp.path}/other'));
      await other.addGroup('Theirs', 'mallory', 'correct horse');
      await other.createGroup(WebDavConfig('https://cloud.example/dav/theirs/', 'u', 'p'));
      await c.init(tmp);
      await c.addGroup('Work', 'alice', 'correct horse');
      await c.createGroup(WebDavConfig('https://cloud.example/dav/work/', 'u', 'p'));
    });
    await pumpApp(t, c, tmp, init: false);
    await waitFor(t, find.text('Inbox'));
    await t.tap(find.byTooltip('Settings'));
    await t.pumpAndSettle();
    await tapText(t, 'Change WebDAV access');
    await t.pumpAndSettle();

    await enter(t, 'WebDAV folder URL', 'not a url');
    await tapText(t, 'Check and save');
    await waitFor(t, find.text('Please enter a full URL.'));

    // A folder holding another group: the app wants the fingerprint.
    await enter(t, 'WebDAV folder URL', 'https://cloud.example/dav/theirs/');
    await tapText(t, 'Check and save');
    await waitFor(t, find.textContaining('different admin key'));
    await enter(t, 'Group fingerprint', 'xyz');
    await tapText(t, 'Check and save');
    await waitFor(t, find.textContaining('not a complete group fingerprint'));
    // Even with its fingerprint, this device is no member there.
    await enter(t, 'Group fingerprint', other.session!.fingerprint);
    await tapText(t, 'Check and save');
    await waitFor(t, find.textContaining('not (or no longer) a member'));
    expect(c.session!.local.webdav.url, 'https://cloud.example/dav/work/');

    await tapText(t, 'Cancel');
    await t.pumpAndSettle();
    await t.pageBack();
    await t.pumpAndSettle();
    await unmount(t);
  }, variant: desktop);

  testWidgets('without any group, the settings (and updates) can be opened', (t) async {
    await prepare(t, tmp);
    updateInstallDir = tmp.path; // as if installed by one of the installers
    addTearDown(() => updateInstallDir = installedDir());
    final c = testController(dav, tmp);
    await pumpApp(t, c, tmp);
    expect(find.text('Welcome to RedCourier'), findsOneWidget);

    await t.tap(find.byTooltip('Settings'));
    await t.pumpAndSettle();
    expect(find.text('Tor'), findsOneWidget);
    expect(find.text('Check for updates at start'), findsOneWidget);
    await t.ensureVisible(find.text('Check now'));
    expect(find.text('Switch group'), findsNothing, reason: 'no group is unlocked');
    expect(find.text('Change WebDAV access'), findsNothing);
    await t.pageBack();
    await t.pumpAndSettle();
    expect(find.text('Welcome to RedCourier'), findsOneWidget);
    await unmount(t);
  }, variant: desktop);

  testWidgets('a group that was never set up can be deleted from its setup screen', (t) async {
    await prepare(t, tmp);
    final c = testController(dav, tmp);
    await pumpApp(t, c, tmp);
    await tapText(t, 'Join a group');
    await enter(t, 'Group name (only on this device)', 'Pending');
    await enter(t, 'Identifier (name or handle)', 'bob');
    await enter(t, 'Password for this group', 'correct horse');
    await enter(t, 'Repeat password', 'correct horse');
    await tapText(t, 'Continue');
    await waitFor(t, find.text('Join an existing group'));
    expect(c.groups, ['Pending']);

    await tapText(t, 'Delete this group from this device');
    await t.pumpAndSettle();
    await tapText(t, 'Delete');
    await waitFor(t, find.text('Welcome to RedCourier'));
    expect(c.groups, isEmpty);
    await unmount(t);
  }, variant: desktop);

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

    // WebDAV access: a folder without this group is refused, the same folder
    // with a new app password is saved.
    await tapText(t, 'Change WebDAV access');
    await t.pumpAndSettle();
    await enter(t, 'WebDAV folder URL', 'https://cloud.example/dav/empty/');
    await tapText(t, 'Check and save');
    await waitFor(t, find.textContaining('No RedCourier group was found'));
    await enter(t, 'WebDAV folder URL', 'https://cloud.example/dav/family/');
    await enter(t, 'WebDAV app password', 'new-secret');
    await tapText(t, 'Check and save');
    await waitFor(t, find.text('WebDAV access checked and saved.'));
    expect(c.session!.local.webdav.password, 'new-secret');

    // Downloads, locking, switching.
    await tapText(t, 'Delete downloaded deliveries');
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
