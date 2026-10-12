import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'blob_crypto.dart';
import 'crypto_util.dart';
import 'messages.dart';

/// Packing of a delivery for the file sharing hosts:
///
///   files ──zip──▶ payload.zip ──encrypt (BlobCrypto)──▶ payload.rcb
///   payload.rcb ──split──▶ part 1..n, each wrapped in its own ZIP
///
/// and the reverse on download. The hosts only ever see encrypted data in
/// ZIPs with random names.
class Delivery {
  static const partEntryName = 'redcourier.part';
  static const defaultPartSize = 256 * 1024 * 1024;

  /// Zips [paths] into [zipPath]. Equal file names get a suffix.
  static Future<void> zipFiles(List<String> paths, String zipPath) => Isolate.run(() async {
        final enc = ZipFileEncoder()..create(zipPath, level: ZipFileEncoder.gzip);
        final used = <String>{};
        for (final path in paths) {
          var name = p.basename(path);
          final base = p.basenameWithoutExtension(name), ext = p.extension(name);
          for (var i = 2; !used.add(name.toLowerCase()); i++) {
            name = '$base ($i)$ext';
          }
          await enc.addFile(File(path), name);
        }
        await enc.close();
      });

  /// Wraps [length] bytes of [blobPath] starting at [offset] into a part ZIP
  /// with a random name in [work]. Returns its path.
  static Future<String> makePart(String blobPath, int offset, int length, Directory work) =>
      Isolate.run(() async {
        final raw = File(p.join(work.path, 'raw_${randomHex(6)}'));
        final input = await File(blobPath).open();
        final out = await raw.open(mode: FileMode.write);
        try {
          await input.setPosition(offset);
          var left = length;
          while (left > 0) {
            final chunk = await input.read(left.clamp(0, 4 * 1024 * 1024));
            if (chunk.isEmpty) break;
            await out.writeFrom(chunk);
            left -= chunk.length;
          }
        } finally {
          await input.close();
          await out.close();
        }
        final zipPath = p.join(work.path, '${randomHex(16)}.zip');
        final enc = ZipFileEncoder()..create(zipPath, level: ZipFileEncoder.store);
        await enc.addFile(raw, partEntryName);
        await enc.close();
        await raw.delete();
        return zipPath;
      });

  /// ZIP overhead of a part (headers, one entry); parts must fit the host limit.
  static const zipOverhead = 512;

  /// Appends the payload stored in the part ZIP [partZip] to [blobPath].
  static Future<void> appendPart(String partZip, String blobPath) => Isolate.run(() async {
        final input = InputFileStream(partZip);
        try {
          final archive = ZipDecoder().decodeStream(input);
          final entry = archive.files.where((f) => f.isFile && f.name == partEntryName).toList();
          if (entry.length != 1) throw AppException('A downloaded part is not a RedCourier part.');
          final tmp = '$blobPath.piece';
          final out = OutputFileStream(tmp);
          entry.single.writeContent(out);
          await out.close();
          final sink = File(blobPath).openWrite(mode: FileMode.append);
          await sink.addStream(File(tmp).openRead());
          await sink.close();
          await File(tmp).delete();
        } finally {
          await input.close();
        }
      });

  /// Unpacks the decrypted payload ZIP into [targetDir] with safe names.
  /// Returns the written file paths.
  static Future<List<String>> unzipPayload(String zipPath, String targetDir) => Isolate.run(() async {
        await Directory(targetDir).create(recursive: true);
        final input = InputFileStream(zipPath);
        final written = <String>[];
        try {
          final archive = ZipDecoder().decodeStream(input);
          for (final entry in archive.files) {
            if (!entry.isFile || entry.isSymbolicLink) continue;
            final name = safeFileName(p.basename(entry.name.replaceAll('\\', '/')));
            var target = p.join(targetDir, name);
            final base = p.basenameWithoutExtension(name), ext = p.extension(name);
            for (var i = 2; File(target).existsSync(); i++) {
              target = p.join(targetDir, '$base ($i)$ext');
            }
            final out = OutputFileStream(target);
            entry.writeContent(out);
            await out.close();
            written.add(target);
          }
        } finally {
          await input.close();
        }
        return written;
      });

  static Future<void> encrypt(String zipPath, String blobPath, Uint8List key, String payloadId) =>
      BlobCrypto.encryptFileInBackground(zipPath, blobPath, key, payloadId);

  static Future<void> decrypt(String blobPath, String zipPath, Uint8List key, String payloadId) =>
      BlobCrypto.decryptFileInBackground(blobPath, zipPath, key, payloadId);

  /// File names come from other users: strip directories and odd characters.
  static String safeFileName(String name) {
    var n = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
    n = n.replaceAll(RegExp(r'^\.+'), '');
    if (n.isEmpty) n = 'file';
    return n.length > 120 ? n.substring(n.length - 120) : n;
  }
}
