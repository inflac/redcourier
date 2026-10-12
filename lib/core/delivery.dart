import 'dart:async';
import 'dart:convert';
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
///   files ──container + encrypt (streamed)──▶ payload.rcb
///   payload.rcb ──split──▶ part 1..n, each wrapped in its own ZIP
///
/// and the reverse on download. No plaintext copy of the files is written on
/// the way: the files are read from where the user keeps them and encrypted
/// as they are read; on the receiving side they are decrypted straight into
/// the folder the user chooses. The hosts only ever see encrypted data in
/// ZIPs with random names.
///
/// Container inside the encryption (format "rcp1"):
///   "RCP1" | file count u32 | per file: name length u16 | UTF-8 name |
///   size u64 | bytes
class Delivery {
  static const partEntryName = 'redcourier.part';
  static const defaultPartSize = 256 * 1024 * 1024;

  static const payloadFormat = 'rcp1';
  static const _containerMagic = [0x52, 0x43, 0x50, 0x31]; // "RCP1"
  static const maxFileNameBytes = 1024;

  /// Encrypts [paths] into the blob [blobPath] without any plaintext copy.
  static Future<void> packEncrypted(List<String> paths, String blobPath, Uint8List key, String payloadId) =>
      Isolate.run(() => BlobCrypto.encryptStream(_container(paths), blobPath, key, payloadId));

  static Stream<List<int>> _container(List<String> paths) async* {
    yield [..._containerMagic, ..._uint(paths.length, 4)];
    for (final path in paths) {
      final file = File(path);
      final size = await file.length();
      final name = utf8.encode(p.basename(path));
      if (name.length > maxFileNameBytes) throw AppException('A file name is too long.');
      yield [..._uint(name.length, 2), ...name, ..._uint(size, 8)];
      var sent = 0;
      await for (final chunk in file.openRead()) {
        sent += chunk.length;
        if (sent > size) break;
        yield chunk;
      }
      if (sent != size) {
        throw AppException('{name} changed while it was being sent.', {'name': p.basename(path)});
      }
    }
  }

  static List<int> _uint(int v, int bytes) => [for (var i = bytes - 1; i >= 0; i--) (v >> (8 * i)) & 0xff];

  /// Decrypts the blob straight into [targetDir] (created if needed) and
  /// returns the written files. Names are made safe and unique. If the blob
  /// turns out to be damaged or forged, everything written is deleted again.
  static Future<List<String>> unpackEncrypted(String blobPath, Uint8List key, String payloadId, String targetDir) =>
      Isolate.run(() => _unpack(blobPath, key, payloadId, targetDir));

  static Future<List<String>> _unpack(String blobPath, Uint8List key, String payloadId, String targetDir) async {
    final dir = Directory(targetDir);
    final createdDir = !await dir.exists();
    await dir.create(recursive: true);
    final written = <String>[];
    final reader = _Reader(BlobCrypto.decryptStream(blobPath, key, payloadId));
    try {
      final magic = await reader.read(4);
      for (var i = 0; i < 4; i++) {
        if (magic[i] != _containerMagic[i]) throw AppException('A downloaded part is not a RedCourier part.');
      }
      final count = _readUint(await reader.read(4));
      for (var n = 0; n < count; n++) {
        final nameLength = _readUint(await reader.read(2));
        if (nameLength > maxFileNameBytes) throw AppException('A file name is too long.');
        final name = safeFileName(p.basename(utf8.decode(await reader.read(nameLength), allowMalformed: true)
            .replaceAll('\\', '/')));
        final size = _readUint(await reader.read(8));
        var target = p.join(targetDir, name);
        final base = p.basenameWithoutExtension(name), ext = p.extension(name);
        for (var i = 2; await File(target).exists(); i++) {
          target = p.join(targetDir, '$base ($i)$ext');
        }
        written.add(target);
        final out = File(target).openWrite();
        try {
          await reader.copyTo(out, size);
        } finally {
          await out.close();
        }
      }
      if (!await reader.atEnd()) throw AppException('A downloaded part is not a RedCourier part.');
      return written;
    } catch (_) {
      for (final f in written) {
        try {
          await File(f).delete();
        } catch (_) {}
      }
      if (createdDir) {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
      rethrow;
    }
  }

  static int _readUint(List<int> bytes) => bytes.fold(0, (v, b) => (v << 8) | b);

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

  /// File names come from other users: strip directories and odd characters.
  static String safeFileName(String name) {
    var n = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
    n = n.replaceAll(RegExp(r'^\.+'), '');
    if (n.isEmpty) n = 'file';
    return n.length > 120 ? n.substring(n.length - 120) : n;
  }
}

/// Reads exact byte counts from a stream of chunks.
class _Reader {
  final StreamIterator<Uint8List> _it;
  Uint8List _buf = Uint8List(0);
  int _pos = 0;
  _Reader(Stream<Uint8List> stream) : _it = StreamIterator(stream);

  Future<bool> _fill() async {
    if (_pos < _buf.length) return true;
    if (!await _it.moveNext()) return false;
    _buf = _it.current;
    _pos = 0;
    return true;
  }

  Future<List<int>> read(int n) async {
    final out = BytesBuilder(copy: false);
    while (out.length < n) {
      if (!await _fill()) throw AppException('A downloaded part is not a RedCourier part.');
      final take = (n - out.length).clamp(0, _buf.length - _pos);
      out.add(Uint8List.sublistView(_buf, _pos, _pos + take));
      _pos += take;
    }
    return out.takeBytes();
  }

  Future<void> copyTo(IOSink sink, int n) async {
    var left = n;
    while (left > 0) {
      if (!await _fill()) throw AppException('A downloaded part is not a RedCourier part.');
      final take = left.clamp(0, _buf.length - _pos);
      sink.add(Uint8List.sublistView(_buf, _pos, _pos + take));
      _pos += take;
      left -= take;
    }
  }

  /// True if nothing follows; reading to the end also checks the final chunk.
  Future<bool> atEnd() async => !await _fill();
}
