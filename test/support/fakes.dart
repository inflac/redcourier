import 'dart:io';
import 'dart:typed_data';

import 'package:redcourier/app_controller.dart';
import 'package:redcourier/core/crypto_util.dart';
import 'package:redcourier/core/group.dart';
import 'package:redcourier/core/hosts.dart';
import 'package:redcourier/core/remote.dart';

/// File host that keeps everything in memory.
class MemHost extends FileHost {
  static final files = <String, Uint8List>{};
  @override
  final String id;
  MemHost(this.id);

  @override
  String get label => id;
  @override
  int get maxBytes => 1024 * 1024;
  @override
  Duration get maxRetention => const Duration(days: 6);
  @override
  List<String> get linkHosts => ['$id.test'];

  @override
  Future<HostedPart> upload(HttpClient client, File file, String name, Duration lifetime,
      {HostProgress? onProgress}) async {
    final bytes = await file.readAsBytes();
    final url = 'https://$id.test/${randomHex(8)}/$name';
    files[url] = bytes;
    onProgress?.call(1);
    return HostedPart(host: id, url: url, size: bytes.length, sha256: sha256Hex(bytes));
  }

  @override
  Future<void> download(HttpClient client, HostedPart part, File target, {HostProgress? onProgress}) async {
    final data = files[part.url];
    if (data == null) throw HostException('The file is no longer available at the hosting service.');
    await target.writeAsBytes(data);
    onProgress?.call(1);
  }

  @override
  Future<void> delete(HttpClient client, HostedPart part) async => files.remove(part.url);
}

/// WebDAV folders by URL, shared by all controllers of a test ("the server").
class MemDav {
  final folders = <String, MemoryStore>{};
}

AppController testController(MemDav dav, Directory dir) => AppController(
      storeFactory: (config) => dav.folders.putIfAbsent(config().url, MemoryStore.new),
      hostingFactory: (_) => Hosting([MemHost('hosta'), MemHost('hostb')], () async => HttpClient()),
    );
