import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'crypto_util.dart';
import 'messages.dart';

typedef HostProgress = void Function(double progress);

class HostException extends AppException {
  HostException(super.template, [super.args]);
}

/// One uploaded part of a delivery, as stored (encrypted) in sync.json.
class HostedPart {
  final String host; // FileHost.id
  final String url;
  final int size; // bytes of the uploaded part file
  final String sha256;
  final DateTime? expires;

  HostedPart({required this.host, required this.url, required this.size, required this.sha256, this.expires});

  Map<String, dynamic> toJson() => {
        'host': host,
        'url': url,
        'size': size,
        'sha256': sha256,
        if (expires != null) 'expires': expires!.millisecondsSinceEpoch ~/ 1000,
      };

  static HostedPart fromJson(Map json) => HostedPart(
        host: json['host'] as String,
        url: json['url'] as String,
        size: json['size'] as int,
        sha256: json['sha256'] as String,
        expires: json['expires'] is int
            ? DateTime.fromMillisecondsSinceEpoch((json['expires'] as int) * 1000)
            : null,
      );
}

/// A file sharing service that accepts anonymous uploads.
///
/// All traffic goes through the HttpClient handed in (Tor in the app). Each
/// host only accepts download links on its own domains, so a manipulated
/// entry cannot make clients fetch arbitrary addresses.
abstract class FileHost {
  String get id;
  String get label;
  int get maxBytes;

  /// How long the host keeps files at most.
  Duration get maxRetention;

  /// Domains download links may point to.
  List<String> get linkHosts;

  Future<HostedPart> upload(HttpClient client, File file, String name, Duration lifetime,
      {HostProgress? onProgress});

  Future<void> download(HttpClient client, HostedPart part, File target, {HostProgress? onProgress}) async {
    final uri = checkLink(part.url);
    final req = await client.getUrl(uri);
    prepareDownload(req);
    final res = await req.close();
    await saveResponse(res, target, part.size, onProgress);
  }

  /// Best effort; most anonymous hosts cannot delete.
  Future<void> delete(HttpClient client, HostedPart part) async {}

  void prepareDownload(HttpClientRequest req) {}

  Uri checkLink(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'https' && !_allowHttp) || !linkHosts.contains(uri.host)) {
      throw HostException('A download link points to an unexpected address.');
    }
    return uri;
  }

  bool get _allowHttp => false;

  static Future<void> saveResponse(
      HttpClientResponse res, File target, int expectedSize, HostProgress? onProgress) async {
    if (res.statusCode == 404 || res.statusCode == 410) {
      await res.drain<void>();
      throw HostException('The file is no longer available at the hosting service.');
    }
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw HostException('The hosting service answered with {status}.', {'status': res.statusCode});
    }
    final sink = target.openWrite();
    var received = 0;
    try {
      await for (final chunk in res) {
        received += chunk.length;
        if (received > expectedSize) throw HostException('A downloaded part is larger than expected.');
        sink.add(chunk);
        if (expectedSize > 0) onProgress?.call(received / expectedSize);
      }
    } finally {
      await sink.close();
    }
  }
}

/// Uploads [file] as the body of [req] with progress.
Future<HttpClientResponse> _sendFile(HttpClientRequest req, File file, int total,
    {List<int> prefix = const [], List<int> suffix = const [], HostProgress? onProgress}) async {
  req.contentLength = prefix.length + total + suffix.length;
  req.add(prefix);
  var sent = 0;
  await for (final chunk in file.openRead()) {
    req.add(chunk);
    sent += chunk.length;
    onProgress?.call(total == 0 ? 1 : sent / total);
    await req.flush();
  }
  req.add(suffix);
  return req.close();
}

/// multipart/form-data with text fields followed by one file field.
Future<HttpClientResponse> _postMultipart(HttpClient client, Uri uri, Map<String, String> fields,
    String fileField, String fileName, File file, {HostProgress? onProgress}) async {
  final boundary = '----redcourier${randomHex(12)}';
  final head = StringBuffer();
  fields.forEach((k, v) {
    head
      ..write('--$boundary\r\n')
      ..write('Content-Disposition: form-data; name="$k"\r\n\r\n')
      ..write('$v\r\n');
  });
  head
    ..write('--$boundary\r\n')
    ..write('Content-Disposition: form-data; name="$fileField"; filename="$fileName"\r\n')
    ..write('Content-Type: application/zip\r\n\r\n');
  final req = await client.postUrl(uri);
  req.headers.contentType = ContentType('multipart', 'form-data', parameters: {'boundary': boundary});
  return _sendFile(req, file, await file.length(),
      prefix: utf8.encode(head.toString()), suffix: utf8.encode('\r\n--$boundary--\r\n'), onProgress: onProgress);
}

