import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:pqcrypto/pqcrypto.dart' as pq;
import 'messages.dart';

/// Low-level cryptographic building blocks shared by the sync format.
///
/// Algorithms:
///  * X25519 + HKDF-SHA256 + AES-256-GCM for sealing data to a public key
///  * AES-256-GCM for symmetric encryption
///  * Ed25519 for signatures
///  * SHA-256 for identifiers and fingerprints

final _rng = Random.secure();
final _aes = AesGcm.with256bits();
final _x25519 = X25519();
final _ed25519 = Ed25519();

class CryptoException extends AppException {
  CryptoException(super.template, [super.args]);
}

Uint8List randomBytes(int length) =>
    Uint8List.fromList(List<int>.generate(length, (_) => _rng.nextInt(256)));

String randomHex(int bytes) => hex(randomBytes(bytes));

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

String b64e(List<int> bytes) => base64.encode(bytes);

Uint8List b64d(Object? value) {
  if (value is! String) throw CryptoException('Expected base64 string.');
  try {
    return base64.decode(value);
  } on FormatException {
    throw CryptoException('Invalid base64 data.');
  }
}

String sha256Hex(List<int> data) => hash.sha256.convert(data).toString();

Future<String> sha256HexOfStream(Stream<List<int>> data) async =>
    (await hash.sha256.bind(data).first).toString();

/// Deterministic JSON: object keys sorted, no whitespace.
String canonicalJson(Object? value) => jsonEncode(_canonicalize(value));

Object? _canonicalize(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    return {for (final k in keys) k: _canonicalize(value[k])};
  }
  if (value is List) return value.map(_canonicalize).toList();
  return value;
}

Uint8List canonicalBytes(String domain, Object? value) =>
    Uint8List.fromList(utf8.encode('$domain\n${canonicalJson(value)}'));

// ── Symmetric encryption ─────────────────────────────────────────────────────

/// AES-256-GCM. Returns {"n": nonce, "ct": ciphertext||tag} as base64.
Future<Map<String, String>> symEncrypt(
    List<int> key, List<int> plaintext, String aad) async {
  final nonce = randomBytes(12);
  final box = await _aes.encrypt(plaintext,
      secretKey: SecretKey(key), nonce: nonce, aad: utf8.encode(aad));
  return {'n': b64e(nonce), 'ct': b64e([...box.cipherText, ...box.mac.bytes])};
}

Future<Uint8List> symDecrypt(List<int> key, Object? enc, String aad) async {
  if (enc is! Map) throw CryptoException('Missing encrypted data.');
  final nonce = b64d(enc['n']);
  final data = b64d(enc['ct']);
  if (nonce.length != 12 || data.length < 16) {
    throw CryptoException('Malformed encrypted data.');
  }
  try {
    final clear = await _aes.decrypt(
      SecretBox(data.sublist(0, data.length - 16),
          nonce: nonce, mac: Mac(data.sublist(data.length - 16))),
      secretKey: SecretKey(key),
      aad: utf8.encode(aad),
    );
    return Uint8List.fromList(clear);
  } on SecretBoxAuthenticationError {
    throw CryptoException('Decryption failed.');
  }
}

// ── Sealing to a public key (hybrid X25519 + ML-KEM-768) ─────────────────────
//
// Every sealed value is protected by a classical and a post-quantum key
// exchange. The AES key is derived from both shared secrets, so an attacker
// has to break X25519 *and* ML-KEM-768 (FIPS 203) to read it. This protects
// today's data against "harvest now, decrypt later" with future quantum
// computers.

final _mlkem = pq.PqcKem.kyber768;
const mlkemPublicKeyLength = 1184;
const mlkemCiphertextLength = 1088;

Future<Uint8List> x25519PublicKey(List<int> seed) async {
  final kp = await _x25519.newKeyPairFromSeed(seed);
  return Uint8List.fromList((await kp.extractPublicKey()).bytes);
}

