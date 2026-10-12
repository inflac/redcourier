import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:redcourier/core/blob_crypto.dart';
import 'package:redcourier/core/crypto_util.dart';
import 'package:redcourier/core/delivery.dart';
import 'package:redcourier/core/group.dart';
import 'package:redcourier/core/hosts.dart';
import 'package:redcourier/core/identity.dart';
import 'package:redcourier/core/messages.dart';
import 'package:redcourier/core/remote.dart';
import 'package:redcourier/core/vault.dart';

final webdav = WebDavConfig('https://cloud.example.com/remote.php/dav/files/x/rc', 'user', 'pw');

late Directory tmp;

/// In-memory file host. Small parts force deliveries to be split.
class FakeHost extends FileHost {
  static final files = <String, Uint8List>{};
  @override
  final String id;
  bool fail = false;
  bool failDownload = false;
  int uploads = 0;
  int downloads = 0;
  final int limit;
  final sizes = <int>[];
  FakeHost(this.id, {this.limit = 1024 * 1024});

  @override
  String get label => id;
  @override
  int get maxBytes => limit;
  @override
  Duration get maxRetention => const Duration(days: 6);
  @override
  List<String> get linkHosts => ['$id.test'];

  @override
  Future<HostedPart> upload(HttpClient client, File file, String name, Duration lifetime,
      {HostProgress? onProgress}) async {
    if (fail) throw HostException('{host} is down', {'host': id});
    uploads++;
    final url = 'https://$id.test/${randomHex(8)}/$name';
    final bytes = await file.readAsBytes();
    expect(bytes.length, lessThanOrEqualTo(maxBytes), reason: 'part fits the host limit');
    sizes.add(bytes.length);
    files[url] = bytes;
    return HostedPart(host: id, url: url, size: bytes.length, sha256: sha256Hex(bytes));
  }

  @override
  Future<void> download(HttpClient client, HostedPart part, File target, {HostProgress? onProgress}) async {
    checkLink(part.url);
    if (failDownload) throw HostException('{host} is down', {'host': id});
    downloads++;
    final data = files[part.url];
    if (data == null) throw HostException('The file is no longer available at the hosting service.');
    await target.writeAsBytes(data);
  }

  @override
  Future<void> delete(HttpClient client, HostedPart part) async => files.remove(part.url);
}

late FakeHost hostA, hostB;
Hosting get hosting => Hosting([hostA, hostB], () async => HttpClient());

Future<GroupSession> createGroup(Identity admin, MemoryStore store) => GroupSession.create(
      identity: admin,
      webdav: webdav,
      store: store,
      hosting: hosting,
      persistLocal: (_) async {},
      tempDir: tmp,
    );

Future<GroupSession> joinGroup(Identity user, MemoryStore store, String fingerprint) =>
    GroupSession.join(
      identity: user,
      invite: Invite(webdav),
      fingerprint: fingerprint,
      store: store,
      hosting: hosting,
      persistLocal: (_) async {},
      tempDir: tmp,
    );

/// Stores sync.json but then reports a timeout, like a reply lost over Tor.
class LostReplyStore extends MemoryStore {
  bool loseNextReply = true;
  @override
  Future<void> putSync(Uint8List bytes, {String? ifMatch, bool createOnly = false}) async {
    await super.putSync(bytes, ifMatch: ifMatch, createOnly: createOnly);
    if (loseNextReply) {
      loseNextReply = false;
      throw RemoteException('Connection timed out.');
    }
  }
}

Future<GroupSession> createWith(Identity admin, RemoteStore store, List<String> pending) =>
    GroupSession.create(
      identity: admin,
      webdav: webdav,
      store: store,
      hosting: hosting,
      persistLocal: (_) async {},
      tempDir: tmp,
      ownAdminKeys: List.of(pending),
      rememberAdminKey: (k) async => pending.add(k),
    );

/// Downloads [entry] (kept encrypted) and saves its files into [dir].
Future<String> receive(GroupSession s, Entry entry, Directory dir) async {
  await s.download(entry);
  return s.saveFiles(entry, dir);
}

Future<String> writeFile(String name, int size) async {
  final f = File(p.join(tmp.path, name));
  await f.writeAsBytes(randomBytes(size));
  return f.path;
}

