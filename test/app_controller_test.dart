import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:redcourier/app_controller.dart';
import 'package:redcourier/core/identity.dart';
import 'package:redcourier/core/messages.dart';
import 'package:redcourier/core/remote.dart';
import 'package:redcourier/core/vault.dart';
import 'package:redcourier/prefs.dart';

import 'support/fakes.dart';

const pw = 'correct horse';
WebDavConfig dav1 = WebDavConfig('https://cloud.example/dav/work/', 'u', 'p');

/// Stores sync.json, then reports a timeout (reply lost over Tor).
class LosingStore extends MemoryStore {
  bool lose = true;
  @override
  Future<void> putSync(Uint8List bytes, {String? ifMatch, bool createOnly = false}) async {
    await super.putSync(bytes, ifMatch: ifMatch, createOnly: createOnly);
    if (lose) {
      lose = false;
      throw RemoteException('Connection timed out.');
    }
  }
}

void main() {
  late Directory tmp;
  late MemDav dav;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('rc_ctrl_');
    dav = MemDav();
    await Prefs.init(tmp);
  });
  tearDown(() => tmp.delete(recursive: true));

  Future<AppController> start(String name) async {
    final dir = Directory(p.join(tmp.path, name))..createSync();
    final c = testController(dav, dir);
    await c.init(dir);
    return c;
  }

  test('first start, create a group, lock, unlock, default group', () async {
    final c = await start('alice');
    expect(c.phase, AppPhase.noIdentity);
    expect(c.validateGroupName(' bad/name'), isNotNull);
    expect(c.validateGroupName('Work'), isNull);

    await c.addGroup('Work', 'alice', pw);
    expect(c.phase, AppPhase.noGroup);
    expect(c.validateGroupName('work'), isNotNull, reason: 'names are unique, ignoring case');

    await c.createGroup(dav1);
    expect(c.phase, AppPhase.ready);
    expect(c.session!.isAdmin, isTrue);

    c.lock();
    expect(c.phase, AppPhase.locked);
    expect(c.session, isNull);
    await expectLater(c.unlock('wrong password'), throwsA(isA<WrongPasswordException>()));
    await c.unlock(pw);
    expect(c.phase, AppPhase.ready);
    expect(c.session!.isLoaded, isTrue, reason: 'loaded from the cache before any sync');

    final r = await c.sync();
    expect(r.newEntries, 0);
    expect(await c.run((s) async => s.members.length), 1);

    await c.setDefaultGroup(true);
    final again = await start('alice');
    expect(again.groupName, 'Work');
    expect(again.phase, AppPhase.locked);
  });

  test('a second group, joining, folder reuse and deleting', () async {
    final a = await start('alice');
    await a.addGroup('Work', 'alice', pw);
    await a.createGroup(dav1);

    final b = await start('bob');
    await b.addGroup('Work', 'bob', pw);
    await a.run((s) => s.addMember(b.identity!.joinRequest));
    await b.joinGroup(Invite(dav1), a.session!.fingerprint);
    expect(b.phase, AppPhase.ready);
    expect(b.session!.members.map((m) => m.identifier), ['alice', 'bob']);

    final f = File(p.join(tmp.path, 'plan.txt'))..writeAsStringSync('plan');
    await a.run((s) => s.send(
        recipientIds: [b.identity!.userId], paths: [f.path], note: '', lifetime: const Duration(days: 1)));
    final r = await b.sync();
    expect(r.newEntries, 1);
    expect(b.session!.inbox.single.senderName, 'alice');

    // Bob adds a second group on the same device; it may not reuse the folder.
    b.startAddingGroup();
    expect(b.phase, AppPhase.noIdentity);
    expect(b.addingGroup, isTrue);
    b.cancelAddingGroup();
    expect(b.phase, AppPhase.locked);
    b.startAddingGroup();
    await b.addGroup('Family', 'bobby', pw);
    // A new group cannot be created where a group already lives.
    await expectLater(b.createGroup(dav1),
        throwsA(isA<AppException>().having((e) => e.template, 'template', contains('already contains'))));
    await b.createGroup(WebDavConfig('https://cloud.example/dav/family/', 'u', 'p'));
    expect(b.groups, ['Family', 'Work']);

    // A second identity on the same device may join the same group (for
    // example to test, or for a second role).
    b.startAddingGroup();
    await b.addGroup('Work 2', 'bob2', pw);
    await a.run((s) => s.addMember(b.identity!.joinRequest));
    await b.joinGroup(Invite(dav1), a.session!.fingerprint);
    expect(b.session!.members.map((m) => m.identifier), ['alice', 'bob', 'bob2']);
    await b.deleteGroup();
    expect(b.groups, ['Family', 'Work']);

    b.selectGroup('Work');
    await b.unlock(pw);
    expect(b.session!.myId, isNot(a.session!.myId));
    await b.deleteGroup();
    expect(b.groups, ['Family']);
    expect(b.phase, AppPhase.locked);
    await b.unlock(pw);
    await b.deleteGroup();
    expect(b.groups, isEmpty);
    expect(b.phase, AppPhase.noIdentity);
  });

  test('a lost reply while creating keeps the input and the retry takes over the group', () async {
    final store = LosingStore();
    final dir = Directory(p.join(tmp.path, 'x'))..createSync();
    final c = AppController(
      storeFactory: (_) => store,
      hostingFactory: testController(dav, dir).hostingFactory,
    );
    await c.init(dir);
    await c.addGroup('Work', 'alice', pw);
    var notified = 0;
    c.addListener(() => notified++);
    await expectLater(c.createGroup(dav1), throwsA(isA<RemoteException>()));
    expect(c.lastCreateAttempt!.url, dav1.url);
    expect(c.lastCreateFailure, isA<RemoteException>());
    expect(notified, greaterThan(0));

    // Even after locking and unlocking, the remembered key is in the vault.
    c.lock();
    await c.unlock(pw);
    expect(c.phase, AppPhase.noGroup);
    await c.createGroup(dav1);
    expect(c.phase, AppPhase.ready);
    expect(c.session!.isAdmin, isTrue);
    expect(c.lastCreateFailure, isNull);
  });

  test('old layouts are migrated into groups/', () async {
    final dir = Directory(p.join(tmp.path, 'old'))..createSync();
    final first = testController(dav, dir);
    await first.init(dir);
    await first.addGroup('Default', 'alice', pw);
    // Move the group back to where the first versions kept it ("profiles").
    await Directory(p.join(dir.path, 'groups')).rename(p.join(dir.path, 'profiles'));
    final c = testController(dav, dir);
    await c.init(dir);
    expect(c.groups, ['Default']);
  });
}
