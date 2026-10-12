import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:redcourier/app_controller.dart';
import 'package:redcourier/core/identity.dart';
import 'package:redcourier/core/remote.dart';
import 'package:redcourier/main.dart';
import 'package:redcourier/ui/send_screen.dart';

import 'support/fakes.dart';
import 'support/ui.dart';

/// Holds the first read until [release] completes, like a slow Tor circuit.
class SlowStore extends MemoryStore {
  final release = Completer<void>();
  @override
  Future<RemoteFile?> getSync() async {
    await release.future;
    return super.getSync();
  }
}

void main() {
  late Directory tmp;
  late MemDav dav;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('rc_ui_');
    dav = MemDav();
  });
  tearDown(() => tmp.delete(recursive: true));

  testWidgets('while the group is created on the server, progress and the input are shown', (t) async {
    await prepare(t, tmp);
    final store = SlowStore();
    final c = AppController(
      storeFactory: (_) => store,
      hostingFactory: testController(dav, tmp).hostingFactory,
    );
    await pumpApp(t, c, tmp);
    await tapText(t, 'Start a new group');
    await enter(t, 'Group name (only on this device)', 'Work');
    await enter(t, 'Identifier (name or handle)', 'alice');
    await enter(t, 'Password for this group', 'correct horse');
    await enter(t, 'Repeat password', 'correct horse');
    await enter(t, 'WebDAV folder URL', 'https://cloud.example/dav/work/');
    await enter(t, 'WebDAV username', 'alice');
    await enter(t, 'WebDAV app password', 'secret');
    await tapText(t, 'Create group');

    // The local group exists, the server is still busy: the setup screen
    // shows progress and the entered data instead of empty fields.
    await waitFor(t, find.text('Creating group…'));
    expect(find.textContaining('This can take a minute'), findsOneWidget);
    expect(find.text('https://cloud.example/dav/work/'), findsOneWidget);
    final create = find.ancestor(of: find.text('Creating group…'), matching: find.byType(ElevatedButton));
    expect(t.widget<ElevatedButton>(create).onPressed, isNull);

    store.release.complete();
    await waitFor(t, find.text('Inbox'));
    await unmount(t);
  }, variant: desktop);

  testWidgets('an admin creates a group, manages members and sends a file', (t) async {
    await prepare(t, tmp);
    final c = testController(dav, tmp);
    await pumpApp(t, c, tmp);

    // Welcome: choose "Start a new group", first with missing input.
    expect(find.text('Welcome to RedCourier'), findsOneWidget);
    await tapText(t, 'Start a new group');
    await tapText(t, 'Create group');
    expect(find.textContaining('Use letters, digits'), findsOneWidget);

    await enter(t, 'Group name (only on this device)', 'Work');
    await enter(t, 'Identifier (name or handle)', 'alice');
    await enter(t, 'Password for this group', 'correct horse');
    await enter(t, 'Repeat password', 'correct horsey');
    await tapText(t, 'Create group');
    expect(find.text('The passwords do not match.'), findsOneWidget);
    await enter(t, 'Repeat password', 'correct horse');
    await enter(t, 'WebDAV folder URL', 'https://cloud.example/dav/work/');
    await enter(t, 'WebDAV username', 'alice');
    await enter(t, 'WebDAV app password', 'secret');
    await tapText(t, 'Create group');
    await waitFor(t, find.text('Inbox'));
    expect(c.session!.isAdmin, isTrue);

    // Members: fingerprint, invite, adding bob and carol.
    await t.tap(find.byTooltip('Members'));
    await t.pumpAndSettle();
    await tapText(t, 'Group fingerprint');
    await t.pumpAndSettle();
    expect(find.text('Group fingerprint'), findsWidgets);
    await tapText(t, 'Copy');
    await tapText(t, 'Close');
    await t.pumpAndSettle();
    await tapText(t, 'Invite');
    await t.pumpAndSettle();
    expect(find.textContaining('RCINVITE2:'), findsOneWidget);
    await tapText(t, 'Group fingerprint'); // opens the fingerprint from the invite dialog
    await t.pumpAndSettle();
    await tapText(t, 'Close');
    await t.pumpAndSettle();

    final bob = (await t.runAsync(() => Identity.generate('bob')))!;
    final carol = (await t.runAsync(() => Identity.generate('carol')))!;
    for (final (who, admin) in [(bob, false), (carol, true)]) {
      await tapText(t, 'Add member');
      await t.pumpAndSettle();
      await enter(t, 'Join request (RCJOIN2:…)', 'nonsense');
      await tapText(t, 'Continue');
      expect(find.text('Not a Red Courier join request.'), findsNothing);
      await enter(t, 'Join request (RCJOIN2:…)', who.joinRequest.encode());
      await tapText(t, 'Continue');
      await t.pumpAndSettle();
      await tapText(t, admin ? 'Add as admin' : 'Add as member');
      await waitFor(t, find.text('Invite').hitTestable());
      await t.pumpAndSettle();
      await tapText(t, 'Close'); // the invite shown after adding
      await t.pumpAndSettle();
    }
    expect(c.session!.activeMembers.map((m) => m.identifier), ['alice', 'bob', 'carol']);

    // Make bob admin, then take it back (shows the new fingerprint).
    Future<void> memberMenu(String name, String item) async {
      final tile = find.ancestor(of: find.text(name), matching: find.byType(ListTile));
      await t.tap(find.descendant(of: tile, matching: find.byType(PopupMenuButton<String>)));
      await t.pumpAndSettle();
      await tapText(t, item);
      await t.pumpAndSettle();
    }

    await memberMenu('bob', 'Make admin');
    await tapText(t, 'Make admin');
    await waitFor(t, find.text('bob is now an admin'));
    expect(c.session!.members.where((m) => m.isAdmin), hasLength(3));
    await memberMenu('bob', 'Remove admin rights');
    await tapText(t, 'Continue');
    await waitFor(t, find.text('New group fingerprint'));
    await tapText(t, 'Close');
    await t.pumpAndSettle();
    await memberMenu('carol', 'Remove from group');
    await tapText(t, 'Remove');
    await waitFor(t, find.text('carol was removed'));
    await t.pumpAndSettle();
    await tapText(t, 'Close'); // new fingerprint (carol was an admin)
    await t.pumpAndSettle();
    await t.pageBack();
    await t.pumpAndSettle();

    // Send a file to bob.
    final file = File(p.join(tmp.path, 'report.pdf'))..writeAsStringSync('hello bob');
    navigatorKey.currentState!.push(MaterialPageRoute(
        builder: (_) => SendScreen(app: c, initialPaths: [file.path])));
    await t.pumpAndSettle();
    await tapText(t, 'Send');
    await waitFor(t, find.text('Choose at least one recipient.'));
    await tapText(t, 'bob');
    await enter(t, 'Note (optional, encrypted)', 'the report');
    await tapText(t, 'Send to 1 recipient(s)');
    await waitFor(t, find.text('Sent'));
    await t.pumpAndSettle();

    // It shows up under "Sent" and can be deleted for everyone.
    await tapText(t, 'Sent');
    await t.pumpAndSettle();
    expect(find.text('To bob'), findsOneWidget);
    expect(find.text('the report'), findsOneWidget);
    await t.tap(find.byType(PopupMenuButton<String>).last);
    await t.pumpAndSettle();
    await tapText(t, 'Delete for everyone');
    await t.pumpAndSettle();
    await tapText(t, 'Delete');
    await waitFor(t, find.text('Deleted'));
    expect(c.session!.sent, isEmpty);

    await unmount(t);
    expect(c.phase, AppPhase.ready);
  }, variant: desktop);
}
