import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'crypto_util.dart';
import 'group.dart';
import 'identity.dart';
import 'messages.dart';

class WrongPasswordException extends AppException {
  WrongPasswordException() : super('Wrong password.');
}

/// Everything this device keeps secret.
class VaultData {
  final Identity identity;
  GroupLocal? group;

  /// Admin keys of groups this device started to create. If creating timed
  /// out after the server stored sync.json, the next attempt recognizes the
  /// group as its own by this key instead of reporting a foreign group.
  final List<String> pendingAdminKeys;

  VaultData(this.identity, this.group, {List<String>? pendingAdminKeys})
      : pendingAdminKeys = pendingAdminKeys ?? [];

  Map<String, dynamic> toJson() => {
        'identity': identity.toJson(),
        'group': group?.toJson(),
        if (pendingAdminKeys.isNotEmpty) 'pending_admin_keys': pendingAdminKeys,
      };

  static Future<VaultData> fromJson(Map<String, dynamic> json) async => VaultData(
        await Identity.fromJson(json['identity'] as Map<String, dynamic>),
        json['group'] == null ? null : GroupLocal.fromJson(json['group'] as Map<String, dynamic>),
        pendingAdminKeys: (json['pending_admin_keys'] as List? ?? const []).cast<String>().toList(),
      );
}

/// Password-protected local storage for private keys and group settings.
///
/// The password is stretched with PBKDF2-HMAC-SHA256; the data is encrypted
/// with AES-256-GCM. Files are written atomically.
class Vault {
  static const _fileName = 'vault.json';
  static const _cacheName = 'sync_cache.json';
  static const _aad = 'rc/vault';
  static const defaultIterations = 300000;
  static const minPasswordLength = 8;

  final Directory dir;
  final Uint8List _key;
  final Uint8List _salt;
  final int _iterations;

  Vault._(this.dir, this._key, this._salt, this._iterations);

  static File _file(Directory dir) => File(p.join(dir.path, _fileName));
  static File cacheFile(Directory dir) => File(p.join(dir.path, _cacheName));

  static Future<bool> exists(Directory dir) => _file(dir).exists();

  static Future<Uint8List> _derive(String password, Uint8List salt, int iterations) =>
      Isolate.run(() => deriveKeyFromPassword(password, salt, iterations));

  static Future<Vault> create(Directory dir, String password, VaultData data,
      {int iterations = defaultIterations}) async {
    final salt = randomBytes(16);
    final vault = Vault._(dir, await _derive(password, salt, iterations), salt, iterations);
    await vault.save(data);
    return vault;
  }

  static Future<(Vault, VaultData)> unlock(Directory dir, String password) async {
    final Map<String, dynamic> outer;
    try {
      outer = jsonDecode(await _file(dir).readAsString()) as Map<String, dynamic>;
    } catch (_) {
      throw const AppException('The local vault file is damaged.');
    }
    final salt = b64d(outer['salt']);
    final iterations = outer['iterations'] as int;
    final key = await _derive(password, salt, iterations);
    final Uint8List clear;
    try {
      clear = await symDecrypt(key, outer['data'], _aad);
    } on CryptoException {
      throw WrongPasswordException();
    }
    final data = await VaultData.fromJson(jsonDecode(utf8.decode(clear)) as Map<String, dynamic>);
    return (Vault._(dir, key, salt, iterations), data);
  }

  Future<void> save(VaultData data) async {
    final enc = await symEncrypt(_key, utf8.encode(jsonEncode(data.toJson())), _aad);
    await writeAtomic(_file(dir), utf8.encode(jsonEncode({
      'version': 1,
      'kdf': 'pbkdf2-hmac-sha256',
      'iterations': _iterations,
      'salt': b64e(_salt),
      'data': enc,
    })));
  }

  static Future<void> writeAtomic(File file, List<int> bytes) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
  }

  /// Delete all local data of this app (identity, group, cache).
  static Future<void> wipe(Directory dir) async {
    for (final f in [_file(dir), cacheFile(dir)]) {
      if (await f.exists()) await f.delete();
    }
  }
}