Future<String> _readText(HttpClientResponse res, {int limit = 64 * 1024}) async {
  final bytes = <int>[];
  await for (final chunk in res) {
    bytes.addAll(chunk);
    if (bytes.length > limit) break;
  }
  return utf8.decode(bytes, allowMalformed: true);
}

Future<String> _sha256File(File f) async => sha256HexOfStream(f.openRead());

/// filebin.net: POST the raw body to /{bin}/{file}; bins expire after about
/// a week. Anyone who knows a bin's address may delete it.
class FilebinHost extends FileHost {
  final Uri base;
  FilebinHost({Uri? base}) : base = base ?? Uri.parse('https://filebin.net/');

  @override
  String get id => 'filebin';
  @override
  String get label => 'filebin.net';
  @override
  int get maxBytes => 500 * 1024 * 1024;
  @override
  Duration get maxRetention => const Duration(days: 6);
  @override
  List<String> get linkHosts => [base.host];
  @override
  bool get _allowHttp => base.scheme == 'http';

  @override
  Future<HostedPart> upload(HttpClient client, File file, String name, Duration lifetime,
      {HostProgress? onProgress}) async {
    final uri = base.resolve('${randomHex(12)}/$name');
    final req = await client.postUrl(uri);
    req.headers.contentType = ContentType.binary;
    final sha = await _sha256File(file);
    req.headers.set('Content-SHA256', sha);
    final res = await _sendFile(req, file, await file.length(), onProgress: onProgress);
    final body = await _readText(res);
    if (res.statusCode != 201) {
      throw HostException('Upload to {host} failed ({status}).', {'host': label, 'status': res.statusCode});
    }
    DateTime? expires;
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      expires = DateTime.tryParse(((json['bin'] as Map)['expired_at'] as String?) ?? '');
    } catch (_) {}
    return HostedPart(host: id, url: uri.toString(), size: await file.length(), sha256: sha, expires: expires);
  }

  @override
  void prepareDownload(HttpClientRequest req) {
    req.headers.set(HttpHeaders.acceptHeader, 'application/octet-stream');
    // The web page shows a warning first; this cookie confirms it.
    req.headers.set(HttpHeaders.cookieHeader, 'verified=2024-05-24');
  }

  @override
  Future<void> delete(HttpClient client, HostedPart part) async {
    final uri = checkLink(part.url);
    // Links are <base>/<bin>/<file>; deleting <base>/<bin> removes the bin.
    final baseSegments = base.pathSegments.where((s) => s.isNotEmpty).length;
    final rel = uri.pathSegments.skip(baseSegments).toList();
    if (rel.length != 2 || rel.first.isEmpty) return;
    final req = await client.deleteUrl(base.resolve(rel.first));
    await (await req.close()).drain<void>();
  }
}

/// temp.sh: multipart upload of field "file", files expire after 3 days.
class TempShHost extends FileHost {
  final Uri base;
  TempShHost({Uri? base}) : base = base ?? Uri.parse('https://temp.sh/');

  @override
  String get id => 'tempsh';
  @override
  String get label => 'temp.sh';
  @override
  int get maxBytes => 4 * 1024 * 1024 * 1024;
  @override
  Duration get maxRetention => const Duration(days: 3);
  @override
  List<String> get linkHosts => [base.host];
  @override
  bool get _allowHttp => base.scheme == 'http';

  @override
  Future<HostedPart> upload(HttpClient client, File file, String name, Duration lifetime,
      {HostProgress? onProgress}) async {
    final res = await _postMultipart(client, base.resolve('upload'), const {}, 'file', name, file,
        onProgress: onProgress);
    final url = (await _readText(res)).trim();
    if (res.statusCode != 200 || !url.startsWith('http')) {
      throw HostException('Upload to {host} failed ({status}).', {'host': label, 'status': res.statusCode});
    }
    checkLink(url);
    return HostedPart(
        host: id,
        url: url,
        size: await file.length(),
        sha256: await _sha256File(file),
        expires: DateTime.now().add(maxRetention));
  }

  /// temp.sh links open a page; the file itself is returned for a POST.
  @override
  Future<void> download(HttpClient client, HostedPart part, File target, {HostProgress? onProgress}) async {
    final uri = checkLink(part.url);
    var res = await (await client.getUrl(uri)).close();
    final html = res.headers.contentType?.mimeType == 'text/html';
    if (html) {
      await res.drain<void>();
      final req = await client.postUrl(uri);
      req.contentLength = 0;
      res = await req.close();
    }
    await FileHost.saveResponse(res, target, part.size, onProgress);
  }
}

