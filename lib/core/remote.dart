import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'identity.dart';
import 'messages.dart';

typedef HttpClientFactory = Future<HttpClient> Function();

class RemoteException extends AppException {
  RemoteException(super.template, [super.args]);
}

/// Someone else wrote sync.json since we read it (HTTP 412).
class ConflictException extends RemoteException {
  ConflictException() : super('sync.json was changed by someone else.');
}

class RemoteFile {
  final Uint8List bytes;
  final String? etag;
  RemoteFile(this.bytes, this.etag);
}

/// Storage backend of a group: only sync.json. The files themselves are
/// uploaded to file sharing hosts (see hosts.dart).
abstract class RemoteStore {
  /// Returns null if sync.json does not exist yet.
  Future<RemoteFile?> getSync();

  /// Writes sync.json. With [ifMatch] the write only succeeds if the file is
  /// unchanged; with [createOnly] only if it does not exist yet.
  /// Throws [ConflictException] otherwise.
  Future<void> putSync(Uint8List bytes, {String? ifMatch, bool createOnly = false});
}

class WebDavStore implements RemoteStore {
  static const syncFileName = 'sync.json';

  /// Read on every request, so updated credentials apply immediately.
  final WebDavConfig Function() configProvider;
  final HttpClientFactory clientFactory;

  WebDavStore(this.configProvider, {required this.clientFactory});

  WebDavConfig get config => configProvider();

  /// Through Tor, building a circuit and the TLS handshake can take a while.
  static const _replyTimeout = Duration(seconds: 120);

  Uri get _base => Uri.parse(config.url);
  Uri get _syncUri => _base.resolve(syncFileName);
  String get _auth =>
      'Basic ${base64.encode(utf8.encode('${config.username}:${config.password}'))}';

  Future<HttpClient> _client() async {
    final c = await clientFactory();
    c.connectionTimeout = const Duration(seconds: 60);
    c.userAgent = 'RedCourier';
    return c;
  }

  Future<HttpClientRequest> _open(HttpClient c, String method, Uri uri) async {
    final req = await c.openUrl(method, uri);
    req.headers.set(HttpHeaders.authorizationHeader, _auth);
    req.followRedirects = false;
    return req;
  }

  Never _fail(int status, String what) {
    switch (status) {
      case 401:
        throw RemoteException('WebDAV login failed (401). Check username and password.');
      case 403:
        throw RemoteException('Access denied (403) while {what}.', {'what': what});
      case 404:
        throw RemoteException('Not found (404) while {what}. Check the folder URL.', {'what': what});
      case 507:
        throw RemoteException('Storage is full (507) while {what}.', {'what': what});
      default:
        throw RemoteException('Unexpected server response ({status}) while {what}.', {'status': status, 'what': what});
    }
  }

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on SocketException catch (e) {
      throw RemoteException('Connection failed: {reason}', {'reason': e.message});
    } on HandshakeException {
      throw RemoteException('TLS handshake failed. Check the URL and certificate.');
    } on HttpException catch (e) {
      throw RemoteException('HTTP error: {reason}', {'reason': e.message});
    } on TimeoutException {
      throw RemoteException('Connection timed out.');
    }
  }

  @override
  Future<RemoteFile?> getSync() => _guard(() async {
        final c = await _client();
        try {
          final req = await _open(c, 'GET', _syncUri);
          req.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
          final res = await req.close().timeout(_replyTimeout);
          if (res.statusCode == 404) {
            await res.drain<void>();
            return null;
          }
          if (res.statusCode != 200) {
            await res.drain<void>();
            _fail(res.statusCode, 'downloading sync.json');
          }
          final builder = BytesBuilder(copy: false);
          await for (final chunk in res) {
            builder.add(chunk);
          }
          return RemoteFile(builder.takeBytes(), res.headers.value(HttpHeaders.etagHeader));
        } finally {
          c.close(force: true);
        }
      });

  @override
  Future<void> putSync(Uint8List bytes, {String? ifMatch, bool createOnly = false}) =>
      _guard(() async {
        final c = await _client();
        try {
          final req = await _open(c, 'PUT', _syncUri);
          req.headers.contentType = ContentType.json;
          req.contentLength = bytes.length;
          if (ifMatch != null) req.headers.set('If-Match', ifMatch);
          if (createOnly) req.headers.set('If-None-Match', '*');
          req.add(bytes);
          final res = await req.close().timeout(_replyTimeout);
          await res.drain<void>();
          if (res.statusCode == 412) throw ConflictException();
          if (res.statusCode != 200 && res.statusCode != 201 && res.statusCode != 204) {
            _fail(res.statusCode, 'uploading sync.json');
          }
        } finally {
          c.close(force: true);
        }
      });

}

/// In-memory backend with the same ETag semantics, used by tests.
class MemoryStore implements RemoteStore {
  Uint8List? sync;
  int _rev = 0;

  String? get etag => sync == null ? null : '"$_rev"';

  @override
  Future<RemoteFile?> getSync() async =>
      sync == null ? null : RemoteFile(Uint8List.fromList(sync!), etag);

  @override
  Future<void> putSync(Uint8List bytes, {String? ifMatch, bool createOnly = false}) async {
    if (createOnly && sync != null) throw ConflictException();
    if (ifMatch != null && ifMatch != etag) throw ConflictException();
    sync = Uint8List.fromList(bytes);
    _rev++;
  }
}
