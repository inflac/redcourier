import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'crypto_util.dart';

/// Streaming encryption of delivery payloads.
///
/// Format (no marker, indistinguishable from random data):
///   nonce prefix (8 random bytes) | chunks...
/// Every chunk holds [defaultChunkSize] bytes of plaintext (the last one
/// fewer) and is AES-256-GCM with
///   nonce = nonce prefix || chunk index u32 BE
///   aad   = blob name || chunk index u32 BE || final flag (1 byte)
/// The final flag stops truncation; the blob name stops swapping blobs.
class BlobCrypto {
  static const prefixLength = 8;
  static const tagLength = 16;
  static const defaultChunkSize = 1024 * 1024;

  static Uint8List _u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.big);

  static List<int> _aad(String blobName, int index, bool last) =>
      [...utf8.encode(blobName), ..._u32(index), last ? 1 : 0];

  /// Encrypts a stream straight into [outPath], so no plaintext copy is ever
  /// written. [chunkSize] must be the same when decrypting (tests use small
  /// chunks; the app always uses [defaultChunkSize]).
  static Future<void> encryptStream(Stream<List<int>> input, String outPath, Uint8List key, String blobName,
      {int chunkSize = defaultChunkSize}) async {
    final aes = AesGcm.with256bits();
    final secret = SecretKey(key);
    final prefix = randomBytes(prefixLength);
    final out = await File(outPath).open(mode: FileMode.write);
    var index = 0;
    Future<void> writeChunk(List<int> plain, bool last) async {
      final box = await aes.encrypt(plain,
          secretKey: secret, nonce: [...prefix, ..._u32(index)], aad: _aad(blobName, index, last));
      await out.writeFrom(box.cipherText);
      await out.writeFrom(box.mac.bytes);
      index++;
    }

    try {
      await out.writeFrom(prefix);
      // The last chunk carries the final flag, so one full chunk is held back
      // until it is known whether more data follows.
      final buffer = BytesBuilder(copy: false);
      Uint8List? held;
      await for (final data in input) {
        buffer.add(data);
        while (buffer.length >= chunkSize) {
          final all = buffer.takeBytes();
          if (held != null) await writeChunk(held, false);
          held = Uint8List.sublistView(all, 0, chunkSize);
          buffer.add(Uint8List.sublistView(all, chunkSize));
        }
      }
      final rest = buffer.takeBytes();
      if (held != null && rest.isEmpty) {
        await writeChunk(held, true);
      } else {
        if (held != null) await writeChunk(held, false);
        await writeChunk(rest, true);
      }
    } finally {
      await out.close();
    }
  }

  /// Decrypts [inPath] chunk by chunk. Every chunk is authenticated before it
  /// is handed on; a truncated or modified file ends the stream with a
  /// [CryptoException], so consumers must discard what they wrote so far.
  static Stream<Uint8List> decryptStream(String inPath, Uint8List key, String blobName,
      {int chunkSize = defaultChunkSize}) async* {
    final aes = AesGcm.with256bits();
    final secret = SecretKey(key);
    final input = await File(inPath).open();
    try {
      final total = await input.length();
      final prefix = await input.read(prefixLength);
      if (prefix.length != prefixLength) throw CryptoException('File is truncated.');
      final body = total - prefixLength;
      final encChunk = chunkSize + tagLength;
      if (body < tagLength) throw CryptoException('File is truncated.');
      final chunks = (body + encChunk - 1) ~/ encChunk;
      for (var i = 0; i < chunks; i++) {
        final last = i == chunks - 1;
        final data = await input.read(encChunk);
        if (data.length < tagLength || (!last && data.length != encChunk)) {
          throw CryptoException('File is truncated.');
        }
        final List<int> plain;
        try {
          plain = await aes.decrypt(
            SecretBox(data.sublist(0, data.length - tagLength),
                nonce: [...prefix, ..._u32(i)], mac: Mac(data.sublist(data.length - tagLength))),
            secretKey: secret,
            aad: _aad(blobName, i, last),
          );
        } on SecretBoxAuthenticationError {
          throw CryptoException('The file was modified or the key is wrong.');
        }
        yield plain is Uint8List ? plain : Uint8List.fromList(plain);
      }
    } finally {
      await input.close();
    }
  }
}