/// ML-KEM-768 key pair from a 64-byte seed (d || z, FIPS 203 KeyGen).
/// Returns (public key, secret key).
(Uint8List, Uint8List) mlkemKeyPair(List<int> seed64) {
  if (seed64.length != 64) throw CryptoException('ML-KEM seed must be 64 bytes.');
  return _mlkem.generateKeyPair(Uint8List.fromList(seed64));
}

/// Plain ML-KEM-768 operations, exposed for known-answer tests.
(Uint8List, Uint8List) mlkemEncapsulate(List<int> publicKey, [List<int>? m]) => _mlkem
    .encapsulate(Uint8List.fromList(publicKey), m == null ? null : Uint8List.fromList(m));
Uint8List mlkemDecapsulate(List<int> secretKey, List<int> ct) =>
    _mlkem.decapsulate(Uint8List.fromList(secretKey), Uint8List.fromList(ct));

Future<Uint8List> _hkdfBytes(List<int> ikm, List<int> salt, String info, int length) async {
  final k = await Hkdf(hmac: Hmac.sha256(), outputLength: length).deriveKey(
    secretKey: SecretKey(ikm),
    nonce: salt,
    info: utf8.encode(info),
  );
  return Uint8List.fromList(await k.extractBytes());
}

/// Binds the key to every public value of the exchange.
List<int> _sealSalt(List<int> ephPub, List<int> xPub, List<int> kemCt, List<int> kemPub) => [
      ...ephPub,
      ...xPub,
      ...hash.sha256.convert(kemCt).bytes,
      ...hash.sha256.convert(kemPub).bytes,
    ];

/// Short tag that lets a recipient skip the (slower) ML-KEM step for values
/// that are not addressed to them. It needs the X25519 secret to compute.
Future<Uint8List> _hint(List<int> xShared, List<int> ephPub, List<int> xPub, String context) =>
    _hkdfBytes(xShared, [...ephPub, ...xPub], 'redcourier/hint/v2/$context', 8);

/// Encrypt [plaintext] for the owner of ([xPub], [kemPub]).
/// [context] is bound into the key derivation and must match on [SealKeyPair.open].
Future<Map<String, String>> seal(
    List<int> xPub, List<int> kemPub, List<int> plaintext, String context) async {
  if (xPub.length != 32 || kemPub.length != mlkemPublicKeyLength) {
    throw CryptoException('Invalid recipient key.');
  }
  final eph = await _x25519.newKeyPair();
  final ephPub = (await eph.extractPublicKey()).bytes;
  final xShared = await (await _x25519.sharedSecretKey(
    keyPair: eph,
    remotePublicKey: SimplePublicKey(xPub, type: KeyPairType.x25519),
  ))
      .extractBytes();
  final (kemCt, kemShared) = mlkemEncapsulate(kemPub);
  final key = await _hkdfBytes([...kemShared, ...xShared],
      _sealSalt(ephPub, xPub, kemCt, kemPub), 'redcourier/seal/v2/$context', 32);
  final enc = await symEncrypt(key, plaintext, context);
  return {
    'epk': b64e(ephPub),
    'kct': b64e(kemCt),
    'h': b64e(await _hint(xShared, ephPub, xPub, context)),
    ...enc,
  };
}

/// Our key pairs, prepared once for opening many sealed values.
class SealKeyPair {
  final SimpleKeyPair _kp;
  final List<int> publicKey;
  final Uint8List _kemSecret;
  final Uint8List kemPublicKey;
  SealKeyPair._(this._kp, this.publicKey, this._kemSecret, this.kemPublicKey);

  static Future<SealKeyPair> fromSeeds(List<int> xSeed, List<int> kemSeed) async {
    final kp = await _x25519.newKeyPairFromSeed(xSeed);
    final (kemPub, kemSecret) = mlkemKeyPair(kemSeed);
    return SealKeyPair._(kp, (await kp.extractPublicKey()).bytes, kemSecret, kemPub);
  }

