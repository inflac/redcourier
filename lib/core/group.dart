import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'crypto_util.dart';
import 'delivery.dart';
import 'hosts.dart';
import 'identity.dart';
import 'remote.dart';
import 'messages.dart';

// ── Format constants ─────────────────────────────────────────────────────────

const syncFormat = 'redcourier-sync';
const syncFormatVersion = 3;

const roleAdmin = 'admin';
const roleMember = 'member';
const roleRemoved = 'removed';

const maxNoteLength = 2000;
const maxFilesPerEntry = 50;

/// Hosts with small upload limits are skipped if a delivery needs more parts.
const maxPartsPerHost = 32;

const _ctxGroupKey = 'group-key';
const _ctxFilesSignKey = 'files-sign-key';
const _ctxAdminSignKey = 'admin-sign-key';
String _ctxEntryKey(String id) => 'entry-key/$id';
const _aadUserDetails = 'rc/user-details';
String _aadEntry(String id) => 'rc/entry/$id';

const _domainUsers = 'redcourier/users/v1';
const _domainFiles = 'redcourier/files/v1';
const _domainEntry = 'redcourier/entry/v1';

// ── Errors ───────────────────────────────────────────────────────────────────

class SyncException extends AppException {
  SyncException(super.template, [super.args]);
}

/// The admin signing key differs from the one this device trusts. The user
/// must compare [fingerprint] with the admin over a trusted channel.
class TrustException extends SyncException {
  final String fingerprint;
  final bool firstContact;
  TrustException(this.fingerprint, {this.firstContact = false})
      : super(firstContact
            ? 'Confirm the group fingerprint before the first sync.'  // i18n
            : 'The group signing key changed. Confirm the new fingerprint with your admin.');  // i18n
}

class NotMemberException extends SyncException {
  NotMemberException()
      : super('You are not (or no longer) a member of this group. '
            'Ask an admin to add you with your join request.');
}

// ── Local state per device ───────────────────────────────────────────────────

/// Group data this device stores in its encrypted vault.
class GroupLocal {
  WebDavConfig webdav;
  String? trustedAdminKey;
  int usersVersion;
  int filesVersion;
  final Set<String> seen;
  final Set<String> hidden;

  GroupLocal({
    required this.webdav,
    this.trustedAdminKey,
    this.usersVersion = 0,
    this.filesVersion = 0,
    Set<String>? seen,
    Set<String>? hidden,
  })  : seen = seen ?? {},
        hidden = hidden ?? {};

  Map<String, dynamic> toJson() => {
        'webdav': webdav.toJson(),
        'trusted_admin_key': trustedAdminKey,
        'users_version': usersVersion,
        'files_version': filesVersion,
        'seen': seen.toList(),
        'hidden': hidden.toList(),
      };

  static GroupLocal fromJson(Map<String, dynamic> json) => GroupLocal(
        webdav: WebDavConfig.fromJson(json['webdav'] as Map),
        trustedAdminKey: json['trusted_admin_key'] as String?,
        usersVersion: json['users_version'] as int? ?? 0,
        filesVersion: json['files_version'] as int? ?? 0,
        seen: {...(json['seen'] as List? ?? const []).cast<String>()},
        hidden: {...(json['hidden'] as List? ?? const []).cast<String>()},
      );
}

// ── Decrypted view models ────────────────────────────────────────────────────

class Member {
  final String id;
  final String identifier;
  final String role;
  final Uint8List encPub;
  Member(this.id, this.identifier, this.role, this.encPub);
  bool get isAdmin => role == roleAdmin;
  bool get isActive => role != roleRemoved;
}

class EntryFile {
  final String name;
  final int size;
  EntryFile(this.name, this.size);
}

/// Where the encrypted delivery lives: one or more ZIP parts at file hosts.
class DeliveryPayload {
  final String id;
  final Uint8List key;
  final List<HostedPart> parts;

  /// Delivery.payloadFormat.
  final String format;
  DeliveryPayload(this.id, this.key, this.parts, [this.format = Delivery.payloadFormat]);
}

class Entry {
  final String id;
  final String senderId;
  final String senderName;
  final DateTime created;
  final DateTime expires;
  final String note;
  final List<EntryFile> files;
  final DeliveryPayload payload;
  final List<String> to;
  final bool sentByMe;
  final bool forMe;

  Entry({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.created,
    required this.expires,
    required this.note,
    required this.files,
    required this.payload,
    required this.to,
    required this.sentByMe,
    required this.forMe,
  });

  int get totalSize => files.fold(0, (s, f) => s + f.size);
  bool get isExpired => DateTime.now().isAfter(expires);
}

class SyncResult {
  final int newEntries;
  final int rejectedEntries;
  SyncResult(this.newEntries, this.rejectedEntries);
}

// ── Verification of a downloaded sync.json ───────────────────────────────────

class _Verified {
  final Map<String, dynamic> doc;
  final String adminPub;
  final String filesPub;
  final Map<String, Map<String, dynamic>> members;
  final Map<String, Map<String, dynamic>> entries; // only entries with valid signatures
  final int usersVersion;
  final int filesVersion;
  final int rejected;
  _Verified(this.doc, this.adminPub, this.filesPub, this.members, this.entries,
      this.usersVersion, this.filesVersion, this.rejected);
}

Uint8List _usersMessage(Map doc) => canonicalBytes(_domainUsers, {
      'format': doc['format'],
      'format_version': doc['format_version'],
      'users': doc['users'],
    });

