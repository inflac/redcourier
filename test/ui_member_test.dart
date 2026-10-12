import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:redcourier/app_controller.dart';
import 'package:redcourier/core/crypto_util.dart';
import 'package:redcourier/core/identity.dart';
import 'package:redcourier/ui/folder_picker.dart';

import 'support/fakes.dart';
import 'support/ui.dart';

final work = WebDavConfig('https://cloud.example/dav/work/', 'u', 'p');

void main() {
  late Directory tmp;
  late MemDav dav;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('rc_ui_m_');
    dav = MemDav();
  });
  tearDown(() => tmp.delete(recursive: true));

  testWidgets('a member joins with invite and fingerprint, receives, confirms a key change, is removed', (t) async {
    final bobDir = Directory(p.join(tmp.path, 'bob'))..createSync();
    final aliceDir = Directory(p.join(tmp.path, 'alice'))..createSync();
    await prepare(t, bobDir);

    // Alice runs the group (without UI).
    final a = testController(dav, aliceDir);
    await t.runAsync(() async {
      await a.init(aliceDir);
      await a.addGroup('Work', 'alice', 'correct horse');
      await a.createGroup(work);
    });

    final b = testController(dav, bobDir);
    await pumpApp(t, b, bobDir);
    await tapText(t, 'Join a group');
    await enter(t, 'Group name (only on this device)', 'Work');
    await enter(t, 'Identifier (name or handle)', 'bob');
    await enter(t, 'Password for this group', 'correct horse');
    await enter(t, 'Repeat password', 'correct horse');
    await tapText(t, 'Continue');
    await waitFor(t, find.text('Join an existing group'));

    // The setup screen: join request, creating without input, joining.
    await tapText(t, 'Show join request');
    await t.pumpAndSettle();
    expect(find.textContaining('RCJOIN2:'), findsOneWidget);
    await tapText(t, 'Close');
    await t.pumpAndSettle();
    await tapText(t, 'Create group');
    expect(find.text('Please enter a full URL.'), findsOneWidget);

    await t.runAsync(() => a.run((s) => s.addMember(b.identity!.joinRequest)));
    await enter(t, 'Invite (RCINVITE2:…)', 'not an invite');
    await tapText(t, 'Join group');
    expect(find.text('Not a RedCourier invite.'), findsOneWidget);
    await enter(t, 'Invite (RCINVITE2:…)', Invite(work).encode());
    await tapText(t, 'Join group');
    expect(find.text('Enter the group fingerprint your admin sent you over a second channel.'), findsOneWidget);
    await enter(t, 'Group fingerprint', 'not hex');
    await tapText(t, 'Join group');
    expect(find.textContaining('not a complete group fingerprint'), findsOneWidget);
    await enter(t, 'Group fingerprint', 'ab' * 32);
    await tapText(t, 'Join group');
    await waitFor(t, find.textContaining('does not match the fingerprint you entered'));
    // As copied from an e-mail: grouped, upper case, over two lines.
    final fp = formatFingerprint(a.session!.fingerprint);
    await enter(t, 'Group fingerprint', '${fp.substring(0, 40)}\n${fp.substring(40)}');
    await tapText(t, 'Join group');
    await waitFor(t, find.text('Inbox'));

    // Alice sends something; bob syncs and downloads it.
    final file = File(p.join(aliceDir.path, 'plan.txt'))..writeAsStringSync('the plan');
    await t.runAsync(() => a.run((s) => s.send(
        recipientIds: [b.identity!.userId], paths: [file.path], note: 'read this', lifetime: const Duration(days: 1))));
    await syncNow(t);
    await waitFor(t, find.text('From alice'));
    expect(find.text('read this'), findsOneWidget);
    expect(find.text('new'), findsOneWidget);
    await tapText(t, 'Download');
    // Downloaded means: encrypted on the device, nothing readable yet.
    await waitFor(t, find.text('Downloaded, encrypted on this device'));
    for (final f in bobDir.listSync(recursive: true).whereType<File>()) {
      expect(f.readAsStringSync(encoding: latin1), isNot(contains('the plan')), reason: f.path);
    }
    // Saving asks for a folder (an encrypted volume in real life).
    final volume = Directory(p.join(tmp.path, 'volume'))..createSync();
    String? asked;
    pickFolder = (label) async {
      asked = label;
      return volume.path;
    };
    addTearDown(() => pickFolder = (_) async => null);
    await tapText(t, 'Save files to…');
    await waitFor(t, find.textContaining('Saved to'));
    expect(asked, 'Save here');
    final saved = volume.listSync(recursive: true).whereType<File>();
    expect(saved.single.readAsStringSync(), 'the plan');
    await tapText(t, 'Delete from this device');
    await waitFor(t, find.text('The encrypted copy was deleted from this device.'));
    expect(find.text('Download'), findsOneWidget);

    await t.tap(find.byType(PopupMenuButton<String>).first);
    await t.pumpAndSettle();
    await tapText(t, 'Remove from my inbox');
    await waitFor(t, find.text('No deliveries for you yet.'));

    // Alice replaces the admin key (adds and demotes an admin): bob must confirm.
    final carol = (await t.runAsync(() => Identity.generate('carol')))!;
    await t.runAsync(() async {
      await a.run((s) => s.addMember(carol.joinRequest, admin: true));
      await a.run((s) => s.setAdmin(carol.userId, false));
    });
    await syncNow(t, waitDone: false);
    await waitFor(t, find.text('Group key changed'));
    await enter(t, 'Fingerprint from your admin', 'abc');
    await tapText(t, 'Verify');
    await waitFor(t, find.textContaining('not a complete group fingerprint'));
    await syncNow(t, waitDone: false);
    await waitFor(t, find.text('Group key changed'));
    await enter(t, 'Fingerprint from your admin', 'cd' * 32);
    await tapText(t, 'Verify');
    await waitFor(t, find.textContaining('The fingerprint does not match'));
    await tapText(t, 'Retry');
    await waitFor(t, find.text('Group key changed'));
    await enter(t, 'Fingerprint from your admin', a.session!.fingerprint);
    await tapText(t, 'Verify');
    await waitGone(t, find.text('Group key changed'));
    await waitFor(t, find.text('Up to date'));

    // Removed from the group: the banner offers to delete it locally.
    await t.runAsync(() => a.run((s) => s.removeMember(b.identity!.userId)));
    await syncNow(t);
    await waitFor(t, find.text('Delete from this device'));
    await tapText(t, 'Delete from this device');
    await t.pumpAndSettle();
    await tapText(t, 'Delete');
    await waitFor(t, find.text('Welcome to RedCourier'));
    expect(b.groups, isEmpty);

    await unmount(t);
    expect(b.phase, AppPhase.noIdentity);
  }, variant: desktop);
}
