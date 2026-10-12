/// Ed25519 public key that signs RedCourier releases.
///
/// Must be identical to assets/release_signing_key.pem (checked by
/// test/updater_test.dart). The updater refuses packages not signed with it.
const releasePublicKeyPem = '''-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAqM4F702GERqjZ1KhRh6VUnINE4iPyedSiua9RX66v58=
-----END PUBLIC KEY-----''';