Uint8List _filesMessage(Map doc) => canonicalBytes(_domainFiles, {
      'format': doc['format'],
      'format_version': doc['format_version'],
      'files': doc['files'],
    });

Uint8List _entryMessage(String id, Map entry) {
  final unsigned = Map<String, dynamic>.from(entry)..remove('sig');
  return canonicalBytes(_domainEntry, {'id': id, 'entry': unsigned});
}

Map<String, dynamic> _map(Object? v, String what) {
  if (v is Map<String, dynamic>) return v;
  throw SyncException('sync.json is malformed ({what}).', {'what': what});
}

int _int(Object? v, String what) {
  if (v is int && v >= 0) return v;
  throw SyncException('sync.json is malformed ({what}).', {'what': what});
}

Future<_Verified> _verify(Uint8List bytes) async {
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes));
  } catch (_) {
    throw SyncException('sync.json is not valid JSON.');
  }
  final doc = _map(decoded, 'root');
  if (doc['format'] != syncFormat) throw SyncException('This is not a RedCourier sync file.');
  if (doc['format_version'] != syncFormatVersion) {
    throw SyncException('Unsupported sync format version. Please update the app.');
  }
  final users = _map(doc['users'], 'users');
  final files = _map(doc['files'], 'files');
  final signKeys = _map(users['sign_keys'], 'sign_keys');
  final adminPub = signKeys['admin'];
  final filesPub = signKeys['files'];
  if (adminPub is! String || filesPub is! String) throw SyncException('Signing keys missing.');

  if (!await verify(adminPub, doc['users_sig'], _usersMessage(doc))) {
    throw SyncException('The user list signature is invalid. The file may have been tampered with.');
  }
  if (!await verify(filesPub, doc['files_sig'], _filesMessage(doc))) {
    throw SyncException('The file list signature is invalid. The file may have been tampered with.');
  }

  final members = <String, Map<String, dynamic>>{};
  _map(users['members'], 'members').forEach((id, m) {
    final member = _map(m, 'member');
    if (!isValidUserId(id)) throw SyncException('sync.json contains an invalid user id.');
    final enc = b64d(member['enc_pub']);
    final sig = b64d(member['sig_pub']);
    final kem = b64d(member['kem_pub']);
    if (enc.length != 32 || sig.length != 32 || kem.length != mlkemPublicKeyLength) {
      throw SyncException('sync.json contains an invalid public key.');
    }
    if (userIdFor(enc, sig, kem) != id) throw SyncException('A user id does not match its keys.');
    if (![roleAdmin, roleMember, roleRemoved].contains(member['role'])) {
      throw SyncException('sync.json contains an unknown role.');
    }
    members[id] = member;
  });

  final entries = <String, Map<String, dynamic>>{};
  var rejected = 0;
  for (final e in _map(files['entries'], 'entries').entries) {
    try {
      final entry = _map(e.value, 'entry');
      final sender = members[entry['sender']];
      if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(e.key) ||
          sender == null ||
          entry['created'] is! int ||
          entry['expires'] is! int ||
          entry['recipients'] is! List ||
          !await verify(sender['sig_pub'], entry['sig'], _entryMessage(e.key, entry))) {
        rejected++;
        continue;
      }
      entries[e.key] = entry;
    } on SyncException {
      rejected++;
    } on CryptoException {
      rejected++;
    }
  }

  return _Verified(doc, adminPub, filesPub, members, entries,
      _int(users['version'], 'users version'), _int(files['version'], 'files version'), rejected);
}

// ── Mutable copy used while preparing a write ────────────────────────────────

class _Draft {
  final Map<String, dynamic> doc;
  Uint8List groupKey;
  Uint8List filesSeed;
  Uint8List? adminSeed;
  bool usersChanged = false;
  bool filesChanged = false;

  _Draft(Map<String, dynamic> original, this.groupKey, this.filesSeed, this.adminSeed)
      : doc = jsonDecode(jsonEncode(original)) as Map<String, dynamic>;

  Map<String, dynamic> get users => doc['users'] as Map<String, dynamic>;
  Map<String, dynamic> get members => users['members'] as Map<String, dynamic>;
  Map<String, dynamic> get signKeys => users['sign_keys'] as Map<String, dynamic>;
  Map<String, dynamic> get entries =>
      (doc['files'] as Map<String, dynamic>)['entries'] as Map<String, dynamic>;

  Future<Map<String, String>> readNames() async {
    final raw = await symDecrypt(groupKey, users['user_details'], _aadUserDetails);
    return (jsonDecode(utf8.decode(raw)) as Map).cast<String, String>();
  }

  Future<void> writeNames(Map<String, String> names) async {
    users['user_details'] =
        await symEncrypt(groupKey, utf8.encode(canonicalJson(names)), _aadUserDetails);
  }

  /// Hand the group's shared keys to an active member according to its role.
  Future<void> sealKeysFor(Map<String, dynamic> member) async {
    final pub = b64d(member['enc_pub']);
    final kem = b64d(member['kem_pub']);
    member['group_key'] = await seal(pub, kem, groupKey, _ctxGroupKey);
    member['files_sign_key'] = await seal(pub, kem, filesSeed, _ctxFilesSignKey);
    if (member['role'] == roleAdmin) {
      member['admin_sign_key'] = await seal(pub, kem, adminSeed!, _ctxAdminSignKey);
    } else {
      member.remove('admin_sign_key');
    }
  }

  Future<void> resealAll() async {
    for (final m in members.values) {
      final member = m as Map<String, dynamic>;
      if (member['role'] != roleRemoved) await sealKeysFor(member);
    }
  }
}