void main() {
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('rc_test_');
    FakeHost.files.clear();
    hostA = FakeHost('hosta');
    hostB = FakeHost('hostb');
  });
  tearDown(() async => tmp.delete(recursive: true));

  test('ML-KEM-768 matches the independent kyber-py reference', () {
    final seed = List<int>.generate(64, (i) => i);
    final m = List<int>.generate(32, (i) => 100 + i);
    final (ek, dk) = mlkemKeyPair(seed);
    expect(sha256Hex(ek), '0b7934c83125c788995e2ba6bd761e33046b3e40571be53e023309a29f398cc9');
    expect(sha256Hex(dk), 'dac268bde6a8dd238e9887117d6b664e7a7a9350ad6b7c08a948e504809572a5');
    final (ct, k) = mlkemEncapsulate(ek, m);
    expect(sha256Hex(ct), '57fe559432dbb3c5547c73f155820622f7efdd532e4330360a36ebf7d2ddec55');
    expect(hex(k), 'c5a74110c158acbaf9c01deb86fa6cc10c14533feda54bec1fdd000d61f07e4e');
    expect(hex(mlkemDecapsulate(dk, ct)), hex(k));
    final bad = Uint8List.fromList(ct)..[0] ^= 1;
    expect(hex(mlkemDecapsulate(dk, bad)),
        'bb28c25ed3222c13ce49d65f663f1c9f148565a664747e142f1abe06f33f4826');
  });

  test('hybrid seal/open and signatures', () async {
    final xSeed = randomBytes(32);
    final kemSeed = randomBytes(64);
    final kp = await SealKeyPair.fromSeeds(xSeed, kemSeed);
    final sealed = await seal(await x25519PublicKey(xSeed), kp.kemPublicKey, [1, 2, 3], 'ctx');
    expect(await kp.open(sealed, 'ctx'), [1, 2, 3]);
    expect(() => kp.open(sealed, 'other'), throwsA(isA<CryptoException>()));

    // Changing the ML-KEM part alone must break decryption (both secrets are used).
    final other = await SealKeyPair.fromSeeds(xSeed, randomBytes(64));
    final forOther = await seal(await x25519PublicKey(xSeed), other.kemPublicKey, [9], 'ctx');
    expect(() => kp.open(forOther, 'ctx'), throwsA(isA<CryptoException>()));

    final sk = randomBytes(32);
    final pub = b64e(await ed25519PublicKey(sk));
    final sig = await sign(sk, utf8.encode('hello'));
    expect(await verify(pub, sig, utf8.encode('hello')), isTrue);
    expect(await verify(pub, sig, utf8.encode('hellO')), isFalse);
  });

  test('blob encryption round trip, chunking and tamper detection', () async {
    Future<List<int>> decrypt(String path, Uint8List key, String name) async =>
        (await BlobCrypto.decryptStream(path, key, name, chunkSize: 4096).toList()).expand((c) => c).toList();

    for (final size in [0, 1, 4096, 4096 * 3, 4096 * 3 + 7]) {
      final src = await writeFile('in_$size', size);
      final enc = p.join(tmp.path, 'enc_$size');
      final key = randomBytes(32);
      await BlobCrypto.encryptStream(File(src).openRead(), enc, key, 'b.rcb', chunkSize: 4096);
      expect(await decrypt(enc, key, 'b.rcb'), await File(src).readAsBytes());
      // A different blob name must fail (no swapping of blobs).
      await expectLater(decrypt(enc, key, 'c.rcb'), throwsA(isA<CryptoException>()));
    }
    // Truncation: drop the final chunk.
    final src = await writeFile('trunc', 4096 * 2 + 10);
    final enc = p.join(tmp.path, 'trunc.enc');
    final key = randomBytes(32);
    await BlobCrypto.encryptStream(File(src).openRead(), enc, key, 'b.rcb', chunkSize: 4096);
    final bytes = await File(enc).readAsBytes();
    await File(enc).writeAsBytes(bytes.sublist(0, BlobCrypto.prefixLength + 2 * (4096 + 16)));
    await expectLater(decrypt(enc, key, 'b.rcb'), throwsA(isA<CryptoException>()));
  });

  test('join request and invite encode/decode', () async {
    final id = await Identity.generate('  alice@example.org ');
    final req = JoinRequest.parse(id.joinRequest.encode());
    expect(req.identifier, 'alice@example.org');
    expect(req.userId, id.userId);
    final inv = Invite.parse(Invite(webdav).encode());
    expect(inv.webdav.url, webdav.url);
    expect(inv.encode(), isNot(contains('fingerprint')));
    expect(() => Invite.parse('RCINVITE9:abc'), throwsFormatException);
    expect(() => JoinRequest.parse('nonsense'), throwsFormatException);
  });

  test('fingerprints are accepted as typed, from an e-mail or from the QR code', () {
    final fp = sha256Hex(utf8.encode('x'));
    expect(parseFingerprint(fp), fp);
    expect(parseFingerprint(formatFingerprint(fp)), fp);
    expect(parseFingerprint('  ${formatFingerprint(fp).replaceAll(' ', '\n')}\n'), fp);
    expect(parseFingerprint(fingerprintQr(fp)), fp);
    expect(parseFingerprint(fingerprintQr(fp).toLowerCase()), fp);
    expect(parseFingerprint(fp.substring(2)), isNull);
    expect(parseFingerprint('Fingerprint: $fp'), isNull, reason: 'stray letters are not silently dropped');
  });

  test('creating a group again after a lost reply takes over the own group', () async {
    final store = LostReplyStore();
    final alice = await Identity.generate('alice');
    final pending = <String>[];
    await expectLater(createWith(alice, store, pending), throwsA(isA<RemoteException>()));
    expect(store.sync, isNotNull, reason: 'the server stored sync.json');
    expect(pending, hasLength(1));

    final a = await createWith(alice, store, pending);
    expect(a.isAdmin, isTrue);
    await a.sync();
    final bob = await Identity.generate('bob');
    await a.addMember(bob.joinRequest);
    final b = await joinGroup(bob, store, a.fingerprint);
    expect(b.members.map((m) => m.identifier), containsAll(['alice', 'bob']));
  });

  test('a group created by someone else is still refused', () async {
    final store = MemoryStore();
    final alice = await Identity.generate('alice');
    await createWith(alice, store, []);
    final mallory = await Identity.generate('mallory');
    await expectLater(createWith(mallory, store, ['x']),
        throwsA(isA<SyncException>().having((e) => e.template, 'template', contains('already contains'))));
    // Even the same identity needs the remembered key of its own attempt.
    await expectLater(createWith(alice, store, []), throwsA(isA<SyncException>()));
  });

  test('full flow: create, add, send, receive, download', () async {
    final store = MemoryStore();
    final alice = await Identity.generate('alice');
    final bob = await Identity.generate('bob');
    final carol = await Identity.generate('carol');

    final a = await createGroup(alice, store);
    expect(a.isAdmin, isTrue);
    await a.addMember(bob.joinRequest);
    await a.addMember(carol.joinRequest);

    final b = await joinGroup(bob, store, a.fingerprint);
    final c = await joinGroup(carol, store, a.fingerprint);
    expect(b.isAdmin, isFalse);
    expect(b.activeMembers.map((m) => m.identifier), ['alice', 'bob', 'carol']);

    final f1 = await writeFile('report.pdf', 3 * 1024 * 1024 + 5);
    final f2 = await writeFile('notes.txt', 1000);
    await a.send(recipientIds: [bob.userId], paths: [f1, f2], note: 'hi bob', lifetime: const Duration(days: 1));
    expect(a.sent.single.to, [bob.userId]);
    // Split into several ZIP parts, spread over both hosts.
    expect(FakeHost.files.length, greaterThan(2));
    expect(hostA.uploads, greaterThan(0));
    expect(hostB.uploads, greaterThan(0));
    // Neither the sync server nor the hosts see names, notes or members.
    expect(utf8.decode(store.sync!).contains('report.pdf'), isFalse);
    expect(utf8.decode(store.sync!).contains('hi bob'), isFalse);
    expect(utf8.decode(store.sync!).contains('carol'), isFalse);
    expect(utf8.decode(store.sync!).contains('hosta.test'), isFalse, reason: 'links are encrypted');
    for (final part in FakeHost.files.values) {
      expect(latin1.decode(part).contains('report.pdf'), isFalse);
    }

    final r = await b.sync();
    expect(r.newEntries, 1);
    final entry = b.inbox.single;
    expect(entry.senderName, 'alice');
    expect(entry.note, 'hi bob');
    expect(entry.files.map((f) => f.name), ['report.pdf', 'notes.txt']);
    expect(entry.totalSize, 3 * 1024 * 1024 + 5 + 1000);
    expect(b.isNew(entry), isTrue);

    final out = await receive(b, entry, Directory(p.join(tmp.path, 'dl')));
    expect(await File(p.join(out, 'report.pdf')).readAsBytes(), await File(f1).readAsBytes());
    expect(await File(p.join(out, 'notes.txt')).readAsBytes(), await File(f2).readAsBytes());
    expect(b.isNew(entry), isFalse);

    await c.sync();
    expect(c.inbox, isEmpty, reason: 'carol is not a recipient');

    // Only sender or admin may delete.
    await expectLater(c.deleteEntry(entry.id), throwsA(isA<SyncException>()));
    await a.deleteEntry(entry.id);
    expect(FakeHost.files, isEmpty, reason: 'the sender deletes the parts at the hosts');
    await b.sync();
    expect(b.inbox, isEmpty);
  });

  test('wrong fingerprint, tampering and rollback are rejected', () async {
    final store = MemoryStore();
    final alice = await Identity.generate('alice');
    final bob = await Identity.generate('bob');
    final a = await createGroup(alice, store);
    await a.addMember(bob.joinRequest);

    await expectLater(joinGroup(bob, store, 'ff' * 32), throwsA(isA<TrustException>()));
    final b = await joinGroup(bob, store, a.fingerprint);

    // Tampering with the member list breaks the admin signature.
    final good = Uint8List.fromList(store.sync!);
    final doc = jsonDecode(utf8.decode(good)) as Map<String, dynamic>;
    ((doc['users'] as Map)['members'] as Map)[bob.userId]['role'] = 'admin';
    await store.putSync(Uint8List.fromList(utf8.encode(jsonEncode(doc))));
    await expectLater(b.sync(), throwsA(isA<SyncException>()));
    await store.putSync(good);
    await b.sync();

    // Replaying an older, validly signed file is detected.
    final old = Uint8List.fromList(store.sync!);
    final f = await writeFile('x.txt', 10);
    await a.send(recipientIds: [bob.userId], paths: [f], note: '', lifetime: const Duration(days: 1));
    await b.sync();
    await store.putSync(old);
    await expectLater(b.sync(), throwsA(isA<SyncException>()));
  });

  test('a forged entry from a member is dropped', () async {
    final store = MemoryStore();
    final alice = await Identity.generate('alice');
    final bob = await Identity.generate('bob');
    final a = await createGroup(alice, store);
    await a.addMember(bob.joinRequest);
    final b = await joinGroup(bob, store, a.fingerprint);
    final f = await writeFile('x.txt', 10);
    await a.send(recipientIds: [bob.userId], paths: [f], note: 'original', lifetime: const Duration(days: 1));

    // Bob holds the shared files key, but cannot re-sign an entry as alice.
    final doc = jsonDecode(utf8.decode(store.sync!)) as Map<String, dynamic>;
    final entries = (doc['files'] as Map)['entries'] as Map;
    final entry = entries.values.single as Map;
    entry['expires'] = (entry['expires'] as int) + 100000;
    // Re-sign the file list like a malicious member could.
    final members = ((doc['users'] as Map)['members'] as Map);
    final sealKp = await bob.sealKeyPair();
    final seed = await sealKp.open(members[bob.userId]['files_sign_key'], 'files-sign-key');
    doc['files_sig'] = await sign(seed, canonicalBytes('redcourier/files/v1', {
      'format': doc['format'],
      'format_version': doc['format_version'],
      'files': doc['files'],
    }));
    await store.putSync(Uint8List.fromList(utf8.encode(jsonEncode(doc))));
    await b.sync();
    expect(b.inbox, isEmpty);
    expect(b.rejectedEntries, 1);
  });

  test('concurrent writes are merged via ETag retries', () async {
    final store = MemoryStore();
    final alice = await Identity.generate('alice');
    final bob = await Identity.generate('bob');
    final a = await createGroup(alice, store);
    await a.addMember(bob.joinRequest);
    final b = await joinGroup(bob, store, a.fingerprint);
    final f = await writeFile('x.txt', 100);
    await Future.wait([
      a.send(recipientIds: [bob.userId], paths: [f], note: 'from a', lifetime: const Duration(days: 1)),
      b.send(recipientIds: [alice.userId], paths: [f], note: 'from b', lifetime: const Duration(days: 1)),
    ]);
    await a.sync();
    await b.sync();
    expect(a.inbox.single.note, 'from b');
    expect(b.inbox.single.note, 'from a');
  });

  test('removing members rotates keys; demoting an admin needs re-confirmation', () async {
    final store = MemoryStore();
    final alice = await Identity.generate('alice');
    final bob = await Identity.generate('bob');
    final carol = await Identity.generate('carol');
    final dave = await Identity.generate('dave');
    final a = await createGroup(alice, store);
    await a.addMember(bob.joinRequest);
    await a.addMember(carol.joinRequest);
    final b = await joinGroup(bob, store, a.fingerprint);
    final c = await joinGroup(carol, store, a.fingerprint);

    final f = await writeFile('x.txt', 10);
    await c.send(recipientIds: [bob.userId], paths: [f], note: 'from carol', lifetime: const Duration(days: 1));

    await a.removeMember(carol.userId);
    await expectLater(c.sync(), throwsA(isA<NotMemberException>()));
    await expectLater(
        c.send(recipientIds: [bob.userId], paths: [f], note: 'x', lifetime: const Duration(days: 1)),
        throwsA(isA<NotMemberException>()));
    expect(FakeHost.files.length, 1, reason: 'the rejected upload was cleaned up');

    // Admin key unchanged: bob syncs without a prompt; carol's old entry still verifies.
    await b.sync();
    expect(b.inbox.single.senderName, 'carol');
    expect(b.activeMembers.map((m) => m.identifier), ['alice', 'bob']);

    // Promote and demote dave: the admin key rotates, members must confirm.
    await a.addMember(dave.joinRequest, admin: true);
    final oldFp = a.fingerprint;
    await a.setAdmin(dave.userId, false);
    expect(a.fingerprint, isNot(oldFp));
    await expectLater(b.sync(), throwsA(isA<TrustException>()));
    await b.sync(confirmedFingerprint: a.fingerprint);

    // A re-added user can be removed and added again.
    await a.addMember(carol.joinRequest);
    await c.sync(confirmedFingerprint: a.fingerprint);
    expect(c.activeMembers.length, 4);
  });

  test('several admins: a new admin can demote the first one and promote again', () async {
    final store = MemoryStore();
    final alice = await Identity.generate('alice');
    final bob = await Identity.generate('bob');
    final carol = await Identity.generate('carol');
    final dave = await Identity.generate('dave');
    final a = await createGroup(alice, store);
    await a.addMember(bob.joinRequest);
    await a.addMember(carol.joinRequest);
    final b = await joinGroup(bob, store, a.fingerprint);
    final c = await joinGroup(carol, store, a.fingerprint);

    // Promoting keeps the admin key, so nobody has to confirm anything.
    await a.setAdmin(bob.userId, true);
    await b.sync();
    expect(b.isAdmin, isTrue);
    await c.sync();

    // The new admin manages members like the first one.
    await b.addMember(dave.joinRequest);
    final d = await joinGroup(dave, store, b.fingerprint);
    expect(d.activeMembers.map((m) => m.identifier), containsAll(['alice', 'bob', 'carol', 'dave']));

    // Bob demotes alice, the group's creator. The admin key is replaced.
    final oldFp = a.fingerprint;
    await b.setAdmin(alice.userId, false);
    expect(b.fingerprint, isNot(oldFp));
    await expectLater(a.sync(), throwsA(isA<TrustException>()));
    await a.sync(confirmedFingerprint: b.fingerprint);
    expect(a.isAdmin, isFalse);
    await expectLater(a.addMember((await Identity.generate('eve')).joinRequest), throwsA(isA<SyncException>()));
    await expectLater(a.setAdmin(bob.userId, false), throwsA(isA<SyncException>()));

    // Nobody can demote themselves, so the group always keeps an admin.
    await expectLater(b.setAdmin(bob.userId, false), throwsA(isA<SyncException>()));

    // Bob makes alice admin again; she uses the current key.
    await b.setAdmin(alice.userId, true);
    await a.sync();
    expect(a.isAdmin, isTrue);
    await a.removeMember(carol.userId);
    await b.sync();
    expect(b.activeMembers.map((m) => m.identifier), ['alice', 'bob', 'dave']);
    expect(b.members.where((m) => m.isAdmin).map((m) => m.identifier), ['alice', 'bob']);
  });

  test('expired entries are cleaned up; credentials are distributed', () async {
    final store = MemoryStore();
    final alice = await Identity.generate('alice');
    final bob = await Identity.generate('bob');
    final a = await createGroup(alice, store);
    await a.addMember(bob.joinRequest);
    final b = await joinGroup(bob, store, a.fingerprint);
    final f = await writeFile('x.txt', 10);
    await a.send(recipientIds: [bob.userId], paths: [f], note: '', lifetime: const Duration(seconds: -5));
    await b.sync();
    expect(b.inbox, isEmpty, reason: 'expired entries are hidden');
    expect(await b.cleanupExpired(), 1);
    await a.sync();
    expect(await a.cleanupExpired(), 0);
  });

  test('WebDAV access is local and only saved after checking the folder', () async {
    final store = MemoryStore();
    final alice = await Identity.generate('alice');
    final bob = await Identity.generate('bob');
    final a = await createGroup(alice, store);
    await a.addMember(bob.joinRequest);
    final b = await joinGroup(bob, store, a.fingerprint);

    // The shared file holds no WebDAV credentials.
    final doc = jsonDecode(utf8.decode(store.sync!)) as Map<String, dynamic>;
    expect((doc['users'] as Map).containsKey('sync_config'), isFalse);
    expect(utf8.decode(store.sync!), isNot(contains('"password"')));

    final moved = WebDavConfig('https://new.example/dav/rc/', 'bob', 'new-pw');
    // An empty folder or another group is refused; nothing changes.
    await expectLater(b.changeWebDav(moved, MemoryStore()), throwsA(isA<SyncException>()));
    final other = MemoryStore();
    await createGroup(await Identity.generate('mallory'), other);
    await expectLater(b.changeWebDav(moved, other), throwsA(isA<TrustException>()));
    expect(b.local.webdav.url, webdav.url);

    // The same group (for example after a new app password) is accepted.
    await b.changeWebDav(moved, store);
    expect(b.local.webdav.url, moved.url);
    expect(b.local.webdav.password, 'new-pw');

    // After an admin change, the new fingerprint from an admin is needed.
    final carol = await Identity.generate('carol');
    await a.addMember(carol.joinRequest, admin: true);
    await a.setAdmin(carol.userId, false);
    await expectLater(b.changeWebDav(webdav, store), throwsA(isA<TrustException>()));
    await b.changeWebDav(webdav, store, confirmedFingerprint: a.fingerprint);
    expect(b.local.webdav.url, webdav.url);

    // A removed member cannot get in by changing the access data.
    await a.removeMember(bob.userId);
    await expectLater(b.changeWebDav(webdav, store), throwsA(isA<NotMemberException>()));
  });

  test('vault round trip and wrong password', () async {
    final id = await Identity.generate('alice');
    final dir = Directory(p.join(tmp.path, 'vault'));
    await Vault.create(dir, 'correct horse', VaultData(id, GroupLocal(webdav: webdav)), iterations: 1000);
    final (_, data) = await Vault.unlock(dir, 'correct horse');
    expect(data.identity.userId, id.userId);
    expect(data.group!.webdav.password, 'pw');
    await expectLater(Vault.unlock(dir, 'wrong'), throwsA(isA<WrongPasswordException>()));
  });

  group('no plaintext on the device', () {
    late Directory src, work, target;
    late Uint8List key;
    setUp(() {
      src = Directory(p.join(tmp.path, 'src'))..createSync();
      work = Directory(p.join(tmp.path, 'work'))..createSync();
      target = Directory(p.join(tmp.path, 'vault-volume'));
      key = randomBytes(32);
    });

    List<String> files() {
      final a = File(p.join(src.path, 'report.pdf'))..writeAsBytesSync(randomBytes(3 * 1024 * 1024 + 17));
      final b = File(p.join(src.path, 'Ünïcode name.txt'))..writeAsStringSync('secret plan');
      final c = File(p.join(src.path, 'empty.bin'))..writeAsBytesSync([]);
      // Same name from another folder.
      final d = File(p.join((Directory(p.join(src.path, 'other'))..createSync()).path, 'report.pdf'))
        ..writeAsStringSync('second report');
      return [a.path, b.path, c.path, d.path];
    }

    test('nothing in a blob or part points to RedCourier', () async {
      final blob = p.join(work.path, 'payload.rcb');
      await Delivery.packEncrypted(files(), blob, key, 'pid');
      final head = File(blob).readAsBytesSync().sublist(0, 16);
      expect(String.fromCharCodes(head.sublist(0, 4)), isNot('RCB1'), reason: 'no format marker');

      final part = await Delivery.makePart(blob, 0, 100000, work);
      final zipText = latin1.decode(File(part).readAsBytesSync());
      expect(zipText.toLowerCase(), isNot(contains('redcourier')));
      expect(p.basename(part), matches(RegExp(r'^[0-9a-f]{32}\.zip$')));
    });

    test('packing writes only the encrypted blob, saving writes only into the target', () async {
      final paths = files();
      final blob = p.join(work.path, 'payload.rcb');
      await Delivery.packEncrypted(paths, blob, key, 'pid');
      expect(work.listSync().map((e) => p.basename(e.path)), ['payload.rcb']);
      final raw = File(blob).readAsBytesSync();
      expect(utf8.decode(raw, allowMalformed: true), isNot(contains('secret plan')));
      expect(utf8.decode(raw, allowMalformed: true), isNot(contains('report.pdf')), reason: 'names are encrypted too');

      final written = await Delivery.unpackEncrypted(blob, key, 'pid', target.path);
      expect(work.listSync(), hasLength(1), reason: 'no temporary plaintext next to the blob');
      expect(written.map(p.basename), ['report.pdf', 'Ünïcode name.txt', 'empty.bin', 'report (2).pdf']);
      for (var i = 0; i < paths.length; i++) {
        expect(File(written[i]).readAsBytesSync(), File(paths[i]).readAsBytesSync());
      }
    });

    test('a damaged or foreign blob leaves no files in the target', () async {
      final blob = p.join(work.path, 'payload.rcb');
      await Delivery.packEncrypted(files(), blob, key, 'pid');
      final bytes = File(blob).readAsBytesSync();

      // Last chunk damaged: the first files were already written, then removed.
      final damaged = Uint8List.fromList(bytes)..[bytes.length - 3] ^= 1;
      File(blob).writeAsBytesSync(damaged);
      await expectLater(Delivery.unpackEncrypted(blob, key, 'pid', target.path), throwsA(isA<CryptoException>()));
      expect(target.existsSync(), isFalse);

      // Cut off after the first chunk (truncation).
      File(blob).writeAsBytesSync(bytes.sublist(0, BlobCrypto.prefixLength + BlobCrypto.defaultChunkSize + 16));
      await expectLater(Delivery.unpackEncrypted(blob, key, 'pid', target.path), throwsA(isA<CryptoException>()));
      expect(target.existsSync(), isFalse);

      // Wrong key or swapped blob id.
      File(blob).writeAsBytesSync(bytes);
      await expectLater(Delivery.unpackEncrypted(blob, randomBytes(32), 'pid', target.path),
          throwsA(isA<CryptoException>()));
      await expectLater(Delivery.unpackEncrypted(blob, key, 'other', target.path), throwsA(isA<CryptoException>()));
      expect(target.existsSync(), isFalse);

      // An existing target folder is kept, only the new files are removed.
      target.createSync();
      File(p.join(target.path, 'mine.txt')).writeAsStringSync('keep');
      File(blob).writeAsBytesSync(damaged);
      await expectLater(Delivery.unpackEncrypted(blob, key, 'pid', target.path), throwsA(isA<CryptoException>()));
      expect(target.listSync().map((e) => p.basename(e.path)), ['mine.txt']);
    });

    test('downloads stay encrypted until the user saves them', () async {
      final store = MemoryStore();
      final alice = await Identity.generate('alice');
      final bob = await Identity.generate('bob');
      final a = await createGroup(alice, store);
      await a.addMember(bob.joinRequest);
      final b = await joinGroup(bob, store, a.fingerprint);
      final f = await writeFile('plan.txt', 0);
      File(f).writeAsStringSync('the secret plan');
      await a.send(recipientIds: [bob.userId], paths: [f], note: '', lifetime: const Duration(days: 1));
      await b.sync();
      final entry = b.inbox.single;

      await expectLater(b.saveFiles(entry, target), throwsA(isA<SyncException>()), reason: 'not downloaded');
      await b.download(entry);
      expect(b.isDownloaded(entry), isTrue);
      // Nothing readable anywhere in the app's folders.
      for (final file in tmp.listSync(recursive: true).whereType<File>()) {
        if (p.isWithin(src.path, file.path) || file.path == f) continue;
        expect(utf8.decode(file.readAsBytesSync(), allowMalformed: true), isNot(contains('the secret plan')),
            reason: file.path);
      }
      final out = await b.saveFiles(entry, target);
      expect(p.isWithin(target.path, out), isTrue);
      expect(p.basename(out), matches(RegExp(r'^\d{4}-\d\d-\d\d \d{4}$')), reason: 'no sender in the folder name');
      expect(File(p.join(out, 'plan.txt')).readAsStringSync(), 'the secret plan');

      await b.deleteDownload(entry);
      expect(b.isDownloaded(entry), isFalse);
    });

  });

  test('file names from other users are sanitized', () {
    expect(Delivery.safeFileName('../../etc/passwd'), '_.._etc_passwd');
    expect(Delivery.safeFileName(r'C:\evil.exe'), 'C__evil.exe');
    expect(Delivery.safeFileName('...'), 'file');
    expect(Delivery.safeFileName('ok name.txt'), 'ok name.txt');
  });

  group('file hosts', () {
    late MemoryStore store;
    late Identity alice, bob;
    late GroupSession a, b;

    setUp(() async {
      store = MemoryStore();
      alice = await Identity.generate('alice');
      bob = await Identity.generate('bob');
      a = await createGroup(alice, store);
      await a.addMember(bob.joinRequest);
      b = await joinGroup(bob, store, a.fingerprint);
    });

    test('a failing host is skipped', () async {
      hostA.fail = true;
      final f = await writeFile('big.bin', 2 * 1024 * 1024 + 3);
      await a.send(recipientIds: [bob.userId], paths: [f], note: '', lifetime: const Duration(days: 1));
      expect(hostA.uploads, 0);
      expect(hostB.uploads, greaterThan(1));
      await b.sync();
      final out = await receive(b, b.inbox.single, Directory(p.join(tmp.path, 'dl')));
      expect(await File(p.join(out, 'big.bin')).readAsBytes(), await File(f).readAsBytes());
    });

    test('when every host fails, nothing is published', () async {
      hostA.fail = true;
      hostB.fail = true;
      final f = await writeFile('x.bin', 10);
      await expectLater(
          a.send(recipientIds: [bob.userId], paths: [f], note: '', lifetime: const Duration(days: 1)),
          throwsA(isA<HostException>()));
      await b.sync();
      expect(b.inbox, isEmpty);
    });

    test('a part changed at the host is detected', () async {
      final f = await writeFile('x.bin', 50000);
      await a.send(recipientIds: [bob.userId], paths: [f], note: '', lifetime: const Duration(days: 1));
      final url = FakeHost.files.keys.single;
      FakeHost.files[url] = Uint8List.fromList([...FakeHost.files[url]!]..[100] ^= 1);
      await b.sync();
      await expectLater(receive(b, b.inbox.single, Directory(p.join(tmp.path, 'dl'))),
          throwsA(isA<HostException>()));
    });

    test('a missing part is reported', () async {
      final f = await writeFile('x.bin', 10);
      await a.send(recipientIds: [bob.userId], paths: [f], note: '', lifetime: const Duration(days: 1));
      FakeHost.files.clear();
      await b.sync();
      await expectLater(receive(b, b.inbox.single, Directory(p.join(tmp.path, 'dl'))),
          throwsA(isA<HostException>()));
    });

    test('lifetimes longer than the hosts keep files are refused', () async {
      final f = await writeFile('x.bin', 10);
      expect(a.maxLifetime, const Duration(days: 6));
      await expectLater(
          a.send(recipientIds: [bob.userId], paths: [f], note: '', lifetime: const Duration(days: 7)),
          throwsA(isA<SyncException>()));
    });

    test("parts are cut to each host's limit; small hosts only take small deliveries", () async {
      final small = FakeHost('small', limit: 8192);
      final s1 = await GroupSession.open(
          identity: alice,
          local: a.local,
          store: store,
          hosting: Hosting([small, hostA], () async => HttpClient()),
          persist: () async {},
          tempDir: tmp);
      await s1.sync();
      // 100 KB fits into 32 small parts. With hostA down, the small host
      // takes every part, each cut to its own limit.
      hostA.fail = true;
      final f = await writeFile('mid.bin', 100 * 1024);
      await s1.send(recipientIds: [bob.userId], paths: [f], note: '', lifetime: const Duration(days: 1));
      expect(small.uploads, greaterThan(10));
      expect(small.sizes.every((n) => n <= 8192), isTrue);
      hostA.fail = false;
      // 3 MB would need far more than 32 small parts: only hostA is used.
      small.uploads = 0;
      final big = await writeFile('big.bin', 3 * 1024 * 1024);
      await s1.send(recipientIds: [bob.userId], paths: [big], note: '', lifetime: const Duration(days: 1));
      expect(small.uploads, 0);

      final b1 = await GroupSession.open(
          identity: bob,
          local: b.local,
          store: store,
          hosting: Hosting([small, hostA], () async => HttpClient()),
          persist: () async {},
          tempDir: tmp);
      await b1.sync();
      for (final entry in b1.inbox) {
        final out = await receive(b1, entry, Directory(p.join(tmp.path, 'dl')));
        final name = entry.files.single.name;
        expect(await File(p.join(out, name)).readAsBytes(),
            await File(name == 'mid.bin' ? f : big).readAsBytes());
      }
    });

    test('an interrupted download continues with the first missing part', () async {
      // 2 MB + 3 bytes at 1 MB per part: parts go to hostA, hostB, hostA.
      final f = await writeFile('big.bin', 2 * 1024 * 1024 + 3);
      await a.send(recipientIds: [bob.userId], paths: [f], note: '', lifetime: const Duration(days: 1));
      await b.sync();
      final entry = b.inbox.single;
      expect(entry.payload.parts.length, 3);
      hostB.failDownload = true;
      await expectLater(receive(b, entry, Directory(p.join(tmp.path, 'dl'))), throwsA(isA<HostException>()));
      expect(b.partialParts(entry), 1);
      expect(hostA.downloads, 1);

      hostB.failDownload = false;
      final out = await receive(b, entry, Directory(p.join(tmp.path, 'dl')));
      expect(await File(p.join(out, 'big.bin')).readAsBytes(), await File(f).readAsBytes());
      expect(hostA.downloads + hostB.downloads, 3, reason: 'no part is downloaded twice');
      expect(b.isDownloaded(entry), isTrue, reason: 'the encrypted copy stays until it is deleted');
    });

    test('a cancelled download keeps its parts and can be resumed', () async {
      final f = await writeFile('big.bin', 2 * 1024 * 1024 + 3);
      await a.send(recipientIds: [bob.userId], paths: [f], note: '', lifetime: const Duration(days: 1));
      await b.sync();
      final entry = b.inbox.single;
      final token = CancelToken();
      await expectLater(
          b.download(entry, cancel: token, onProgress: (t, args, _) {
            if (args['i'] == 2) token.cancel();
          }),
          throwsA(isA<CancelledException>()));
      expect(b.partialParts(entry), 2);
      final out = await receive(b, entry, Directory(p.join(tmp.path, 'dl')));
      expect(await File(p.join(out, 'big.bin')).readAsBytes(), await File(f).readAsBytes());
      expect(hostA.downloads + hostB.downloads, 3);
    });

    test('a cancelled upload publishes nothing and removes uploaded parts', () async {
      final f = await writeFile('big.bin', 2 * 1024 * 1024 + 3);
      final token = CancelToken();
      await expectLater(
          a.send(
              recipientIds: [bob.userId],
              paths: [f],
              note: '',
              lifetime: const Duration(days: 1),
              cancel: token,
              onProgress: (t, args, _) {
                if (args['i'] == 2) token.cancel();
              }),
          throwsA(isA<CancelledException>()));
      expect(FakeHost.files, isEmpty);
      await b.sync();
      expect(b.inbox, isEmpty);
    });

    test('hiding an entry removes its interrupted download', () async {
      final f = await writeFile('big.bin', 2 * 1024 * 1024 + 3);
      await a.send(recipientIds: [bob.userId], paths: [f], note: '', lifetime: const Duration(days: 1));
      await b.sync();
      final entry = b.inbox.single;
      hostB.failDownload = true;
      await expectLater(receive(b, entry, Directory(p.join(tmp.path, 'dl'))), throwsA(isA<HostException>()));
      expect(b.partialParts(entry), 1);
      await b.hide(entry);
      expect(b.partialParts(entry), isNull);
      expect(Directory(p.join(b.partialDir.path, entry.id)).existsSync(), isFalse);
    });

    test('links to foreign domains are refused', () async {
      expect(() => hostA.checkLink('https://evil.example/x.zip'), throwsA(isA<HostException>()));
      expect(() => hostA.checkLink('http://hosta.test/x.zip'), throwsA(isA<HostException>()));
      expect(hostA.checkLink('https://hosta.test/x.zip').host, 'hosta.test');
    });
  });
}
