import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'crypto_util.dart';

/// Streaming file encryption for blobs on the server.
///
/// Format:
///   magic "RCB1" (4) | chunk size u32 BE (4) | nonce prefix (8) | chunks...
/// Every chunk is AES-256-GCM with
///   nonce = nonce prefix || chunk index u32 BE
///   aad   = blob name || chunk index u32 BE || final flag (1 byte)
/// The final flag stops truncation; the blob name stops swapping blobs.
class BlobCrypto {
  static const magic = [0x52, 0x43, 0x42, 0x31]; // "RCB1"
  static const headerLength = 16;
  static const tagLength = 16;
  static const defaultChunkSize = 1024 * 1024;
  static const maxChunkSize = 16 * 1024 * 1024;

  static Uint8List _u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.big);

  static List<int> _aad(String blobName, int index, bool last) =>
      [...utf8.encode(blobName), ..._u32(index), last ? 1 : 0];

  static Future<void> encryptFile(String inPath, String outPath, Uint8List key, String blobName,
      {int chunkSize = defaultChunkSize}) async {
    final aes = AesGcm.with256bits();
    final secret = SecretKey(key);
    final prefix = randomBytes(8);
    final input = await File(inPath).open();
    final out = await File(outPath).open(mode: FileMode.write);
    try {
      final size = await input.length();
      await out.writeFrom([...magic, ..._u32(chunkSize), ...prefix]);
      final chunks = size == 0 ? 1 : (size + chunkSize - 1) ~/ chunkSize;
      for (var i = 0; i < chunks; i++) {
        final plain = await input.read(chunkSize);
        final last = i == chunks - 1;
        final box = await aes.encrypt(plain,
            secretKey: secret, nonce: [...prefix, ..._u32(i)], aad: _aad(blobName, i, last));
        await out.writeFrom(box.cipherText);
        await out.writeFrom(box.mac.bytes);
      }
    } finally {
      await input.close();
      await out.close();
    }
  }

  /// Decrypts into [outPath]. Writes to a temporary file first so a failed
  /// or tampered download never leaves a partial file behind.
  static Future<void> decryptFile(String inPath, String outPath, Uint8List key, String blobName) async {
    final aes = AesGcm.with256bits();
    final secret = SecretKey(key);
    final input = await File(inPath).open();
    final tmp = File('$outPath.part');
    final out = await tmp.open(mode: FileMode.write);
    var ok = false;
    try {
      final total = await input.length();
      final header = await input.read(headerLength);
      if (header.length != headerLength ||
          header[0] != magic[0] ||
          header[1] != magic[1] ||
          header[2] != magic[2] ||
          header[3] != magic[3]) {
        throw CryptoException('Not a RedCourier file.');
      }
      final chunkSize = ByteData.sublistView(header, 4, 8).getUint32(0, Endian.big);
      if (chunkSize == 0 || chunkSize > maxChunkSize) {
        throw CryptoException('Invalid chunk size.');
      }
      final prefix = header.sublist(8, 16);
      final body = total - headerLength;
      final encChunk = chunkSize + tagLength;
      if (body < tagLength) throw CryptoException('File is truncated.');
      final chunks = (body + encChunk - 1) ~/ encChunk;
      for (var i = 0; i < chunks; i++) {
        final last = i == chunks - 1;
        final data = await input.read(encChunk);
        if (data.length < tagLength || (!last && data.length != encChunk)) {
          throw CryptoException('File is truncated.');
        }
        try {
          final plain = await aes.decrypt(
            SecretBox(data.sublist(0, data.length - tagLength),
                nonce: [...prefix, ..._u32(i)], mac: Mac(data.sublist(data.length - tagLength))),
            secretKey: secret,
            aad: _aad(blobName, i, last),
          );
          await out.writeFrom(plain);
        } on SecretBoxAuthenticationError {
          throw CryptoException('The file was modified or the key is wrong.');
        }
      }
      ok = true;
    } finally {
      await input.close();
      await out.close();
      if (ok) {
        final target = File(outPath);
        if (await target.exists()) await target.delete();
        await tmp.rename(outPath);
      } else if (await tmp.exists()) {
        await tmp.delete();
      }
    }
  }

  /// Encrypts a stream straight into [outPath], so no plaintext copy is ever
  /// written. With [header] the file starts like [encryptFile] ("RCB1",
  /// chunk size, nonce prefix). Without it, only the random nonce prefix is
  /// written and the chunk size is [defaultChunkSize]: the file is then
  /// indistinguishable from random data. Which variant a blob uses is
  /// recorded elsewhere (the encrypted delivery entry).
  static Future<void> encryptStream(Stream<List<int>> input, String outPath, Uint8List key, String blobName,
      {int chunkSize = defaultChunkSize, bool header = true}) async {
    if (!header) chunkSize = defaultChunkSize;
    final aes = AesGcm.with256bits();
    final secret = SecretKey(key);
    final prefix = randomBytes(8);
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
      await out.writeFrom(header ? [...magic, ..._u32(chunkSize), ...prefix] : prefix);
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
      {bool header = true}) async* {
    final aes = AesGcm.with256bits();
    final secret = SecretKey(key);
    final input = await File(inPath).open();
    try {
      final total = await input.length();
      final int chunkSize;
      final List<int> prefix;
      final int headLength;
      if (header) {
        final head = await input.read(headerLength);
        if (head.length != headerLength ||
            head[0] != magic[0] ||
            head[1] != magic[1] ||
            head[2] != magic[2] ||
            head[3] != magic[3]) {
          throw CryptoException('Not a RedCourier file.');
        }
        chunkSize = ByteData.sublistView(head, 4, 8).getUint32(0, Endian.big);
        if (chunkSize == 0 || chunkSize > maxChunkSize) throw CryptoException('Invalid chunk size.');
        prefix = head.sublist(8, 16);
        headLength = headerLength;
      } else {
        prefix = await input.read(8);
        if (prefix.length != 8) throw CryptoException('File is truncated.');
        chunkSize = defaultChunkSize;
        headLength = 8;
      }
      final body = total - headLength;
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

  /// Run in a background isolate so large files do not block the UI.
  static Future<void> encryptFileInBackground(
          String inPath, String outPath, Uint8List key, String blobName) =>
      Isolate.run(() => encryptFile(inPath, outPath, key, blobName));

  static Future<void> decryptFileInBackground(
          String inPath, String outPath, Uint8List key, String blobName) =>
      Isolate.run(() => decryptFile(inPath, outPath, key, blobName));
}