/// litterbox.catbox.moe: temporary uploads for 1 to 72 hours, up to 1 GB.
class LitterboxHost extends FileHost {
  final Uri api;
  final List<String> _links;
  LitterboxHost({Uri? api, List<String>? linkHosts})
      : api = api ?? Uri.parse('https://litterbox.catbox.moe/resources/internals/api.php'),
        _links = linkHosts ?? const ['litter.catbox.moe', 'files.catbox.moe'];

  @override
  String get id => 'litterbox';
  @override
  String get label => 'litterbox.catbox.moe';
  @override
  int get maxBytes => 1000 * 1000 * 1000;
  @override
  Duration get maxRetention => const Duration(hours: 72);
  @override
  List<String> get linkHosts => _links;
  @override
  bool get _allowHttp => api.scheme == 'http';

  static String _time(Duration lifetime) {
    if (lifetime <= const Duration(hours: 1)) return '1h';
    if (lifetime <= const Duration(hours: 12)) return '12h';
    if (lifetime <= const Duration(hours: 24)) return '24h';
    return '72h';
  }

  @override
  Future<HostedPart> upload(HttpClient client, File file, String name, Duration lifetime,
      {HostProgress? onProgress}) async {
    final time = _time(lifetime);
    final res = await _postMultipart(
        client, api, {'reqtype': 'fileupload', 'time': time}, 'fileToUpload', name, file,
        onProgress: onProgress);
    final url = (await _readText(res)).trim();
    if (res.statusCode != 200 || !url.startsWith('http')) {
      throw HostException('Upload to {host} failed ({status}).', {'host': label, 'status': res.statusCode});
    }
    checkLink(url);
    final hours = int.parse(time.substring(0, time.length - 1));
    return HostedPart(
        host: id,
        url: url,
        size: await file.length(),
        sha256: await _sha256File(file),
        expires: DateTime.now().add(Duration(hours: hours)));
  }
}

/// Sends bytes over a raw TCP connection and returns the reply (Tor in the app).
typedef TcpExchange = Future<List<int>> Function(String host, int port, List<int> data);

/// termbin.com: a netcat pastebin (send text to port 9999, get a link back).
/// It stores text only and accepts about 32 KB, so parts are base64 encoded
/// and kept small. Pastes are deleted after one week.
class TermbinHost extends FileHost {
  final TcpExchange tcp;
  final String server;
  final int port;
  final List<String> _links;
  final bool _http;

  TermbinHost({required this.tcp, this.server = 'termbin.com', this.port = 9999,
      List<String>? linkHosts, bool allowHttpForTests = false})
      : _links = linkHosts ?? const ['termbin.com'],
        _http = allowHttpForTests;

  @override
  String get id => 'termbin';
  @override
  String get label => 'termbin.com';

  /// Raw part size; base64 of it plus a newline stays below 32 KB.
  @override
  int get maxBytes => 24000;
  @override
  Duration get maxRetention => const Duration(days: 6);
  @override
  List<String> get linkHosts => _links;
  @override
  bool get _allowHttp => _http;

  @override
  Future<HostedPart> upload(HttpClient client, File file, String name, Duration lifetime,
      {HostProgress? onProgress}) async {
    final bytes = await file.readAsBytes();
    if (bytes.length > maxBytes) throw HostException('The part is too large for {host}.', {'host': label});
    onProgress?.call(0);
    final reply = await tcp(server, port, utf8.encode('${base64.encode(bytes)}\n'));
    onProgress?.call(1);
    final url = utf8.decode(reply, allowMalformed: true).replaceAll('\u0000', '').trim();
    if (!url.startsWith('http')) {
      throw HostException('{host} answered with an unexpected reply.', {'host': label});
    }
    checkLink(url);
    return HostedPart(
        host: id,
        url: url,
        size: bytes.length,
        sha256: sha256Hex(bytes),
        expires: DateTime.now().add(const Duration(days: 7)));
  }

  @override
  Future<void> download(HttpClient client, HostedPart part, File target, {HostProgress? onProgress}) async {
    final uri = checkLink(part.url);
    final res = await (await client.getUrl(uri)).close();
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw HostException(res.statusCode == 404
          ? 'The file is no longer available at the hosting service.'
          : 'The hosting service answered with {status}.', {'status': res.statusCode});
    }
    final text = (await _readText(res, limit: 64 * 1024)).trim();
    final List<int> bytes;
    try {
      bytes = base64.decode(text);
    } on FormatException {
      throw HostException('A downloaded part is not a RedCourier part.');
    }
    await target.writeAsBytes(bytes, flush: true);
    onProgress?.call(1);
  }
}

/// The hosts RedCourier uses, in the default order. termbin needs a raw TCP
/// connection and is only added when [tcp] is given.
List<FileHost> defaultHosts({TcpExchange? tcp}) => [
      FilebinHost(),
      TempShHost(),
      LitterboxHost(),
      if (tcp != null) TermbinHost(tcp: tcp),
    ];
