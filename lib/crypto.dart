import 'dart:io';
import 'dart:math';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:async';
import 'dart:isolate';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:archive/archive.dart';
import 'package:convert/convert.dart'; // provides AccumulatorSink<T>
import 'package:path/path.dart' as path;
import 'logger.dart'; // <-- dein neuer Logger

/// Thrown when a single file exceeds the allowed maximum size.
class FileSizeException implements Exception {
  final String filename;
  final int sizeInBytes;
  FileSizeException(this.filename, this.sizeInBytes);
  @override
  String toString() =>
      'FileSizeException: File $filename is too large (${(sizeInBytes / 1024 / 1024).toStringAsFixed(2)} MB). Max allowed size is 500 MB.';
}

class FileCryptoManager {
  static const int chunkSize = 64 * 1024; // 64 KB
  static const int maxGroupSize = 500 * 1024 * 1024; // 500 MB
  static const int maxFileCountPerGroup = 1000;
  static const int pbkdf2Iterations = 200000;
  static const int keyLength = 32;
  static const int saltLength = 16;
  static const int macLength = 32; // SHA-256
  static const int ivLength = 16; // AES block size

  // Generate a cryptographically secure random password.
  static String generatePassword([int length = 32]) {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#\$%^&*()-_=+';
    final rnd = Random.secure();
    return List.generate(length, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  // Generate a URL-safe random string (alphanumeric).
  static String generateUrlSafeString([int length = 32]) {
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rnd = Random.secure();
    return List.generate(length, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  /// Returns cryptographically secure random bytes for salt/IV.
  static Uint8List generateRandomBytes(int length) {
    final rnd = Random.secure();
    return Uint8List.fromList(List<int>.generate(length, (_) => rnd.nextInt(256)));
  }

  /// Derive separate encryption and MAC keys from the password and salt.
  static Map<String, Uint8List> deriveKeys(String password, Uint8List salt) {
    final keyBytes = pbkdf2(
      password: utf8.encode(password),
      salt: salt,
      iterations: pbkdf2Iterations,
      keyLength: keyLength * 2,
    );
    return {
      'encKey': Uint8List.fromList(keyBytes.sublist(0, keyLength)),
      'macKey': Uint8List.fromList(keyBytes.sublist(keyLength, keyLength * 2)),
    };
  }

  /// PBKDF2-HMAC-SHA256 implementation.
  static Uint8List pbkdf2({
    required List<int> password,
    required List<int> salt,
    required int iterations,
    required int keyLength,
  }) {
    final hmac = Hmac(sha256, password);
    final hmacLength = sha256.convert([]).bytes.length;
    final blocks = (keyLength + hmacLength - 1) ~/ hmacLength;
    final output = BytesBuilder();

    for (var blockIndex = 1; blockIndex <= blocks; blockIndex++) {
      var u = hmac.convert([...salt, ..._int32BE(blockIndex)]).bytes;
      final f = u.toList();
      for (var i = 1; i < iterations; i++) {
        u = hmac.convert(u).bytes;
        for (var j = 0; j < f.length; j++) f[j] ^= u[j];
      }
      output.add(f);
    }

    return Uint8List.fromList(output.toBytes().sublist(0, keyLength));
  }

  static List<int> _int32BE(int i) =>
      [(i >> 24) & 0xff, (i >> 16) & 0xff, (i >> 8) & 0xff, i & 0xff];

  /// Constant-time equality check to mitigate timing attacks.
  static bool constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  // ------------------------------------------------------------------
  // ZIP creation helper (adds files already written to disk).
  // ------------------------------------------------------------------
  static Future<void> _createZipPart(
      String currentZipPath, List<File> filesToZip, List<String> zipPaths) async {
    if (filesToZip.isEmpty) {
      AppLogger.warn('No files to ZIP for $currentZipPath, skipping.');
      return;
    }

    AppLogger.info('Creating ZIP part at: $currentZipPath with ${filesToZip.length} files');

    final zipEncoder = ZipFileEncoder();

    try {
      zipEncoder.create(currentZipPath);

      // Add files with checks
      for (final f in filesToZip) {
        try {
          if (!await f.exists()) {
            AppLogger.error('File does not exist and will be skipped: ${f.path}');
            continue;
          }

          final fileSize = await f.length();
          if (fileSize == 0) {
            AppLogger.error('File is empty and will be skipped: ${f.path}');
            continue;
          }

          AppLogger.debug('Adding file to ZIP: ${f.path} (size: $fileSize bytes)');
          zipEncoder.addFileSync(f, path.basename(f.path));
        } catch (e) {
          AppLogger.error('Failed to add file ${f.path} to ZIP: $e');
          rethrow;
        }
      }

      zipEncoder.close();

      // Check if ZIP is plausibly valid (> minimal ZIP size)
      final zipFile = File(currentZipPath);
      if (!await zipFile.exists()) {
        throw Exception('ZIP file was not created: $currentZipPath');
      }

      final zipSize = await zipFile.length();
      if (zipSize <= 22) {
        throw Exception('ZIP file is too small ($zipSize bytes), likely corrupted: $currentZipPath');
      }

      AppLogger.info('ZIP part created successfully: $currentZipPath (size: $zipSize bytes)');

    } catch (e) {
      AppLogger.error('ZIP creation error for $currentZipPath: $e');
      try {
        zipEncoder.close();
      } catch (_) {}
      rethrow;
    }

    // Clean up encrypted files only if ZIP seems valid
    for (final f in filesToZip) {
      try {
        if (await f.exists()) await f.delete();
      } catch (e) {
        AppLogger.warn('Cleanup warning: could not delete ${f.path}: $e');
      }
    }

    zipPaths.add(currentZipPath);
  }

  /// Encrypt files into .enc files and package into ZIP parts.
  static Future<Map<String, dynamic>> encryptFiles(List<File> files) async {
    if (files.isEmpty) throw Exception('No files to encrypt.');

    final password = generatePassword();
    final tempDirName = 'encrypted_files_${generateUrlSafeString(8)}';
    final tempDir = await Directory.systemTemp.createTemp(tempDirName);
    AppLogger.info('Temporary directory created: ${tempDir.path}');

    final zipPaths = <String>[];
    int partNumber = 1;
    final currentGroup = <File>[];
    int currentGroupSize = 0;
    String zipPath() => '${tempDir.path}/encrypted_files_part$partNumber.zip';

    for (final file in files) {
      final originalFileSize = await file.length();
      AppLogger.debug('Processing input file: ${file.path} (size: ${originalFileSize} bytes)');

      if (originalFileSize > maxGroupSize) {
        throw FileSizeException(file.uri.pathSegments.last, originalFileSize);
      }

      final salt = generateRandomBytes(saltLength);
      final keys = deriveKeys(password, salt);
      final encKey = encrypt.Key(keys['encKey']!);
      final macKey = keys['macKey']!;

      final ivBytes = generateRandomBytes(ivLength);
      var iv = encrypt.IV(ivBytes);

      final encrypterNoPadding = encrypt.Encrypter(
        encrypt.AES(encKey, mode: encrypt.AESMode.cbc, padding: null),
      );
      final encrypterWithPadding = encrypt.Encrypter(
        encrypt.AES(encKey, mode: encrypt.AESMode.cbc, padding: 'PKCS7'),
      );

      final encFile = File('${tempDir.path}/${file.uri.pathSegments.last}.enc');
      final sink = encFile.openWrite();
      sink.add(salt);
      sink.add(iv.bytes);

      final hmac = Hmac(sha256, macKey);
      final hmacAcc = AccumulatorSink<Digest>();
      final hmacSink = hmac.startChunkedConversion(hmacAcc);
      hmacSink.add(salt);
      hmacSink.add(iv.bytes);

      try {
        final stream = file.openRead();
        var chunkBuffer = <int>[];
        AppLogger.debug('Streaming file for encryption: ${file.path}');

        Future<void> processChunk(List<int> chunkData, {required bool isFinal}) async {
          final encryptedBytes = Uint8List.fromList(
              (isFinal
                  ? encrypterWithPadding
                  : encrypterNoPadding)
                  .encryptBytes(chunkData, iv: iv)
                  .bytes);
          sink.add(encryptedBytes);
          hmacSink.add(encryptedBytes);
          iv = encrypt.IV(encryptedBytes.sublist(encryptedBytes.length - ivLength));
        }

        await for (final incoming in stream) {
          var offset = 0;
          while (offset < incoming.length) {
            final take = min(incoming.length - offset, chunkSize - chunkBuffer.length);
            chunkBuffer.addAll(incoming.sublist(offset, offset + take));
            offset += take;
            if (chunkBuffer.length == chunkSize) {
              await processChunk(Uint8List.fromList(chunkBuffer), isFinal: false);
              chunkBuffer = [];
            }
          }
        }

        if (chunkBuffer.isNotEmpty || originalFileSize == 0) {
          await processChunk(Uint8List.fromList(chunkBuffer), isFinal: true);
        }

        hmacSink.close();
        final mac = hmacAcc.events.single.bytes;
        sink.add(mac);
        await sink.flush();
        await sink.close();
        AppLogger.info('Encrypted file complete: ${encFile.path}');
      } catch (e) {
        await sink.close();
        if (await encFile.exists()) await encFile.delete();
        AppLogger.error('Encryption failed for file ${file.path}: $e');
        rethrow;
      }

      final encSize = await encFile.length();

      if (currentGroupSize + encSize > (maxGroupSize * 0.95) ||
          currentGroup.length >= maxFileCountPerGroup) {
        AppLogger.info('Creating ZIP part #$partNumber (group threshold reached)');
        await _createZipPart(zipPath(), currentGroup, zipPaths);
        currentGroup.clear();
        currentGroupSize = 0;
        partNumber++;
      }

      currentGroup.add(encFile);
      currentGroupSize += encSize;
      AppLogger.debug('Added encrypted file to group. Size: $currentGroupSize bytes.');
    }

    if (currentGroup.isNotEmpty) {
      AppLogger.info('Creating final ZIP part #$partNumber');
      await _createZipPart(zipPath(), currentGroup, zipPaths);
    }

    AppLogger.info('Encryption batch complete. ZIP parts: ${zipPaths.length}');
    return {'zipPaths': zipPaths, 'password': password, 'tempDir': tempDir.path};
  }

  // Isolate wrappers --------------------------------------------------
  static Future<Map<String, dynamic>> encryptFilesSafe(List<File> files) async {
    final receivePort = ReceivePort();
    final filePaths = files.map((f) => f.path).toList();

    try {
      await Isolate.spawn(_encryptInIsolate, [receivePort.sendPort, filePaths]);
      final result = await receivePort.first;
      if (result is String) throw Exception(result);
      if (result is Map<String, dynamic>) return result;
      throw Exception('Encryption Isolate returned unexpected data type.');
    } finally {
      receivePort.close();
    }
  }

  // Decryption --------------------------------------------------------
  static Future<void> decryptFiles(List<String> zipPaths, String password, String outputDir) async {
    await Directory(outputDir).create(recursive: true);

    for (final zipPath in zipPaths) {
      AppLogger.info('Processing ZIP: $zipPath');
      final inFile = InputFileStream(zipPath);
      final archive = ZipDecoder().decodeStream(inFile);

      for (final file in archive) {
        AppLogger.debug('Found archive entry: ${file.name}');
        if (!file.isFile) continue;
        final fileName = file.name;
        final fileTotalLength = file.size;

        if (fileTotalLength < saltLength + ivLength + macLength) {
          AppLogger.warn('Skipping ${fileName}: too small to contain header and MAC');
          continue;
        }

        final outputFilePath = '$outputDir/${fileName.replaceAll('.enc', '')}';
        final outFile = File(outputFilePath);
        IOSink? outSink;

        try {
          outSink = outFile.openWrite(mode: FileMode.write);
          final List<int> content = file.content as List<int>;
          final inputStream = InputMemoryStream(content);

          final saltBuffer = inputStream.readBytes(saltLength);
          final ivBuffer = inputStream.readBytes(ivLength);
          if (saltBuffer.length != saltLength || ivBuffer.length != ivLength) {
            throw Exception('Could not read salt/IV from encrypted file.');
          }

          final salt = saltBuffer.toUint8List();
          var currentIV = encrypt.IV(ivBuffer.toUint8List());
          final keys = deriveKeys(password, salt);
          final encKey = encrypt.Key(keys['encKey']!);
          final macKey = keys['macKey']!;

          final encrypterNoPadding = encrypt.Encrypter(
            encrypt.AES(encKey, mode: encrypt.AESMode.cbc, padding: null),
          );
          final encrypterWithPadding = encrypt.Encrypter(
            encrypt.AES(encKey, mode: encrypt.AESMode.cbc, padding: 'PKCS7'),
          );

          final hmac = Hmac(sha256, macKey);
          final hmacAcc = AccumulatorSink<Digest>();
          final hmacSink = hmac.startChunkedConversion(hmacAcc);
          hmacSink.add(salt);
          hmacSink.add(currentIV.bytes);

          final cipherLength = fileTotalLength - saltLength - ivLength - macLength;
          var bytesRemaining = cipherLength;

          while (bytesRemaining > 0) {
            final bytesToRead = min(chunkSize, bytesRemaining);
            final chunkBuffer = inputStream.readBytes(bytesToRead);
            final chunk = chunkBuffer.toUint8List();
            if (chunk.isEmpty) throw Exception('Unexpected end of ciphertext.');

            hmacSink.add(chunk);
            final isLastChunk = bytesRemaining <= chunk.length;
            final decryptedBytes = Uint8List.fromList(
              (isLastChunk
                  ? encrypterWithPadding
                  : encrypterNoPadding)
                  .decryptBytes(encrypt.Encrypted(chunk), iv: currentIV),
            );

            outSink.add(decryptedBytes);
            currentIV = encrypt.IV(chunk.sublist(chunk.length - ivLength));
            bytesRemaining -= chunk.length;
          }

          await outSink.flush();
          hmacSink.close();
          final computedMac = hmacAcc.events.single.bytes;
          final macBytesBuffer = inputStream.readBytes(macLength);
          final macBytes = macBytesBuffer.toUint8List();

          if (!constantTimeEquals(macBytes, computedMac)) {
            AppLogger.error('HMAC verification failed for $fileName');
            throw Exception('Incorrect password or corrupted file.');
          }

          await outSink.close();
          AppLogger.info('Decryption complete for $fileName');
        } catch (e) {
          if (outSink != null) await outSink.close();
          if (await outFile.exists()) await outFile.delete();
          AppLogger.error('Decryption failed for ${file.name}: $e');
          rethrow;
        }
      }
      inFile.close();
    }
  }

  static Future<void> decryptFilesSafe(List<String> zipPaths, String password, String outputDir) async {
    final receivePort = ReceivePort();
    try {
      await Isolate.spawn(_decryptInIsolate, [receivePort.sendPort, zipPaths, password, outputDir]);
      final result = await receivePort.first;
      if (result is String) throw Exception(result);
    } finally {
      receivePort.close();
    }
  }
}

// Isolate helpers -----------------------------------------------------
void _decryptInIsolate(List<dynamic> message) async {
  final sendPort = message[0] as SendPort;
  final filePaths = message[1] as List<String>;
  final password = message[2] as String;
  final outputDir = message[3] as String;

  try {
    await FileCryptoManager.decryptFiles(filePaths, password, outputDir);
    sendPort.send(true);
  } catch (e) {
    sendPort.send(e.toString());
  }
}

void _encryptInIsolate(List<dynamic> message) async {
  final sendPort = message[0] as SendPort;
  final filePaths = message[1] as List<String>;
  final files = filePaths.map((p) => File(p)).toList();

  try {
    final result = await FileCryptoManager.encryptFiles(files);
    sendPort.send({
      'zipPaths': result['zipPaths'],
      'password': result['password'],
      'tempDirPath': result['tempDir'],
    });
  } catch (e) {
    sendPort.send(e.toString());
  }
}