  /// Open data sealed to this key. Throws [CryptoException] on failure.
  Future<Uint8List> open(Object? sealed, String context) async {
    if (sealed is! Map) throw CryptoException('Missing sealed data.');
    final ephPub = b64d(sealed['epk']);
    final kemCt = b64d(sealed['kct']);
    final hint = b64d(sealed['h']);
    if (ephPub.length != 32 || kemCt.length != mlkemCiphertextLength || hint.length != 8) {
      throw CryptoException('Malformed sealed data.');
    }
    final xShared = await (await _x25519.sharedSecretKey(
      keyPair: _kp,
      remotePublicKey: SimplePublicKey(ephPub, type: KeyPairType.x25519),
    ))
        .extractBytes();
    final expected = await _hint(xShared, ephPub, publicKey, context);
    var diff = 0;
    for (var i = 0; i < 8; i++) {
      diff |= expected[i] ^ hint[i];
    }
    if (diff != 0) throw CryptoException('Not addressed to this key.');
    final Uint8List kemShared;
    try {
      kemShared = mlkemDecapsulate(_kemSecret, kemCt);
    } on ArgumentError {
      throw CryptoException('Malformed sealed data.');
    }
    final key = await _hkdfBytes([...kemShared, ...xShared],
        _sealSalt(ephPub, publicKey, kemCt, kemPublicKey), 'redcourier/seal/v2/$context', 32);
    return symDecrypt(key, sealed, context);
  }
}

// ── Signatures (Ed25519) ─────────────────────────────────────────────────────

Future<Uint8List> ed25519PublicKey(List<int> seed) async {
  final kp = await _ed25519.newKeyPairFromSeed(seed);
  return Uint8List.fromList((await kp.extractPublicKey()).bytes);
}

Future<String> sign(List<int> seed, List<int> message) async {
  final kp = await _ed25519.newKeyPairFromSeed(seed);
  final sig = await _ed25519.sign(message, keyPair: kp);
  return b64e(sig.bytes);
}

Future<bool> verify(Object? publicKeyB64, Object? signatureB64, List<int> message) async {
  try {
    final pub = b64d(publicKeyB64);
    final sig = b64d(signatureB64);
    if (pub.length != 32 || sig.length != 64) return false;
    return await _ed25519.verify(
      message,
      signature: Signature(sig,
          publicKey: SimplePublicKey(pub, type: KeyPairType.ed25519)),
    );
  } on CryptoException {
    return false;
  }
}

// ── Password-based key derivation ────────────────────────────────────────────

Future<Uint8List> deriveKeyFromPassword(
    String password, List<int> salt, int iterations) async {
  final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256);
  final key = await pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(password)), nonce: salt);
  return Uint8List.fromList(await key.extractBytes());
}

// ── Fingerprints ─────────────────────────────────────────────────────────────

/// Fingerprint of the group's admin signing key. This is the trust anchor
/// users compare out of band before trusting a group.
String adminKeyFingerprint(String adminSignPubB64) =>
    sha256Hex(utf8.encode(canonicalJson({'admin_sign_key': adminSignPubB64})));

String normalizeFingerprint(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^0-9a-f]'), '');

/// Prefix of the fingerprint QR code, so a scanner can tell it from an invite.
const fingerprintQrPrefix = 'RCFP1:';

/// Accepts a fingerprint as typed, pasted from an e-mail (spaces, line
/// breaks, upper case) or scanned from the QR code. Returns the normalized
/// value or null if it is not a complete fingerprint.
String? parseFingerprint(String value) {
  var v = value.trim();
  if (v.toUpperCase().startsWith(fingerprintQrPrefix)) v = v.substring(fingerprintQrPrefix.length);
  if (RegExp(r'[^0-9a-fA-F\s:-]').hasMatch(v)) return null;
  final n = normalizeFingerprint(v);
  return n.length == 64 ? n : null;
}

/// Content of the fingerprint QR code.
String fingerprintQr(String fingerprint) => '$fingerprintQrPrefix${normalizeFingerprint(fingerprint)}';

String formatFingerprint(String value, {int group = 4}) {
  final n = normalizeFingerprint(value).toUpperCase();
  final parts = <String>[];
  for (var i = 0; i < n.length; i += group) {
    parts.add(n.substring(i, min(i + group, n.length)));
  }
  return parts.join(' ');
}