// ── Group session ────────────────────────────────────────────────────────────

/// An unlocked group: verified, decrypted state plus all operations.
class GroupSession {
  final Identity identity;
  final GroupLocal local;
  final RemoteStore store;

  /// File hosts for the encrypted deliveries, in order of preference.
  final List<FileHost> hosts;

  /// HTTP client for the file hosts (Tor in the app).
  final Future<HttpClient> Function() hostClient;

  /// Called whenever [local] changed and must be persisted.
  final Future<void> Function() persist;

  /// Where downloaded files and temporary data go.
  final Directory tempDir;

  /// Interrupted downloads, kept so they can be resumed (one folder per entry).
  final Directory partialDir;

  late SealKeyPair _sealKey;
  _Verified? _state;
  Uint8List? _groupKey;
  Uint8List? _filesSeed;
  Uint8List? _adminSeed;
  String _role = roleMember;
  Map<String, String> _names = {};
  List<Entry> _entries = [];
  int _rejected = 0;
  Future<void> _queue = Future.value();

  GroupSession._(this.identity, this.local, this.store, this.hosts, this.hostClient, this.persist,
      this.tempDir, Directory? partialDir)
      : partialDir = partialDir ?? Directory(p.join(tempDir.path, 'partial'));

  // ── Public state ──

  String get myId => identity.userId;
  bool get isAdmin => _role == roleAdmin;
  bool get isLoaded => _state != null;
  String get fingerprint => adminKeyFingerprint(_state!.adminPub);
  int get rejectedEntries => _rejected;

  List<Member> get members {
    final s = _state;
    if (s == null) return [];
    final list = s.members.entries
        .map((e) => Member(e.key, _names[e.key] ?? '(unknown)', e.value['role'] as String,
            b64d(e.value['enc_pub'])))
        .toList()
      ..sort((a, b) => a.identifier.toLowerCase().compareTo(b.identifier.toLowerCase()));
    return list;
  }

  List<Member> get activeMembers => members.where((m) => m.isActive).toList();

  String nameOf(String userId) => _names[userId] ?? '(unknown)';

  List<Entry> get inbox => _entries
      .where((e) => e.forMe && !e.sentByMe && !e.isExpired && !local.hidden.contains(e.id))
      .toList()
    ..sort((a, b) => b.created.compareTo(a.created));

  List<Entry> get sent => _entries.where((e) => e.sentByMe && !e.isExpired).toList()
    ..sort((a, b) => b.created.compareTo(a.created));

  bool isNew(Entry e) => !local.seen.contains(e.id);

  // ── Construction ──

  static Future<GroupSession> _make(Identity identity, GroupLocal local, RemoteStore store,
      Hosting hosting, Future<void> Function() persist, Directory tempDir, Directory? partialDir) async {
    final s = GroupSession._(
        identity, local, store, hosting.hosts, hosting.client, persist, tempDir, partialDir);
    s._sealKey = await identity.sealKeyPair();
    return s;
  }

  /// Create a new group in an empty WebDAV folder. The creator becomes admin.
  ///
  /// Creating can be retried safely: before uploading, the new admin key is
  /// handed to [rememberAdminKey] (stored in the vault). If the folder already
  /// holds a group whose admin key is one of [ownAdminKeys] (an earlier
  /// attempt whose reply was lost, for example in a timeout), that group is
  /// taken over instead of being reported as foreign. Nobody else can sign
  /// with these keys, so this cannot be abused to plant a group.
  static Future<GroupSession> create({
    required Identity identity,
    required WebDavConfig webdav,
    required RemoteStore store,
    required Hosting hosting,
    required Future<void> Function(GroupLocal) persistLocal,
    required Directory tempDir,
    Directory? partialDir,
    Iterable<String> ownAdminKeys = const [],
    Future<void> Function(String adminPub)? rememberAdminKey,
  }) async {
    final local = GroupLocal(webdav: webdav);
    final session =
        await _make(identity, local, store, hosting, () => persistLocal(local), tempDir, partialDir);

    final adminSeed = randomBytes(32);
    final filesSeed = randomBytes(32);
    final groupKey = randomBytes(32);
    final adminPub = b64e(await ed25519PublicKey(adminSeed));

    final doc = <String, dynamic>{
      'format': syncFormat,
      'format_version': syncFormatVersion,
      'users': {
        'version': 1,
        'sign_keys': {'admin': adminPub, 'files': b64e(await ed25519PublicKey(filesSeed))},
        'members': {
          identity.userId: {
            'enc_pub': b64e(identity.encPub),
            'sig_pub': b64e(identity.sigPub),
            'kem_pub': b64e(identity.kemPub),
            'role': roleAdmin,
          },
        },
        'user_details': null,
      },
      'files': {'version': 1, 'entries': <String, dynamic>{}},
    };
    final draft = _Draft(doc, groupKey, filesSeed, adminSeed);
    await draft.writeNames({identity.userId: identity.identifier});
    await draft.resealAll();
    final out = draft.doc;
    out['users_sig'] = await sign(adminSeed, _usersMessage(out));
    out['files_sig'] = await sign(filesSeed, _filesMessage(out));

    // Takes over a group this device created in an earlier attempt.
    Future<GroupSession> adoptOrFail(Uint8List remote, Set<String> own) async {
      final _Verified v;
      try {
        v = await _verify(remote);
      } on SyncException {
        throw SyncException('This folder already contains a RedCourier group. Join it instead.');
      }
      if (!own.contains(v.adminPub)) {
        throw SyncException('This folder already contains a RedCourier group. Join it instead.');
      }
      local.trustedAdminKey = v.adminPub;
      await session._load(v);
      await session.persist();
      return session;
    }

    final existing = await store.getSync();
    if (existing != null) return adoptOrFail(existing.bytes, {...ownAdminKeys});

    await rememberAdminKey?.call(adminPub);
    final bytes = _encode(out);
    try {
      await store.putSync(bytes, createOnly: true);
    } on ConflictException {
      // Someone wrote first, possibly this very request retried on the way.
      final again = await store.getSync();
      if (again == null) rethrow;
      return adoptOrFail(again.bytes, {...ownAdminKeys, adminPub});
    }
    local.trustedAdminKey = adminPub;
    await session._load(await _verify(bytes));
    await session.persist();
    return session;
  }

