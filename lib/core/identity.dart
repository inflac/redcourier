import 'dart:convert';
import 'dart:typed_data';

import 'crypto_util.dart';

/// Max length of a user identifier (display name, e-mail, handle, ...).
const int maxIdentifierLength = 64;

String normalizeIdentifier(String value) => value.trim();

String? validateIdentifier(String value) {
  final v = normalizeIdentifier(value);
  if (v.isEmpty) return 'Please enter an identifier.';  // i18n
  if (v.length > maxIdentifierLength) {
    return 'At most 64 characters.';  // i18n
  }
  if (RegExp(r'[\x00-\x1f]').hasMatch(v)) return 'Control characters are not allowed.';  // i18n
  return null;
}

/// User ids are derived from the public keys, not from the identifier.
/// A hash of an identifier (like an e-mail) could be brute-forced by the
/// server; a hash of random public keys cannot, and it binds the id to the keys.
String userIdFor(List<int> encPub, List<int> sigPub, List<int> kemPub) =>
    sha256Hex([...encPub, ...sigPub, ...kemPub]).substring(0, 32);

bool isValidUserId(Object? id) => id is String && RegExp(r'^[0-9a-f]{32}$').hasMatch(id);

/// The local user: X25519 + ML-KEM-768 keys for receiving (hybrid) and an
/// Ed25519 key for signing. Only the seeds are stored.
class Identity {
  final String identifier;
  final Uint8List encSeed;
  final Uint8List sigSeed;
  final Uint8List kemSeed;
  final Uint8List encPub;
  final Uint8List sigPub;
  final Uint8List kemPub;

  Identity._(this.identifier, this.encSeed, this.sigSeed, this.kemSeed, this.encPub,
      this.sigPub, this.kemPub);

  String get userId => userIdFor(encPub, sigPub, kemPub);

  static Future<Identity> _fromSeeds(
      String identifier, Uint8List encSeed, Uint8List sigSeed, Uint8List kemSeed) async {
    final (kemPub, _) = mlkemKeyPair(kemSeed);
    return Identity._(normalizeIdentifier(identifier), encSeed, sigSeed, kemSeed,
        await x25519PublicKey(encSeed), await ed25519PublicKey(sigSeed), kemPub);
  }

  static Future<Identity> generate(String identifier) =>
      _fromSeeds(identifier, randomBytes(32), randomBytes(32), randomBytes(64));

  Map<String, dynamic> toJson() => {
        'identifier': identifier,
        'enc_seed': b64e(encSeed),
        'sig_seed': b64e(sigSeed),
        'kem_seed': b64e(kemSeed),
      };

  static Future<Identity> fromJson(Map<String, dynamic> json) => _fromSeeds(
      json['identifier'] as String,
      b64d(json['enc_seed']),
      b64d(json['sig_seed']),
      b64d(json['kem_seed']));

  Future<SealKeyPair> sealKeyPair() => SealKeyPair.fromSeeds(encSeed, kemSeed);

  JoinRequest get joinRequest => JoinRequest(identifier, encPub, sigPub, kemPub);
}

/// What a new user sends to an admin: identifier + public keys.
class JoinRequest {
  static const prefix = 'RCJOIN2:';

  final String identifier;
  final Uint8List encPub;
  final Uint8List sigPub;
  final Uint8List kemPub;

  JoinRequest(this.identifier, this.encPub, this.sigPub, this.kemPub);

  String get userId => userIdFor(encPub, sigPub, kemPub);

  String encode() => prefix +
      base64Url.encode(utf8.encode(canonicalJson({
        'identifier': identifier,
        'enc_pub': b64e(encPub),
        'sig_pub': b64e(sigPub),
        'kem_pub': b64e(kemPub),
      })));

  static JoinRequest parse(String text) {
    final t = text.replaceAll(RegExp(r'\s'), '');
    if (!t.startsWith(prefix)) throw const FormatException('Not a RedCourier join request.');
    try {
      final json = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(t.substring(prefix.length)))));
      final identifier = normalizeIdentifier(json['identifier'] as String);
      final err = validateIdentifier(identifier);
      if (err != null) throw FormatException(err);
      final enc = b64d(json['enc_pub']);
      final sig = b64d(json['sig_pub']);
      final kem = b64d(json['kem_pub']);
      if (enc.length != 32 || sig.length != 32 || kem.length != mlkemPublicKeyLength) {
        throw const FormatException('Invalid keys.');
      }
      return JoinRequest(identifier, enc, sig, kem);
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Corrupted join request.');
    }
  }
}

/// WebDAV access data of a group.
class WebDavConfig {
  final String url;
  final String username;
  final String password;

  WebDavConfig(String url, this.username, this.password)
      : url = url.trim().endsWith('/') ? url.trim() : '${url.trim()}/';

  Map<String, dynamic> toJson() => {'url': url, 'username': username, 'password': password};

  static WebDavConfig fromJson(Map json) =>
      WebDavConfig(json['url'] as String, json['username'] as String, json['password'] as String);

  static String? validateUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return 'Please enter a full URL.';  // i18n
    if (uri.scheme != 'https' && uri.scheme != 'http') return 'Only http(s) URLs are supported.';  // i18n
    return null;
  }
}

/// What an admin sends to a new member: where the group lives.
///
/// The group fingerprint is deliberately not part of the invite. It travels
/// over a second channel (e-mail, QR code), so an attacker would have to
/// control both channels to make someone join a fake group.
class Invite {
  static const prefix = 'RCINVITE2:';

  final WebDavConfig webdav;

  Invite(this.webdav);

  String encode() => prefix + base64Url.encode(utf8.encode(canonicalJson({'webdav': webdav.toJson()})));

  static Invite parse(String text) {
    final t = text.replaceAll(RegExp(r'\s'), '');
    if (!t.startsWith(prefix)) throw const FormatException('Not a RedCourier invite.');
    try {
      final json = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(t.substring(prefix.length)))));
      final cfg = WebDavConfig.fromJson(json['webdav'] as Map);
      if (WebDavConfig.validateUrl(cfg.url) != null) throw const FormatException('Invalid URL.');
      return Invite(cfg);
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Corrupted invite.');
    }
  }
}
