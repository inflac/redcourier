import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'core/group.dart';
import 'core/hosts.dart';
import 'core/identity.dart';
import 'core/messages.dart';
import 'core/remote.dart';
import 'core/tor.dart';
import 'core/vault.dart';
import 'prefs.dart';

enum AppPhase { loading, noIdentity, locked, noGroup, ready }

/// Holds the unlocked state of the app and drives the screen flow.
///
/// The device can hold several groups. Each group lives in its own folder
/// with its own identity, password, WebDAV folder (and therefore its own
/// sync.json) and Tor circuits. Nothing is shared between groups.
class AppController extends ChangeNotifier {
  static const _defaultGroupKey = 'default_group';
  static final _nameRe = RegExp(r'^[\p{L}\p{N}][\p{L}\p{N}_ .\-]{0,39}$', unicode: true);

  /// The app uses WebDAV, the public file hosts and the system download
  /// folder, all through Tor. Tests pass in-memory replacements.
  AppController({this.storeFactory, this.hostingFactory});

  final RemoteStore Function(WebDavConfig Function() config)? storeFactory;
  final Hosting Function(String group)? hostingFactory;

  AppPhase phase = AppPhase.loading;
  late Directory dataDir;

  /// Local names of the groups on this device.
  List<String> groups = [];

  /// The selected group.
  String? groupName;
  String? defaultGroup;

  /// True while another group is being added next to existing ones.
  bool addingGroup = false;

  /// WebDAV data of the last failed attempt to create a group, so the user
  /// does not have to type it again (memory only).
  WebDavConfig? lastCreateAttempt;
  Object? lastCreateFailure;

  /// True while the group's sync.json is being created on the server (this
  /// can take a while through Tor). The setup screen shows progress.
  bool creatingGroup = false;

  Vault? _vault;
  VaultData? _data;
  GroupSession? session;

  Identity? get identity => _data?.identity;
  Directory get tempDir => Directory(p.join(dataDir.path, 'tmp'));
  Directory get _groupsDir => Directory(p.join(dataDir.path, 'groups'));
  Directory _groupDir(String name) => Directory(p.join(_groupsDir.path, name));
  File get _cacheFile => Vault.cacheFile(_groupDir(groupName!));

  /// Interrupted downloads of the selected group (encrypted parts only).
  Directory get _partialDir => Directory(p.join(_groupDir(groupName!).path, 'partial'));

  Future<void> init(Directory dir) async {
    dataDir = dir;
    try {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    } catch (_) {}
    await tempDir.create(recursive: true);
    await _loadGroups();
    defaultGroup = Prefs.getString(_defaultGroupKey);
    if (groups.isEmpty) {
      phase = AppPhase.noIdentity;
      notifyListeners();
    } else {
      selectGroup(groups.contains(defaultGroup) ? defaultGroup! : groups.first);
    }
  }

  Future<void> _loadGroups() async {
    final list = <String>[];
    if (await _groupsDir.exists()) {
      await for (final e in _groupsDir.list()) {
        if (e is Directory && await Vault.exists(e)) list.add(p.basename(e.path));
      }
    }
    list.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    groups = list;
  }

  /// Returns an error template or null.
  String? validateGroupName(String name) {
    final n = name.trim();
    if (!_nameRe.hasMatch(n) || n.endsWith('.')) {
      return 'Use letters, digits, spaces, dots, dashes or underscores, starting with a letter or digit.'; // i18n
    }
    if (groups.any((x) => x.toLowerCase() == n.toLowerCase())) {
      return 'A group with this name already exists on this device.'; // i18n
    }
    return null;
  }

  void selectGroup(String name) {
    _forgetUnlocked();
    groupName = name;
    addingGroup = false;
    phase = AppPhase.locked;
    notifyListeners();
  }

  Future<void> setDefaultGroup(bool isDefault) async {
    defaultGroup = isDefault ? groupName : null;
    await Prefs.set(_defaultGroupKey, defaultGroup);
    notifyListeners();
  }

  void startAddingGroup() {
    _forgetUnlocked();
    addingGroup = true;
    phase = AppPhase.noIdentity;
    notifyListeners();
  }

  void cancelAddingGroup() {
    if (groups.isEmpty) return;
    selectGroup(groups.contains(groupName) ? groupName! : groups.first);
  }

  void _forgetUnlocked() {
    _vault = null;
    _data = null;
    session = null;
    lastCreateAttempt = null;
    lastCreateFailure = null;
    creatingGroup = false;
  }

  /// File hosts for deliveries, reached through Tor on circuits separate
  /// from the sync traffic.
  Hosting get _hosting =>
      hostingFactory?.call(groupName!) ??
      Hosting(
          defaultHosts(
              tcp: (host, port, data) =>
                  TorNetwork.tcpExchange(host, port, data, isolation: '$groupName/files')),
          () => TorNetwork.createHttpClient(isolation: '$groupName/files'));

  RemoteStore _store(WebDavConfig initial) {
    WebDavConfig config() => _data?.group?.webdav ?? initial;
    return storeFactory?.call(config) ?? WebDavStore(config, clientFactory: TorNetwork.createHttpClient);
  }