  /// Join an existing group the admin invited us to. [fingerprint] came
  /// from the admin over a second channel; the group must match it.
  static Future<GroupSession> join({
    required Identity identity,
    required Invite invite,
    required String fingerprint,
    required RemoteStore store,
    required Hosting hosting,
    required Future<void> Function(GroupLocal) persistLocal,
    required Directory tempDir,
    Directory? partialDir,
  }) async {
    final local = GroupLocal(webdav: invite.webdav);
    final session =
        await _make(identity, local, store, hosting, () => persistLocal(local), tempDir, partialDir);
    await session.sync(confirmedFingerprint: fingerprint);
    return session;
  }

  /// Open the group stored on this device.
  static Future<GroupSession> open({
    required Identity identity,
    required GroupLocal local,
    required RemoteStore store,
    required Hosting hosting,
    required Future<void> Function() persist,
    required Directory tempDir,
    Directory? partialDir,
  }) =>
      _make(identity, local, store, hosting, persist, tempDir, partialDir);

  /// Load a cached copy (offline start). Same checks as a download.
  Future<void> loadCached(Uint8List bytes) async {
    final v = await _verify(bytes);
    _checkTrust(v, null);
    await _load(v);
  }

  Uint8List? get cachedBytes => _state == null ? null : _encode(_state!.doc);

  // ── Sync ──

  /// Download sync.json, verify it and update the local view.
  Future<SyncResult> sync({String? confirmedFingerprint}) => _serial(() async {
        final file = await store.getSync();
        if (file == null) throw SyncException('No sync.json found in the WebDAV folder.');
        final before = _entries.where((e) => e.forMe && !e.sentByMe).map((e) => e.id).toSet();
        final hadState = _state != null;
        final v = await _verify(file.bytes);
        _checkTrust(v, confirmedFingerprint);
        _checkRollback(v);
        await _load(v);
        await persist();
        await _cleanupPartials();
        final fresh = _entries
            .where((e) => e.forMe && !e.sentByMe && !e.isExpired && !before.contains(e.id))
            .length;
        return SyncResult(hadState ? fresh : inbox.where(isNew).length, v.rejected);
      });

  void _checkTrust(_Verified v, String? confirmedFingerprint) {
    if (local.trustedAdminKey == v.adminPub) return;
    final fp = adminKeyFingerprint(v.adminPub);
    if (confirmedFingerprint != null && normalizeFingerprint(confirmedFingerprint) == fp) {
      local.trustedAdminKey = v.adminPub;
      return;
    }
    throw TrustException(fp, firstContact: local.trustedAdminKey == null);
  }

  void _checkRollback(_Verified v) {
    if (v.usersVersion < local.usersVersion || v.filesVersion < local.filesVersion) {
      throw SyncException('The server returned an older version of sync.json than this device '
          'has already seen. This can be a replay attack. Nothing was changed.');
    }
  }

  /// Decrypt everything this user may read.
  Future<void> _load(_Verified v) async {
    final me = v.members[myId];
    if (me == null || me['role'] == roleRemoved) throw NotMemberException();
    final groupKey = await _sealKey.open(me['group_key'], _ctxGroupKey);
    final filesSeed = await _sealKey.open(me['files_sign_key'], _ctxFilesSignKey);
    if (b64e(await ed25519PublicKey(filesSeed)) != v.filesPub) {
      throw SyncException('The file signing key does not match. Ask an admin to re-add you.');
    }
    Uint8List? adminSeed;
    if (me['role'] == roleAdmin) {
      adminSeed = await _sealKey.open(me['admin_sign_key'], _ctxAdminSignKey);
      if (b64e(await ed25519PublicKey(adminSeed)) != v.adminPub) {
        throw SyncException('The admin signing key does not match.');
      }
    }
    final draft = _Draft(v.doc, groupKey, filesSeed, adminSeed);
    final names = await draft.readNames();

    final entries = <Entry>[];
    for (final e in v.entries.entries) {
      final entry = await _openEntry(e.key, e.value, names);
      if (entry != null) entries.add(entry);
    }

    _state = v;
    _groupKey = groupKey;
    _filesSeed = filesSeed;
    _adminSeed = adminSeed;
    _role = me['role'] as String;
    _names = names;
    _entries = entries;
    _rejected = v.rejected;
    local.usersVersion = v.usersVersion;
    local.filesVersion = v.filesVersion;
    local.hidden.retainAll(v.entries.keys);
    local.seen.retainAll(v.entries.keys);
  }

