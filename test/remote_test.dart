import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:redcourier/core/identity.dart';
import 'package:redcourier/core/remote.dart';

/// Minimal WebDAV folder with ETags, like Nextcloud.
class FakeDav {
  final HttpServer server;
  Uint8List? file;
  int rev = 0;
  int? forceStatus;
  final auth = <String?>[];
  FakeDav(this.server) {
    server.listen(_handle);
  }
  String get etag => '"$rev"';
  String get url => 'http://127.0.0.1:${server.port}/dav/group';

  Future<void> _handle(HttpRequest r) async {
    final body = await r.fold<List<int>>([], (a, b) => a..addAll(b));
    auth.add(r.headers.value(HttpHeaders.authorizationHeader));
    final res = r.response;
    if (forceStatus != null) {
      res.statusCode = forceStatus!;
    } else if (r.uri.path != '/dav/group/sync.json') {
      res.statusCode = 404;
    } else if (r.method == 'GET') {
      if (file == null) {
        res.statusCode = 404;
      } else {
        res.headers.set(HttpHeaders.etagHeader, etag);
        res.add(file!);
      }
    } else if (r.method == 'PUT') {
      final ifMatch = r.headers.value('If-Match');
      final ifNone = r.headers.value('If-None-Match');
      if ((ifNone == '*' && file != null) || (ifMatch != null && ifMatch != etag)) {
        res.statusCode = 412;
      } else {
        res.statusCode = file == null ? 201 : 204;
        file = Uint8List.fromList(body);
        rev++;
      }
    }
    await res.close();
  }
}

void main() {
  late FakeDav dav;
  late WebDavStore store;
  var cfg = WebDavConfig('', 'user', 'pw');

  setUp(() async {
    dav = FakeDav(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    cfg = WebDavConfig(dav.url, 'user', 'pw');
    store = WebDavStore(() => cfg, clientFactory: () async => HttpClient());
  });

  tearDown(() => dav.server.close(force: true));

  test('missing file, create, read with ETag, conditional update', () async {
    expect(await store.getSync(), isNull);
    await store.putSync(Uint8List.fromList(utf8.encode('v1')), createOnly: true);
    final f = await store.getSync();
    expect(utf8.decode(f!.bytes), 'v1');
    expect(f.etag, '"1"');

    await expectLater(store.putSync(Uint8List.fromList([1]), createOnly: true), throwsA(isA<ConflictException>()));
    await store.putSync(Uint8List.fromList(utf8.encode('v2')), ifMatch: f.etag);
    await expectLater(store.putSync(Uint8List.fromList([1]), ifMatch: f.etag), throwsA(isA<ConflictException>()));
    expect(utf8.decode((await store.getSync())!.bytes), 'v2');
    expect(dav.auth.last, 'Basic ${base64.encode(utf8.encode('user:pw'))}');
  });

  test('updated credentials apply to the next request', () async {
    await store.getSync();
    cfg = WebDavConfig(dav.url, 'user', 'new');
    await store.getSync();
    expect(dav.auth.last, 'Basic ${base64.encode(utf8.encode('user:new'))}');
  });

  test('server errors become readable messages', () async {
    for (final (status, text) in [
      (401, 'login failed'),
      (403, 'Access denied'),
      (404, 'Not found'),
      (507, 'Storage is full'),
      (500, 'Unexpected server response'),
    ]) {
      dav.forceStatus = status;
      if (status != 404) {
        await expectLater(store.getSync(),
            throwsA(isA<RemoteException>().having((e) => e.message, 'message', contains(text))));
      }
      await expectLater(store.putSync(Uint8List.fromList([1])),
          throwsA(isA<RemoteException>().having((e) => e.message, 'message', contains(text))));
    }
  });

  test('connection problems become RemoteException', () async {
    final port = dav.server.port;
    await dav.server.close(force: true);
    cfg = WebDavConfig('http://127.0.0.1:$port/dav/group', 'user', 'pw');
    await expectLater(store.getSync(), throwsA(isA<RemoteException>()));
  });

  test('memory store has the same semantics', () async {
    final m = MemoryStore();
    expect(await m.getSync(), isNull);
    await m.putSync(Uint8List.fromList([1]), createOnly: true);
    await expectLater(m.putSync(Uint8List.fromList([2]), createOnly: true), throwsA(isA<ConflictException>()));
    await expectLater(m.putSync(Uint8List.fromList([2]), ifMatch: '"0"'), throwsA(isA<ConflictException>()));
    await m.putSync(Uint8List.fromList([2]), ifMatch: m.etag);
    expect((await m.getSync())!.bytes, [2]);
  });
}