  Future<void> _persist() async {
    final vault = _vault;
    final data = _data;
    if (vault == null || data == null) return;
    await vault.save(data);
    final bytes = session?.cachedBytes;
    if (bytes != null) await Vault.writeAtomic(_cacheFile, bytes);
  }

  Future<void> _persistLocal(GroupLocal local) async {
    _data!.group = local;
    await _vault!.save(_data!);
  }

  /// Creates a new local group with its own identity and password.
  /// It is connected to a WebDAV folder afterwards (join or create).
  Future<void> addGroup(String name, String identifier, String password) async {
    final n = name.trim();
    final error = validateGroupName(n);
    if (error != null) throw AppException(error);
    final dir = _groupDir(n);
    await dir.create(recursive: true);
    final id = await Identity.generate(identifier);
    final data = VaultData(id, null);
    _vault = await Vault.create(dir, password, data);
    _data = data;
    await _loadGroups();
    groupName = n;
    addingGroup = false;
    TorNetwork.isolationKey = n;
    phase = AppPhase.noGroup;
    notifyListeners();
  }

  Future<void> unlock(String password) async {
    final name = groupName!;
    final (vault, data) = await Vault.unlock(_groupDir(name), password);
    _vault = vault;
    _data = data;
    TorNetwork.isolationKey = name;
    final local = data.group;
    if (local != null) {
      final s = await GroupSession.open(
        identity: data.identity,
        local: local,
        store: _store(local.webdav),
        hosting: _hosting,
        persist: _persist,
        tempDir: tempDir,
        partialDir: _partialDir,
      );
      if (await _cacheFile.exists()) {
        try {
          await s.loadCached(await _cacheFile.readAsBytes());
        } catch (_) {
          // The cache is only for offline viewing; a fresh sync follows.
        }
      }
      session = s;
      phase = AppPhase.ready;
    } else {
      phase = AppPhase.noGroup;
    }
    notifyListeners();
  }

  /// Create the group's sync.json in an empty WebDAV folder (as admin).
  Future<void> createGroup(WebDavConfig cfg) async {
    lastCreateAttempt = cfg;
    creatingGroup = true;
    notifyListeners();
    final data = _data!;
    try {
      session = await GroupSession.create(
        identity: identity!,
        webdav: cfg,
        store: _store(cfg),
        hosting: _hosting,
        persistLocal: _persistLocal,
        tempDir: tempDir,
        partialDir: _partialDir,
        ownAdminKeys: data.pendingAdminKeys,
        rememberAdminKey: (key) async {
          data.pendingAdminKeys.add(key);
          await _vault!.save(data);
        },
      );
    } catch (e) {
      // The setup screen is rebuilt with the entered data and the error.
      creatingGroup = false;
      lastCreateFailure = e;
      notifyListeners();
      rethrow;
    }
    creatingGroup = false;
    data.pendingAdminKeys.clear();
    lastCreateAttempt = null;
    lastCreateFailure = null;
    await _persist();
    phase = AppPhase.ready;
    notifyListeners();
  }

  /// Uses new WebDAV access data for the unlocked group on this device. It
  /// is saved only if the folder holds this group (GroupSession.changeWebDav).
  Future<void> updateWebDav(WebDavConfig cfg, {String? confirmedFingerprint}) async {
    try {
      final candidate =
          storeFactory?.call(() => cfg) ?? WebDavStore(() => cfg, clientFactory: TorNetwork.createHttpClient);
      await session!.changeWebDav(cfg, candidate, confirmedFingerprint: confirmedFingerprint);
      } finally {
      notifyListeners();
    }
  }

  /// Join an existing group with an invite from its admin.
  Future<void> joinGroup(Invite invite, String fingerprint) async {
    session = await GroupSession.join(
      identity: identity!,
      invite: invite,
      fingerprint: fingerprint,
      store: _store(invite.webdav),
      hosting: _hosting,
      persistLocal: _persistLocal,
      tempDir: tempDir,
      partialDir: _partialDir,
    );
    await _persist();
    phase = AppPhase.ready;
    notifyListeners();
  }

  Future<SyncResult> sync({String? confirmedFingerprint}) async {
    try {
      return await session!.sync(confirmedFingerprint: confirmedFingerprint);
    } finally {
      notifyListeners();
    }
  }

  /// Run a group operation and refresh the UI afterwards.
  Future<T> run<T>(Future<T> Function(GroupSession s) action) async {
    try {
      return await action(session!);
    } finally {
      notifyListeners();
    }
  }

  void lock() {
    _forgetUnlocked();
    phase = groups.isEmpty ? AppPhase.noIdentity : AppPhase.locked;
    notifyListeners();
  }

  /// Delete the selected group from this device: identity, keys, cache.
  /// Nothing on the server is changed.
  Future<void> deleteGroup() async {
    final name = groupName;
    if (name == null) return;
    final dir = _groupDir(name);
    await Vault.wipe(dir);
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
    if (defaultGroup == name) await setDefaultGroup(false);
    await _loadGroups();
    _forgetUnlocked();
    if (groups.isEmpty) {
      groupName = null;
      phase = AppPhase.noIdentity;
      notifyListeners();
    } else {
      selectGroup(groups.first);
    }
  }
}