  Future<Entry?> _openEntry(String id, Map<String, dynamic> raw, Map<String, String> names) async {
    Uint8List? key;
    for (final sealed in raw['recipients'] as List) {
      try {
        key = await _sealKey.open(sealed, _ctxEntryKey(id));
        break;
      } on CryptoException {
        continue;
      }
    }
    if (key == null) return null;
    try {
      final data = jsonDecode(utf8.decode(await symDecrypt(key, raw['data'], _aadEntry(id))))
          as Map<String, dynamic>;
      final files = [
        for (final f in data['files'] as List)
          EntryFile((f as Map)['name'] as String, f['size'] as int),
      ];
      final payloadJson = data['payload'] as Map<String, dynamic>;
      final payloadId = payloadJson['id'] as String;
      final payloadKey = b64d(payloadJson['key']);
      final parts = [for (final part in payloadJson['parts'] as List) HostedPart.fromJson(part as Map)];
      if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(payloadId) || payloadKey.length != 32 || parts.isEmpty) {
        return null;
      }
      final to = (data['to'] as List).cast<String>();
      final sender = raw['sender'] as String;
      return Entry(
        id: id,
        senderId: sender,
        senderName: names[sender] ?? '(unknown)',
        created: DateTime.fromMillisecondsSinceEpoch((raw['created'] as int) * 1000),
        expires: DateTime.fromMillisecondsSinceEpoch((raw['expires'] as int) * 1000),
        note: data['note'] as String? ?? '',
        files: files,
        payload: DeliveryPayload(payloadId, payloadKey, parts, payloadJson['format'] as String? ?? ''),
        to: to,
        sentByMe: sender == myId,
        forMe: to.contains(myId),
      );
    } catch (_) {
      return null;
    }
  }

  // ── Writing ──

  Future<T> _serial<T>(Future<T> Function() body) {
    final completer = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        completer.complete(await body());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// Download the latest sync.json, apply [change] and upload it again.
  /// The upload only succeeds if nobody else wrote in between (ETag);
  /// otherwise the change is re-applied to the newer file.
  Future<void> _mutate(Future<void> Function(_Draft d) change) => _serial(() async {
        for (var attempt = 0; attempt < 5; attempt++) {
          final file = await store.getSync();
          if (file == null) throw SyncException('sync.json disappeared from the server.');
          final v = await _verify(file.bytes);
          _checkTrust(v, null);
          _checkRollback(v);
          await _load(v);

          final draft = _Draft(v.doc, _groupKey!, _filesSeed!, _adminSeed);
          await change(draft);
          if (!draft.usersChanged && !draft.filesChanged) return;

          final out = draft.doc;
          if (draft.usersChanged) {
            if (draft.adminSeed == null) throw SyncException('Only admins can change members.');
            draft.users['version'] = v.usersVersion + 1;
            out['users_sig'] = await sign(draft.adminSeed!, _usersMessage(out));
          }
          if (draft.filesChanged) {
            final files = out['files'] as Map<String, dynamic>;
            files['version'] = v.filesVersion + 1;
            out['files_sig'] = await sign(draft.filesSeed, _filesMessage(out));
          }
          final bytes = _encode(out);
          try {
            await store.putSync(bytes, ifMatch: file.etag);
          } on ConflictException {
            continue;
          }
          final written = await _verify(bytes);
          local.trustedAdminKey = written.adminPub; // we signed it ourselves
          await _load(written);
          await persist();
          return;
        }
        throw SyncException('sync.json keeps changing. Please try again in a moment.');
      });

  static Uint8List _encode(Map<String, dynamic> doc) =>
      Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent(' ').convert(doc)));

  // ── Sending ──

  FileHost? _host(String id) => hosts.where((h) => h.id == id).firstOrNull;

  /// The longest lifetime the configured hosts can keep files.
  Duration get maxLifetime =>
      hosts.map((h) => h.maxRetention).fold(Duration.zero, (a, b) => a > b ? a : b);

  /// Zip, encrypt and upload [paths] to the file hosts, then publish an entry
  /// with the links for [recipientIds]. Large deliveries are split into
  /// several ZIP parts; each part goes to the next host in turn and falls
  /// back to the other hosts on errors.
  Future<void> send({
    required List<String> recipientIds,
    required List<String> paths,
    required String note,
    required Duration lifetime,
    void Function(String template, Map<String, Object?> args, double? progress)? onProgress,
    CancelToken? cancel,
  }) async {
    final token = cancel ?? CancelToken();
    if (recipientIds.isEmpty) throw SyncException('Choose at least one recipient.');
    if (paths.isEmpty) throw SyncException('Choose at least one file.');
    if (paths.length > maxFilesPerEntry) throw SyncException('At most {n} files.', {'n': maxFilesPerEntry});
    if (note.length > maxNoteLength) throw SyncException('The note is too long.');
    final eligible = hosts.where((h) => h.maxRetention >= lifetime).toList();
    if (eligible.isEmpty) {
      throw SyncException('No hosting service keeps files that long. Choose a shorter time.');
    }

    final uploaded = <HostedPart>[];
    final work = await tempDir.createTemp('send_');
    try {
      final files = <Map<String, dynamic>>[
        for (final path in paths) {'name': p.basename(path), 'size': await File(path).length()},
      ];
      // The files are encrypted while they are read; no plaintext copy.
      onProgress?.call('Encrypting…', const {}, null);
      final payloadId = randomHex(16);
      final payloadKey = randomBytes(32);
      final blob = p.join(work.path, 'payload.rcb');
      await Delivery.packEncrypted(paths, blob, payloadKey, payloadId);
      token.throwIfCancelled();

      // Each part is cut to the size of the host that receives it. Hosts with
      // small limits are only used when the delivery fits into a few parts.
      final blobSize = await File(blob).length();
      final usable = eligible
          .where((h) => blobSize <= (h.maxBytes - Delivery.zipOverhead) * maxPartsPerHost)
          .toList();
      if (usable.isEmpty) throw SyncException('No hosting service accepts a delivery of this size.');

      var offset = 0;
      for (var i = 0; offset < blobSize || i == 0; i++) {
        Object? lastError;
        HostedPart? done;
        var length = 0;
        for (var k = 0; k < usable.length && done == null; k++) {
          token.throwIfCancelled();
          final host = usable[(i + k) % usable.length];
          length = [blobSize - offset, Delivery.defaultPartSize, host.maxBytes - Delivery.zipOverhead]
              .reduce((a, b) => a < b ? a : b);
          final partPath = await Delivery.makePart(blob, offset, length, work);
          final file = File(partPath);
          final args = {'i': i + 1, 'host': host.label};
          onProgress?.call('Part {i}: uploading to {host}…', args, 0);
          final client = await hostClient();
          final unregister = token.onCancel(() => client.close(force: true));
          try {
            done = await host.upload(client, file, p.basename(partPath), lifetime,
                onProgress: (v) => onProgress?.call('Part {i}: uploading to {host}…', args, v));
          } catch (e) {
            // A cancelled upload must not fall back to the next host.
            token.throwIfCancelled();
            lastError = e;
          } finally {
            unregister();
            client.close(force: true);
            await file.delete();
          }
        }
        if (done == null) {
          throw HostException('No hosting service accepted part {i}. Last error: {reason}',
              {'i': i + 1, 'reason': lastError});
        }
        uploaded.add(done);
        offset += length;
      }
      await File(blob).delete();
      token.throwIfCancelled();

      onProgress?.call('Publishing…', const {}, null);
      final id = randomHex(16);
      final now = DateTime.now();
      var expires = now.add(lifetime);
      for (final part in uploaded) {
        if (part.expires != null && part.expires!.isBefore(expires)) expires = part.expires!;
      }
      final data = {
        'note': note,
        'files': files,
        'to': recipientIds.toSet().toList(),
        'payload': {
          'format': Delivery.payloadFormat,
          'id': payloadId,
          'key': b64e(payloadKey),
          'parts': [for (final part in uploaded) part.toJson()],
        },
      };
      await _mutate((d) async {
        final recipients = {...recipientIds, myId};
        final sealed = <Map<String, String>>[];
        final entryKey = randomBytes(32);
        for (final r in recipients) {
          final m = d.members[r] as Map<String, dynamic>?;
          if (m == null || m['role'] == roleRemoved) {
            throw SyncException('A recipient is no longer a member of the group.');
          }
          sealed.add(await seal(b64d(m['enc_pub']), b64d(m['kem_pub']), entryKey, _ctxEntryKey(id)));
        }
        sealed.shuffle();
        final entry = <String, dynamic>{
          'sender': myId,
          'created': now.millisecondsSinceEpoch ~/ 1000,
          'expires': expires.millisecondsSinceEpoch ~/ 1000,
          'recipients': sealed,
          'data': await symEncrypt(entryKey, utf8.encode(jsonEncode(data)), _aadEntry(id)),
        };
        entry['sig'] = await sign(identity.sigSeed, _entryMessage(id, entry));
        d.entries[id] = entry;
        d.filesChanged = true;
      });
      local.seen.add(id);
      await persist();
    } catch (_) {
      await _deleteParts(uploaded);
      rethrow;
    } finally {
      try {
        await work.delete(recursive: true);
      } catch (_) {}
    }
  }

  // ── Receiving ──
  //
  // Received deliveries are only ever kept encrypted on this device
  // (partialDir/<entry id>/payload.rcb). The user saves the files to a folder
  // of their choice, for example an encrypted volume; only there is
  // plaintext written.

  Directory _partialFor(Entry entry) => Directory(p.join(partialDir.path, entry.id));

  /// How many parts of [entry] are on this device (encrypted), or null if
  /// none. Equal to the number of parts once the download is complete.
  int? partialParts(Entry entry) {
    try {
      final f = File(p.join(_partialFor(entry).path, 'progress.json'));
      if (!f.existsSync()) return null;
      final json = jsonDecode(f.readAsStringSync()) as Map;
      if (json['payload'] != entry.payload.id) return null;
      return json['done'] as int;
    } catch (_) {
      return null;
    }
  }

  /// True if all parts of [entry] are on this device, still encrypted.
  bool isDownloaded(Entry entry) => partialParts(entry) == entry.payload.parts.length;

  /// Downloads all parts of [entry] and checks them. The delivery stays
  /// encrypted on this device; [saveFiles] writes the files somewhere.
  ///
  /// Every finished part is kept. If the download is cancelled or fails, the
  /// next call continues with the first missing part.
  Future<void> download(Entry entry,
      {void Function(String template, Map<String, Object?> args, double? progress)? onProgress,
      CancelToken? cancel}) async {
    final token = cancel ?? CancelToken();
    final payload = entry.payload;
    final dir = _partialFor(entry);
    await dir.create(recursive: true);
    final blob = File(p.join(dir.path, 'payload.rcb'));
    final progressFile = File(p.join(dir.path, 'progress.json'));

    // Continue where the last attempt stopped. The blob is cut back to the
    // length recorded after the last finished part.
    var first = 0;
    final resumed = partialParts(entry);
    if (resumed != null && resumed <= payload.parts.length) {
      final length = (jsonDecode(await progressFile.readAsString()) as Map)['length'] as int;
      if (await blob.exists() && await blob.length() >= length) {
        final raf = await blob.open(mode: FileMode.append);
        await raf.truncate(length);
        await raf.close();
        first = resumed;
      }
    }
    if (first == 0) {
      if (await blob.exists()) await blob.delete();
      if (await progressFile.exists()) await progressFile.delete();
    }

    for (var i = first; i < payload.parts.length; i++) {
      token.throwIfCancelled();
      final part = payload.parts[i];
      final host = _host(part.host);
      if (host == null) {
        throw HostException('A part is stored at an unknown hosting service ({host}).', {'host': part.host});
      }
      final args = {'i': i + 1, 'n': payload.parts.length, 'host': host.label};
      onProgress?.call('Part {i}/{n}: downloading from {host}…', args, 0);
      final partFile = File(p.join(dir.path, 'part.zip'));
      final client = await hostClient();
      final unregister = token.onCancel(() => client.close(force: true));
      try {
        await host.download(client, part, partFile,
            onProgress: (v) => onProgress?.call('Part {i}/{n}: downloading from {host}…', args, v));
      } catch (_) {
        token.throwIfCancelled();
        rethrow;
      } finally {
        unregister();
        client.close(force: true);
      }
      if (await partFile.length() != part.size ||
          await sha256HexOfStream(partFile.openRead()) != part.sha256) {
        await partFile.delete();
        throw HostException('Part {i} was changed at the hosting service.', {'i': i + 1});
      }
      await Delivery.appendPart(partFile.path, blob.path);
      await partFile.delete();
      final tmp = File('${progressFile.path}.tmp');
      await tmp.writeAsString(
          jsonEncode({'payload': payload.id, 'done': i + 1, 'length': await blob.length()}));
      await tmp.rename(progressFile.path);
    }
    token.throwIfCancelled();
    local.seen.add(entry.id);
    await persist();
  }

  /// Decrypts the downloaded [entry] straight into a new folder inside
  /// [targetDir] (`<sender> <date> <time>`) and returns that folder. Nothing
  /// is written anywhere else. If the delivery turns out to be damaged, the
  /// files written so far are deleted again. The encrypted copy stays until
  /// [deleteDownload] or until the delivery is removed or expires.
  Future<String> saveFiles(Entry entry, Directory targetDir,
      {void Function(String template, Map<String, Object?> args, double? progress)? onProgress}) async {
    if (entry.payload.format != Delivery.payloadFormat) {
      throw SyncException('This delivery uses a format this version cannot read.');
    }
    if (!isDownloaded(entry)) throw SyncException('Download the delivery first.');
    final blob = File(p.join(_partialFor(entry).path, 'payload.rcb'));
    onProgress?.call('Decrypting…', const {}, null);
    final stamp = entry.created;
    String two(int v) => v.toString().padLeft(2, '0');
    final folderName = Delivery.safeFileName('${entry.senderName} ${stamp.year}-${two(stamp.month)}-'
        '${two(stamp.day)} ${two(stamp.hour)}${two(stamp.minute)}');
    var target = Directory(p.join(targetDir.path, folderName));
    for (var i = 2; await target.exists(); i++) {
      target = Directory(p.join(targetDir.path, '$folderName ($i)'));
    }
    await Delivery.unpackEncrypted(blob.path, entry.payload.key, entry.payload.id, target.path);
    return target.path;
  }

  /// Removes the encrypted copy of [entry] from this device.
  Future<void> deleteDownload(Entry entry) => _deletePartial(entry.id);

  /// Removes all encrypted copies of this group from this device.
  Future<void> deleteAllDownloads() async {
    try {
      if (await partialDir.exists()) await partialDir.delete(recursive: true);
    } catch (_) {}
  }

  Future<void> _deletePartial(String entryId) async {
    try {
      final d = Directory(p.join(partialDir.path, entryId));
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
  }

  /// Removes interrupted downloads of entries that are gone, expired or hidden.
  Future<void> _cleanupPartials() async {
    try {
      if (!await partialDir.exists()) return;
      final keep = inbox.map((e) => e.id).toSet();
      await for (final d in partialDir.list()) {
        if (d is Directory && !keep.contains(p.basename(d.path))) {
          await d.delete(recursive: true);
        }
      }
    } catch (_) {}
  }

  Future<void> markSeen(Entry entry) async {
    if (local.seen.add(entry.id)) await persist();
  }

  /// Remove an entry from this device's inbox only.
  Future<void> hide(Entry entry) async {
    local.hidden.add(entry.id);
    await persist();
    await _deletePartial(entry.id);
  }

  // ── Deleting ──

  /// Delete an entry for everyone (sender or admin). Where a host allows it,
  /// the uploaded parts are deleted too.
  Future<void> deleteEntry(String id) async {
    final parts = _entries.where((e) => e.id == id).expand((e) => e.payload.parts).toList();
    await _mutate((d) async {
      final e = d.entries[id] as Map<String, dynamic>?;
      if (e == null) return;
      if (e['sender'] != myId && d.adminSeed == null) {
        throw SyncException('Only the sender or an admin can delete this.');
      }
      d.entries.remove(id);
      d.filesChanged = true;
    });
    await _deletePartial(id);
    await _deleteParts(parts);
  }

  /// Remove expired entries. Any member may do this.
  Future<int> cleanupExpired() async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final s = _state;
    if (s == null || !s.entries.values.any((e) => (e['expires'] as int) < now)) return 0;
    final mine = _entries.where((e) => e.isExpired && e.sentByMe).expand((e) => e.payload.parts).toList();
    var removed = 0;
    await _mutate((d) async {
      final expired = d.entries.entries
          .where((e) => ((e.value as Map)['expires'] as int) < now)
          .map((e) => e.key)
          .toList();
      expired.forEach(d.entries.remove);
      removed = expired.length;
      if (removed > 0) d.filesChanged = true;
    });
    await _deleteParts(mine);
    return removed;
  }

  Future<void> _deleteParts(List<HostedPart> parts) async {
    for (final part in parts) {
      final host = _host(part.host);
      if (host == null) continue;
      try {
        final client = await hostClient();
        try {
          await host.delete(client, part);
        } finally {
          client.close(force: true);
        }
      } catch (_) {}
    }
  }

  // ── Member management (admins) ──

  void _requireAdmin(_Draft d) {
    if (d.adminSeed == null) throw SyncException('Only admins can manage members.');
  }

  Future<void> addMember(JoinRequest request, {bool admin = false}) => _mutate((d) async {
        _requireAdmin(d);
        final id = request.userId;
        final existing = d.members[id] as Map<String, dynamic>?;
        if (existing != null && existing['role'] != roleRemoved) {
          throw SyncException('{name} is already a member.', {'name': request.identifier});
        }
        final names = await d.readNames();
        final active = d.members.entries
            .where((e) => (e.value as Map)['role'] != roleRemoved)
            .map((e) => names[e.key]?.toLowerCase());
        if (active.contains(request.identifier.toLowerCase())) {
          throw SyncException('Another member already uses the identifier "{name}".', {'name': request.identifier});
        }
        final member = <String, dynamic>{
          'enc_pub': b64e(request.encPub),
          'sig_pub': b64e(request.sigPub),
          'kem_pub': b64e(request.kemPub),
          'role': admin ? roleAdmin : roleMember,
        };
        await d.sealKeysFor(member);
        d.members[id] = member;
        names[id] = request.identifier;
        await d.writeNames(names);
        d.usersChanged = true;
      });

  /// Remove a member. All shared keys the member knew are replaced, so the
  /// member cannot read the member list or sign changes any more.
  Future<void> removeMember(String id) => _mutate((d) async {
        _requireAdmin(d);
        if (id == myId) throw SyncException('You cannot remove yourself.');
        final m = d.members[id] as Map<String, dynamic>?;
        if (m == null || m['role'] == roleRemoved) return;
        final wasAdmin = m['role'] == roleAdmin;

        // Keep the public keys so entries this user sent stay verifiable.
        d.members[id] = {
          'enc_pub': m['enc_pub'],
          'sig_pub': m['sig_pub'],
          'kem_pub': m['kem_pub'],
          'role': roleRemoved,
        };

        final names = await d.readNames();
        d.groupKey = randomBytes(32);
        await d.writeNames(names);

        d.filesSeed = randomBytes(32);
        d.signKeys['files'] = b64e(await ed25519PublicKey(d.filesSeed));
        if (wasAdmin) {
          d.adminSeed = randomBytes(32);
          d.signKeys['admin'] = b64e(await ed25519PublicKey(d.adminSeed!));
        }
        await d.resealAll();
        d.usersChanged = true;
        d.filesChanged = true; // re-sign the file list with the new key
      });

  Future<void> setAdmin(String id, bool admin) => _mutate((d) async {
        _requireAdmin(d);
        if (id == myId) throw SyncException('You cannot change your own role.');
        final m = d.members[id] as Map<String, dynamic>?;
        if (m == null || m['role'] == roleRemoved) throw SyncException('User not found.');
        final newRole = admin ? roleAdmin : roleMember;
        if (m['role'] == newRole) return;
        m['role'] = newRole;
        if (!admin) {
          // The former admin knows the admin key: replace it.
          d.adminSeed = randomBytes(32);
          d.signKeys['admin'] = b64e(await ed25519PublicKey(d.adminSeed!));
          await d.resealAll();
        } else {
          await d.sealKeysFor(m);
        }
        d.usersChanged = true;
      });

  // ── WebDAV access ──

  /// Uses new WebDAV access data (URL, user, app password) on this device,
  /// for example after the admin changed the app password. [candidate]
  /// reaches the new folder. Nothing is saved unless it holds this very
  /// group: signatures valid and the admin key this device trusts (or, after
  /// an admin change, the [confirmedFingerprint] from an admin).
  Future<void> changeWebDav(WebDavConfig cfg, RemoteStore candidate, {String? confirmedFingerprint}) =>
      _serial(() async {
        final file = await candidate.getSync();
        if (file == null) {
          throw SyncException('No RedCourier group was found in this folder. Check the folder URL.');
        }
        final v = await _verify(file.bytes);
        if (v.adminPub != local.trustedAdminKey) {
          final fp = adminKeyFingerprint(v.adminPub);
          if (confirmedFingerprint == null || normalizeFingerprint(confirmedFingerprint) != fp) {
            throw TrustException(fp);
          }
          local.trustedAdminKey = v.adminPub;
        }
        final me = v.members[myId];
        if (me == null || me['role'] == roleRemoved) throw NotMemberException();
        local.webdav = cfg;
        await _load(v);
        await persist();
      });
}

/// File hosts plus the HTTP client used to reach them.
class Hosting {
  final List<FileHost> hosts;
  final Future<HttpClient> Function() client;
  const Hosting(this.hosts, this.client);
}
